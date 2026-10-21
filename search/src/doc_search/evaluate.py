"""Known-answer evaluation (design sections 3(b) and 9): `doc-search eval <file.jsonl>`.

Each line of the file is `{"query": "...", "expect": ["repo/relative/path", ...], "kind": "..."}`; `kind` is
optional and, when lines carry one, the report breaks every leg down by it. A query is scored per *file*:
a leg's ranked hits are collapsed to distinct paths in rank order and the first `k` are compared with `expect`.

 - recall@k: the share of the expected files in the top k, averaged over the queries.
 - MRR: 1 / the rank of the first expected file in the top k (0 when none is), averaged over the queries.

Legs, in the order they are reported:

 - `docs`: the searcher with `scope=docs` (docs index, the identifier leg, and the cloud leg when it is on).
 - `code`: `scope=code`.
 - `cloud`: the cloud leg alone, asked directly with the allowed set (only when a cloud leg is given).
 - `all`: `scope=all`, the joined result.
 - `semble-single`: one semble index over docs and code (`docs.model`), queried at `k x 3` chunks and collapsed
   per file. It is skipped for a transformer `docs.model`: the single index would encode the code with it.

semble-single cannot tell a deprecated doc from a current one, so the legs it is compared with cannot either: the
`docs` and `all` legs (and the allowed set of the `cloud` leg) include the terminal docs (deprecated, superseded,
archived), as `include_terminal=true` does for a search. The report says so on its first line.

A leg that cannot answer (its index is off or failed, or the cloud failed every query) is reported as skipped
with the reason, not scored 0.
The last line applies the decision rule of section 3(b): semble-single is a candidate for the default when it
comes within 0.02 of the joined result on recall@k and MRR. Within means not worse by more than 0.02; a
single index that scores higher qualifies a fortiori.
"""

from __future__ import annotations

import json
import logging
from collections import defaultdict
from collections.abc import Callable, Collection, Sequence
from dataclasses import dataclass, field
from pathlib import Path

from semble import ContentType, SembleIndex
from semble.cache import save_index_to_cache

from .cloud import describe
from .config import Config
from .corpus import Corpus
from .engines import FOREGROUND_WAIT_S, IndexPool
from .repo import norm_rel
from .searcher import MAX_LIMIT, CloudLeg, Searcher
from .types import SearchRequest

logger = logging.getLogger(__name__)

TOLERANCE = 0.02  # the decision rule of section 3(b)
SINGLE_FETCH = 3  # semble-single is asked for k x 3 chunks: collapsing them per file leaves fewer
LEG_ORDER = ("docs", "code", "cloud", "all", "semble-single")
NO_KIND = "(no kind)"
TERMINAL_NOTE = "(terminal docs included)"  # on the report's first line: the docs and all legs search terminal docs
EPSILON = 1e-9


class EvalFileError(ValueError):
    """A known-answer file that cannot be used. `line` is the 1-based number of the line at fault, 0 for the file."""

    def __init__(self, line: int, problem: str) -> None:
        self.line = line
        self.problem = problem
        super().__init__(f"line {line}: {problem}" if line else problem)


@dataclass(frozen=True)
class EvalCase:
    query: str
    expect: tuple[str, ...]
    kind: str | None = None


@dataclass(frozen=True)
class Score:
    """Recall@k and MRR averaged over `queries` queries."""

    queries: int
    recall: float
    mrr: float


@dataclass
class LegResult:
    """One leg's scores, or why it was skipped. `notes` are the header notes its answers carried."""

    name: str
    overall: Score | None
    by_kind: dict[str, Score] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    skipped: str | None = None


