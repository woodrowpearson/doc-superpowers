"""The cloud legs, read path (design sections 6 and 8; the code leg: cloud-code design sections 7 and 8).

A query is embedded (`RETRIEVAL_QUERY` for docs, `CODE_RETRIEVAL_QUERY` for code) and the nearest chunks come
from Firestore's `find_nearest` over the corpus's collection. The collection was built at some commit, the
*corpus stamp* (`<meta_collection>/index` for docs, `<meta_collection>/code-index` for code). A file that
differs from that commit in this worktree (edited, renamed, untracked) is not what the cloud holds, so its
remote chunks are dropped and the local leg alone serves it. That needs the stamp commit locally; without it
the leg is skipped with a note, and so is it, with the reason, when the cloud cannot answer at all. The local
legs always answer.

The docs leg is the one there has always been: its notes and status lines start `cloud`. The code leg
(`corpus=` a `CodeCloudCorpus`) is a second `CloudLeg` with its own stamp, changed-path set and failure memory:
its notes and lines start `cloud code`, its hits are code kind with the leg `cloud-code`, it never filters on
`docType`, and its calls are bounded by `cloud.code.timeout_s`. A code hit keeps its stored line range: a file
changed on the branch is dropped, so the stored lines are those of HEAD's file.

The leg runs inside a search (alongside the local legs, on its own thread), so it is bounded three ways:
every call to Vertex or Firestore has a timeout and no library retry (`cloud.timeout_s`, 20 s by default),
the whole leg gets a wall-clock deadline (`cloud.timeout_s` and 5 s more, enforced on a worker thread, because
a credential refresh is not covered by the call timeouts), and a failure is remembered for FAILURE_MEMORY_S so
that the next searches skip the cloud at once instead of waiting for it to fail again.

`status_lines` reads the stamp document and git, never the collection.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING, Any

from ..config import DEADLINE_GRACE_S, CloudCfg
from ..corpus import Corpus
from ..repo import GitError, confine, diff_names, git, is_ancestor, norm_rel, rev_parse
from ..types import Hit, LocalOnlyReason
from . import CloudUnavailable, LazyClient, describe, has_class_named, import_module
from .vertex import QUERY_TASK, VertexEmbedder, rejected

if TYPE_CHECKING:
    from ..config import Config
    from .corpora import CloudCorpus

logger = logging.getLogger(__name__)

STAMP_DOC = "index"
STAMP_TTL_S = 60.0  # the stamp document is read at most this often
FAILURE_MEMORY_S = 60.0  # after a failure the cloud is not asked again for this long
CHANGED_TTL_S = 5.0  # the branch-changed set is recomputed at most this often (the local legs rescan on this scale)
CHANGED_ENTRIES = 8
SCOPE_ENTRIES = 8  # the code leg's per-worktree scopes kept (one per worktree and HEAD)
MAX_FIRESTORE_LIMIT = 1000  # find_nearest's own cap
MAX_READ_BYTES = 1 << 20  # corpus files are skipped above this size elsewhere too

_Answer = tuple[list[Hit], str | None, LocalOnlyReason | None]  # hits, header note, why the cloud gave nothing


def _timed_out(err: BaseException) -> bool:
    """True for a leg that ran out of time: its own deadline, or a Firestore or HTTP call's own timeout."""
    if isinstance(err, TimeoutError):
        return True
    return has_class_named(err, "DeadlineExceeded") or has_class_named(err, "TimeoutException")


@dataclass(frozen=True)
class CorpusStamp:
    """What the cloud collection was built from: `<meta_collection>/index`."""

    built_from_commit: str
    built_at: str | None
    mode: str | None
    embedder_id: str | None
    repo_id: str | None = None  # the root commit(s) of the repository that wrote it (the write path's, optional)
    chunker_version: int | None = None  # the docs corpus's chunker (`doc_search.chunker.CHUNKER_VERSION`)
    chunker_id: str | None = None  # the code corpus's chunker, `semble-<major>.<minor>`

    @property
    def short(self) -> str:
        return self.built_from_commit[:7]


def _parse_stamp(data: dict[str, Any] | None) -> CorpusStamp | None:
    if not data:
        return None
    commit = data.get("built_from_commit")
    if not isinstance(commit, str) or not commit.strip():
        return None
    version = data.get("chunker_version")
    return CorpusStamp(
        commit.strip(),
        _text(data.get("built_at")),
        _text(data.get("mode")),
        _text(data.get("embedder_id")),
        _text(data.get("repo_id")),
        version if isinstance(version, int) and not isinstance(version, bool) else None,
        _text(data.get("chunker_id")),
    )


