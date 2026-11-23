"""`doc-search check`: whether doc-search can answer for this worktree now, as a verdict a hook can gate on.

`assess` walks a fixed order (design: 2026-10-27-doc-search-readiness-gate-design.md), and the first row
that decides wins:

1. no config: `not-in-force`;
2. an invalid config: `not-ready` when its raw text says `"required": true`, else `not-in-force`;
3. the plugin below `requires`: `not-ready`;
3b. the plugin below the newest security release in the release notes on disk (`release_cache`; never
    fetched): `not-ready` with `security_floor`, else `degraded`, remembered; the fix is the upgrade either way;
4. the committed launcher copy absent, or below `requires`: `not-ready`; differing from the plugin's own
   but meeting the floor: `degraded`, remembered;
5. with a transformer docs model and no transformer index: the static fallback valid is `degraded`, stale
   is refreshed, absent is `not-ready`;
6. any static or code index absent: `not-ready` (no build here);
7. anything stale: when required, one refresh, bounded by the budget, then the cache states are read once
   more (with no transformer index the refresh runs on a static docs config: `check` never starts a first
   transformer build); when not required, no refresh: `not-in-force`, `not required here (stale: …)`;
8. required: the result stands;
9. not required: `not-in-force`, the reason naming the state it would have been;
10. `mcp` says, per client, whether this developer's client is expected to run the MCP server: the one client
    the hook names (`gate --client claude|codex`), or each of them when none is named.

Exit codes: 0 ready or degraded, 1 not-ready, 4 not-in-force (the CLI's 3 is usage).
"""

from __future__ import annotations

import dataclasses
import json
import re
import shlex
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from . import release_cache
from .config import CONFIG_REL, Config, ConfigError, load_config, parse_version
from .engines import Building, IndexPool
from .progress import read_progress
from .releases import newest_security, parse_releases
from .repo import GitError, git
from .version import launcher_stamp, plugin_root, plugin_version

State = Literal["ready", "degraded", "not-ready", "not-in-force"]
LauncherState = Literal["current", "differs", "below-floor", "absent"]
McpState = Literal["expected", "off", "not-registered"]
Client = Literal["claude", "codex"]

CLIENTS: tuple[Client, ...] = ("claude", "codex")
"""The clients whose MCP registration `check` reads: Claude Code (`.mcp.json`) and Codex (its `config.toml`s)."""

LAUNCHER_REL = ".claude/doc-superpowers/search-mcp.sh"
"""The launcher copy a project commits (install.sh install --search writes it)."""

INDEX_FIX = f"sh {LAUNCHER_REL} index"
PLUGIN_FIX = "claude plugin update doc-superpowers"
UPGRADE_FIX = "bash {install_sh} upgrade"
"""The fix for any install that is neither a Claude Code plugin nor a branch checkout (a release checkout, the
Codex root): the plugin's own `install.sh upgrade`, by its path (`_plugin_fix` renders it, quoted when the path
needs it)."""
PULL_FIX = "git -C {root} pull"
"""The fix for a checkout on a branch, which `install.sh upgrade` refuses (it follows its branch)."""
CONFIG_FIX = f"edit {CONFIG_REL}, then run sh {LAUNCHER_REL} check"
TRANSFORMER_NOT_BUILT = "transformer index not built"
"""Row 5's reason when nothing serves the docs: its fix, INDEX_FIX, is a first transformer build that takes hours,
so the session-start text gives it to the user (gate.py)."""

_EXITS: dict[str, int] = {"ready": 0, "degraded": 0, "not-ready": 1, "not-in-force": 4}
_REQUIRED_RE = re.compile(r'"required"\s*:\s*true')
_MCP_TABLE = "[mcp_servers.doc-search]"


