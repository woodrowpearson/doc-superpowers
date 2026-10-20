"""The join: one request in, ranked docs and code hits out (design section 6).

Three legs feed a response. The *docs leg* is semble's docs index searched with an exact
pre-filter: the corpus files that pass `doc_type`, `path_prefix` and the terminal filter, among the
files that index holds. The *code leg* is the code index; its hits under corpus paths become doc
hits when they pass the filters and are dropped otherwise, the rest stay code. The optional *cloud
leg* is another ranked list of doc chunks. Docs are fused by RRF over the docs and cloud legs and
collapsed to one hit per file; with `scope=all` they are interleaved with the code leg under a
per-kind floor. Only the hits that are returned are enriched (heading path, doc type, status,
cross-links), and doc metadata is only ever read for paths of the corpus.

A first build can outlast the wait; the pool then says which half is ready and the answer comes
from that half with a note, unless the half the scope needs is the one still building.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Protocol

from semble import SembleIndex
from semble.utils import resolve_model_name

from .config import Config
from .corpus import Corpus
from .engines import Building, IndexPool, WorktreeIndexes
from .fusion import collapse_by_file, interleave_with_floor, rrf
from .repo import GitError, RepoInfo, norm_rel
from .types import HeaderInfo, Hit, SearchRequest, SearchResponse

logger = logging.getLogger(__name__)

SCOPES = ("all", "docs", "code")
MAX_LIMIT = 50
DOCS_FETCH = 3  # the docs and cloud legs fetch limit x 3 chunks, the code leg limit x 2
CODE_FETCH = 2
MEMO_ENTRIES = 32


class CloudLeg(Protocol):
    """The optional remote docs leg (Task 7)."""

    def hits(self, query: str, allowed: set[str], worktree: Path, limit: int) -> tuple[list[Hit], str | None]:
        """Up to `limit` ranked doc chunks for `query`, never from outside `allowed`, and a header note or None."""
        ...


def model_label(model: str | None) -> str:
    """A model's short name for the header: the last path segment of its id or directory."""
    name = model or resolve_model_name()
    return name.rstrip("/").rsplit("/", 1)[-1] or name


@dataclass
class _Engine:
    """What the search can do with one kind of index right now."""

    index: SembleIndex | None = None
    building: bool = False
    disabled: bool = False  # switched off in the config
    problem: str | None = None  # why there is no index, when it is neither building nor disabled
    stale: str | None = None  # a refresh failed; the previous index is serving

    @property
    def usable(self) -> bool:
        return self.index is not None

    def reason(self) -> str:
        return self.problem or "no index"


@dataclass
class _Memo:
    at: float
    listing: list[str]
    allowed: frozenset[str]


