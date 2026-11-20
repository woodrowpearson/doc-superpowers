"""The release notes `check` reads for the security floor, from disk only: nothing here fetches.

Four sources, each read on its own (`check` takes the highest security release any of them names, and names
the source that gave it; the first of them on a tie):

1. the file `$DOC_SEARCH_RELEASE_NOTES` names (a blank value is unset);
2. the cache `install.sh upgrade` writes, `${XDG_CACHE_HOME:-~/.cache}/doc-superpowers/release-notes.md`, read
   only from a real directory that is the user's own and writable by no one else (no `0o022` bit), and only
   files in it that are the user's own;
3. for a Claude Code plugin install only, the clone of the marketplace this install came from,
   `~/.claude/plugins/marketplaces/<mkt>/RELEASE-NOTES.md` (`<mkt>` read from the root's path as `install.sh`'s
   `upg_kind` reads `UPG_MKT`; Claude Code keeps that clone fresh by itself), when its `.claude-plugin/plugin.json`
   names doc-superpowers, and never above that manifest's `version`. Another marketplace, a fork's say, could
   name a release `claude plugin update` never installs, so no other clone is read; a checkout or the Codex
   root reads none;
4. the plugin's own `RELEASE-NOTES.md`, never above its `package.json` version, so it can never show a
   release past its own.

A notes file may have a sidecar beside it, the same name with `.json`: `{"tag": "vX.Y.Z", "fetched": "<ISO-8601
UTC>", "source": "<remote URL>"}`, as `install.sh upgrade` writes for the cache. A source's own release, its
ceiling, is its first release heading (check-version's rule), and no later than a valid sidecar `tag`: a
security section above it is dropped (`releases.newest_security`'s `ceiling`), as `install.sh`'s `upg_scan` does.

Everything read here is untrusted data (fetched notes, a sidecar anyone could have written). The notes are
parsed by `releases`' regexes only, and a sidecar field that fails its check shows as `unknown`: `tag` against
`vX.Y.Z`, `fetched` against ISO-8601 UTC, `source` against the character set `install.sh`'s
`valid_marketplace_url` allows. Any text that reaches a reason has its ANSI sequences and control characters
stripped (`safe`), so it can neither break the gate's two-line verdict file nor paint a terminal.
"""

from __future__ import annotations

import json
import os
import re
import stat
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .config import parse_version
from .releases import MAX_NOTES_BYTES, Version, first_release, notes_text
from .version import plugin_root, plugin_version

ENV_VAR = "DOC_SEARCH_RELEASE_NOTES"
NOTES_NAME = "release-notes.md"
SIDECAR_NAME = "release-notes.json"
UNKNOWN = "unknown"
PLUGIN_NAME = "doc-superpowers"

MAX_SIDECAR_BYTES = 4096
"""A sidecar is three short fields; a longer one is not read."""

MAX_SHOWN = 200
"""The most characters of one field a reason shows; a longer one keeps its tail (`safe`)."""

_TAG = re.compile(r"v([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})")
_FETCHED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|\+00:00)")
_SOURCE = re.compile(r"[A-Za-z0-9._~:/@%+=,][A-Za-z0-9._~:/@%+=,-]*")
"""`install.sh`'s `valid_marketplace_url`: what `git clone` takes, with no space, quote, backslash or `$`."""

