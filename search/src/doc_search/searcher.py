"""The join: one request in, ranked docs and code hits out (design section 6).

Legs feed a response. The *docs leg* is semble's docs index searched with an exact pre-filter: the
corpus files that pass `doc_type`, `path_prefix` and the terminal filter, among the files that index
holds. The *ident leg* ranks the allowed files whose front matter, path or title names an
identifier of the query (`ADR-114`, `chat-70`) as a whole (`adr-11` is not `ADR-114`): semble's BM25
drops tokens that start with a digit, so the number of an id is invisible to it. The optional *cloud leg* is another ranked list of doc
chunks. The *code leg* is the code index; its hits under corpus paths become doc hits when they
pass the filters and are dropped otherwise, the rest stay code (with `scope=docs` the code index is
asked only about the allowed files it holds, which reaches corpus files of a code type such as
`.jsx` wireframes).

Docs are fused at file level (`fusion.fuse_by_file`): every leg is collapsed to one rank per file,
RRF runs over those rankings, and a file is shown by its best local docs chunk, else the cloud's
chunk. With `scope=all` the fused docs are interleaved with the code leg under a per-kind floor, on
the same score scale. Only the hits that are returned are enriched (heading path, doc type, status,
cross-links), and doc metadata is only ever read for paths of the corpus.

A first build can outlast the wait; the pool then says which half is ready and the answer comes
from that half with a note, unless the half the scope needs is the one still building.
"""

from __future__ import annotations

import logging
import re
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Protocol

from semble import SembleIndex
from semble.types import Chunk
from semble.utils import resolve_model_name

from .config import Config
from .corpus import Corpus
from .engines import Building, IndexPool, WorktreeIndexes
from .fusion import fuse_by_file, interleave_with_floor
from .repo import GitError, RepoInfo, norm_rel
from .types import HeaderInfo, Hit, SearchRequest, SearchResponse

logger = logging.getLogger(__name__)

SCOPES = ("all", "docs", "code")
MAX_LIMIT = 50
DOCS_FETCH = 3  # the docs and cloud legs fetch limit x 3 chunks, the code leg limit x 2
CODE_FETCH = 2
MEMO_ENTRIES = 32
MEMO_WORKTREES = 4
MAX_IDENT_TOKENS = 8
# An identifier is selective. A token that matches more than this many allowed files is not one
# (`2026`, `docs/`, `docs/specs`) and the ident leg ignores it, so it cannot flood the other legs.
IDENT_MAX_FILES = 10

# docs legs, in the order they enter the RRF (the earlier leg wins an exact tie: an exact identifier
# match beats a file that only ranks first by similarity) and in the order a leg's chunk represents a file
RANK_ORDER = ("ident", "docs", "cloud", "code")
PREFER = ("docs", "cloud", "code", "ident")

_TOKEN_STRIP = "\"'`,;:!?()[]{}<>\u201c\u201d\u2018\u2019"  # not ".": a name can start with one
_TOKEN_MARKS = frozenset("-_./")


class CloudLeg(Protocol):
    """The optional remote docs leg (Task 7)."""

    def hits(self, query: str, allowed: set[str], worktree: Path, limit: int) -> tuple[list[Hit], str | None]:
        """Up to `limit` ranked doc chunks for `query`, never from outside `allowed`, and a header note or None."""
        ...

    def status_lines(self, worktree: Path) -> list[str]:
        """The `status` tool's cloud lines for `worktree`. Reads the meta document at most, never scans a collection."""
        ...


def identifier_tokens(query: str) -> list[str]:
    """The words of `query` that look like identifiers: ids, keys, file names, paths.

    A word qualifies when, with what surrounds it stripped (quotes, commas, brackets, a final full
    stop, a leading `./`), it has at least 4 characters and contains a digit or one of `- _ . /`.
    Each token once whatever its case, first spelling kept, at most MAX_IDENT_TOKENS.
    """
    found: dict[str, str] = {}
    for word in query.split():
        token = _clean_token(word)
        if len(token) < 4 or not (any(c.isdigit() for c in token) or _TOKEN_MARKS & set(token)):
            continue
        found.setdefault(token.lower(), token)
        if len(found) == MAX_IDENT_TOKENS:
            break
    return list(found.values())


def _clean_token(word: str) -> str:
    token = word
    while True:
        cleaned = token.strip(_TOKEN_STRIP).rstrip(".")
        while cleaned.startswith("./"):
            cleaned = cleaned[2:]
        if cleaned == token:
            return token
        token = cleaned


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


