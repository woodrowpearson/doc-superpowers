"""The cloud docs leg, write path (design section 8): the guarded indexer. Only the CLI runs it, never the server.

One run, in this order (abundance's guarantees, carried over, plus the checks of the review):

 1. `base_ref` is resolved: the configured value, else `origin/<the remote's default branch>`.
 2. Base guard: HEAD must be `base_ref` or an ancestor of it. The collection is one shared corpus with one
    stamp, so a branch must not write it; `allow_off_base` is the explicit override.
 3. The stamp is read (no write yet) and decides what the run is, in this order:
    - a stamp naming another repository (`repo_id`, the root commit(s)) is refused unless `force`; a stamp
      without one (abundance's) is accepted;
    - no stamp: a full run;
    - the stamp's commit S is not in this clone: refused (`git fetch`); `allow_off_base` opens an explicit
      `full` or `prune-orphans`, never a catch-up;
    - HEAD is a strict ancestor of S (fetched, not pulled): the corpus is ahead. A catch-up does nothing and
      says so; an explicit `full` or `prune-orphans` is refused unless `allow_off_base`. Nothing rolls the
      corpus back by accident;
    - S == HEAD: a catch-up does nothing; S an ancestor of HEAD: a catch-up from S; histories that diverged:
      a full run. Another embedder or chunker version in the stamp makes a catch-up a full run that trusts no
      sha.
    A refusal or a no-op writes nothing, not even the lease.
 4. Lease: a transactional lease document (`<meta>/catch_up_lease`, 1800 s) keeps two hosts from rewriting the
    same files at once. It is released in `finally`, renewed every 5 minutes, and checked again before orphans
    are deleted and before the stamp. A lease another host took ends the run (`LeaseLost`): no more writes, no
    stamp. So does a lease document that is gone: only a holder deletes it, so another run took ours (it
    expired while this one stalled), finished and released it, and may have written. Only the first
    acquisition creates the document.
 5. The file set: every in-scope file of HEAD for `full`; the files changed from the stamp to HEAD for
    `catch-up`. `prune-orphans` indexes nothing.
 6. Per file: sha256 against the stored chunk 0's `fileSha256`, then chunk, embed (`RETRIEVAL_DOCUMENT`), and
    replace the file's chunks in batches of at most 500 operations.
 7. A deleted file's chunks go only when `git ls-tree HEAD -- <path>` says it is gone.
 8. Orphans (`full`, `prune-orphans`): corpus paths git no longer knows. More than max(20, 10% of the corpus's
    paths) are not pruned without `force` (the corpus measured as it was before this run wrote anything): that
    many means this is not the repository the corpus was built from. The run reports them
    (`orphans_pending`) and is not stamped.
 9. The stamp (`<meta>/index`) is written only when no file failed and nothing is pending: it is the lower
    bound of the next catch-up, so stamping over a failure would drop that file from every later run's range.

What is indexed is what HEAD holds, not the working tree: the stamp says "built from this commit", and a
dirty checkout must not put its edits in the shared corpus under that commit. The files come from
`git ls-tree`, their bytes from `git cat-file`; the working tree is read only for each doc's type and title.

Chunk documents have deterministic ids (a hash of the path, and the ordinal), so a rewrite replaces a chunk
in place and an interrupted run leaves no duplicates. A file's chunks are written highest ordinal first:
chunk 0 carries the sha the next run trusts, so it is the last thing a file's write commits. The ten fields
are abundance's, plus `startLine` and `endLine`; `headingPath` is a list of strings, as abundance's reader
expects.
"""

from __future__ import annotations

import hashlib
import logging
import os
import socket
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path, PurePosixPath
from typing import Any, Literal

from ..chunker import CHUNKER_VERSION, CloudChunk, chunk_lines, chunk_markdown
from ..config import Config
from ..corpus import Corpus
from ..docindex import DocIndex
from ..repo import git, git_bytes, is_ancestor, rev_parse
from . import CLOUD_TIMEOUT_S, CloudUnavailable, LazyClient, describe, import_module
from .read import STAMP_DOC, CorpusStamp, _parse_stamp, resolve_base_ref
from .vertex import VertexEmbedder