_ANSI = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)?|[@-Z\\-_])")
_CONTROL = re.compile(r"[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
"""C0 and C1 controls; the zero-width and direction marks (U+200B to U+200F); the line and paragraph
separators (U+2028, U+2029); the bidi embeddings, overrides and isolates (U+202A to U+202E, U+2066 to U+2069)."""


@dataclass(frozen=True)
class Source:
    """One source's notes: its text, its ceiling (no security release above it counts), and `meta`: `tag` (the
    ceiling as `vX.Y.Z`), `fetched` and `source` (the sidecar's, each checked or `unknown`; without a sidecar,
    the file's change time and a label naming the file)."""

    text: str
    meta: dict[str, str]
    ceiling: Version


def safe(text: str) -> str:
    """`text` with its ANSI escape sequences and `_CONTROL` characters dropped, at most MAX_SHOWN characters:
    a longer text is cut from the front, behind a `…`, so its tail (a path's file and nearest directories, a
    URL's repository) survives."""
    clean = _CONTROL.sub("", _ANSI.sub("", text))
    return clean if len(clean) <= MAX_SHOWN else "…" + clean[-(MAX_SHOWN - 1) :]


def _shown(path: Path, home: Path) -> str:
    """`path` as a label shows it: from `~/` when it is under `home`."""
    try:
        return "~/" + str(path.relative_to(home)) if path != home else "~"
    except ValueError:
        return str(path)


def cache_dir(env: Mapping[str, str]) -> Path:
    """`$XDG_CACHE_HOME/doc-superpowers`, else `~/.cache/doc-superpowers` (an empty XDG_CACHE_HOME is unset)."""
    base = env.get("XDG_CACHE_HOME") or ""
    if base:
        return Path(base) / "doc-superpowers"
    return Path(env.get("HOME") or Path.home()) / ".cache" / "doc-superpowers"


def load(env: Mapping[str, str], plugin: Path | None = None) -> list[Source]:
    """Every readable source with a release heading, in the module docstring's order. A source is never
    merged with another or dropped for being older: a newer marketplace clone with no `### Security` section
    must not hide the cache's security release. `plugin` is the plugin's root (default: the one this package
    runs from)."""
    return _sources(env, plugin if plugin is not None else plugin_root())


def store(env: Mapping[str, str], text: str, tag: str, source: str) -> None:
    """Write the cache as `install.sh upgrade` does: the notes and their sidecar, each to a temp file beside it
    and renamed into place. Raises ValueError for a tag that is not `vX.Y.Z` or a source outside the URL
    character set, and OSError for a cache dir that is a symbolic link, not the user's own, or writable by the
    group or others."""
    if _TAG.fullmatch(tag) is None:
        raise ValueError(f"not a release tag: {safe(tag)!r}")
    if _SOURCE.fullmatch(source) is None:
        raise ValueError(f"not a repository URL: {safe(source)!r}")
    where = cache_dir(env)
    if where.is_symlink():
        raise OSError(f"{where} is a symbolic link: the release-notes cache is never written through one")
    where.mkdir(mode=0o755, parents=True, exist_ok=True)
    if not _private_dir(where):
        raise OSError(f"{where} is not your own directory, or others can write it: the release-notes cache must not be")
    fetched = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sidecar = json.dumps({"tag": tag, "fetched": fetched, "source": source}) + "\n"
    _atomic_write(where / NOTES_NAME, text)
    _atomic_write(where / SIDECAR_NAME, sidecar)


def _atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _uid_ok(uid: int) -> bool:
    getuid = getattr(os, "getuid", None)
    return getuid is None or uid == getuid()  # no uids here (Windows): nothing to compare


def _private_dir(path: Path) -> bool:
    """A real directory (not a symbolic link), the user's own, that neither its group nor others can write."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and _uid_ok(info.st_uid) and not info.st_mode & 0o022


_OPEN_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
"""Never through a final symbolic link, and never blocking (on a FIFO, say) before `fstat` refuses it."""


def _read_regular(path: Path, limit: int, *, own: bool = False) -> tuple[bytes, os.stat_result] | None:
    """At most `limit + 1` bytes of `path` and its `fstat`, when it is a regular file (and, with `own`, the
    user's own); None otherwise. The checks and the read use one descriptor, so the file cannot be swapped
    between them."""
    try:
        fd = os.open(path, _OPEN_FLAGS)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or (own and not _uid_ok(info.st_uid)):
            return None
        chunks: list[bytes] = []
        left = limit + 1
        while left > 0:
            chunk = os.read(fd, min(left, 1 << 20))
            if not chunk:
                break
            chunks.append(chunk)
            left -= len(chunk)
        return b"".join(chunks), info
    except OSError:
        return None
    finally:
        os.close(fd)


def plugin_install(env: Mapping[str, str], root: Path) -> tuple[bool, str | None]:
    """Whether `root` is a Claude Code plugin install, and the name of the marketplace it came from (None when
    the path does not say), as `install.sh`'s `upg_kind` decides `UPG_KIND=plugin` and `UPG_MKT`: a root under
    `~/.claude/plugins/` (its marketplace the directory after `marketplaces/` or `cache/`), or under
    `${CLAUDE_PLUGIN_CACHE:-~/.claude/plugins/cache}` (the directory after the cache)."""
    home = Path(env.get("HOME") or Path.home())
    real = Path(root).resolve()
    plugins = (home / ".claude" / "plugins").resolve()
    cache = Path(env.get("CLAUDE_PLUGIN_CACHE") or home / ".claude" / "plugins" / "cache").resolve()
    if real.is_relative_to(plugins):
        parts = real.relative_to(plugins).parts
        if len(parts) >= 2 and parts[0] in ("marketplaces", "cache"):
            return True, parts[1]
        return True, None
    if real.is_relative_to(cache):
        parts = real.relative_to(cache).parts
        return True, parts[0] if parts else None
    return False, None


def _sources(env: Mapping[str, str], plugin: Path) -> list[Source]:
    found: list[Source] = []
    home = Path(env.get("HOME") or Path.home())
    named = (env.get(ENV_VAR) or "").strip()
    if named:
        notes = Path(named)
        _add(found, notes, _sidecar(notes.with_suffix(".json")), _shown(notes, home))
    where = cache_dir(env)
    if _private_dir(where):
        notes = where / NOTES_NAME
        _add(found, notes, _sidecar(where / SIDECAR_NAME, own=True), _shown(notes, home), own=True)
    is_plugin, market = plugin_install(env, plugin)
    if is_plugin and market is not None:
        clone = home / ".claude" / "plugins" / "marketplaces" / market
        version = _manifest_version(clone)
        if version is not None:
            label = f"the marketplace clone {_shown(clone, home)}"
            _add(found, clone / "RELEASE-NOTES.md", {}, label, limit=version)
    own = Path(plugin) / "RELEASE-NOTES.md"
    _add(found, own, {}, f"the plugin's own {_shown(own, home)}", limit=plugin_version(Path(plugin)))
    return found


def _add(
    found: list[Source],
    notes: Path,
    sidecar: dict[str, str],
    label: str,
    limit: Version | None = None,
    *,
    own: bool = False,
) -> None:
    """Append `notes` when it is a regular file (no symbolic link; with `own`, the user's own) with a release
    heading. Its ceiling is its first release heading, lowered to a valid sidecar `tag` and to `limit` when
    they are lower."""
    read = _read_regular(notes, MAX_NOTES_BYTES, own=own)
    if read is None:
        return
    data, info = read
    text = notes_text(data)
    first = first_release(text)
    if first is None:
        return
    ceiling = min(v for v in (first, _parse_tag(sidecar.get("tag")), limit) if v is not None)
    meta = {
        "tag": "v" + ".".join(str(part) for part in ceiling),
        "fetched": sidecar.get("fetched") or _iso(info.st_mtime),
        "source": sidecar.get("source") or safe(label),
    }
    found.append(Source(text=text, meta=meta, ceiling=ceiling))


def _sidecar(path: Path, *, own: bool = False) -> dict[str, str]:
    """A notes file's sidecar, each field checked (`unknown` when it fails); {} when there is none (no regular
    file, or with `own` none of the user's own)."""
    read = _read_regular(path, MAX_SIDECAR_BYTES, own=own)
    if read is None:
        return {}
    raw: object = None
    data = read[0]
    try:
        if len(data) <= MAX_SIDECAR_BYTES:
            raw = json.loads(data.decode("utf-8"))
    except ValueError:
        raw = None
    fields = raw if isinstance(raw, dict) else {}
    checks = {"tag": _TAG, "fetched": _FETCHED, "source": _SOURCE}
    return {
        key: value if isinstance(value := fields.get(key), str) and pattern.fullmatch(value) else UNKNOWN
        for key, pattern in checks.items()
    }


def _parse_tag(value: str | None) -> Version | None:
    match = _TAG.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        return None
    major, minor, patch = (int(part) for part in match.groups())
    return (major, minor, patch)


def _iso(stamp: float) -> str:
    """When a notes file without a sidecar last changed, as ISO-8601 UTC."""
    return datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _manifest_version(clone: Path) -> Version | None:
    """The `version` of a marketplace clone's `.claude-plugin/plugin.json` when its `name` is doc-superpowers;
    None otherwise (no manifest, another plugin's, no valid version: the clone is not read)."""
    read = _read_regular(clone / ".claude-plugin" / "plugin.json", MAX_SIDECAR_BYTES * 16)
    if read is None or len(read[0]) > MAX_SIDECAR_BYTES * 16:
        return None
    try:
        fields = json.loads(read[0].decode("utf-8"))
    except ValueError:
        return None
    if not isinstance(fields, dict) or fields.get("name") != PLUGIN_NAME:
        return None
    version = fields.get("version")
    return parse_version(version) if isinstance(version, str) else None