class Searcher:
    """Answers `SearchRequest`s for the worktrees of `repo`.

    `corpus_for(worktree)` supplies the worktree's `Corpus` (its doc-index included); the
    caller owns that cache. `search` may be called from several threads.
    """

    def __init__(
        self,
        cfg: Config,
        repo: RepoInfo,
        pool: IndexPool,
        corpus_for: Callable[[Path], Corpus],
        cloud: CloudLeg | None = None,
        *,
        wait_s: float = 20.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.cfg = cfg
        self.repo = repo
        self._pool = pool
        self._corpus_for = corpus_for
        self._cloud = cloud
        self._wait_s = wait_s
        self._clock = clock
        self._lock = threading.Lock()
        self._memo: OrderedDict[tuple, _Memo] = OrderedDict()

    # -- entry point ---------------------------------------------------------------------

    def search(self, req: SearchRequest, worktree: Path) -> SearchResponse | str:
        """The ranked hits, or a one-line answer (invalid request, index building, engine off, git failure)."""
        try:
            return self._search(req, Path(worktree))
        except GitError as err:
            return f"doc-search: git failed: {err}"

    def _search(self, req: SearchRequest, worktree: Path) -> SearchResponse | str:
        query = req.query.strip()
        if not query:
            return "doc-search: invalid request: query is empty"
        scope = req.scope
        if scope not in SCOPES:
            return f"doc-search: invalid request: scope must be all, docs or code (got {scope!r})"
        limit = max(1, min(MAX_LIMIT, req.limit))
        corpus = self._corpus_for(worktree)

        got = self._pool.get(worktree, wait_s=self._wait_s)
        docs, code = self._engines(got)
        refusal = self._refusal(scope, docs, code, got, worktree)
        if refusal:
            return refusal

        notes: list[str] = []
        for kind, engine, wanted in (("docs", docs, scope != "code"), ("code", code, scope != "docs")):
            if not wanted:
                continue
            if engine.building:
                notes.append(f"{kind} index building")
            elif not engine.usable and not engine.disabled:
                notes.append(f"{kind} index unavailable ({engine.reason()})")
            elif engine.stale:
                notes.append(f"{kind} index refresh failed, serving the previous one ({engine.stale})")

        allowed = self._allowed(corpus, worktree, req) if scope != "code" else frozenset()
        docs_leg: list[Hit] = []
        cloud_leg: list[Hit] = []
        if scope != "code" and docs.usable:
            docs_leg = self._docs_leg(query, limit, docs.index, allowed, worktree)
            if self._cloud is not None and allowed:
                cloud_leg, note = self._cloud_leg(query, limit, allowed, worktree)
                if note:
                    notes.append(note)
        docs_fused, docs_scores = _fuse_docs(docs_leg, cloud_leg)

        code_leg: list[Hit] = []
        if scope != "docs" and code.usable:
            shown = {hit.path for hit in docs_fused}
            code_leg = self._code_leg(query, limit, code.index, scope, corpus, allowed, shown, req, worktree)

        if scope == "docs":
            final = docs_fused[:limit]
        elif scope == "code":
            final = code_leg[:limit]
        else:
            final = interleave_with_floor(docs_fused, code_leg, limit, docs_scores=docs_scores)

        hits = [self._enrich(hit, corpus) for hit in final]
        header = HeaderInfo(
            docs_model=model_label(self.cfg.docs.model),
            code=self._pool.semble_version() if code.usable or code.building else "off",
            cloud=self._cloud_label(),
            notes=tuple(notes),
            truncated=False,
        )
        return SearchResponse(hits=hits, header=header)

    # -- which engines answer ----------------------------------------------------------------

    def _engines(self, got: WorktreeIndexes | Building) -> tuple[_Engine, _Engine]:
        if isinstance(got, Building):
            seen = got.partial or WorktreeIndexes()
            done = {"docs": got.docs_ready, "code": got.code_ready}
        else:
            seen = got
            done = {"docs": True, "code": True}
        docs = self._engine("docs", seen.docs, done["docs"], seen)
        if not self.cfg.code.enabled:
            return docs, _Engine(disabled=True, problem="code.enabled is false")
        return docs, self._engine("code", seen.code, done["code"], seen)

    @staticmethod
    def _engine(kind: str, index: SembleIndex | None, finished: bool, seen: WorktreeIndexes) -> _Engine:
        error = seen.error.get(kind)
        if not finished:
            return _Engine(building=True)
        if index is None:
            return _Engine(problem=f"index failed: {error}" if error else "no index")
        return _Engine(index=index, stale=error)

    def _refusal(
        self, scope: str, docs: _Engine, code: _Engine, got: WorktreeIndexes | Building, worktree: Path
    ) -> str | None:
        """The one-line answer when the scope's own engines cannot answer, else None."""
        if scope == "docs":
            if docs.building:
                return _building_line(got, worktree)
            if not docs.usable:
                return f"doc-search: docs search is off ({docs.reason()})"
        elif scope == "code":
            if code.building:
                return _building_line(got, worktree)
            if not code.usable:
                return f"doc-search: code search is off ({code.reason()})"
        elif not docs.usable and not code.usable:
            if docs.building or code.building:
                return _building_line(got, worktree)
            return f"doc-search: no search index is available (docs: {docs.reason()}; code: {code.reason()})"
        return None

    def _cloud_label(self) -> str | None:
        if self._cloud is None:
            return None
        return self.cfg.cloud.vertex.model if self.cfg.cloud else "cloud"

    # -- the allowed set -----------------------------------------------------------------------

    def _allowed(self, corpus: Corpus, worktree: Path, req: SearchRequest) -> frozenset[str]:
        """The corpus files passing the request's filters, remembered for `search.rescan_seconds`.

        `Corpus.allowed` costs about 0.1 ms per doc, so repeated queries reuse the result as long as
        the corpus listing is unchanged and the interval has not passed (a status edit shows up
        within it, as a changed file list does).
        """
        key = (
            worktree,
            tuple(sorted({t.lower() for t in req.doc_type})),
            norm_rel(req.path_prefix) if req.path_prefix else "",
            bool(req.include_terminal),
        )
        listing = corpus.files()
        now = self._clock()
        with self._lock:
            memo = self._memo.get(key)
            if memo and now - memo.at < self.cfg.search.rescan_seconds and memo.listing == listing:
                self._memo.move_to_end(key)
                return memo.allowed
        entry = _Memo(
            at=now,
            listing=listing,
            allowed=frozenset(corpus.allowed(req.doc_type, req.path_prefix, req.include_terminal)),
        )
        with self._lock:
            self._memo[key] = entry
            self._memo.move_to_end(key)
            while len(self._memo) > MEMO_ENTRIES:
                self._memo.popitem(last=False)
        return entry.allowed

    # -- legs -----------------------------------------------------------------------------------

    def _docs_leg(
        self, query: str, limit: int, index: SembleIndex, allowed: frozenset[str], worktree: Path
    ) -> list[Hit]:
        # semble stops filtering when none of the paths it is given is indexed: an empty
        # intersection must mean no hits, so it never reaches semble
        candidates = sorted(allowed & self._pool.indexed_files(worktree, "docs"))
        if not candidates:
            return []
        results = index.search(query, top_k=limit * DOCS_FETCH, filter_paths=candidates)
        return [
            Hit("doc", r.chunk.file_path, r.chunk.start_line, r.chunk.end_line, r.chunk.content, legs=("docs",))
            for r in results
            if r.chunk.file_path in allowed  # second guard
        ]

    def _cloud_leg(
        self, query: str, limit: int, allowed: frozenset[str], worktree: Path
    ) -> tuple[list[Hit], str | None]:
        try:
            hits, note = self._cloud.hits(query, set(allowed), worktree, limit * DOCS_FETCH)
        except Exception as err:  # noqa: BLE001 - the remote leg must never take local search down
            logger.debug("doc-search: cloud leg failed", exc_info=True)
            return [], f"cloud leg failed ({type(err).__name__})"
        return [hit for hit in hits if hit.path in allowed], note

    def _code_leg(
        self,
        query: str,
        limit: int,
        index: SembleIndex,
        scope: str,
        corpus: Corpus,
        allowed: frozenset[str],
        shown_docs: set[str],
        req: SearchRequest,
        worktree: Path,
    ) -> list[Hit]:
        options: dict = {}
        if req.path_prefix:
            prefix = norm_rel(req.path_prefix)
            under = sorted(p for p in self._pool.indexed_files(worktree, "code") if p.startswith(prefix))
            if not under:  # see _docs_leg: an empty filter must not reach semble
                return []
            options["filter_paths"] = under
        out: list[Hit] = []
        converted: dict[str, int] = {}  # corpus path -> its place in `out`
        for r in index.search(query, top_k=limit * CODE_FETCH, **options):
            chunk = r.chunk
            if not corpus.contains(chunk.file_path):
                out.append(
                    Hit("code", chunk.file_path, chunk.start_line, chunk.end_line, chunk.content, legs=("code",))
                )
            elif scope == "all" and chunk.file_path in allowed and chunk.file_path not in shown_docs:
                # a corpus file the docs index did not return: it is a doc, once per file
                place = converted.get(chunk.file_path)
                if place is None:
                    converted[chunk.file_path] = len(out)
                    out.append(
                        Hit("doc", chunk.file_path, chunk.start_line, chunk.end_line, chunk.content, legs=("code",))
                    )
                else:
                    out[place] = replace(out[place], more_in_file=out[place].more_in_file + 1)
        return out

    # -- enrichment --------------------------------------------------------------------------------

    def _enrich(self, hit: Hit, corpus: Corpus) -> Hit:
        if hit.kind == "code":
            return replace(hit, links=tuple(corpus.docindex.docs_covering(hit.path)))
        if not corpus.contains(hit.path):
            return hit  # corpus.meta serves any path: doc metadata is for corpus files only
        meta = corpus.meta(hit.path)
        if meta is None:
            return hit
        return replace(
            hit,
            heading_path=corpus.heading_path_at(hit.path, hit.start_line),
            doc_type=meta.doc_type,
            status=meta.status,
            links=meta.code_refs,
        )


def _building_line(got: WorktreeIndexes | Building, worktree: Path) -> str:
    docs_ready = got.docs_ready if isinstance(got, Building) else True
    code_ready = got.code_ready if isinstance(got, Building) else True
    return (
        f"doc-search: index building for {worktree} "
        f"(docs {'ready' if docs_ready else 'building'}, code {'ready' if code_ready else 'building'}); retry shortly"
    )


def _fuse_docs(docs_leg: list[Hit], cloud_leg: list[Hit]) -> tuple[list[Hit], list[float]]:
    """RRF over the docs and cloud legs, one hit per file, with each kept hit's fused score."""
    by_key: dict[tuple[str, int, int], Hit] = {}
    ranked: list[list[tuple[str, int, int]]] = []
    for leg in (docs_leg, cloud_leg):
        keys = []
        for hit in leg:
            key = (hit.path, hit.start_line, hit.end_line)
            seen = by_key.get(key)
            if seen is None:
                by_key[key] = hit
            else:  # the same chunk from both legs: the first leg's text, both legs named
                by_key[key] = replace(seen, legs=seen.legs + tuple(leg for leg in hit.legs if leg not in seen.legs))
            keys.append(key)
        ranked.append(keys)
    fused = rrf(ranked)
    hits = collapse_by_file([by_key[key] for key, _ in fused])
    best: dict[str, float] = {}
    for key, score in fused:
        best.setdefault(key[0], score)
    return hits, [best[hit.path] for hit in hits]
