"""The `doc-search` command line. `serve` is the MCP server on stdio; the other verbs arrive with Task 9."""

from __future__ import annotations

import sys
from collections.abc import Sequence
from pathlib import Path

USAGE = "usage: doc-search serve"


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args != ["serve"]:
        print(USAGE, file=sys.stderr)
        return 3
    from .server import serve

    serve(Path.cwd())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