@dataclass(frozen=True)
class _Row:
    """What the ident leg matches an allowed file on, lowercased once."""

    path: str
    path_l: str
    title: str
    title_l: str
    values: frozenset[str]  # the scalar front-matter values

    def tier(self, token: str, boundary: re.Pattern[str]) -> int | None:
        """How `token` (lowercase) names this file, strongest first, else None.

        0: a front-matter value equal to it, an explicit key. 1: it occurs in the path, 2: in the
        title, with a non-alphanumeric character or an end on both sides (`boundary`), so `adr-11`
        is not in `ADR-114` and `chat-70` is not in `chat-700`.
        """
        if token in self.values:
            return 0
        if token in self.path_l and boundary.search(self.path_l):
            return 1
        if token in self.title_l and boundary.search(self.title_l):
            return 2
        return None


@dataclass
class _Memo:
    at: float
    listing: list[str]
    allowed: frozenset[str]


@dataclass
class _RowsMemo:
    at: float
    listing: list[str]
    rows: tuple[_Row, ...]


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
        self._rows: OrderedDict[Path, _RowsMemo] = OrderedDict()  # per worktree: the ident leg's view of the corpus

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
        ident_leg = self._ident_leg(query, limit, allowed, corpus, docs.index, docs_leg, worktree)

        code_leg: list[Hit] = []
        code_docs: list[Hit] = []  # scope=docs: corpus files the code index holds, as one more docs leg
        if code.usable and scope != "docs":
            shown = {hit.path for hit in docs_leg + cloud_leg + ident_leg}
            code_leg = self._code_leg(query, limit, code.index, scope, corpus, allowed, shown, req, worktree)
        elif code.usable and allowed:
            code_docs = self._code_leg(query, limit, code.index, scope, corpus, allowed, set(), req, worktree)

        docs_fused, docs_scores = fuse_by_file(
            {"ident": ident_leg, "docs": docs_leg, "cloud": cloud_leg, "code": code_docs},
            rank_order=RANK_ORDER,
            prefer=PREFER,
        )
        if scope == "docs":
            final = docs_fused[:limit]
        elif scope == "code":
            final = code_leg[:limit]
        else:
            final = interleave_with_floor(docs_fused, code_leg, limit, docs_scores=docs_scores)

        hits = [enrich_hit(hit, corpus) for hit in final]
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
        """The code index's hits for a scope.

        `code` and `all`: code hits stay code; a hit under a corpus path is dropped for `code`, and
        for `all` becomes one doc hit per file when the file is allowed and no other leg shows it.
        `docs`: the index is asked about the allowed files it holds and nothing else, and every hit
        is a doc hit (one per file).
        """
        options: dict = {}
        if scope == "docs":
            held = sorted(allowed & self._pool.indexed_files(worktree, "code"))
            if not held:  # see _docs_leg: an empty filter must not reach semble
                return []
            options["filter_paths"] = held
        elif req.path_prefix:
            prefix = norm_rel(req.path_prefix)
            under = sorted(p for p in self._pool.indexed_files(worktree, "code") if p.startswith(prefix))
            if not under:
                return []
            options["filter_paths"] = under
        out: list[Hit] = []
        converted: dict[str, int] = {}  # corpus path -> its place in `out`
        for r in index.search(query, top_k=limit * CODE_FETCH, **options):
            chunk = r.chunk
            path = chunk.file_path
            if not corpus.contains(path):
                if scope != "docs":
                    out.append(Hit("code", path, chunk.start_line, chunk.end_line, chunk.content, legs=("code",)))
            elif scope != "code" and path in allowed and (scope == "docs" or path not in shown_docs):
                place = converted.get(path)
                if place is None:
                    converted[path] = len(out)
                    out.append(Hit("doc", path, chunk.start_line, chunk.end_line, chunk.content, legs=("code",)))
                else:
                    out[place] = replace(out[place], more_in_file=out[place].more_in_file + 1)
        return out

    def _ident_leg(
        self,
        query: str,
        limit: int,
        allowed: frozenset[str],
        corpus: Corpus,
        index: SembleIndex | None,
        docs_leg: list[Hit],
        worktree: Path,
    ) -> list[Hit]:
        """The allowed files named by an identifier of the query, best first.

        Tokens (`identifier_tokens`) are matched without case, as whole identifiers: a front-matter
        value equal to the token (tier 0), the token in the path (1) or in the title (2) between
        non-alphanumeric characters or ends. A file takes its best tier over the tokens; within a
        tier the shorter path comes first, then path order. A token that matches more than
        IDENT_MAX_FILES allowed files is dropped. Nothing reads file contents here: title and front
        matter come from the corpus's cached head parse, gathered once per corpus listing and
        `search.rescan_seconds`.

        A file is shown by the docs leg's best chunk of it when there is one, else by its first chunk
        in the docs index, else by a stand-in at line 1 with the title as the text.
        """
        tokens = [token.lower() for token in identifier_tokens(query)]
        if not tokens or not allowed:
            return []
        patterns = [re.compile(rf"(?<![a-z0-9]){re.escape(token)}(?![a-z0-9])") for token in tokens]
        per_token: list[list[tuple[int, _Row]]] = [[] for _ in tokens]
        for row in self._ident_rows(corpus, worktree):
            if row.path not in allowed:
                continue
            for found, token, pattern in zip(per_token, tokens, patterns, strict=True):
                tier = row.tier(token, pattern)
                if tier is not None:
                    found.append((tier, row))
        best: dict[str, tuple[int, int, str, _Row]] = {}
        for found in per_token:
            if not found or len(found) > IDENT_MAX_FILES:
                continue
            for tier, row in found:
                kept = best.get(row.path)
                if kept is None or tier < kept[0]:
                    best[row.path] = (tier, len(row.path), row.path, row)
        ranked = sorted(best.values(), key=lambda match: match[:3])
        rows = [match[3] for match in ranked[: limit * DOCS_FETCH]]

        best_local: dict[str, Hit] = {}
        for hit in docs_leg:
            best_local.setdefault(hit.path, hit)
        wanted = {row.path for row in rows if row.path not in best_local}
        first = _first_chunks(index, wanted & self._pool.indexed_files(worktree, "docs")) if index and wanted else {}
        out: list[Hit] = []
        for row in rows:
            local = best_local.get(row.path)
            chunk = first.get(row.path)
            if local is not None:
                out.append(replace(local, legs=("ident",), more_in_file=0))
            elif chunk is not None:
                out.append(Hit("doc", row.path, chunk.start_line, chunk.end_line, chunk.content, legs=("ident",)))
            else:
                out.append(Hit("doc", row.path, 1, 1, row.title, legs=("ident",)))
        return out

    def _ident_rows(self, corpus: Corpus, worktree: Path) -> tuple[_Row, ...]:
        """A row per corpus file, whatever the filters: shared by every query of the worktree."""
        listing = corpus.files()
        now = self._clock()
        with self._lock:
            memo = self._rows.get(worktree)
            if memo and now - memo.at < self.cfg.search.rescan_seconds and memo.listing == listing:
                return memo.rows
        built = []
        for path in listing:
            head = corpus.title_and_front_matter(path)  # one read per file: title and front matter together
            if head is None:
                continue
            title, fields = head
            values = frozenset(value.strip().lower() for value in fields.values())
            built.append(_Row(path, path.lower(), title, title.lower(), values))
        entry = _RowsMemo(at=now, listing=listing, rows=tuple(built))
        with self._lock:
            self._rows[worktree] = entry
            self._rows.move_to_end(worktree)
            while len(self._rows) > MEMO_WORKTREES:
                self._rows.popitem(last=False)
        return entry.rows


def enrich_hit(hit: Hit, corpus: Corpus) -> Hit:
    """A hit with its heading path, doc type, status and cross-links, from the corpus and its doc-index.

    A code hit gets the docs that cover its file; a doc hit gets its metadata, but only for a path of the
    corpus (`Corpus.meta` serves any path, so a non-corpus file under a doc's name must not read as a doc).
    """
    if hit.kind == "code":
        return replace(hit, links=tuple(corpus.docindex.docs_covering(hit.path)))
    if not corpus.contains(hit.path):
        return hit
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


def _first_chunks(index: SembleIndex, paths: set[str]) -> dict[str, Chunk]:
    """The chunk of each of `paths` that starts first, in one pass over the index."""
    found: dict[str, Chunk] = {}
    if not paths:
        return found
    for chunk in index.chunks:
        if chunk.file_path in paths:
            seen = found.get(chunk.file_path)
            if seen is None or chunk.start_line < seen.start_line:
                found[chunk.file_path] = chunk
    return found
