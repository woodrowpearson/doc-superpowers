"""The plugin's own version and the launcher's version stamp.

`requires` in the config is a floor for both: the doc-superpowers this package runs from
(`package.json`'s `version`) and the launcher copy a project commits, which carries the
stamp line `# doc-search launcher vX.Y.Z` (line 2 of `scripts/search/launch.sh`;
`doc-tools.sh bump-version` writes it with the manifests).
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from doc_search.config import parse_version

STAMP_RE = re.compile(r"# doc-search launcher v([0-9]+\.[0-9]+\.[0-9]+)")
"""One whole stamp line (match it with `fullmatch`); group 1 is the version."""

_STAMP_WITHIN = 5
"""The stamp is looked for in this many leading lines."""


def plugin_root() -> Path:
    """The doc-superpowers checkout this package runs from (`search/src/doc_search/` is 3 below it)."""
    return Path(__file__).resolve().parents[3]


def plugin_version(root: Path) -> tuple[int, int, int] | None:
    """`root/package.json`'s `version` as a tuple; None when it is missing, unreadable or not X.Y.Z."""
    try:
        data = json.loads((root / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    version = data.get("version") if isinstance(data, dict) else None
    return parse_version(version) if isinstance(version, str) else None


def launcher_stamp(path: Path) -> tuple[int, int, int] | None:
    """The version of the first stamp line within the first 5 lines of `path`; None when there is none."""
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for _ in range(_STAMP_WITHIN):
                line = handle.readline()
                if not line:
                    break
                match = STAMP_RE.fullmatch(line.rstrip("\n"))
                if match is not None:
                    return parse_version(match.group(1))
    except OSError:
        return None
    return None
