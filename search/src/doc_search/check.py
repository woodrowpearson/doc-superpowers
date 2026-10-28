"""`doc-search check`: whether doc-search can answer for this worktree now, as a verdict a hook can gate on.

`assess` walks a fixed order (design: 2026-10-27-doc-search-readiness-gate-design.md), and the first row
that decides wins:

1. no config: `not-in-force`;
2. an invalid config: `not-ready` when its raw text says `"required": true`, else `not-in-force`;
3. the plugin below `requires`: `not-ready`;
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
10. `mcp` says whether this developer's client is expected to run the MCP server.

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

from .config import CONFIG_REL, Config, ConfigError, load_config
from .engines import Building, IndexPool
from .progress import read_progress
from .version import launcher_stamp, plugin_root, plugin_version

State = Literal["ready", "degraded", "not-ready", "not-in-force"]
LauncherState = Literal["current", "differs", "below-floor", "absent"]
McpState = Literal["expected", "off", "not-registered"]

LAUNCHER_REL = ".claude/doc-superpowers/search-mcp.sh"
"""The launcher copy a project commits (install.sh install --search writes it)."""

INDEX_FIX = f"sh {LAUNCHER_REL} index"
PLUGIN_FIX = "claude plugin update doc-superpowers"
CONFIG_FIX = f"edit {CONFIG_REL}, then run sh {LAUNCHER_REL} check"

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
    mcp: McpState
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


def outside(env: Mapping[str, str], where: Path) -> Verdict:
    """The verdict outside a git work tree: not in force."""
    version = plugin_version(plugin_root())
    mcp = mcp_state(where, env)
    return _verdict("not-in-force", "not in a git work tree", None, False, None, "absent", version, mcp)


def assess(top: Path, *, budget_s: float, env: Mapping[str, str]) -> Verdict:
    """The verdict for the worktree at `top`. Only a required config refreshes stale indexes (for at most
    `budget_s` seconds); otherwise the would-be state comes from the cache states alone."""
    top = Path(top).resolve()
    mcp = mcp_state(top, env)
    version = plugin_version(plugin_root())
    try:
        cfg = load_config(top, env)
    except ConfigError as err:
        required = config_says_required(top)
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
    mcp: McpState = "not-registered",
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
        mcp=mcp,
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
    a stale index of a repository that does not require doc-search is reported, not refreshed."""

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
    if launcher in ("absent", "below-floor"):
        return verdict("not-ready", launcher_reason, _install_fix())
    degraded = [launcher_reason] if launcher == "differs" and launcher_reason else []
    fix = _install_fix() if degraded else None

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
            return "transformer index not built", False, []
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


def _plugin_fix(env: Mapping[str, str]) -> str:
    """How this install is updated: the Codex root (`${CODEX_HOME:-~/.codex}/doc-superpowers`) is a git checkout
    and is pulled; anything else is taken to be the Claude Code plugin."""
    home = Path(env.get("HOME") or Path.home()).resolve()
    root = plugin_root()
    if root != (Path(env.get("CODEX_HOME") or home / ".codex") / "doc-superpowers").resolve():
        return PLUGIN_FIX
    shown = f"~/{root.relative_to(home)}" if root.is_relative_to(home) else str(root)
    return f"git -C {shown} pull"


def _install_fix() -> str:
    """The plugin's `install.sh install --search`, which copies its launcher into the project."""
    return f"bash {shlex.quote(str(plugin_root() / 'scripts' / 'hooks' / 'install.sh'))} install --search"


def mcp_state(top: Path, env: Mapping[str, str]) -> McpState:
    """Row 10: `off` by the developer's switch; `expected` when a client config registers the server."""
    if env.get("DOC_SEARCH_MCP", "").strip() == "0":
        return "off"
    try:
        servers = json.loads((top / ".mcp.json").read_text(encoding="utf-8")).get("mcpServers")
        if isinstance(servers, dict) and "doc-search" in servers:
            return "expected"
    except (OSError, ValueError, AttributeError):
        pass
    home = env.get("HOME") or str(Path.home())
    codex_home = Path(env.get("CODEX_HOME") or Path(home) / ".codex")
    for toml in (codex_home / "config.toml", top / ".codex" / "config.toml"):
        if _toml_registers(toml):
            return "expected"
    return "not-registered"


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