def _text(value: Any) -> str | None:
    if value is None:
        return None
    if hasattr(value, "isoformat"):  # a Firestore timestamp arrives as a datetime
        try:
            return value.isoformat(timespec="seconds")
        except TypeError:
            return value.isoformat()
    return str(value)


def resolve_base_ref(top: Path, configured: str | None) -> str | None:
    """`cloud.firestore.base_ref`, else `origin/<the remote's default branch>`, else None."""
    if configured:
        return configured
    try:
        head = git(top, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip()
    except GitError:
        return None
    name = head.removeprefix("origin/")
    return f"origin/{name}" if name else None


def _untracked(top: Path) -> set[str]:
    out = git(top, "ls-files", "--others", "--exclude-standard", "-z")
    return {path for path in out.split("\0") if path}


@dataclass
class _Changed:
    at: float
    names: frozenset[str]


class CloudLeg:
    """Ranked chunks from one cloud collection, and the `status` lines about it.

    `corpus` names the collection the leg reads (a `CloudCorpus`); without one it is the docs leg, as it has
    always been. `embedder` embeds the query; `client` stands in for `firestore.Client` (tests), otherwise one
    is built on first use. `corpus_for` lets `status` count only the corpus's files among the branch-changed
    paths: for the docs leg it gives the worktree's `Corpus` (the server's, its `files()` counted); for the code
    leg the worktree's `CloudCorpus` (its `in_scope` asked; without `corpus_for`, `corpus`'s own). `clock`
    times the caches and `deadline_s` is how long `hits` waits for the cloud (default: the leg's per-call
    timeout and 5 s more: `cloud.timeout_s` for docs, `cloud.code.timeout_s` for code).
    """

    def __init__(
        self,
        cfg: CloudCfg,
        embedder: VertexEmbedder,
        client: Any = None,
        *,
        corpus: CloudCorpus | None = None,
        corpus_for: Callable[[Path], Any] | None = None,
        clock: Callable[[], float] = time.monotonic,
        deadline_s: float | None = None,
    ) -> None:
        if not cfg.firestore.project:
            raise CloudUnavailable("no project (set cloud.firestore.project or GOOGLE_CLOUD_PROJECT)")
        code = corpus is not None and corpus.name == "code"
        if code and cfg.code is None:
            raise CloudUnavailable("cloud code is not configured (set cloud.code)")
        if client is None:
            import_module("google.cloud.firestore")
        self._cfg = cfg
        self._embedder = embedder
        self._db = LazyClient(self._make_db, clock=clock) if client is None else LazyClient(lambda: client)
        self._corpus = corpus
        self._corpus_for = corpus_for
        self._code = code
        self._collection = corpus.collection if corpus is not None else cfg.firestore.collection
        self._stamp_doc = corpus.stamp_doc if corpus is not None else STAMP_DOC
        self._query_task = corpus.query_task if corpus is not None else QUERY_TASK
        self._kind = corpus.hit_kind if corpus is not None else "doc"
        self._prefix = corpus.note_prefix if corpus is not None else "cloud"
        self._legs = ("cloud-code",) if code else ("cloud",)
        self._timeout_s = cfg.code.timeout_s if code and cfg.code is not None else cfg.timeout_s
        default_deadline = self._timeout_s + DEADLINE_GRACE_S if code else cfg.deadline_s
        self._clock = clock
        self._deadline_s = default_deadline if deadline_s is None else deadline_s
        self._lock = threading.Lock()
        self._stamp: CorpusStamp | None = None
        self._stamp_at: float | None = None
        self._stamp_failure: tuple[float, str] | None = None  # (when, why) of the last failed read
        self._down: tuple[float, str, LocalOnlyReason] | None = None  # (when, note, reason) of the last failed search
        self._prefilter_off = False  # the collection has no docType-prefixed vector index
        self._changed: OrderedDict[tuple[Path, str], _Changed] = OrderedDict()

    @property
    def deadline_s(self) -> float:
        """How long `hits` waits for the whole leg."""
        return self._deadline_s

    def _make_db(self) -> Any:
        firestore = import_module("google.cloud.firestore")
        return firestore.Client(project=self._cfg.firestore.project, database=self._cfg.firestore.database)

    # -- the corpus stamp ----------------------------------------------------------------------

    def stamp(self) -> CorpusStamp | None:
        """The stamp document's content, read at most every 60 s. None when there is no usable stamp.

        A failed read is remembered for FAILURE_MEMORY_S and raised again, as CloudUnavailable, until then.
        """
        now = self._clock()
        with self._lock:
            if self._stamp_at is not None and now - self._stamp_at < STAMP_TTL_S:
                return self._stamp
            if self._stamp_failure is not None and now - self._stamp_failure[0] < FAILURE_MEMORY_S:
                raise CloudUnavailable(self._stamp_failure[1])
        try:
            document = self._db.get().collection(self._cfg.firestore.meta_collection).document(self._stamp_doc)
            snapshot = document.get(timeout=self._timeout_s, retry=None)
        except Exception as err:
            with self._lock:
                self._stamp_failure = (self._clock(), describe(err))
            raise
        stamp = _parse_stamp(snapshot.to_dict() if snapshot.exists else None)
        with self._lock:
            self._stamp, self._stamp_at, self._stamp_failure = stamp, now, None
        return stamp

    def changed_paths(self, worktree: Path, stamp: CorpusStamp) -> frozenset[str] | None:
        """Paths that differ from the stamp commit in `worktree`, untracked files included.

        None when the stamp commit is not present locally. Remembered for a few seconds per
        worktree and stamp.
        """
        key = (worktree, stamp.built_from_commit)
        now = self._clock()
        with self._lock:
            memo = self._changed.get(key)
            if memo and now - memo.at < CHANGED_TTL_S:
                self._changed.move_to_end(key)
                return memo.names
        names = diff_names(worktree, stamp.built_from_commit)
        if names is None:
            return None
        found = frozenset(names | _untracked(worktree))
        with self._lock:
            self._changed[key] = _Changed(now, found)
            self._changed.move_to_end(key)
            while len(self._changed) > CHANGED_ENTRIES:
                self._changed.popitem(last=False)
        return found

    # -- search --------------------------------------------------------------------------------

    def hits(
        self,
        query: str,
        allowed: set[str],
        worktree: Path,
        limit: int,
        doc_types: Sequence[str] = (),
    ) -> tuple[list[Hit], str | None]:
        """Up to `limit` chunks nearest to `query`, best first, and a note for the header or None.

        Never from outside `allowed`, and never for a path that differs from the stamp commit in
        `worktree`. `limit` is the number of chunks to ask the collection for. For the docs leg a single
        entry in `doc_types` also filters the collection on `docType`; the code leg ignores it. Any failure
        is a note, not an error.

        The wait is bounded by `deadline_s`. After a failure (a timeout, a 5xx, no credentials, ...; not a
        400 about this one request) the cloud is not asked again for FAILURE_MEMORY_S: the same note comes
        back at once.
        """
        hits, note, _ = self.hits_with_reason(query, allowed, worktree, limit, doc_types)
        return hits, note

    def hits_with_reason(
        self,
        query: str,
        allowed: set[str],
        worktree: Path,
        limit: int,
        doc_types: Sequence[str] = (),
    ) -> _Answer:
        """`hits`, and why the cloud gave nothing when it could not answer: `timeout` (over `deadline_s`, a call's
        own timeout, or held back by the failure memory after one), `no-stamp` (no corpus stamp, or its commit is
        not fetched here) or `failed` (anything else). None when the cloud answered, hits or not.
        """
        with self._lock:
            down = self._down
        if down is not None and self._clock() - down[0] < FAILURE_MEMORY_S:
            return [], down[1], down[2]
        try:
            return self._within_deadline(lambda: self._hits(query, allowed, Path(worktree), limit, tuple(doc_types)))
        except Exception as err:  # noqa: BLE001 - the remote leg degrades to a note, it never takes the search down
            logger.debug("doc-search: %s leg failed", self._prefix, exc_info=True)
            note = f"{self._prefix} failed: {describe(err)}"
            reason: LocalOnlyReason = "timeout" if _timed_out(err) else "failed"
            if not rejected(err):
                with self._lock:
                    self._down = (self._clock(), note, reason)
            return [], note, reason

    def _within_deadline(self, work: Callable[[], _Answer]) -> _Answer:
        """`work()` on a daemon thread, waited for at most `deadline_s`; TimeoutError when it is still running.

        A call stuck in a library (a credential refresh has no timeout of ours) is left behind, not killed.
        """
        outcome: dict[str, Any] = {}

        def run() -> None:
            try:
                outcome["value"] = work()
            except Exception as err:  # noqa: BLE001 - handed to the caller's thread
                outcome["error"] = err

        worker = threading.Thread(target=run, name=f"doc-search-{self._legs[0]}", daemon=True)
        worker.start()
        worker.join(min(self._deadline_s, threading.TIMEOUT_MAX))  # a huge `cloud.timeout_s` is valid, an overflow is not
        if worker.is_alive():
            raise TimeoutError(f"no answer within {self._deadline_s:g} s")
        if "error" in outcome:
            raise outcome["error"]
        return outcome["value"]

    def _hits(
        self, query: str, allowed: set[str], worktree: Path, limit: int, doc_types: tuple[str, ...]
    ) -> _Answer:
        stamp = self.stamp()
        if stamp is None:
            where = f"{self._cfg.firestore.meta_collection}/{self._stamp_doc}"
            return [], f"{self._prefix} skipped: no corpus stamp ({where})", "no-stamp"
        changed = self.changed_paths(worktree, stamp)
        if changed is None:
            return [], f"{self._prefix} skipped: stamp {stamp.short} not fetched", "no-stamp"
        if self._query_task == QUERY_TASK:
            vector = self._embedder.embed_query(query)  # the embedder's default task
        else:
            vector = self._embedder.embed_query(query, task=self._query_task)
        rows = self._nearest(vector, min(max(1, limit), MAX_FIRESTORE_LIMIT), () if self._code else doc_types)
        read: dict[str, str | None] = {}
        out: list[Hit] = []
        for row in rows:
            path = row.get("path")
            if not isinstance(path, str):
                continue
            path = norm_rel(path)
            if path not in allowed or path in changed:
                continue
            text = row.get("text")
            text = text if isinstance(text, str) else ""
            start, end = _lines(row)
            if start is None:
                if self._code:
                    continue  # a code chunk without a usable range points nowhere: the local leg serves the file
                start, end = _locate(worktree, path, text, read)
            out.append(Hit(self._kind, path, start, end, text, legs=self._legs))
        return out, None, None

    def _nearest(self, vector: Any, limit: int, doc_types: tuple[str, ...]) -> list[dict[str, Any]]:
        collection = self._db.get().collection(self._collection)
        doc_type = doc_types[0].lower() if len(doc_types) == 1 and not self._prefilter_off else None
        try:
            return self._query(collection, vector, limit, doc_type)
        except Exception as err:
            # the prefilter needs a vector index prefixed by docType; without one the exact filter by
            # the allowed set (applied by the caller) does the same work on a wider result, and the
            # collection is not asked for the prefilter again
            if doc_type is None or not has_class_named(err, "FailedPrecondition"):
                raise
            rows = self._query(collection, vector, limit, None)
            self._prefilter_off = True
            return rows

    def _query(self, collection: Any, vector: Any, limit: int, doc_type: str | None) -> list[dict[str, Any]]:
        base_query = import_module("google.cloud.firestore_v1.base_query")
        distance = import_module("google.cloud.firestore_v1.base_vector_query")
        vectors = import_module("google.cloud.firestore_v1.vector")
        source = collection
        if doc_type is not None:
            source = collection.where(filter=base_query.FieldFilter("docType", "==", doc_type))
        nearest = source.find_nearest(
            vector_field="embedding",
            query_vector=vectors.Vector([float(x) for x in vector]),
            distance_measure=distance.DistanceMeasure.COSINE,
            limit=limit,
            distance_result_field="vector_distance",
        )
        return [snapshot.to_dict() or {} for snapshot in nearest.get(timeout=self._timeout_s, retry=None)]

    # -- status --------------------------------------------------------------------------------

    def status_lines(self, worktree: Path) -> list[str]:
        """The `status` tool's lines for this leg: the stamp, its relation to `base_ref`, the branch-changed count.

        Each starts `cloud:` (docs) or `cloud code:` (code). Reads the stamp document and git only. The
        collection is never scanned.
        """
        worktree = Path(worktree)
        fs, p = self._cfg.firestore, self._prefix
        lines = [
            f"{p}: Firestore {fs.project}/{fs.database} collection {self._collection}, embedder {self._embedder.id}"
        ]
        try:
            stamp = self.stamp()
        except Exception as err:  # noqa: BLE001 - status reports a failure, it does not raise one
            return lines + [f"{p}: corpus stamp unreadable ({describe(err)})"]
        if stamp is None:
            return lines + [f"{p}: no corpus stamp ({fs.meta_collection}/{self._stamp_doc}): the {p} leg is skipped"]
        parts = [f"built {stamp.built_at}"] if stamp.built_at else []
        if stamp.mode:
            parts.append(f"mode {stamp.mode}")
        if stamp.chunker_id:
            parts.append(f"chunker {stamp.chunker_id}")
        lines.append(f"{p}: corpus stamp {stamp.short}" + (f" ({', '.join(parts)})" if parts else ""))
        if stamp.embedder_id and stamp.embedder_id != self._embedder.id:
            lines.append(
                f"{p}: stamp embedder {stamp.embedder_id} is not this server's {self._embedder.id}: "
                "query vectors may not match the collection's"
            )
        try:
            return lines + self._git_lines(worktree, stamp)
        except GitError as err:
            return lines + [f"{p}: git failed: {describe(err)}"]

    def _git_lines(self, worktree: Path, stamp: CorpusStamp) -> list[str]:
        p = self._prefix
        sha = rev_parse(worktree, stamp.built_from_commit)
        if sha is None:
            return [
                f"{p}: stamp commit {stamp.short} is not fetched in this worktree: git fetch, then retry "
                f"(the {p} leg is skipped until then)"
            ]
        lines = [self._relation_line(worktree, sha)]
        changed = self.changed_paths(worktree, stamp)
        if changed is not None:
            if self._code:
                scope = self._corpus_for(worktree) if self._corpus_for is not None else self._corpus
                if scope is not None:
                    changed = frozenset(path for path in changed if scope.in_scope(path))
                lines.append(f"{p}: {len(changed)} branch-changed code files, served by the local index only")
            else:
                if self._corpus_for is not None:
                    changed = changed & set(self._corpus_for(worktree).files())
                lines.append(f"{p}: {len(changed)} branch-changed docs, served by the local index only")
        return lines

    def _relation_line(self, worktree: Path, stamp_sha: str) -> str:
        p = self._prefix
        base = resolve_base_ref(worktree, self._cfg.firestore.base_ref)
        if base is None:
            return f"{p}: base_ref unknown (no origin/HEAD; set cloud.firestore.base_ref)"
        base_sha = rev_parse(worktree, base)
        if base_sha is None:
            return f"{p}: base_ref {base} not found here (git fetch)"
        if stamp_sha == base_sha:
            return f"{p}: stamp is current with {base}"
        if not is_ancestor(worktree, stamp_sha, base_sha):
            return f"{p}: stamp is not an ancestor of {base}"
        behind = git(worktree, "rev-list", "--count", f"{stamp_sha}..{base_sha}").strip()
        return f"{p}: stamp is behind {base} by {behind}"


def _lines(row: dict[str, Any]) -> tuple[int | None, int]:
    """The chunk's own `startLine` / `endLine` when both are sane integers, else (None, 0)."""
    start, end = row.get("startLine"), row.get("endLine")
    if (
        isinstance(start, int)
        and isinstance(end, int)
        and not isinstance(start, bool)
        and not isinstance(end, bool)
        and 1 <= start <= end
    ):
        return start, end
    return None, 0


def _locate(worktree: Path, path: str, text: str, read: dict[str, str | None]) -> tuple[int, int]:
    """Where `text` sits in the working-tree file `path`, as 1-based lines; (1, 1) when it cannot be found."""
    if path not in read:
        read[path] = _read(worktree, path)
    content, needle = read[path], text.strip()
    if content is not None and needle:
        at = content.find(needle)
        if at >= 0:
            start = content.count("\n", 0, at) + 1
            return start, start + needle.count("\n")
    return 1, 1


def _read(worktree: Path, rel: str) -> str | None:
    try:
        with confine(worktree, rel).open("rb") as handle:
            data = handle.read(MAX_READ_BYTES + 1)
    except (OSError, ValueError):
        return None
    if len(data) > MAX_READ_BYTES:
        return None
    return data.decode("utf-8", "replace").replace("\r\n", "\n")


class DegradedLeg:
    """Stands in for a cloud leg that could not be built: every answer says why, and the local legs carry on.

    `note_prefix` is the leg's name in its notes and lines: `cloud` (docs) or `cloud code`.
    """

    def __init__(self, reason: str, note_prefix: str = "cloud") -> None:
        self.reason = reason
        self.note_prefix = note_prefix

    def hits(
        self,
        query: str,
        allowed: set[str],
        worktree: Path,
        limit: int,
        doc_types: Sequence[str] = (),
    ) -> tuple[list[Hit], str | None]:
        return [], f"{self.note_prefix} failed: {self.reason}"

    def hits_with_reason(
        self,
        query: str,
        allowed: set[str],
        worktree: Path,
        limit: int,
        doc_types: Sequence[str] = (),
    ) -> _Answer:
        return [], f"{self.note_prefix} failed: {self.reason}", "failed"

    def status_lines(self, worktree: Path) -> list[str]:
        return [f"{self.note_prefix}: unavailable: {self.reason}"]


def build_cloud_leg(cfg: CloudCfg, *, corpus_for: Callable[[Path], Corpus] | None = None) -> CloudLeg | DegradedLeg:
    """The docs cloud leg for `cfg`, or a degraded one when it cannot be built (no extra, no project).

    Building does not touch the network and loads no credentials: those are resolved at the first search.
    """
    try:
        return CloudLeg(cfg, VertexEmbedder(cfg), corpus_for=corpus_for)
    except Exception as err:  # noqa: BLE001 - a leg that cannot be built must not stop the server
        return DegradedLeg(describe(err))


class _CodeScopes:
    """The code corpus of each worktree asked about, as its HEAD holds it: one shared server serves several
    worktrees, each with its own ignore rules. Built on first use and kept per (worktree, HEAD commit)."""

    def __init__(self, build: Callable[[Path], CloudCorpus]) -> None:
        self._build = build
        self._lock = threading.Lock()
        self._built: OrderedDict[tuple[Path, str | None], CloudCorpus] = OrderedDict()

    def __call__(self, worktree: Path) -> CloudCorpus:
        key = (Path(worktree), rev_parse(worktree, "HEAD"))
        with self._lock:
            found = self._built.get(key)
            if found is not None:
                self._built.move_to_end(key)
                return found
        corpus = self._build(key[0])
        with self._lock:
            self._built[key] = corpus
            while len(self._built) > SCOPE_ENTRIES:
                self._built.popitem(last=False)
        return corpus


def _build_code_leg(cfg: Config, top: Path) -> CloudLeg | DegradedLeg:
    from .corpora import CodeCloudCorpus  # corpora reads this module's stamp: imported here, not at the top

    cloud, code = cfg.cloud, cfg.cloud.code if cfg.cloud else None
    try:
        if cloud is None or code is None:
            raise CloudUnavailable("cloud code is not configured (set cloud.code)")
        # the query embedding is held to the code leg's own per-call budget too
        embedder = VertexEmbedder(replace(cloud, timeout_s=code.timeout_s))
        scopes = _CodeScopes(lambda tree: CodeCloudCorpus(cfg, tree))
        return CloudLeg(cloud, embedder, corpus=CodeCloudCorpus(cfg, top), corpus_for=scopes)
    except Exception as err:  # noqa: BLE001 - a leg that cannot be built must not stop the server
        return DegradedLeg(describe(err), note_prefix="cloud code")


def build_cloud_legs(
    cfg: Config, top: Path, *, corpus_for: Callable[[Path], Corpus] | None = None
) -> tuple[CloudLeg | DegradedLeg | None, CloudLeg | DegradedLeg | None]:
    """The (docs, code) cloud legs the config turns on; None for a corpus it leaves off (or no `cloud` at all).

    `corpus_for` is the server's docs `Corpus` per worktree, for the docs leg's status. Building touches no
    network and loads no credentials; a leg that cannot be built is a `DegradedLeg` (the code one's notes read
    `cloud code failed: …`).
    """
    cloud = cfg.cloud
    if cloud is None:
        return None, None
    docs = build_cloud_leg(cloud, corpus_for=corpus_for) if cloud.docs else None
    code = _build_code_leg(cfg, Path(top)) if cloud.code is not None else None
    return docs, code
