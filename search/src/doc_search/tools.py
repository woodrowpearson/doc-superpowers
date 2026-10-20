"""The three tools beside `search`: `fetch`, `related` and `status` (design section 7).

`fetch` reads one file of the working tree, confined to the worktree top, and answers at most
FETCH_MAX_LINES lines in all (the location line, the doc header and the truncation note included).
`related` moves between a document and the code it covers: the doc-index supplies the references,
semble's `find_related` the similar passages. `status` says what is indexed and what is not; it never
waits for a build and never reads a cloud collection.

Every answer is text. What cannot be answered is one line starting `doc-search:`; a path or a message
with a line break in it is flattened first, so repository content cannot start a line of its own.
"""

from __future__ import annotations

import posixpath
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from semble import SembleIndex
from semble.types import Chunk
from semble.utils import resolve_model_name

from .config import CONFIG_REL, Config
from .corpus import Corpus
from .engines import Building, IndexPool, Kind, WorktreeIndexes
from .render import INDENT, LINK_LIMIT, SEP, fit_to_cap, flat, render_hits
from .repo import GitError, RepoInfo, confine, norm_rel
from .searcher import CloudLeg, enrich_hit
from .types import DocMeta, Hit

FETCH_MAX_LINES = 400  # the whole answer: location line, doc header, file lines and truncation note
FETCH_CONTEXT = 20
FETCH_LINE_CHARS = 2000  # a minified file's single line must not eat the whole answer
FETCH_MAX_BYTES = 8 * 1024 * 1024
BINARY_PROBE = 8192

MAX_LIMIT = 50
RELATED_FETCH = 3  # the over-fetch for "see also", which drops the doc's own chunks and non-corpus files
RELATED_MAX_FETCH = 1000
LISTED = 5  # status: how many unindexed or skipped files it names

State = Literal["off", "building", "ready", "failed", "unloaded"]


class _Refuse(Exception):
    """A request that gets a one-line answer; the message is that line."""


def _refuse(message: str) -> _Refuse:
    return _Refuse(f"doc-search: {flat(message)}")


@dataclass(frozen=True)
class _View:
    """One kind of index in one worktree, as `status` and `related` need it."""

    kind: Kind
    state: State
    index: SembleIndex | None = None
    error: str | None = None
    built_at: float | None = None
    build_seconds: float | None = None

    def why(self) -> str:
        """Why there is no index to ask (for the states without one)."""
        if self.state == "off":
            return "code.enabled is false"
        if self.state == "building":
            return f"{self.kind} index building"
        if self.state == "unloaded":
            return f"{self.kind} index not loaded"
        return f"index failed: {flat(self.error)}" if self.error else "no index"