@dataclass(frozen=True)
class Verdict:
    """What `check` says. `cache` is `{}` when the order stopped before the indexes were looked at."""

    state: State
    reason: str | None
    fix: str | None  # one command that would make it ready
    required: bool
    requires: str | None  # the floor as the config writes it, `>=X.Y.Z`
    version: str | None  # the running plugin's version
    launcher: LauncherState
    mcp: dict[str, McpState]  # per client: the one the hook named, or each of CLIENTS
    cache: dict[str, str | None]
    refreshed: bool

    def exit_code(self) -> int:
        return _EXITS[self.state]

    def line(self) -> str:
        """`doc-search: <state>[: <reason>][; run <fix>]`, on one line."""
        text = f"doc-search: {self.state.replace('-', ' ')}"
        if self.reason:
            text += f": {self.reason}"
        if self.fix:
            text += f"; run {self.fix}"
        return " ".join(text.split())


def config_says_required(top: Path) -> bool:
    """Whether `<top>/docs/search/config.json`'s raw text says `"required": true` (it may not parse)."""
    try:
        text = (Path(top) / CONFIG_REL).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return _REQUIRED_RE.search(text) is not None


def _raw_floor(top: Path) -> tuple[int, int, int] | None:
    """The `requires` floor from the raw JSON, or None when the file is absent, unparsable or has no valid floor."""
    try:
        raw = json.loads((Path(top) / CONFIG_REL).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    value = raw.get("requires") if isinstance(raw, dict) else None
    if isinstance(value, str) and value.startswith(">="):
        return parse_version(value[2:])
    return None


def mcp_line(mcp: Mapping[str, McpState]) -> str:
    """`claude=expected codex=not-registered`: each client's state, as the `mcp:` line shows it."""
    return " ".join(f"{client}={state}" for client, state in mcp.items())


def outside(env: Mapping[str, str], where: Path) -> Verdict:
    """The verdict outside a git work tree: not in force."""
    version = plugin_version(plugin_root())
    mcp = mcp_state(where, env)
    return _verdict("not-in-force", "not in a git work tree", None, False, None, "absent", version, mcp)


def assess(top: Path, *, budget_s: float, env: Mapping[str, str], client: Client | None = None) -> Verdict:
    """The verdict for the worktree at `top`. Only a required config refreshes stale indexes (for at most
    `budget_s` seconds); otherwise the would-be state comes from the cache states alone. `mcp` is `client`'s
    state, or each client's when it is None."""
    top = Path(top).resolve()
    mcp = mcp_state(top, env, client)
    version = plugin_version(plugin_root())
    try:
        cfg = load_config(top, env)
    except ConfigError as err:
        required = config_says_required(top)
        floor = _raw_floor(top)
        if floor is not None and (version is None or version < floor):
            # the floor first: a key this release does not know reads "plugin too old", not "invalid config"
            shown = _dotted(version) if version is not None else "(version unknown)"
            reason = f"doc-superpowers {shown} is below requires >={_dotted(floor)}"
            launcher = _launcher(top, None)[0]
            if not required:
                reason = f"not required here (not-ready: {reason})"
                return _verdict("not-in-force", reason, None, False, floor, launcher, version, mcp)
            return _verdict("not-ready", reason, _plugin_fix(env), True, floor, launcher, version, mcp)
        state: State = "not-ready" if required else "not-in-force"
        fix = CONFIG_FIX if required else None
        launcher = _launcher(top, None)[0]
        return _verdict(state, f"invalid config: {err}", fix, required, None, launcher, version, mcp)
    if cfg is None:
        return _verdict("not-in-force", f"no {CONFIG_REL}", None, False, None, _launcher(top, None)[0], version, mcp)

    launcher, launcher_reason = _launcher(top, cfg.requires)
    would = _would_be(top, cfg, launcher, launcher_reason, budget_s, version, env)
    if not cfg.required and would.state != "not-in-force":
        summary = would.state + (f": {would.reason}" if would.reason else "")
        would = dataclasses.replace(would, state="not-in-force", reason=f"not required here ({summary})")
    return dataclasses.replace(would, required=cfg.required, mcp=mcp)


def _verdict(
    state: State,
    reason: str | None,
    fix: str | None,
    required: bool,
    requires: tuple[int, int, int] | None,
    launcher: LauncherState,
    version: tuple[int, int, int] | None,
    mcp: dict[str, McpState] | None = None,
    cache: dict[str, str | None] | None = None,
    refreshed: bool = False,
) -> Verdict:
    return Verdict(
        state=state,
        reason=reason,
        fix=fix,
        required=required,
        requires=f">={_dotted(requires)}" if requires is not None else None,
        version=_dotted(version) if version is not None else None,
        launcher=launcher,
        mcp=mcp if mcp is not None else {},
        cache=cache if cache is not None else {},
        refreshed=refreshed,
    )


def _dotted(version: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in version)


def _would_be(
    top: Path,
    cfg: Config,
    launcher: LauncherState,
    launcher_reason: str | None,
    budget_s: float,
    version: tuple[int, int, int] | None,
    env: Mapping[str, str],
) -> Verdict:
    """Rows 3 to 7: the verdict as if the repository required doc-search. Row 7 refreshes only when it does:
    a stale index of a repository that does not require doc-search is reported, not refreshed. Row 3b's
    `security_floor` halt therefore holds only where `required` is true (assess turns the rest not-in-force)."""

    def verdict(
        state: State,
        reason: str | None,
        fix: str | None,
        cache: dict[str, str | None] | None = None,
        refreshed: bool = False,
    ) -> Verdict:
        floor = cfg.requires
        return _verdict(state, reason, fix, cfg.required, floor, launcher, version, cache=cache, refreshed=refreshed)

    if cfg.requires is not None and (version is None or version < cfg.requires):
        shown = _dotted(version) if version is not None else "(version unknown)"
        reason = f"doc-superpowers {shown} is below requires >={_dotted(cfg.requires)}"
        return verdict("not-ready", reason, _plugin_fix(env))
    security = _security(version, env)
    if security is not None and cfg.security_floor:
        return verdict("not-ready", security, _plugin_fix(env))
    if launcher in ("absent", "below-floor"):
        return verdict("not-ready", launcher_reason, _install_fix())
    degraded = [launcher_reason] if launcher == "differs" and launcher_reason else []
    fix = _install_fix() if degraded else None
    if security is not None:
        degraded.insert(0, security)
        fix = _plugin_fix(env)

    pool = IndexPool(cfg, fallback=False)
    cache = _cache(pool, top, cfg)
    problem, building, stale = _classify(cfg, cache)
    refreshed = False
    if problem is None and stale and not cfg.required:
        summary = f"stale: {', '.join(stale)} index stale"
        return verdict("not-in-force", f"not required here ({summary})", INDEX_FIX, cache=cache)
    if problem is None and stale:
        refreshed = True
        # No transformer index: the static config refreshes what is stale, so no first transformer build starts.
        no_transformer = cfg.docs.transformer is not None and cache["docs"] == "absent"
        refresh_cfg = _static_docs(cfg) if no_transformer else cfg
        got = (pool if refresh_cfg is cfg else IndexPool(refresh_cfg, fallback=False)).get(top, wait_s=budget_s)
        if isinstance(got, Building):
            problem = f"refresh did not finish within {budget_s:g}s"
        else:
            failed = [(kind, got.error.get(kind)) for kind in ("docs", "code") if got.error.get(kind)]
            if failed:
                problem = f"{failed[0][0]} index failed: {failed[0][1]}"
            else:
                cache = _cache(pool, top, cfg)
                problem, building, stale = _classify(cfg, cache)
                if problem is None and stale:
                    problem = f"{', '.join(stale)} index still stale after the refresh"
    if problem is not None:
        return verdict("not-ready", problem, INDEX_FIX, cache=cache, refreshed=refreshed)
    if building:
        degraded.insert(0, _building_reason(top))
    if degraded:
        return verdict("degraded", "; ".join(degraded), fix, cache=cache, refreshed=refreshed)
    return verdict("ready", None, None, cache=cache, refreshed=refreshed)


def _cache(pool: IndexPool, top: Path, cfg: Config) -> dict[str, str | None]:
    """The disk states, as `status` names them."""
    return {
        "docs": pool.cache_state(top, "docs"),
        "code": pool.cache_state(top, "code") if cfg.code.enabled else "off",
        "docs_fallback": pool.fallback_cache_state(top),
    }


def _classify(cfg: Config, cache: Mapping[str, str | None]) -> tuple[str | None, bool, list[str]]:
    """Rows 5 and 6: a not-ready reason (or None), whether the static fallback serves, and what is stale."""
    stale: list[str] = []
    building = False
    transformer = cfg.docs.transformer is not None
    if transformer and cache["docs"] == "absent":
        fallback = cache["docs_fallback"]
        if fallback == "absent":
            return TRANSFORMER_NOT_BUILT, False, []
        if fallback == "valid":
            building = True
        else:
            stale.append("static docs")
    for kind in ("docs", "code"):
        if cache[kind] == "absent" and not (transformer and kind == "docs"):
            return f"{kind} index absent", False, []
        if cache[kind] == "stale":
            stale.append(kind)
    return None, building, stale


def _static_docs(cfg: Config) -> Config:
    """`cfg` with semble's static docs model: the config the static fallback is refreshed with."""
    return dataclasses.replace(cfg, docs=dataclasses.replace(cfg.docs, model=None, transformer=None))


def _building_reason(top: Path) -> str:
    reason = "static index while the transformer index builds"
    progress = read_progress(top)
    return f"{reason} ({progress.line()})" if progress is not None else reason


def _launcher(top: Path, floor: tuple[int, int, int] | None) -> tuple[LauncherState, str | None]:
    """Row 4: the committed launcher copy against the floor and the plugin's own launcher."""
    copy = top / LAUNCHER_REL
    try:
        text = copy.read_bytes()
    except OSError:
        return "absent", f"launcher copy absent ({LAUNCHER_REL})"
    stamp = launcher_stamp(copy)
    if floor is not None:
        if stamp is None:
            return "below-floor", f"launcher copy has no version stamp (requires >={_dotted(floor)})"
        if stamp < floor:
            return "below-floor", f"launcher copy v{_dotted(stamp)} is below requires >={_dotted(floor)}"
    try:
        current = (plugin_root() / "scripts" / "search" / "launch.sh").read_bytes() == text
    except OSError:
        current = False
    return ("current", None) if current else ("differs", "launcher copy differs from the plugin's")


def _security(version: tuple[int, int, int] | None, env: Mapping[str, str]) -> str | None:
    """Row 3b: why the plugin is below the newest security release in the release notes on disk, naming where
    the notes came from; None when it is not (or its version is unknown, or no notes are found). Each source's
    newest security release is taken under that source's own ceiling, and the highest of them wins (the first
    source on a tie), so one source can never hide another's. Never fetches."""
    if version is None:
        return None
    best: tuple[tuple[int, int, int], release_cache.Source] | None = None
    for source in release_cache.load(env, plugin_root()):
        found = newest_security(parse_releases(source.text), ceiling=source.ceiling)
        if found is not None and (best is None or found > best[0]):
            best = (found, source)
    if best is None or version >= best[0]:
        return None
    newest, source = best
    meta, shown = source.meta, release_cache.safe
    return (
        f"doc-superpowers {_dotted(version)} is below security release {_dotted(newest)}"
        f" (release notes {shown(meta['tag'])} from {shown(meta['source'])}, fetched {shown(meta['fetched'])})"
    )


def _plugin_fix(env: Mapping[str, str]) -> str:
    """How this install is updated: a Claude Code plugin install (a root under `~/.claude/plugins/`, or under
    `${CLAUDE_PLUGIN_CACHE:-~/.claude/plugins/cache}`) by Claude Code; a checkout on a branch, which
    `install.sh upgrade` refuses, by `git -C <root> pull` (PULL_FIX); any other root, a release checkout or the
    Codex root, by its own `install.sh upgrade` (UPGRADE_FIX), which moves it to the newest release tag.
    launch.sh's `plugin_fix` and install.sh's `upg_fix` are the shell twins."""
    root = plugin_root()
    if release_cache.plugin_install(env, root)[0]:
        return PLUGIN_FIX
    if _branch_checkout(root, env):
        return PULL_FIX.format(root=_sh_quote(str(root)))
    return UPGRADE_FIX.format(install_sh=_sh_quote(str(root / "scripts" / "hooks" / "install.sh")))


def _branch_checkout(root: Path, env: Mapping[str, str]) -> bool:
    """Whether `root` is what `install.sh`'s `upg_kind` calls a `checkout` (a git checkout whose top is `root`,
    not the Codex root `${CODEX_HOME:-~/.codex}/doc-superpowers`) and its HEAD is a branch. Local git only."""
    home = Path(env.get("HOME") or Path.home())
    codex = Path(env.get("CODEX_HOME") or home / ".codex") / "doc-superpowers"
    if codex.resolve() == root:
        return False
    try:
        top = Path(git(root, "rev-parse", "--show-toplevel").strip()).resolve()
        if top != root:
            return False
        git(root, "symbolic-ref", "-q", "HEAD")
    except GitError:
        return False
    return True


def _sh_quote(text: str) -> str:
    """`text` as one shell word: as it is when it needs no quoting, else in single quotes (install.sh's
    `sh_squote`, so the two print the same command)."""
    if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", text):
        return text
    return "'" + text.replace("'", "'\\''") + "'"


def _install_fix() -> str:
    """The plugin's `install.sh install --search`, which copies its launcher into the project."""
    return f"bash {shlex.quote(str(plugin_root() / 'scripts' / 'hooks' / 'install.sh'))} install --search"


def mcp_state(top: Path, env: Mapping[str, str], client: Client | None = None) -> dict[str, McpState]:
    """Row 10, per client (`client`, or each of CLIENTS): `off` by the developer's switch, for every client;
    `expected` when that client's config registers the server (Claude Code: `.mcp.json`; Codex: the project's
    `.codex/config.toml` or `${CODEX_HOME:-~/.codex}/config.toml`); else `not-registered`."""
    clients = CLIENTS if client is None else (client,)
    if env.get("DOC_SEARCH_MCP", "").strip() == "0":
        return {name: "off" for name in clients}
    registers = {"claude": _claude_registers, "codex": _codex_registers}
    return {name: "expected" if registers[name](top, env) else "not-registered" for name in clients}


def _claude_registers(top: Path, env: Mapping[str, str]) -> bool:
    """Whether the project's `.mcp.json` registers `doc-search` (Claude Code)."""
    try:
        servers = json.loads((top / ".mcp.json").read_text(encoding="utf-8")).get("mcpServers")
    except (OSError, ValueError, AttributeError):
        return False
    return isinstance(servers, dict) and "doc-search" in servers


def _codex_registers(top: Path, env: Mapping[str, str]) -> bool:
    """Whether the user's or the project's Codex config has an `mcp_servers.doc-search` table."""
    home = env.get("HOME") or str(Path.home())
    codex_home = Path(env.get("CODEX_HOME") or Path(home) / ".codex")
    return any(_toml_registers(toml) for toml in (codex_home / "config.toml", top / ".codex" / "config.toml"))


def _toml_registers(path: Path) -> bool:
    """Whether a Codex config has an `mcp_servers.doc-search` table (by its text when it does not parse)."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    try:
        servers = tomllib.loads(text).get("mcp_servers")
    except tomllib.TOMLDecodeError:
        return _MCP_TABLE in text
    return isinstance(servers, dict) and "doc-search" in servers
