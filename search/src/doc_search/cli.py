"""The `doc-search` command line (design section 9): serve, init, index, query, status, eval.

Exit codes: 0 ok (inert included), 1 findings, 2 could not run, 3 usage. When several apply, 1 wins over 2,
and 2 over 0. Without `docs/search/config.json` every verb but `init` prints the inert line and exits 0; with
an invalid one it prints `doc-search: invalid config: <message>` on stderr and exits 2.

The verbs that search (`query`, `status`, `eval`) use the same `Runtime` as the MCP tools. `index`, `query` and
`eval` are foreground work and wait for a build without a bound (a build that is cached once is fast the next
time). `status` is the readiness probe: it never builds, loads or waits, and says whether semble's saved index
of each kind is `valid`, `stale` or `absent` on disk.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import asdict
from pathlib import Path
from typing import Any, NoReturn

from semble.utils import resolve_model_name

from .cloud import CloudUnavailable, describe
from .cloud.vertex import VertexEmbedder
from .cloud.write import BaseRefError, CloudIndexer, CorpusRefused, IndexReport, LeaseHeld, LeaseLost
from .config import CONFIG_REL, DEFAULTS, INERT_LINE, Config, ConfigError, load_config
from .corpus import Corpus
from .docindex import DocIndex
from .engines import FOREGROUND_WAIT_S, Building, IndexPool, WorktreeIndexes
from .evaluate import EvalFileError, run_eval
from .render import render_search
from .repo import GitError, NotARepo, RepoInfo, resolve_worktree
from .tools import cloud_status_lines
from .types import SearchRequest

EXIT_FINDINGS = 1
EXIT_COULD_NOT_RUN = 2
EXIT_USAGE = 3

INVALID_REQUEST = "doc-search: invalid request:"
ORPHAN_LIST = 10


class _Parser(argparse.ArgumentParser):
    """argparse with the usage exit code: a bad command line is 3, not argparse's 2."""

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"doc-search: {message}\n")


def _fail(code: int, line: str) -> int:
    print(" ".join(line.split()), file=sys.stderr)
    return code


def _number(text: str, *, name: str, low: float, high: float, whole: bool) -> float:
    try:
        value = int(text) if whole else float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{name} must be {'an integer' if whole else 'a number'}: {text!r}") from None
    if not low <= value <= high:
        raise argparse.ArgumentTypeError(f"{name} must be between {low:g} and {high:g}: {text}")
    return value


def _build_parser() -> tuple[argparse.ArgumentParser, dict[str, argparse.ArgumentParser]]:
    parser = _Parser(prog="doc-search", description="Search a repository's docs and code (opt-in per repository).")
    verbs = parser.add_subparsers(dest="verb", required=True, metavar="verb", parser_class=_Parser)
    subs: dict[str, argparse.ArgumentParser] = {}

    def verb(name: str, help_: str) -> argparse.ArgumentParser:
        subs[name] = verbs.add_parser(name, help=help_, description=help_, allow_abbrev=False)
        return subs[name]

    verb("serve", "Run the MCP server over stdio.")
    verb("init", "Write docs/search/config.json (the defaults) when it is absent; never overwrites.")

    index = verb("index", "Build both semble indexes for this worktree; with --cloud, write the cloud corpus.")
    index.add_argument("--cloud", action="store_true", help="write the cloud corpus (needs the cloud object)")
    modes = index.add_mutually_exclusive_group()
    modes.add_argument(
        "--catch-up",
        dest="mode",
        action="store_const",
        const="catch-up",
        help="(default) files changed since the stamp",
    )
    modes.add_argument("--full", dest="mode", action="store_const", const="full", help="every file of HEAD")
    modes.add_argument(
        "--prune-orphans",
        dest="mode",
        action="store_const",
        const="prune-orphans",
        help="remove chunks of files git no longer knows",
    )
    index.add_argument(
        "--allow-off-base", action="store_true", help="write from a commit that is not on the base branch"
    )
    index.add_argument("--force", action="store_true", help="bypass the repository-identity refusal and the prune cap")

    query = verb("query", "The search tool from a shell.")
    query.add_argument("text", help="what to find")
    query.add_argument("--scope", choices=("all", "docs", "code"), default="all")
    query.add_argument(
        "--limit",
        type=lambda t: int(_number(t, name="--limit", low=1, high=50, whole=True)),
        default=None,
        help="1-50 (default: search.default_limit)",
    )
    query.add_argument("--doc-type", action="append", default=[], help="only docs of this type (repeatable)")
    query.add_argument("--path-prefix", default=None, help="only docs under this repo-relative prefix")
    query.add_argument("--include-terminal", action="store_true", help="also deprecated, superseded and archived docs")
    query.add_argument("--worktree", default=None, help="another worktree of this repository")
    query.add_argument("--format", choices=("text", "json"), default="text")

    status = verb("status", "How doc-search is set up here and whether the saved indexes are valid (builds nothing).")
    status.add_argument("--format", choices=("text", "json"), default="text")

    ev = verb("eval", "Known-answer evaluation: recall@k and MRR per leg, and the semble-single decision.")
    ev.add_argument("file", help='JSON lines: {"query", "expect": [paths], "kind"?}')
    ev.add_argument("--k", type=lambda t: int(_number(t, name="--k", low=1, high=50, whole=True)), default=10)
    ev.add_argument(
        "--min-recall",
        type=lambda t: _number(t, name="--min-recall", low=0, high=1, whole=False),
        default=None,
        help="exit 1 when the `all` leg's recall@k is below this",
    )
    return parser, subs