class DocTools:
    """`fetch`, `related` and `status` for the worktrees of one repository.

    `corpus_for(worktree)` supplies the worktree's `Corpus` (the caller owns that cache). `wait_s`
    is how long `related` waits for a first build; `fetch` never touches the indexes and `status`
    never waits. `cloud` is the optional remote docs leg: only its `status_lines` are used here.
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
    ) -> None:
        self.cfg = cfg
        self.repo = repo
        self._pool = pool
        self._corpus_for = corpus_for
        self._cloud = cloud
        self._wait_s = wait_s

    # -- entry points ----------------------------------------------------------------------------

    def fetch(
        self,
        path: str,
        worktree: Path,
        start_line: int | None = None,
        end_line: int | None = None,
        line: int | None = None,
        context: int = FETCH_CONTEXT,
    ) -> str:
        """A file of the working tree: lines `start_line`..`end_line`, or `line` and `context` either side."""
        return self._answer(lambda: self._fetch(path, Path(worktree), start_line, end_line, line, context))

    def related(self, path: str, worktree: Path, line: int | None = None, limit: int = 10) -> str:
        """For a doc: its metadata and similar passages. For code: the docs covering it and similar code."""
        return self._answer(lambda: self._related(path, Path(worktree), line, limit))

    def status(self, worktree: Path) -> str:
        """The setup and the index state of `worktree` first, then of the other worktrees in memory."""
        return self._answer(lambda: self._status(Path(worktree)))

    @staticmethod
    def _answer(job: Callable[[], str]) -> str:
        try:
            return job()
        except _Refuse as refusal:
            return str(refusal)
        except GitError as err:
            return f"doc-search: git failed: {flat(err)}"
        except OSError as err:  # a directory or file the process may not read
            return f"doc-search: cannot read: {flat(err.strerror or type(err).__name__)}"

    # -- fetch -----------------------------------------------------------------------------------

    def _fetch(
        self, path: str, worktree: Path, start_line: int | None, end_line: int | None, line: int | None, context: int
    ) -> str:
        rel, real = _locate(worktree, path)
        if not real.is_file():
            raise _refuse(f"not a file: {rel}")
        first, last = _window(start_line, end_line, line, context)
        size = real.stat().st_size
        if size > FETCH_MAX_BYTES:
            raise _refuse(f"file too large to fetch: {rel} ({size} bytes; the limit is {FETCH_MAX_BYTES})")
        lines, total = _read_lines(real, rel, first, last)
        if total == 0:
            return f"{rel}: empty file"
        if line is not None and line > total:
            raise _refuse(f"line {line} is past the end ({rel} has {total} lines)")
        if first > total:
            raise _refuse(f"start_line {first} is past the end ({rel} has {total} lines)")

        header = self._doc_header(worktree, rel)
        room = FETCH_MAX_LINES - 1 - (1 if header else 0)  # the location line and the header come first
        wanted = (total if last is None else min(last, total)) - first + 1
        note = None
        shown = wanted
        if wanted > room:
            shown = room - 1  # one line is the note
            note = (
                f"(truncated at {FETCH_MAX_LINES} lines: {wanted - shown} more lines in the range; "
                f"call again with start_line={first + shown} to continue)"
            )
        out = [f"{rel}:{first}-{first + shown - 1} of {total} lines"]
        if header:
            out.append(header)
        out += lines[:shown]
        if note:
            out.append(note)
        return "\n".join(out)

    def _doc_header(self, worktree: Path, rel: str) -> str | None:
        """`<title> · <type>[ · <status>][ · code: …]` for a corpus doc; None for any other file."""
        corpus = self._corpus_for(worktree)
        if not corpus.contains(rel):  # corpus.meta serves any path: metadata is for corpus files only
            return None
        meta = corpus.meta(rel)
        if meta is None:
            return None
        parts = [flat(meta.title), flat(meta.doc_type or "other")]
        if meta.status:
            parts.append(flat(meta.status))
        if meta.code_refs:
            parts.append(f"code: {_listed(meta.code_refs, LINK_LIMIT)}")
        return SEP.join(parts)

    # -- related ---------------------------------------------------------------------------------

    def _related(self, path: str, worktree: Path, line: int | None, limit: int) -> str:
        rel, _ = _locate(worktree, path)
        if line is not None and line < 1:
            raise _refuse("invalid request: line must be at least 1")
        limit = max(1, min(MAX_LIMIT, limit))
        corpus = self._corpus_for(worktree)
        if corpus.contains(rel):
            return self._related_doc(rel, worktree, corpus, line, limit)
        return self._related_code(rel, worktree, corpus, line, limit)

    def _related_doc(self, rel: str, worktree: Path, corpus: Corpus, line: int | None, limit: int) -> str:
        meta = corpus.meta(rel)
        if meta is None:
            raise _refuse(f"cannot read {rel} as text ({corpus.skipped().get(rel, 'unreadable')})")
        head = [f"related{SEP}{flat(rel)}{SEP}doc", _meta_line(meta)]
        if meta.code_refs:
            head.append(f"code: {_listed(meta.code_refs, limit)}")
        if meta.replaces:
            head.append(f"replaces: {flat(meta.replaces)}")
        if meta.superseded_by:
            head.append(f"superseded by: {flat(meta.superseded_by)}")
        head += _doc_index_note(corpus)

        view = self._view(self._pool.get(worktree, wait_s=self._wait_s), "docs")
        if view.index is None:
            head.append(f"see also: unavailable ({view.why()})")
            return "\n".join(head)
        seed = _seed_chunk(view.index, rel, line)
        if seed is None:
            head.append("see also: unavailable (not in semble's docs index; check .sembleignore)")
            return "\n".join(head)
        hits = [enrich_hit(hit, corpus) for hit in self._see_also(view.index, seed, rel, corpus, limit)]
        label = f"see also (similar to lines {seed.start_line}-{seed.end_line}):"
        return _with_hits(head, label, hits)

    @staticmethod
    def _see_also(index: SembleIndex, seed: Chunk, rel: str, corpus: Corpus, limit: int) -> list[Hit]:
        """The best passage of each other corpus file that is similar to `seed`, most similar first."""
        own = sum(1 for chunk in index.chunks if chunk.file_path == rel)
        top_k = limit * RELATED_FETCH + own
        while True:
            results = index.find_related(seed, top_k=top_k)
            found: dict[str, Chunk] = {}
            for result in results:
                path = result.chunk.file_path
                if path != rel and path not in found and corpus.contains(path):
                    found[path] = result.chunk
            if len(found) >= limit or len(results) < top_k or top_k >= RELATED_MAX_FETCH:
                break
            top_k = min(top_k * 4, RELATED_MAX_FETCH)  # the doc's own chunks and non-corpus files crowded the list
        return [
            Hit("doc", c.file_path, c.start_line, c.end_line, c.content, legs=("docs",))
            for c in list(found.values())[:limit]
        ]

    def _related_code(self, rel: str, worktree: Path, corpus: Corpus, line: int | None, limit: int) -> str:
        head = [f"related{SEP}{flat(rel)}{SEP}code"]
        covering = corpus.docindex.docs_covering(rel)
        if covering:
            head.append(f"documented by ({len(covering)}):")
            head += [INDENT + _doc_line(corpus, doc) for doc in covering[:limit]]
            if len(covering) > limit:
                head.append(f"{INDENT}(+{len(covering) - limit} more)")
        else:
            head.append("documented by: none")
        head += _doc_index_note(corpus)

        if line is None:
            head.append("similar code: pass `line` to find code similar to a passage of this file")
            return "\n".join(head)
        view = self._view(self._pool.get(worktree, wait_s=self._wait_s), "code")
        if view.index is None:
            head.append(f"similar code: unavailable ({view.why()})")
            return "\n".join(head)
        seed = _seed_chunk(view.index, rel, line)
        if seed is None:
            head.append("similar code: unavailable (not in the code index)")
            return "\n".join(head)
        hits = [
            enrich_hit(
                Hit(
                    "doc" if corpus.contains(r.chunk.file_path) else "code",
                    r.chunk.file_path,
                    r.chunk.start_line,
                    r.chunk.end_line,
                    r.chunk.content,
                    legs=("code",),
                ),
                corpus,
            )
            for r in view.index.find_related(seed, top_k=limit)
        ]
        return _with_hits(head, f"similar code (around lines {seed.start_line}-{seed.end_line}):", hits)

    # -- status ----------------------------------------------------------------------------------

    def _status(self, worktree: Path) -> str:
        top = worktree.resolve()
        docs_model = flat(self.cfg.docs.model or resolve_model_name())
        code_model = flat(self.cfg.code.model or resolve_model_name()) if self.cfg.code.enabled else "off"
        out = [
            "doc-search status",
            f"config: {self.repo.top / CONFIG_REL}",
            f"docs model: {docs_model}",
            f"code model: {code_model}",
            f"semble {IndexPool.semble_version()}",
            "",
            f"worktree: {top}",
            *self._worktree_lines(top, self._asked(top)),
        ]
        for tree in self._pool.resident():  # read after the asked worktree's call: that may have changed it
            if tree == top:
                continue
            got = self._pool.peek(tree)  # a look, not a use: the LRU order and the builds stay as they were
            if got is not None:  # None: evicted since resident() was read
                out += ["", f"worktree: {tree}", *self._worktree_lines(tree, got)]
        return "\n".join(out)

    def _asked(self, top: Path) -> WorktreeIndexes | Building | None:
        """The asked worktree's indexes without disturbing the pool; None when they are not loaded.

        One in memory is only looked at. One that is not is loaded (`get`, which starts the builds
        and never waits) so a first status call warms it, unless the pool is full: loading it would
        evict another worktree's warm indexes, and `status` must not do that.
        """
        got = self._pool.peek(top)
        if got is None and len(self._pool.resident()) < self._pool.max_worktrees:
            got = self._pool.get(top, wait_s=0)
        return got

    def _worktree_lines(self, tree: Path, got: WorktreeIndexes | Building | None) -> list[str]:
        docs, code = self._view(got, "docs"), self._view(got, "code")
        out = self._index_lines(tree, docs) + self._index_lines(tree, code)
        corpus = self._corpus_for(tree)
        try:
            out += self._corpus_lines(tree, corpus, docs, code)
        except GitError as err:
            out.append(f"corpus: git failed: {flat(err)}")
        index = corpus.docindex
        if index.present:
            out.append("doc-index: present")
        elif index.error:
            out.append(f"doc-index: absent ({flat(index.error)})")
        else:
            out.append("doc-index: absent (no docs/.doc-index.json: code refs and cross-links are omitted)")
        if self._cloud is not None:
            try:
                out += [flat(line) for line in self._cloud.status_lines(tree)]
            except Exception as err:  # noqa: BLE001 - the remote leg must never take status down
                out.append(f"cloud: status failed ({type(err).__name__})")
        return out

    def _index_lines(self, tree: Path, view: _View) -> list[str]:
        if view.state == "off":
            return [f"{view.kind} index: off ({view.why()})"]
        if view.state == "building":
            return [f"{view.kind} index: building (first build not finished)"]
        if view.state == "unloaded":
            return [f"{view.kind} index: not loaded (the pool is full; a search of this worktree loads it)"]
        state = (
            "ready (refresh failed; serving the previous index)" if view.state == "ready" and view.error else view.state
        )
        return [
            f"{view.kind} index: {state}",
            f"  chunks: {len(view.index.chunks) if view.index is not None else 0}",
            f"  files: {len(self._pool.indexed_files(tree, view.kind))}",
            f"  last build: {_age(self._pool.clock() - view.built_at) if view.built_at is not None else 'never'}",
            f"  build seconds: {view.build_seconds:.2f}" if view.build_seconds is not None else "  build seconds: n/a",
            f"  error: {flat(view.error) if view.error else 'none'}",
        ]

    def _corpus_lines(self, tree: Path, corpus: Corpus, docs: _View, code: _View) -> list[str]:
        files = corpus.files()
        count = f"corpus files: {len(files)}; not in semble's docs index: "
        if docs.index is None:
            out = [count + f"unknown (docs index {'not loaded' if docs.state == 'unloaded' else docs.state})"]
        else:
            missing = sorted(set(files) - self._pool.indexed_files(tree, "docs"))
            held = self._pool.indexed_files(tree, "code") if code.index is not None else set()
            out = [count + str(len(missing))]
            if missing:
                names = [flat(p) + (" [in code index]" if p in held else "") for p in missing[:LISTED]]
                more = f", +{len(missing) - LISTED} more" if len(missing) > LISTED else ""
                # a file the code index reads is findable; the hint is for the ones nothing indexes
                hint = "; check .sembleignore" if any(p not in held for p in missing) else ""
                out[0] += f" ({', '.join(names)}{more}){hint}"
        skipped = corpus.skipped()
        if skipped:
            shown = [f"{flat(path)}: {reason}" for path, reason in list(skipped.items())[:LISTED]]
            more = f", +{len(skipped) - LISTED} more" if len(skipped) > LISTED else ""
            out.append(f"skipped: {len(skipped)} ({', '.join(shown)}{more})")
        else:
            out.append("skipped: none")
        return out

    # -- the indexes ------------------------------------------------------------------------------

    def _view(self, got: WorktreeIndexes | Building | None, kind: Kind) -> _View:
        if kind == "code" and not self.cfg.code.enabled:
            return _View(kind, "off")
        if got is None:
            return _View(kind, "unloaded")
        if isinstance(got, Building):
            if not (got.docs_ready if kind == "docs" else got.code_ready):
                return _View(kind, "building")
            seen = got.partial or WorktreeIndexes()
        else:
            seen = got
        index = seen.docs if kind == "docs" else seen.code
        error = seen.error.get(kind)
        return _View(
            kind,
            "ready" if index is not None else "failed",
            index=index,
            error=error,
            built_at=seen.built_at.get(kind),
            build_seconds=seen.build_seconds.get(kind),
        )


# -- helpers ----------------------------------------------------------------------------------------


def _locate(worktree: Path, path: str) -> tuple[str, Path]:
    """The normalised repo-relative path and the real file or directory behind it, confined to `worktree`."""
    raw = norm_rel(path) if isinstance(path, str) else ""
    try:
        real = confine(worktree, raw)
    except ValueError as err:
        raise _refuse(str(err)) from err
    rel = posixpath.normpath(raw)
    if not real.exists():
        raise _refuse(f"no such file: {rel}")
    return rel, real


def _window(start_line: int | None, end_line: int | None, line: int | None, context: int) -> tuple[int, int | None]:
    """The first line wanted and the last (None: to the end of the file)."""
    if line is not None:
        if start_line is not None or end_line is not None:
            raise _refuse("invalid request: give either start_line and end_line, or line, not both")
        if line < 1:
            raise _refuse("invalid request: line must be at least 1")
        spread = max(0, context)
        return max(1, line - spread), line + spread
    if start_line is not None and start_line < 1:
        raise _refuse("invalid request: start_line must be at least 1")
    if end_line is not None and end_line < 1:
        raise _refuse("invalid request: end_line must be at least 1")
    first = 1 if start_line is None else start_line
    if end_line is not None and end_line < first:
        raise _refuse(f"invalid request: end_line {end_line} is before start_line {first}")
    return first, end_line


def _read_lines(real: Path, rel: str, first: int, last: int | None) -> tuple[list[str], int]:
    """Lines `first`..`last` (at most FETCH_MAX_LINES of them, as text) and the file's line count.

    Lines are the editor's: split on LF, a CR dropped. Invalid UTF-8 is replaced, not an error; a
    NUL byte in the first BINARY_PROBE bytes makes the file binary and it is refused.
    """
    window: list[str] = []
    total = 0
    try:
        with real.open("rb") as handle:
            if b"\0" in handle.read(BINARY_PROBE):
                raise _refuse(f"binary file: {rel}")
            handle.seek(0)
            for raw in handle:
                total += 1
                if total >= first and (last is None or total <= last) and len(window) < FETCH_MAX_LINES:
                    window.append(_text_line(raw, total == 1))
    except OSError as err:
        raise _refuse(f"cannot read {rel}: {err.strerror or type(err).__name__}") from err
    return window, total


def _text_line(raw: bytes, first: bool) -> str:
    text = raw.decode("utf-8", "replace")
    if first:
        text = text.removeprefix("﻿")
    text = text.removesuffix("\n").removesuffix("\r")
    if len(text) > FETCH_LINE_CHARS:
        text = f"{text[:FETCH_LINE_CHARS]}… [{len(text) - FETCH_LINE_CHARS} more characters]"
    return text


def _listed(items: tuple[str, ...], limit: int) -> str:
    """The first `limit` items, comma-separated, then a `(+N)` for the rest."""
    shown = ", ".join(flat(item) for item in items[:limit])
    extra = len(items) - limit
    return f"{shown} (+{extra})" if extra > 0 else shown


def _meta_line(meta: DocMeta) -> str:
    parts = [flat(meta.title), flat(meta.doc_type or "other")]
    if meta.status:
        parts.append(flat(meta.status))
    return SEP.join(parts)


def _doc_line(corpus: Corpus, path: str) -> str:
    """A doc named by the doc-index: its path, and title, type and status when it is a corpus doc."""
    meta = corpus.meta(path) if corpus.contains(path) else None
    return f"{flat(path)}{SEP}{_meta_line(meta)}" if meta is not None else flat(path)


def _doc_index_note(corpus: Corpus) -> list[str]:
    index = corpus.docindex
    if index.present:
        return []
    reason = flat(index.error) if index.error else "no doc-index (docs/.doc-index.json)"
    return [f"note: {reason}: code refs and doc links are unavailable; see status"]


def _seed_chunk(index: SembleIndex, rel: str, line: int | None) -> Chunk | None:
    """The chunk of `rel` that holds `line`, else the one nearest to it; the first chunk without a line."""
    chunks = [chunk for chunk in index.chunks if chunk.file_path == rel]
    if not chunks:
        return None
    if line is None:
        return min(chunks, key=lambda c: c.start_line)

    def gap(chunk: Chunk) -> tuple[int, int]:
        away = (
            0
            if chunk.start_line <= line <= chunk.end_line
            else min(abs(line - chunk.start_line), abs(line - chunk.end_line))
        )
        return away, chunk.start_line

    return min(chunks, key=gap)


def _with_hits(head: list[str], label: str, hits: list[Hit]) -> str:
    """The head lines, then the label and the numbered hits, in at most the response cap."""
    blocks = render_hits(hits)
    if blocks:
        blocks[0] = f"{label}\n{blocks[0]}"
        return fit_to_cap("\n".join(head), blocks)
    return "\n".join([*head, f"{label[:-1]}: none"])


def _age(seconds: float) -> str:
    whole = max(0, int(seconds))
    if whole < 60:
        return f"{whole} s ago"
    if whole < 3600:
        return f"{whole // 60} min ago"
    return f"{whole // 3600} h ago"