logger = logging.getLogger(__name__)

Mode = Literal["catch-up", "full", "prune-orphans"]
MODES: tuple[str, ...] = ("catch-up", "full", "prune-orphans")

LEASE_DOC = "catch_up_lease"
LEASE_TTL_S = 1800
LEASE_RENEW_S = 300  # a run checks and extends its lease at least this often
PRUNE_CAP_MIN = 20  # orphans are pruned without force up to max(PRUNE_CAP_MIN, PRUNE_CAP_RATIO of the corpus's paths)
PRUNE_CAP_RATIO = 0.10
PENDING_SAMPLE = 10  # how many pending orphans a report names
BATCH_OPS = 500  # Firestore's limit for one batch
READ_TIMEOUT_S = 60.0  # one small query
SCAN_TIMEOUT_S = 300.0  # the query that lists every path of the corpus
COMMIT_TIMEOUT_S = 60.0
MAX_FILE_BYTES = 1 << 20  # the corpus's own limit; a larger file is not indexed
MARKDOWN_SUFFIXES = (".md", ".markdown", ".mdx")
REGULAR_MODES = ("100644", "100755")  # symlinks (120000) and submodules (160000) are not docs


class BaseRefError(Exception):
    """HEAD may not write the shared corpus: `base_ref` is unknown, or HEAD is not on it."""


class LeaseHeld(Exception):
    """Another host holds the corpus lease. `expires_at` is None when the lease document has no usable expiry."""

    def __init__(self, holder: str | None, expires_at: datetime | None) -> None:
        self.holder = holder
        self.expires_at = expires_at
        until = f"until {expires_at.isoformat(timespec='seconds')}" if expires_at else "with no usable expiry"
        super().__init__(f"the corpus lease is held by {holder or 'an unknown holder'} {until}")


class CorpusRefused(Exception):
    """The corpus is not in a state this HEAD may write: another repository's, or a stamp commit not fetched."""


class LeaseLost(Exception):
    """The lease this run took is no longer its own: the remaining writes were abandoned and nothing was stamped.

    `holder` is who has it now, or None when the lease document is gone: only a holder deletes it, so another
    run took it (this one stalled past the TTL) and has finished, and may have written. `report` is what the
    run had done by then.
    """

    def __init__(self, holder: str | None, report: IndexReport | None = None) -> None:
        self.holder = holder
        self.report = report
        super().__init__(f"lease lost to {holder}" if holder else "lease vanished; another run may have written")


@dataclass
class IndexReport:
    """What a run did. `mode` is the mode that ran: a catch-up with no usable stamp reports `full`.

    `files_written` and `files_skipped` (sha unchanged) count files, `chunks_written` counts chunk documents.
    `files_deleted` counts files whose chunks were removed because the file is gone or cannot be indexed,
    `orphans_removed` the paths pruned. `files_failed` maps a path to why it failed; with any, nothing is stamped.
    `orphans_pending` counts orphans left alone because they exceed the prune cap (`orphans_sample`: the first
    ten); a run with any is not stamped. `notes` say why a run did nothing, or skipped a step.
    """

    mode: str
    files_written: int = 0
    files_deleted: int = 0
    orphans_removed: int = 0
    files_failed: dict[str, str] = field(default_factory=dict)
    stamped: bool = False
    stamp: str | None = None
    files_skipped: int = 0
    chunks_written: int = 0
    orphans_pending: int = 0
    orphans_sample: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class _Tree:
    """HEAD's files: `regular` maps a regular file to its blob, `everything` has every path (links included)."""

    regular: dict[str, str]
    everything: frozenset[str]