def main(argv: Sequence[str] | None = None) -> int:
    parser, subs = _build_parser()
    try:
        args = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
        if args.verb == "index" and not args.cloud and (args.mode or args.allow_off_base or args.force):
            subs["index"].error("--catch-up, --full, --prune-orphans, --allow-off-base and --force need --cloud")
    except SystemExit as stop:
        return stop.code if isinstance(stop.code, int) else (EXIT_USAGE if stop.code else 0)
    try:
        return _VERBS[args.verb](args)
    except NotARepo as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: {err}")
    except GitError as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: git failed: {err}")
    except ConfigError as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: invalid config: {err}")


# -- the repository ------------------------------------------------------------------------------------------


def _runtime(*, as_json: bool = False) -> Any:
    """The shared runtime of the repository around the working directory, or an exit code when the verb is answered.

    Inert prints the inert line (a JSON object with `--format json`) and is 0; an invalid config is 2.
    """
    from .server import Runtime  # the MCP SDK is only needed once something is searched

    try:
        repo = RepoInfo.from_cwd(Path.cwd())
    except NotARepo as err:
        return _could_not_run(f"doc-search: {err}", as_json)
    # the command line builds what the config names, in the foreground: no static docs fallback
    rt = Runtime(repo.top, None, FOREGROUND_WAIT_S, warm=False, fallback=False)
    if rt.fixed is None:
        return rt
    if rt.fixed == INERT_LINE:
        print(json.dumps({"enabled": False, "message": INERT_LINE}, indent=2) if as_json else INERT_LINE)
        return 0
    return _could_not_run(rt.fixed, as_json)


def _could_not_run(line: str, as_json: bool) -> int:
    """Exit 2 with the one-line reason on stderr; a JSON probe also gets `{"enabled": false, "error": <line>}`."""
    if as_json:
        print(json.dumps({"enabled": False, "error": " ".join(line.split())}, indent=2))
    return _fail(EXIT_COULD_NOT_RUN, line)


# -- serve ---------------------------------------------------------------------------------------------------


def _serve(args: argparse.Namespace) -> int:
    from .server import serve

    serve(Path.cwd())
    return 0


# -- init ----------------------------------------------------------------------------------------------------


def _init(args: argparse.Namespace) -> int:
    top = RepoInfo.from_cwd(Path.cwd()).top
    target = top / CONFIG_REL
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "x", encoding="utf-8") as handle:  # exclusive: it never overwrites
            handle.write(json.dumps(DEFAULTS, indent=2) + "\n")
    except FileExistsError:
        print(f"doc-search: {CONFIG_REL} exists; not changed")
        return 0
    except OSError as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: cannot write {CONFIG_REL}: {err}")

    cfg = load_config(top)
    assert cfg is not None
    default = "semble default"
    code = (
        "off"
        if not cfg.code.enabled
        else f"enabled (content {', '.join(cfg.code.content)}; model {cfg.code.model or default})"
    )
    types = f"{len(cfg.docs.types)} rules" if cfg.docs.types else "none (the built-in rules)"
    terminal = ", ".join(cfg.search.terminal_statuses)
    print(f"doc-search: wrote {CONFIG_REL}")
    print(f"docs.include: {', '.join(cfg.docs.include)}")
    print(f"docs.exclude: {', '.join(cfg.docs.exclude)}")
    print(f"docs.types: {types}")
    print(f"docs.model: {cfg.docs.model or default}")
    print(f"docs.threads: {cfg.docs.threads or 'auto'}")
    print(f"code: {code}")
    print(f"cloud: {'on' if cfg.cloud else 'off'}")
    print(
        f"search: default_limit {cfg.search.default_limit}, rescan_seconds {cfg.search.rescan_seconds}, "
        f"terminal statuses {terminal}"
    )
    print(f"corpus: {len(Corpus(top, cfg, DocIndex(top)).files())} files would be indexed")
    return 0


