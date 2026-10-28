"""The `doc-search` command line (design section 9): serve, init, index, query, status, eval, check, gate.

Exit codes: 0 ok (inert included), 1 findings, 2 could not run, 3 usage. When several apply, 1 wins over 2,
and 2 over 0. Without `docs/search/config.json` every verb but `init`, `check` and `gate` (silent) prints the inert
line and exits 0; with an invalid one it prints `doc-search: invalid config: <message>` on stderr and exits 2. `check`
has exits of its own (check.py): 0 ready or degraded, 1 not-ready, 3 usage, 4 not-in-force. `gate` (gate.py), the
client hooks' entry, always exits 0 (3 for usage): its decision is the JSON it prints.

The verbs that search (`query`, `status`, `eval`) use the same `Runtime` as the MCP tools. `index`, `query` and
`eval` are foreground work and wait for a build without a bound (a build that is cached once is fast the next
time). With a transformer docs model a first build takes hours, so these verbs print the build's progress on
stderr every PROGRESS_EVERY_S seconds. `status` is the readiness probe: it never builds, loads or waits, and says
whether semble's saved index of each kind is `valid`, `stale` or `absent` on disk (for a transformer docs model also
the static index that serves while it builds), and, from the progress file a live build publishes, how that build
is getting on. `check` is the gating probe: it runs the incremental refresh a stale index needs, bounded by
`--budget`, and never starts a first build. `check` and `gate` keep the verdict file the tool gate reads (gate.py),
unless `DOC_SEARCH_GATE=0`.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import threading
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import asdict
from pathlib import Path
from typing import Any, NoReturn

from semble.utils import resolve_model_name

from .check import CLIENTS, Verdict, assess, mcp_line, outside
from .cloud import CloudUnavailable, describe
from .cloud.vertex import VertexEmbedder
from .cloud.write import BaseRefError, CloudIndexer, CorpusRefused, IndexReport, LeaseHeld, LeaseLost
from .config import CONFIG_REL, DEFAULTS, INERT_LINE, Config, ConfigError, load_config
from .corpus import Corpus
from .docindex import DocIndex
from .encode_cache import cache_size, encode_cache_path
from .engines import FOREGROUND_WAIT_S, Building, IndexPool, WorktreeIndexes
from .evaluate import EvalFileError, run_eval
from .gate import EVENTS, gate_off, hook_output, judge, verdict_path, write_verdict
from .progress import ProgressView, read_progress
from .render import render_search
from .repo import GitError, NotARepo, RepoInfo, resolve_worktree
from .tools import cloud_status_lines
from .types import SearchRequest

logger = logging.getLogger(__name__)

EXIT_FINDINGS = 1
EXIT_COULD_NOT_RUN = 2
EXIT_USAGE = 3

# How often a foreground verb prints the progress of a transformer docs build, in seconds.
PROGRESS_EVERY_S = 30.0

# How long `check` may spend refreshing stale indexes by default, in seconds.
CHECK_BUDGET_S = 20

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

    def budget(sub: argparse.ArgumentParser) -> None:
        sub.add_argument(
            "--budget",
            type=lambda t: int(_number(t, name="--budget", low=1, high=600, whole=True)),
            default=CHECK_BUDGET_S,
            help="seconds the refresh may take, 1-600 (default: 20)",
        )

    probe = verb("check", "Whether doc-search can answer here now, refreshing stale indexes within --budget (a gate).")
    probe.add_argument("--format", choices=("text", "json"), default="text")
    budget(probe)

    hook = verb("gate", "The client hooks' entry: check, keep the verdict file, print the hook's JSON (always exit 0).")
    hook.add_argument("event", choices=EVENTS, help="the hook event (the launcher answers `tool` itself)")
    hook.add_argument(
        "--client", choices=CLIENTS, default=None, help="the client whose MCP registration counts (default: each)"
    )
    budget(hook)

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


def _print_progress(line: str) -> None:
    print(f"doc-search: {line}", file=sys.stderr, flush=True)


@contextmanager
def _progress_lines(rt: Any, worktree: Path) -> Iterator[None]:
    """While a foreground verb waits for the indexes, say on stderr how a transformer docs build is getting on.

    Every PROGRESS_EVERY_S seconds the build of `worktree` in this process, if there is one, prints its line
    (`ProgressView.line`) as `doc-search: <line>`. The first build of a transformer docs index takes hours, and a
    verb that prints nothing for that long looks hung. It starts nothing for a static docs model and stops when
    the verb returns.
    """
    if rt.cfg.docs.transformer is None:
        yield
        return
    stop = threading.Event()

    def say() -> None:
        while not stop.wait(PROGRESS_EVERY_S):
            try:
                view = rt.pool.progress(worktree)
                if view is not None:
                    _print_progress(view.line())
            except Exception:  # noqa: BLE001 - a side channel: a line that cannot be printed must not end the verb
                logger.debug("doc-search: build progress not printed", exc_info=True)

    thread = threading.Thread(target=say, name="doc-search-progress", daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(5)


# -- serve ---------------------------------------------------------------------------------------------------


def _serve(args: argparse.Namespace) -> int:
    from .server import serve

    serve(Path.cwd())
    return 0


# -- init ----------------------------------------------------------------------------------------------------

# Top-level keys `init` leaves out of the file it writes: absent, they take their defaults. A plugin older
# than 3.11.0 rejects them as unknown, so a repository that never opted into the gate must not carry them.
INIT_OMITS = ("required", "requires")


def init_config() -> dict[str, Any]:
    """The config `init` writes: DEFAULTS without INIT_OMITS (setup's copy, scripts/setup/search-config.json, is
    this, byte for byte)."""
    return {key: value for key, value in DEFAULTS.items() if key not in INIT_OMITS}


def _init(args: argparse.Namespace) -> int:
    top = RepoInfo.from_cwd(Path.cwd()).top
    target = top / CONFIG_REL
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "x", encoding="utf-8") as handle:  # exclusive: it never overwrites
            handle.write(json.dumps(init_config(), indent=2) + "\n")
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
    with _progress_lines(rt, rt.repo.top):
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
    with _progress_lines(rt, worktree):
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
    load it), `stale` (a rebuild is due) or `absent`. With a transformer docs model `docs` is the transformer
    index's state and `docs_fallback` the static index's, which serves while the transformer one builds (None
    for a static model); a build running in another process is read from the progress file it publishes.
    """
    as_json = args.format == "json"
    rt = _runtime(as_json=as_json)
    if isinstance(rt, int):
        return rt
    top = rt.repo.top
    cache = {
        "docs": rt.pool.cache_state(top, "docs"),
        "code": rt.pool.cache_state(top, "code") if rt.cfg.code.enabled else "off",
        "docs_fallback": rt.pool.fallback_cache_state(top),
    }
    progress = rt.pool.progress(top)  # a build of this process, if the pool holds one (a fresh process holds none)
    if not as_json:
        print(rt.status(warm=False))  # the tool's text, without starting the builds it would start for a server
        print(f"docs cache: {cache['docs']}")
        if cache["docs_fallback"] is not None:
            print(f"docs fallback cache: {cache['docs_fallback']}")
        print(f"code cache: {cache['code']}")
        if rt.cfg.docs.transformer is not None and progress is None:  # the text above has this process's own
            other = read_progress(top)
            if other is not None:
                print(other.line())
        return 0
    got = rt.pool.peek(top)  # in memory only: None in a fresh process; it starts and waits for nothing
    kinds = {kind: _kind_status(rt, got, kind) for kind in ("docs", "code")}
    kinds["docs"]["transformer"] = _transformer_status(rt.cfg, top, progress)
    fallback = {"docs": cache["docs_fallback"]}
    cloud = None
    if rt.cloud is not None:  # bounded: the probe answers at once, whatever the network does
        lines = [" ".join(line.split()) for line in cloud_status_lines(rt.cloud, top)]
        cloud = {"configured": True, "lines": lines}
    payload = {
        "enabled": True,
        "ready": all(_ready(kinds[kind], cache[kind], fallback.get(kind)) for kind in kinds),
        "worktree": str(top),
        "config": str(top / CONFIG_REL),
        "semble": IndexPool.semble_version(),
        **kinds,
        "cache": cache,
        "encode_cache": _encode_cache_status(rt.cfg),
        "corpus_files": len(rt.corpus_for(top).files()),
        "cloud": cloud,
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def _transformer_status(cfg: Config, top: Path, progress: ProgressView | None) -> dict[str, Any] | None:
    """`docs.transformer`: the model and the build under way (this process's, else the one a live process publishes)."""
    spec = cfg.docs.transformer
    if spec is None:
        return None
    shown = progress or read_progress(top)
    return {"model": spec.model_path, "progress": shown.as_dict() if shown is not None else None}


def _encode_cache_status(cfg: Config) -> dict[str, Any] | None:
    """`encode_cache`: where the transformer's vectors are cached and how big the cache is (null: none yet)."""
    spec = cfg.docs.transformer
    if spec is None:
        return None
    path = encode_cache_path(spec)
    return {"path": str(path), "bytes": cache_size(path)}


def _ready(info: dict[str, Any], cache: str, fallback: str | None = None) -> bool:
    """A kind is ready when its saved index is valid (or it is off), or this process already holds it without error.

    Docs with a transformer model are also ready while the static index that serves meanwhile is valid (`fallback`).
    """
    return cache in ("valid", "off") or fallback == "valid" or (info["state"] == "ready" and not info["error"])


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


# -- check ---------------------------------------------------------------------------------------------------


def _check(args: argparse.Namespace) -> int:
    """The gating probe (check.py): the verdict line, `mcp:` and `launcher:`, or the verdict as JSON with `exit`. In a
    repository it keeps the verdict file as `gate` does, so `check` after a fix lifts the tool gate."""
    try:
        top: Path | None = RepoInfo.from_cwd(Path.cwd()).top
    except NotARepo:
        top = None
    verdict = assess(top, budget_s=args.budget, env=os.environ) if top else outside(os.environ, Path.cwd())
    if top is not None and not gate_off(os.environ):
        _keep_verdict(top, verdict)
    if args.format == "json":
        print(json.dumps({**asdict(verdict), "exit": verdict.exit_code()}, indent=2, ensure_ascii=False))
    else:
        print(verdict.line())
        print(f"mcp: {mcp_line(verdict.mcp)}")
        print(f"launcher: {verdict.launcher}")
    return verdict.exit_code()


# -- gate ----------------------------------------------------------------------------------------------------


def _gate(args: argparse.Namespace) -> int:
    """The hook entry (gate.py): read and drop the event on stdin, judge, keep the verdict file, print the JSON."""
    _drain_stdin()
    if gate_off(os.environ):
        return 0
    try:
        top = RepoInfo.from_cwd(Path.cwd()).top
    except (NotARepo, GitError):
        return 0
    verdict = judge(top, budget_s=args.budget, env=os.environ, client=args.client)
    _keep_verdict(top, verdict, "gate")
    output = hook_output(args.event, verdict)
    if output is not None:
        print(json.dumps(output))
    return 0


def _keep_verdict(top: Path, verdict: Verdict, verb: str = "check") -> None:
    """Write or remove the verdict file the tool gate reads (gate.py); a failure is one stderr line."""
    try:
        write_verdict(verdict_path(top), verdict)
    except (GitError, OSError) as err:
        print(" ".join(f"doc-search: {verb}: cannot keep the verdict file: {err}".split()), file=sys.stderr)


def _drain_stdin() -> None:
    """Read the hook event to its end and drop it, so the client's write never blocks (not from a terminal)."""
    stream = sys.stdin
    try:
        if stream is None or stream.isatty():
            return
        getattr(stream, "buffer", stream).read()
    except (OSError, ValueError):
        pass


# -- eval ----------------------------------------------------------------------------------------------------


def _eval(args: argparse.Namespace) -> int:
    rt = _runtime()
    if isinstance(rt, int):
        return rt
    try:
        with _progress_lines(rt, rt.repo.top):
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
    "check": _check,
    "gate": _gate,
}


if __name__ == "__main__":
    raise SystemExit(main())