@dataclass
class EvalReport:
    path: str
    k: int
    queries: int
    legs: list[LegResult]

    def leg(self, name: str) -> LegResult | None:
        return next((leg for leg in self.legs if leg.name == name), None)

    def recall(self, name: str) -> float | None:
        leg = self.leg(name)
        return leg.overall.recall if leg is not None and leg.overall is not None else None

    def decision(self) -> bool:
        """True when semble-single is within TOLERANCE of the joined result; False too when either did not run."""
        joined, single = self.leg("all"), self.leg("semble-single")
        if joined is None or single is None or joined.overall is None or single.overall is None:
            return False
        return (
            single.overall.recall >= joined.overall.recall - TOLERANCE - EPSILON
            and single.overall.mrr >= joined.overall.mrr - TOLERANCE - EPSILON
        )

    def decision_line(self) -> str:
        return (
            f"semble-single within {TOLERANCE:.2f} of joined (recall@k and MRR): {'yes' if self.decision() else 'no'}"
        )

    def render(self) -> str:
        """The report as text; the decision line is the last."""
        k = self.k
        name_width = max(len(leg.name) for leg in self.legs) + 2
        out = [f"doc-search eval · {self.path} · {self.queries} queries · k={k} {TERMINAL_NOTE}"]
        notes: dict[str, list[str]] = {}  # a note once, with the legs whose answers carried it
        for leg in self.legs:
            if leg.overall is None:
                out.append(f"{leg.name:<{name_width}}skipped: {leg.skipped}")
                continue
            out.append(f"{leg.name:<{name_width}}{_cells(leg.overall, k)}")
            kind_width = max((len(kind) for kind in leg.by_kind), default=0)
            if leg.by_kind and not (len(leg.by_kind) == 1 and NO_KIND in leg.by_kind):
                for kind, score in leg.by_kind.items():
                    out.append(f"  {kind:<{kind_width}} ({score.queries})  {_cells(score, k)}")
            for note in leg.notes:
                notes.setdefault(note, []).append(leg.name)
        out += [f"note: {note} ({', '.join(names)})" for note, names in notes.items()]
        out.append(self.decision_line())
        return "\n".join(out)


def _cells(score: Score, k: int) -> str:
    return f"recall@{k} {score.recall:.4f}  MRR {score.mrr:.4f}"


# -- the file ---------------------------------------------------------------------------------------------


def load_cases(path: Path | str) -> list[EvalCase]:
    """The cases of a known-answer file. Blank lines are skipped (and still counted in the line numbers).

    Raises EvalFileError for a line that is not a usable case or a file with none, and OSError when the file
    cannot be read.
    """
    cases: list[EvalCase] = []
    try:
        with open(path, encoding="utf-8") as handle:
            for number, raw in enumerate(handle, start=1):
                if not raw.strip():
                    continue
                cases.append(_case(number, raw))
    except UnicodeDecodeError as err:
        raise EvalFileError(0, f"not UTF-8 text ({err.reason})") from err
    if not cases:
        raise EvalFileError(0, "no queries in the file")
    return cases


def _case(number: int, raw: str) -> EvalCase:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as err:
        raise EvalFileError(number, f"not valid JSON ({err.msg})") from err
    if not isinstance(data, dict):
        raise EvalFileError(number, "each line must be a JSON object")
    query = data.get("query")
    if not isinstance(query, str) or not query.strip():
        raise EvalFileError(number, '"query" must be a non-empty string')
    expect = data.get("expect")
    if not isinstance(expect, list) or not expect or not all(isinstance(item, str) and item.strip() for item in expect):
        raise EvalFileError(number, '"expect" must be a non-empty array of paths')
    kind = data.get("kind")
    if kind is not None and (not isinstance(kind, str) or not kind.strip()):
        raise EvalFileError(number, '"kind" must be a non-empty string when present')
    return EvalCase(query, tuple(dict.fromkeys(norm_rel(item.strip()) for item in expect)), kind)


# -- scoring ----------------------------------------------------------------------------------------------


def score_ranking(ranked: Sequence[str], expect: Collection[str], k: int) -> tuple[float, float]:
    """(recall@k, reciprocal rank) of one query: `ranked` is the leg's paths in rank order, `expect` the answers."""
    wanted = set(expect)
    top = list(ranked[:k])
    found = wanted & set(top)
    recall = len(found) / len(wanted) if wanted else 0.0
    reciprocal = next((1.0 / rank for rank, path in enumerate(top, start=1) if path in wanted), 0.0)
    return recall, reciprocal


def _average(rows: Sequence[tuple[float, float]]) -> Score:
    n = len(rows)
    return Score(n, sum(r for r, _ in rows) / n, sum(m for _, m in rows) / n)


def _distinct(paths: Sequence[str]) -> list[str]:
    return list(dict.fromkeys(paths))


class _Skip(Exception):
    """The leg cannot answer; the message says why."""


class _Unanswered(Exception):
    """One query the leg could not answer; the message says why. The leg is skipped only when every query is."""


Ranker = Callable[[str], tuple[list[str], list[str]]]  # query -> (distinct paths in rank order, header notes)