# -- index ---------------------------------------------------------------------------------------------------


def _index(args: argparse.Namespace) -> int:
    rt = _runtime()
    if isinstance(rt, int):
        return rt
    return _index_cloud(rt, args) if args.cloud else _index_local(rt)


def _index_local(rt: Any) -> int:
    got = rt.pool.get(rt.repo.top, wait_s=FOREGROUND_WAIT_S)
    if isinstance(got, Building):  # not reachable with this wait; never a hang or a traceback if it is
        return _fail(EXIT_COULD_NOT_RUN, "doc-search: the indexes are still building")
    failed = False
    for kind in ("docs", "code"):
        if kind == "code" and not rt.cfg.code.enabled:
            print("code: off (code.enabled is false)")
            continue
        index = got.docs if kind == "docs" else got.code
        error = got.error.get(kind)
        if error:
            failed = True
            print(f"doc-search: {kind} index failed: {error}", file=sys.stderr)
        if index is not None:
            seconds = got.build_seconds.get(kind)
            took = f"{seconds:.2f} s" if seconds is not None else "n/a"
            print(f"{kind}: {len(index.chunks)} chunks, {len(rt.pool.indexed_files(rt.repo.top, kind))} files, {took}")
    return EXIT_COULD_NOT_RUN if failed else 0


def make_indexer(cfg: Config, top: Path) -> CloudIndexer:
    """The cloud indexer for `top`. The seam the tests replace: it is the only place the network is reached from."""
    if cfg.cloud is None:
        raise CloudUnavailable(
            "cloud is not configured (set the cloud object in docs/search/config.json; DOC_SEARCH_CLOUD=0 disables it)"
        )
    return CloudIndexer(cfg, top, VertexEmbedder(cfg.cloud))


def _index_cloud(rt: Any, args: argparse.Namespace) -> int:
    mode = args.mode or "catch-up"
    try:
        report = make_indexer(rt.cfg, rt.repo.top).run(mode, allow_off_base=args.allow_off_base, force=args.force)
    except LeaseLost as err:
        if err.report is not None:
            print(_render_report(err.report))
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: {err}")
    except (BaseRefError, LeaseHeld, CorpusRefused) as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: {err}")
    except CloudUnavailable as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: cloud unavailable: {err}")
    except GitError:
        raise  # main() words it
    except Exception as err:  # noqa: BLE001 - a Firestore or Vertex failure is a line, not a traceback
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: index failed: {describe(err)}")
    print(_render_report(report))
    return EXIT_FINDINGS if report.files_failed or report.orphans_pending else 0


def _render_report(report: IndexReport) -> str:
    lines = [
        f"mode: {report.mode}",
        f"files: {report.files_written} written, {report.files_skipped} skipped, {report.files_deleted} deleted",
        f"chunks written: {report.chunks_written}",
        f"orphans: {report.orphans_removed} removed, {report.orphans_pending} pending",
    ]
    if report.orphans_sample:
        lines.append(f"pending orphans (first {ORPHAN_LIST}): {', '.join(report.orphans_sample[:ORPHAN_LIST])}")
    lines.append(f"stamped: yes ({report.stamp})" if report.stamped else "stamped: no")
    lines += [f"note: {note}" for note in report.notes]
    lines += [f"failed: {path}: {why}" for path, why in report.files_failed.items()]
    return "\n".join(" ".join(line.split()) for line in lines)


# -- query ---------------------------------------------------------------------------------------------------


def _query(args: argparse.Namespace) -> int:
    rt = _runtime()
    if isinstance(rt, int):
        return rt
    try:
        worktree = resolve_worktree(rt.repo, args.worktree)
    except ValueError as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: {err}")
    request = SearchRequest(
        query=args.text,
        scope=args.scope,
        limit=args.limit if args.limit is not None else rt.cfg.search.default_limit,
        doc_type=tuple(args.doc_type),
        path_prefix=args.path_prefix,
        include_terminal=args.include_terminal,
    )
    answer = rt.searcher.search(request, worktree)
    if isinstance(answer, str):  # a one-line answer: the search could not be made
        return _fail(EXIT_USAGE if answer.startswith(INVALID_REQUEST) else EXIT_COULD_NOT_RUN, answer)
    if args.format == "json":
        print(
            json.dumps(
                {"header": asdict(answer.header), "hits": [asdict(hit) for hit in answer.hits]},
                indent=2,
                ensure_ascii=False,
            )
        )
    else:
        print(render_search(answer))
    return 0