def chunk_id(path: str, ordinal: int) -> str:
    """The document id of a chunk: stable, and safe whatever the path holds (Firestore ids cannot hold `/`)."""
    return f"{hashlib.sha256(path.encode()).hexdigest()[:24]}-{ordinal}"


def repo_identity(top: Path, head: str) -> str | None:
    """Which repository `head` belongs to: its root commit(s), sorted and comma-joined.

    None for a shallow clone, whose roots are only where the history was cut.
    """
    if git(top, "rev-parse", "--is-shallow-repository").strip() == "true":
        return None
    roots = sorted(set(git(top, "rev-list", "--max-parents=0", head).split()))
    return ",".join(roots) or None


def _short_ids(repo_id: str) -> str:
    return ",".join(part[:7] for part in repo_id.split(","))


@dataclass(frozen=True)
class _Plan:
    """What a run will do: `mode` is the mode that runs, `base` the commit a catch-up diffs from, `rewrite` that no
    stored sha is trusted, `noop` the note of a run with nothing to do."""

    mode: str
    base: str | None = None
    rewrite: bool = False
    noop: str | None = None


def _lease_rival(data: dict[str, Any] | None, me: str) -> tuple[str | None, datetime | None] | None:
    """Who holds the lease instead of `me` now; None only when it is still `me`'s.

    A missing (or empty) document is `(None, None)`: this run held the lease, and only a holder deletes it, so
    another run took it and released it. It is not taken again; only the first acquisition creates the document.
    """
    if not data:
        return None, None
    holder, expires = data.get("holder"), data.get("expires_at")
    if holder == me:
        return None
    return (
        holder if isinstance(holder, str) and holder else "an unknown holder",
        expires if isinstance(expires, datetime) else None,
    )


def _lease_blocker(data: dict[str, Any] | None, me: str, now: datetime) -> tuple[str | None, datetime | None] | None:
    """Who holds the lease against `me`, with the expiry; None when `me` may take it.

    Free when absent, `me`'s own (refreshed), or expired. A lease whose expiry is missing or not a time is
    taken as live: an unreadable lease must not open the door to a second writer.
    """
    if not data or data.get("holder") == me:
        return None
    holder = data.get("holder")
    holder = holder if isinstance(holder, str) else None
    expires = data.get("expires_at")
    if not isinstance(expires, datetime):
        return holder, None
    stamped = expires if expires.tzinfo else expires.replace(tzinfo=UTC)
    return None if stamped <= now else (holder, expires)


def _decode(data: bytes) -> str | None:
    """UTF-8 text (a BOM dropped), or None for a file too large, binary or not UTF-8."""
    if len(data) > MAX_FILE_BYTES or b"\0" in data:
        return None
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None


