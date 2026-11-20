"""The release notes `check` reads for the security floor, from disk only: nothing here fetches.

Four sources, and the one whose own release is newest wins (the first of them on a tie):

1. the file `$DOC_SEARCH_RELEASE_NOTES` names (a blank value is unset);
2. the cache `install.sh upgrade` writes, `${XDG_CACHE_HOME:-~/.cache}/doc-superpowers/release-notes.md`, never
   read through a symbolic link or from a directory that is not the user's own;
3. Claude Code's marketplace clone of doc-superpowers, `~/.claude/plugins/marketplaces/<name>/RELEASE-NOTES.md`,
   known by its `.claude-plugin/plugin.json` `name` (Claude Code keeps that clone fresh by itself);
4. the plugin's own `RELEASE-NOTES.md`, which can never show a release past its own.

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
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .releases import Version, first_release, read_notes
from .version import plugin_root

ENV_VAR = "DOC_SEARCH_RELEASE_NOTES"
NOTES_NAME = "release-notes.md"
SIDECAR_NAME = "release-notes.json"
UNKNOWN = "unknown"
PLUGIN_NAME = "doc-superpowers"

MAX_SIDECAR_BYTES = 4096
"""A sidecar is three short fields; a longer one is not read."""

MAX_SHOWN = 200
"""The most characters of one field a reason shows."""

_TAG = re.compile(r"v([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})")
_FETCHED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|\+00:00)")
_SOURCE = re.compile(r"[A-Za-z0-9._~:/@%+=,][A-Za-z0-9._~:/@%+=,-]*")
"""`install.sh`'s `valid_marketplace_url`: what `git clone` takes, with no space, quote, backslash or `$`."""

_ANSI = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)?|[@-Z\\-_])")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f  ]")


@dataclass(frozen=True)
class _Source:
    text: str
    meta: dict[str, str]
    ceiling: Version


def safe(text: str) -> str:
    """`text` with its ANSI escape sequences and control characters dropped, at most MAX_SHOWN characters."""
    return _CONTROL.sub("", _ANSI.sub("", text))[:MAX_SHOWN]


def cache_dir(env: Mapping[str, str]) -> Path:
    """`$XDG_CACHE_HOME/doc-superpowers`, else `~/.cache/doc-superpowers` (an empty XDG_CACHE_HOME is unset)."""
    base = env.get("XDG_CACHE_HOME") or ""
    if base:
        return Path(base) / "doc-superpowers"
    return Path(env.get("HOME") or Path.home()) / ".cache" / "doc-superpowers"


def load(env: Mapping[str, str], plugin: Path | None = None) -> tuple[str, dict[str, str]] | None:
    """The notes text and their sidecar (`tag`, `fetched`, `source`, each a checked value or `unknown`) of the
    source whose own release is newest; None when no source has a release heading. `tag` is that source's
    ceiling as `vX.Y.Z`. `plugin` is the plugin's root (default: the one this package runs from)."""
    if plugin is None:
        plugin = plugin_root()
    best: _Source | None = None
    for source in _sources(env, plugin):
        if best is None or source.ceiling > best.ceiling:
            best = source
    return (best.text, best.meta) if best is not None else None


def store(env: Mapping[str, str], text: str, tag: str, source: str) -> None:
    """Write the cache as `install.sh upgrade` does: the notes and their sidecar, each to a temp file beside it
    and renamed into place. Raises ValueError for a tag that is not `vX.Y.Z` or a source outside the URL
    character set, and OSError for a cache dir that is a symbolic link or not the user's own."""
    if _TAG.fullmatch(tag) is None:
        raise ValueError(f"not a release tag: {safe(tag)!r}")
    if _SOURCE.fullmatch(source) is None:
        raise ValueError(f"not a repository URL: {safe(source)!r}")
    where = cache_dir(env)
    if where.is_symlink():
        raise OSError(f"{where} is a symbolic link: the release-notes cache is never written through one")
    where.mkdir(parents=True, exist_ok=True)
    if not _owned(where):
        raise OSError(f"{where} is not your own directory: the release-notes cache must be")
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


def _owned(path: Path) -> bool:
    getuid = getattr(os, "getuid", None)
    if getuid is None:  # no uids here (Windows): nothing to compare
        return True
    try:
        return path.stat().st_uid == getuid()
    except OSError:
        return False


def _sources(env: Mapping[str, str], plugin: Path) -> list[_Source]:
    """Every readable source, in the module docstring's order."""
    found: list[_Source] = []
    named = (env.get(ENV_VAR) or "").strip()
    if named:
        notes = Path(named)
        _add(found, notes, _sidecar(notes.with_suffix(".json")), str(notes))
    where = cache_dir(env)
    if not where.is_symlink() and where.is_dir() and _owned(where):
        _add(found, where / NOTES_NAME, _sidecar(where / SIDECAR_NAME), str(where / NOTES_NAME))
    home = env.get("HOME") or str(Path.home())
    for clone in _marketplace_clones(Path(home) / ".claude" / "plugins" / "marketplaces"):
        _add(found, clone / "RELEASE-NOTES.md", {}, f"the marketplace clone {clone}")
    _add(found, Path(plugin) / "RELEASE-NOTES.md", {}, f"the plugin's own {Path(plugin) / 'RELEASE-NOTES.md'}")
    return found


def _add(found: list[_Source], notes: Path, sidecar: dict[str, str], label: str) -> None:
    """Append `notes` when it is a regular file (no symbolic link) with a release heading."""
    if notes.is_symlink() or not notes.is_file():
        return
    text = read_notes(notes)
    first = first_release(text)
    if text is None or first is None:
        return
    tag = _parse_tag(sidecar.get("tag"))
    ceiling = first if tag is None else min(first, tag)
    meta = {
        "tag": "v" + ".".join(str(part) for part in ceiling),
        "fetched": sidecar.get("fetched") or _mtime(notes),
        "source": sidecar.get("source") or safe(label),
    }
    found.append(_Source(text=text, meta=meta, ceiling=ceiling))


def _sidecar(path: Path) -> dict[str, str]:
    """A notes file's sidecar, each field checked (`unknown` when it fails); {} when there is no sidecar."""
    if path.is_symlink() or not path.is_file():
        return {}
    raw: object = None
    try:
        with path.open("rb") as handle:
            data = handle.read(MAX_SIDECAR_BYTES + 1)
        if len(data) <= MAX_SIDECAR_BYTES:
            raw = json.loads(data.decode("utf-8"))
    except (OSError, ValueError):
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


def _mtime(path: Path) -> str:
    """When a notes file without a sidecar last changed, as ISO-8601 UTC; `unknown` when it cannot be read."""
    try:
        stamp = path.stat().st_mtime
    except OSError:
        return UNKNOWN
    return datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _marketplace_clones(root: Path) -> list[Path]:
    """The marketplace clones whose `.claude-plugin/plugin.json` names doc-superpowers, by directory name."""
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return []
    clones = []
    for clone in entries:
        manifest = clone / ".claude-plugin" / "plugin.json"
        try:
            with manifest.open("rb") as handle:
                data = handle.read(MAX_SIDECAR_BYTES * 16 + 1)
            if len(data) > MAX_SIDECAR_BYTES * 16:
                continue
            name = json.loads(data.decode("utf-8")).get("name")
        except (OSError, ValueError, AttributeError):
            continue
        if name == PLUGIN_NAME:
            clones.append(clone)
    return clones