# -- status --------------------------------------------------------------------------------------------------


def _status(args: argparse.Namespace) -> int:
    """The probe: what is set up, what this process holds (nothing, when it is fresh) and what is on disk.

    It never builds, loads or waits. The disk is asked through `IndexPool.cache_state`: `valid` (a build would
    load it), `stale` (a rebuild is due) or `absent`.
    """
    as_json = args.format == "json"
    rt = _runtime(as_json=as_json)
    if isinstance(rt, int):
        return rt
    top = rt.repo.top
    cache = {
        "docs": rt.pool.cache_state(top, "docs"),
        "code": rt.pool.cache_state(top, "code") if rt.cfg.code.enabled else "off",
    }
    if not as_json:
        print(rt.status(warm=False))  # the tool's text, without starting the builds it would start for a server
        for kind, state in cache.items():
            print(f"{kind} cache: {state}")
        return 0
    got = rt.pool.peek(top)  # in memory only: None in a fresh process; it starts and waits for nothing
    kinds = {kind: _kind_status(rt, got, kind) for kind in ("docs", "code")}
    cloud = None
    if rt.cloud is not None:  # bounded: the probe answers at once, whatever the network does
        lines = [" ".join(line.split()) for line in cloud_status_lines(rt.cloud, top)]
        cloud = {"configured": True, "lines": lines}
    payload = {
        "enabled": True,
        "ready": all(_ready(kinds[kind], cache[kind]) for kind in kinds),
        "worktree": str(top),
        "config": str(top / CONFIG_REL),
        "semble": IndexPool.semble_version(),
        **kinds,
        "cache": cache,
        "corpus_files": len(rt.corpus_for(top).files()),
        "cloud": cloud,
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def _ready(info: dict[str, Any], cache: str) -> bool:
    """A kind is ready when its saved index is valid (or it is off), or this process already holds it without error."""
    return cache in ("valid", "off") or (info["state"] == "ready" and not info["error"])


def _kind_status(rt: Any, got: WorktreeIndexes | Building | None, kind: str) -> dict[str, Any]:
    cfg: Config = rt.cfg
    if kind == "code" and not cfg.code.enabled:
        return {"model": None, "state": "off", "chunks": 0, "files": 0, "build_seconds": None, "error": None}
    model = (cfg.docs.model if kind == "docs" else cfg.code.model) or resolve_model_name()
    if got is None:  # not in memory: the `cache` member says what is on disk
        return {
            "model": model,
            "state": "unloaded",
            "chunks": None,
            "files": None,
            "build_seconds": None,
            "error": None,
        }
    finished = True
    seen = got
    if isinstance(got, Building):
        finished = got.docs_ready if kind == "docs" else got.code_ready
        seen = got.partial or WorktreeIndexes()
    index = seen.docs if kind == "docs" else seen.code
    return {
        "model": model,
        "state": "building" if not finished else "ready" if index is not None else "failed",
        "chunks": len(index.chunks) if index is not None else 0,
        "files": len(rt.pool.indexed_files(rt.repo.top, kind)),
        "build_seconds": seen.build_seconds.get(kind),
        "error": seen.error.get(kind),
    }


# -- eval ----------------------------------------------------------------------------------------------------


def _eval(args: argparse.Namespace) -> int:
    rt = _runtime()
    if isinstance(rt, int):
        return rt
    try:
        report = run_eval(
            rt.searcher, rt.pool, Path(args.file), args.k, rt.repo.top, cloud=rt.cloud, corpus_for=rt.corpus_for
        )
    except EvalFileError as err:
        where = f"{args.file} {err}" if err.line else f"{args.file}: {err}"
        return _fail(EXIT_USAGE, f"doc-search: eval: {where}")
    except OSError as err:
        return _fail(EXIT_COULD_NOT_RUN, f"doc-search: eval: cannot read {args.file}: {err}")
    print(report.render())
    recall = report.recall("all")
    if args.min_recall is not None:
        if recall is None:
            return _fail(
                EXIT_COULD_NOT_RUN, "doc-search: eval: the `all` leg did not run, so --min-recall cannot be checked"
            )
        if recall < args.min_recall:
            return _fail(
                EXIT_FINDINGS,
                f"doc-search: eval: recall@{args.k} {recall:.4f} is below --min-recall {args.min_recall:g}",
            )
    return 0


_VERBS = {
    "serve": _serve,
    "init": _init,
    "index": _index,
    "query": _query,
    "status": _status,
    "eval": _eval,
}


if __name__ == "__main__":
    raise SystemExit(main())