def run_eval(
    searcher: Searcher,
    pool: IndexPool,
    path: Path | str,
    k: int,
    worktree: Path,
    *,
    cloud: CloudLeg | None = None,
    corpus_for: Callable[[Path], Corpus] | None = None,
) -> EvalReport:
    """Score every leg over the cases of `path` for `worktree`.

    `cloud` (with `corpus_for`, for the allowed set) adds the cloud-alone leg. The file is read first, so a
    malformed one raises EvalFileError before any index is touched; the indexes are then built (waited for)
    once, and the legs run one after the other.
    """
    if not 1 <= k <= MAX_LIMIT:
        raise ValueError(f"k must be between 1 and {MAX_LIMIT}")
    cases = load_cases(path)
    worktree = Path(worktree)
    pool.get(worktree, wait_s=FOREGROUND_WAIT_S)  # build once, here; the legs then only search

    def searched(scope: str) -> Ranker:
        def rank(query: str) -> tuple[list[str], list[str]]:
            request = SearchRequest(
                query=query,
                scope=scope,  # type: ignore[arg-type]
                limit=k,
                include_terminal=scope != "code",  # the code leg never reads the allowed set
            )
            answer = searcher.search(request, worktree)
            if isinstance(answer, str):
                raise _Skip(_reason(answer))
            return _distinct([hit.path for hit in answer.hits]), list(answer.header.notes)

        return rank

    legs: list[tuple[str, Callable[[], Ranker]]] = [
        ("docs", lambda: searched("docs")),
        ("code", lambda: searched("code")),
    ]
    if cloud is not None:
        legs.append(("cloud", lambda: _cloud_ranker(cloud, corpus_for, worktree, k)))
    legs += [
        ("all", lambda: searched("all")),
        ("semble-single", lambda: _single_ranker(searcher.cfg, worktree, k)),
    ]
    return EvalReport(str(path), k, len(cases), [_run_leg(name, make, cases, k) for name, make in legs])


def _run_leg(name: str, make: Callable[[], Ranker], cases: Sequence[EvalCase], k: int) -> LegResult:
    notes: dict[str, None] = {}
    rows: list[tuple[float, float]] = []
    kinds: dict[str, list[tuple[float, float]]] = defaultdict(list)
    unanswered: list[str] = []
    try:
        rank = make()
        for case in cases:
            try:
                ranked, case_notes = rank(case.query)
            except _Unanswered as why:  # scored as an empty answer, unless nothing was answered at all
                unanswered.append(str(why))
                ranked, case_notes = [], [str(why)]
            notes.update(dict.fromkeys(case_notes))
            row = score_ranking(ranked, case.expect, k)
            rows.append(row)
            kinds[case.kind or NO_KIND].append(row)
    except _Skip as skip:
        return LegResult(name, None, skipped=str(skip))
    if len(unanswered) == len(cases):
        return LegResult(name, None, skipped=unanswered[0])
    by_kind = {kind: _average(found) for kind, found in sorted(kinds.items())}
    return LegResult(name, _average(rows), by_kind, list(notes))


def _reason(line: str) -> str:
    """A searcher's one-line refusal without its `doc-search: ` prefix."""
    return line.removeprefix("doc-search: ")


def _cloud_ranker(cloud: CloudLeg, corpus_for: Callable[[Path], Corpus] | None, worktree: Path, k: int) -> Ranker:
    if corpus_for is None:
        raise _Skip("no corpus to name the allowed files")
    allowed = set(corpus_for(worktree).allowed((), None, True))  # terminal docs too, as the docs and all legs

    def rank(query: str) -> tuple[list[str], list[str]]:
        try:
            hits, note = cloud.hits(query, allowed, worktree, k * SINGLE_FETCH)
        except Exception as err:  # noqa: BLE001 - a remote leg that fails is a note, as in search
            raise _Unanswered(f"cloud leg failed ({describe(err)})") from err
        if note and not hits:  # a degraded leg, or one with no stamp to read: it said why it has nothing
            raise _Unanswered(note)
        return _distinct([hit.path for hit in hits if hit.path in allowed]), [note] if note else []

    return rank


def _single_ranker(cfg: Config, worktree: Path, k: int) -> Ranker:
    if not cfg.code.enabled:
        raise _Skip("code.enabled is false: there is no code index to join")
    if cfg.docs.transformer is not None:  # one index has one model; the code index is static (code.model refuses this)
        raise _Skip("docs.model is a transformer model: the single index would encode the code with it")
    try:
        index = SembleIndex.from_path(
            str(worktree), content=[ContentType.DOCS, ContentType.CODE], model_path=cfg.docs.model
        )
    except Exception as err:  # noqa: BLE001 - an index that cannot be built is a skipped leg
        raise _Skip(f"index failed: {describe(err)}") from err
    try:
        save_index_to_cache(index, str(worktree))  # the next run finds it, as the pool's indexes are found
    except Exception as err:  # noqa: BLE001 - an index that cannot be cached still serves
        logger.warning("doc-search: could not cache the single index of %s: %s", worktree, describe(err))

    def rank(query: str) -> tuple[list[str], list[str]]:
        results = index.search(query, top_k=k * SINGLE_FETCH)
        return _distinct([r.chunk.file_path for r in results]), []

    return rank