def _is_line(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


class CloudIndexer:
    """Writes the cloud docs corpus for the checkout at `top`.

    `embedder` embeds the chunks. `client` stands in for `firestore.Client` (tests); otherwise one is built on
    first use. `clock` (epoch seconds) times the lease; `holder` names this run in it, by default `host:pid`.
    """

    def __init__(
        self,
        cfg: Config,
        top: Path,
        embedder: VertexEmbedder,
        client: Any = None,
        clock: Callable[[], float] = time.time,
        holder: str | None = None,
    ) -> None:
        if cfg.cloud is None:
            raise CloudUnavailable("cloud is not configured (set the cloud object in docs/search/config.json)")
        if not cfg.cloud.firestore.project:
            raise CloudUnavailable("no project (set cloud.firestore.project or GOOGLE_CLOUD_PROJECT)")
        if client is None:
            import_module("google.cloud.firestore")
        self._cfg = cfg
        self._fs = cfg.cloud.firestore
        self._top = Path(top)
        self._embedder = embedder
        self._db = LazyClient(self._make_db) if client is None else LazyClient(lambda: client)
        self._clock = clock
        self._holder = holder or f"{socket.gethostname()}:{os.getpid()}"
        self._checked_at = 0.0  # when this run last confirmed its lease

    def _make_db(self) -> Any:
        firestore = import_module("google.cloud.firestore")
        return firestore.Client(project=self._fs.project, database=self._fs.database)

    # -- one run -------------------------------------------------------------------------------

    def run(self, mode: Mode, allow_off_base: bool = False, force: bool = False) -> IndexReport:
        """Index (or prune) the corpus; see the module docstring for the steps.

        `allow_off_base` lets HEAD write from off the base branch, and an explicit `full` / `prune-orphans`
        write when the corpus is ahead of HEAD or its stamp commit is not fetched. `force` bypasses the
        repository-identity refusal and the prune cap, and nothing else.

        Raises BaseRefError, CorpusRefused and LeaseHeld before anything is written; CloudUnavailable when the
        cloud cannot be used at all (no extra, no credentials); LeaseLost when another host took the lease
        mid-run. A file that fails is reported in `files_failed`, not raised. A run with nothing to do returns a
        report with a note.
        """
        if mode not in MODES:
            raise ValueError(f"unknown mode {mode!r} (expected one of {', '.join(MODES)})")
        head = self._check_base(allow_off_base)
        db = self._db.get()
        repo_id = repo_identity(self._top, head)
        plan = self._plan(db, mode, head, repo_id, allow_off_base, force)  # reads only
        if plan.noop is not None:
            return IndexReport(mode, notes=[plan.noop])
        with self._leased(db):
            plan = self._plan(db, mode, head, repo_id, allow_off_base, force)  # the stamp may have moved meanwhile
            if plan.noop is not None:
                return IndexReport(mode, notes=[plan.noop])
            return self._run(db, plan, head, repo_id, force)

    def _plan(self, db: Any, mode: str, head: str, repo_id: str | None, allow_off_base: bool, force: bool) -> _Plan:
        """What `mode` means against the corpus's stamp (step 3 of the module docstring). Writes nothing."""
        stamp = self._read_stamp(db)
        if stamp is None:
            return _Plan("full" if mode == "catch-up" else mode)
        if stamp.repo_id and repo_id and stamp.repo_id != repo_id and not force:
            raise CorpusRefused(
                f"corpus belongs to another repository (repo_id {_short_ids(stamp.repo_id)}); "
                "use a different collection or force"
            )
        other_embedder = bool(stamp.embedder_id and stamp.embedder_id != self._embedder.id)
        # a stamp this indexer wrote (it names an embedder) names the chunker too; abundance's names neither
        other_chunker = (
            stamp.chunker_version != CHUNKER_VERSION if stamp.chunker_version is not None else bool(stamp.embedder_id)
        )
        rewrite = other_embedder or other_chunker  # the stored vectors or cuts are not this run's: trust no sha
        sha = rev_parse(self._top, stamp.built_from_commit)
        if sha is None:
            if mode == "catch-up" or not allow_off_base:
                raise CorpusRefused(f"stamp {stamp.short} is not in this clone; git fetch first")
            return _Plan(mode, rewrite=rewrite and mode == "full")
        if sha != head and is_ancestor(self._top, head, sha):  # HEAD is behind the corpus
            if mode == "catch-up":
                return _Plan(mode, noop=f"corpus is ahead of HEAD ({stamp.short}); pull to catch up")
            if not allow_off_base:
                raise CorpusRefused(
                    f"corpus is ahead of HEAD ({stamp.short}): pull first, or pass --allow-off-base to write "
                    "from an older commit"
                )
            return _Plan(mode, rewrite=rewrite and mode == "full")
        if mode != "catch-up":
            return _Plan(mode, rewrite=rewrite and mode == "full")
        if rewrite:
            return _Plan("full", rewrite=True)
        if sha == head:
            return _Plan(mode, noop="corpus is at HEAD")
        if is_ancestor(self._top, sha, head):
            return _Plan("catch-up", base=sha)
        return _Plan("full")  # the histories diverged

    def _run(self, db: Any, plan: _Plan, head: str, repo_id: str | None, force: bool) -> IndexReport:
        report = IndexReport(plan.mode)
        try:
            self._work(db, plan, head, repo_id, force, report)
        except LeaseLost as err:
            err.report = report
            raise
        return report

    def _work(self, db: Any, plan: _Plan, head: str, repo_id: str | None, force: bool, report: IndexReport) -> None:
        tree = self._head_tree(head)
        if plan.mode == "prune-orphans":
            self._prune_orphans(db, tree, self._indexed_paths(db), report, force)
            return

        corpus = Corpus(self._top, self._cfg, DocIndex(self._top))
        # the corpus as it was before this run: the prune cap measures it, and the files written below are not in it
        indexed = self._indexed_paths(db) if plan.mode == "full" else set()
        if plan.mode == "full":
            todo = sorted(path for path in tree.regular if corpus.in_scope(path))
            deletions: list[str] = []
        else:
            assert plan.base is not None
            changed = self._changed(plan.base, head)
            todo = [path for path in changed if path in tree.regular and corpus.in_scope(path)]
            deletions = [path for path in changed if path not in tree.everything and corpus.in_scope(path)]

        for path in todo:
            self._tick(db)
            self._guarded(
                report, path, lambda path=path: self._index_file(db, corpus, tree, path, report, plan.rewrite)
            )
        for path in deletions:
            self._tick(db)
            self._guarded(report, path, lambda path=path: self._delete_file(db, head, path, report))
        if plan.mode == "full":
            self._prune_orphans(db, tree, indexed, report, force)

        if not report.files_failed and not report.orphans_pending:
            self._check_lease(db)
            self._write_stamp(db, head, plan.mode, repo_id)
            report.stamped, report.stamp = True, head

    @staticmethod
    def _guarded(report: IndexReport, path: str, work: Callable[[], None]) -> None:
        """Run one file's work; a failure is recorded against the path, except one that stops the whole run."""
        try:
            work()
        except (CloudUnavailable, LeaseLost):
            raise  # no extra, no credentials, a broken response: every other file would fail the same way
        except Exception as err:  # noqa: BLE001 - one bad file must not stop the others, or the report
            logger.warning("doc-search index: %s failed: %s", path, describe(err))
            report.files_failed[path] = describe(err)

    # -- steps 1 and 2: the base guard ----------------------------------------------------------

    def _check_base(self, allow_off_base: bool) -> str:
        head = rev_parse(self._top, "HEAD")
        if head is None:
            raise BaseRefError("HEAD is not a commit: there is nothing to index")
        if allow_off_base:
            return head
        base = resolve_base_ref(self._top, self._fs.base_ref)
        if base is None:
            raise BaseRefError(
                "cannot resolve base_ref: set cloud.firestore.base_ref, or fetch so that origin/HEAD exists "
                "(or pass --allow-off-base)"
            )
        base_sha = rev_parse(self._top, base)
        if base_sha is None:
            raise BaseRefError(
                f"base_ref {base} not found in this repository: git fetch, or set cloud.firestore.base_ref "
                "(or pass --allow-off-base)"
            )
        if head != base_sha and not is_ancestor(self._top, head, base_sha):
            raise BaseRefError(
                f"HEAD ({head[:7]}) is not {base} ({base_sha[:7]}) or an ancestor of it. The cloud corpus is one "
                "shared collection with one stamp: writing from another branch would replace main's chunks. "
                "Run from an up-to-date main checkout, or pass --allow-off-base"
            )
        return head

    # -- step 3: the lease ----------------------------------------------------------------------

    def _now(self) -> datetime:
        return datetime.fromtimestamp(self._clock(), tz=UTC)

    @contextmanager
    def _leased(self, db: Any) -> Iterator[None]:
        self._hold_lease(db, taking=True)
        self._checked_at = self._clock()
        try:
            yield
        finally:
            self._drop_lease(db)

    def _lease_ref(self, db: Any) -> Any:
        return db.collection(self._fs.meta_collection).document(LEASE_DOC)

    def _hold_lease(self, db: Any, *, taking: bool) -> None:
        """Take the lease (`taking`), or confirm it is still ours and extend it by the TTL.

        Taking fails with LeaseHeld while another host's lease is live. Confirming fails with LeaseLost when
        another host holds the document at all (ours expired and was taken, and whoever has it may be at work),
        and when the document is gone (it was taken and released: the corpus may have moved on without us).
        """
        firestore = import_module("google.cloud.firestore")
        ref, me, now = self._lease_ref(db), self._holder, self._now()

        @firestore.transactional
        def attempt(txn: Any) -> tuple[str | None, datetime | None] | None:
            snapshot = ref.get(transaction=txn, timeout=CLOUD_TIMEOUT_S)
            data = snapshot.to_dict() if snapshot.exists else None
            rival = _lease_blocker(data, me, now) if taking else _lease_rival(data, me)
            if rival is None:
                since = (data or {}).get("acquired_at") if not taking else None
                txn.set(
                    ref,
                    {"holder": me, "acquired_at": since or now, "expires_at": now + timedelta(seconds=LEASE_TTL_S)},
                )
            return rival

        rival = attempt(db.transaction())
        if rival is not None:
            raise LeaseHeld(*rival) if taking else LeaseLost(rival[0])

    def _check_lease(self, db: Any) -> None:
        self._hold_lease(db, taking=False)
        self._checked_at = self._clock()

    def _tick(self, db: Any) -> None:
        """Between files: renew the lease when it has been LEASE_RENEW_S since it was last checked."""
        if self._clock() - self._checked_at >= LEASE_RENEW_S:
            self._check_lease(db)

    def _drop_lease(self, db: Any) -> None:
        """Delete the lease if it is still ours. A failure is logged, never raised: the run's own outcome
        matters more, and the TTL frees a lease nobody released."""
        try:
            firestore = import_module("google.cloud.firestore")
            ref, me = self._lease_ref(db), self._holder

            @firestore.transactional
            def drop(txn: Any) -> None:
                snapshot = ref.get(transaction=txn, timeout=CLOUD_TIMEOUT_S)
                if snapshot.exists and (snapshot.to_dict() or {}).get("holder") != me:
                    return  # ours expired and another host took it: it is not ours to delete
                txn.delete(ref)

            drop(db.transaction())
        except Exception as err:  # noqa: BLE001
            logger.warning(
                "doc-search index: could not release the lease (it expires in %d s): %s", LEASE_TTL_S, describe(err)
            )

    # -- step 4: the file set -------------------------------------------------------------------

    def _head_tree(self, head: str) -> _Tree:
        regular: dict[str, str] = {}
        everything: set[str] = set()
        for record in git(self._top, "ls-tree", "-r", "-z", "--full-tree", head).split("\0"):
            info, _, path = record.partition("\t")
            parts = info.split(" ")
            if not path or len(parts) != 3:
                continue
            everything.add(path)
            if parts[1] == "blob" and parts[0] in REGULAR_MODES:
                regular[path] = parts[2]
        return _Tree(regular, frozenset(everything))

    def _read_stamp(self, db: Any) -> CorpusStamp | None:
        snapshot = db.collection(self._fs.meta_collection).document(STAMP_DOC).get(timeout=CLOUD_TIMEOUT_S)
        return _parse_stamp(snapshot.to_dict() if snapshot.exists else None)

    def _changed(self, base: str, head: str) -> list[str]:
        out = git(self._top, "diff", "--name-only", "--no-renames", "-z", base, head, "--")
        return sorted({path for path in out.split("\0") if path})

    # -- step 5: one file -----------------------------------------------------------------------

    def _chunks(self, corpus: Corpus, path: str, text: str) -> list[CloudChunk]:
        meta = corpus.meta(path)
        title = meta.title if meta else ""
        if PurePosixPath(path).suffix.lower() in MARKDOWN_SUFFIXES:
            return chunk_markdown(path, text, title)
        return chunk_lines(path, text, title)

    def _index_file(self, db: Any, corpus: Corpus, tree: _Tree, path: str, report: IndexReport, rewrite: bool) -> None:
        data = git_bytes(self._top, "cat-file", "blob", tree.regular[path])
        sha = hashlib.sha256(data).hexdigest()
        if not rewrite and self._is_current(db, path, sha):
            report.files_skipped += 1
            return
        text = _decode(data)
        chunks = self._chunks(corpus, path, text) if text is not None else []
        if not chunks:
            # a content defect (binary, not UTF-8, too large, empty) fails identically on every run, so it is
            # not a failure; but the cloud must not keep serving an older version of what it cannot hold now
            if self._purge(db, path):
                report.files_deleted += 1
            return
        vectors = self._embedder.embed_documents([chunk.text for chunk in chunks])
        meta = corpus.meta(path)
        doc_type = ((meta.doc_type if meta else None) or "other").lower()
        self._replace(db, path, sha, doc_type, chunks, vectors)
        report.files_written += 1
        report.chunks_written += len(chunks)

    def _collection(self, db: Any) -> Any:
        return db.collection(self._fs.collection)

    def _where_path(self, db: Any, path: str) -> Any:
        field_filter = import_module("google.cloud.firestore_v1.base_query").FieldFilter
        return self._collection(db).where(filter=field_filter("path", "==", path))

    def _is_current(self, db: Any, path: str, sha: str) -> bool:
        """True when the stored chunk 0 has this sha and the line range (abundance's chunks lack it: rewritten once)."""
        field_filter = import_module("google.cloud.firestore_v1.base_query").FieldFilter
        query = self._where_path(db, path).where(filter=field_filter("chunkIndex", "==", 0)).limit(1)
        for snapshot in query.stream(timeout=READ_TIMEOUT_S):
            stored = snapshot.to_dict() or {}
            return (
                stored.get("fileSha256") == sha
                and _is_line(stored.get("startLine"))
                and _is_line(stored.get("endLine"))
            )
        return False

    def _replace(self, db: Any, path: str, sha: str, doc_type: str, chunks: list[CloudChunk], vectors: Any) -> None:
        """Make the cloud hold exactly `chunks` for `path`: delete what is stale, then write highest ordinal first."""
        firestore = import_module("google.cloud.firestore")
        vector_type = import_module("google.cloud.firestore_v1.vector").Vector
        collection = self._collection(db)
        keep = {chunk_id(path, chunk.ordinal) for chunk in chunks}
        ops: list[tuple[str, Any, dict[str, Any] | None]] = [
            ("delete", ref, None) for ref in self._refs(db, path) if ref.id not in keep
        ]
        for chunk in reversed(chunks):
            data = {
                "path": path,
                "chunkIndex": chunk.ordinal,
                "text": chunk.text,
                "embedding": vector_type([float(x) for x in vectors[chunk.ordinal]]),
                "headingPath": list(chunk.heading_path),
                "lastIndexedAt": firestore.SERVER_TIMESTAMP,
                "fileSha256": sha,
                "docType": doc_type,
                "startLine": chunk.start_line,
                "endLine": chunk.end_line,
            }
            ops.append(("set", collection.document(chunk_id(path, chunk.ordinal)), data))
        self._commit(db, ops)

    def _refs(self, db: Any, path: str) -> list[Any]:
        """References to every chunk of `path` (names only: the vectors stay where they are)."""
        return [s.reference for s in self._where_path(db, path).select([]).stream(timeout=READ_TIMEOUT_S)]

    def _commit(self, db: Any, ops: list[tuple[str, Any, dict[str, Any] | None]]) -> None:
        for start in range(0, len(ops), BATCH_OPS):
            batch = db.batch()
            for kind, ref, data in ops[start : start + BATCH_OPS]:
                if kind == "delete":
                    batch.delete(ref)
                else:
                    batch.set(ref, data)
            batch.commit(timeout=COMMIT_TIMEOUT_S)

    def _purge(self, db: Any, path: str) -> int:
        """Delete every chunk of `path`; returns how many there were."""
        refs = self._refs(db, path)
        self._commit(db, [("delete", ref, None) for ref in refs])
        return len(refs)

    # -- step 6: deletions ----------------------------------------------------------------------

    def _delete_file(self, db: Any, head: str, path: str, report: IndexReport) -> None:
        """Remove the chunks of a file that left the tree, once git confirms it: `ls-tree` must list nothing.

        A git failure raises (the file is recorded as failed): not knowing is never read as deleted.
        """
        if git(self._top, "ls-tree", head, "--", path).strip():
            raise RuntimeError(f"still in {head[:7]}: its chunks were left alone")
        if self._purge(db, path):
            report.files_deleted += 1

    # -- step 7: orphans ------------------------------------------------------------------------

    def _indexed_paths(self, db: Any) -> set[str]:
        """Every distinct path the collection holds (the `path` field alone is read)."""
        indexed: set[str] = set()
        for snapshot in self._collection(db).select(["path"]).stream(timeout=SCAN_TIMEOUT_S):
            value = (snapshot.to_dict() or {}).get("path")
            if isinstance(value, str):
                indexed.add(value)
        return indexed

    def _prune_orphans(self, db: Any, tree: _Tree, indexed: set[str], report: IndexReport, force: bool) -> None:
        """Delete the chunks of the paths in `indexed` that git no longer knows: absent from HEAD and the index.

        `indexed` is the corpus as it was before this run wrote anything. The cap is measured against it: a run
        that has just written every file of HEAD must not count them as the corpus it is pruning.

        The test is "the file is gone", not "the file is out of scope": an archived doc that still exists keeps
        its chunks (they are what `include_terminal` searches). More orphans than the cap is not a cleanup but a
        sign that the corpus and the repository do not match (a shared collection, the wrong checkout): they are
        reported, not deleted, unless `force`.
        """
        known = tree.everything | {p for p in git(self._top, "ls-files", "-z").split("\0") if p}
        orphans = sorted(indexed - known)
        if not orphans:
            return
        cap = max(PRUNE_CAP_MIN, PRUNE_CAP_RATIO * len(indexed))
        if len(orphans) > cap and not force:
            report.orphans_pending = len(orphans)
            report.orphans_sample = orphans[:PENDING_SAMPLE]
            unstamped = "" if report.mode == "prune-orphans" else ", nothing stamped"
            report.notes.append(
                f"{len(orphans)} orphaned paths exceed the prune cap of {int(cap)}: none deleted{unstamped} "
                "(a corpus of another repository? use force if these really are gone)"
            )
            return
        self._check_lease(db)
        for path in orphans:
            self._tick(db)
            self._guarded(report, path, lambda path=path: self._drop_orphan(db, path, report))

    def _drop_orphan(self, db: Any, path: str, report: IndexReport) -> None:
        self._purge(db, path)
        report.orphans_removed += 1

    # -- step 8: the stamp ----------------------------------------------------------------------

    def _write_stamp(self, db: Any, head: str, mode: str, repo_id: str | None) -> None:
        firestore = import_module("google.cloud.firestore")
        stamp: dict[str, Any] = {
            "built_from_commit": head,
            "built_at": firestore.SERVER_TIMESTAMP,
            "mode": mode,
            "embedder_id": self._embedder.id,
            "chunker_version": CHUNKER_VERSION,
        }
        if repo_id:  # unknown in a shallow clone: leave what the stamp already says
            stamp["repo_id"] = repo_id
        db.collection(self._fs.meta_collection).document(STAMP_DOC).set(stamp, merge=True, timeout=COMMIT_TIMEOUT_S)
