"""The `doc-search` console script: `serve` and the hidden `daemon` verb without the CLI's imports.

`serve` runs the shared server's proxy (shared.py) unless `--in-process` is given or the shared path is off,
then today's in-process server. `daemon` (started by a proxy, never by hand) takes the life lock before it
imports the server. Every other verb goes to cli.main.
"""

from __future__ import annotations

import sys
from pathlib import Path


def run_serve(in_process: bool) -> int:
    if not in_process:
        from .shared import serve_shared

        code = serve_shared()
        if code is not None:
            return code
    from .server import serve

    serve(Path.cwd())
    return 0


def _daemon(argv: list[str]) -> int:
    """The life lock first, then the server's imports: a second daemon for a key leaves at once."""
    import argparse

    from .shared import Place, hold_alive

    parser = argparse.ArgumentParser(prog="doc-search daemon")
    parser.add_argument("--key", required=True)
    parser.add_argument("--dir", required=True, type=Path)
    args = parser.parse_args(argv)
    place = Place(args.key, args.dir)
    life = hold_alive(place)
    if life is None:
        return 0  # another daemon has this key
    from .daemon import run

    return run(place, life)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args[:1] == ["serve"] and set(args[1:]) <= {"--in-process"}:
        return run_serve("--in-process" in args[1:])
    if args[:1] == ["daemon"]:
        return _daemon(args[1:])
    from .cli import main as cli_main

    return cli_main(args)


if __name__ == "__main__":
    sys.exit(main())
