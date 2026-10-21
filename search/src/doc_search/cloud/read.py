"""The cloud docs leg, read path (design sections 6 and 8).

A query is embedded (`RETRIEVAL_QUERY`) and the nearest chunks come from Firestore's `find_nearest`
over the configured collection. The collection was built at some commit, the *corpus stamp*
(`<meta_collection>/index`). A doc that differs from that commit in this worktree (edited,
renamed, untracked) is not what the cloud holds, so its remote chunks are dropped and the local
docs leg alone serves it. That needs the stamp commit locally; without it the leg is skipped with a
note, and so is it, with the reason, when the cloud cannot answer at all. The local legs always
answer.

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
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..config import CloudCfg
from ..corpus import Corpus
from ..repo import GitError, confine, diff_names, git, is_ancestor, norm_rel, rev_parse
from ..types import Hit
from . import CloudUnavailable, LazyClient, describe, has_class_named, import_module
from .vertex import VertexEmbedder, rejected

logger = logging.getLogger(__name__)

STAMP_DOC = "index"
STAMP_TTL_S = 60.0  # the stamp document is read at most this often
FAILURE_MEMORY_S = 60.0  # after a failure the cloud is not asked again for this long
CHANGED_TTL_S = 5.0  # the branch-changed set is recomputed at most this often (the local legs rescan on this scale)
CHANGED_ENTRIES = 8
MAX_FIRESTORE_LIMIT = 1000  # find_nearest's own cap
MAX_READ_BYTES = 1 << 20  # corpus files are skipped above this size elsewhere too


@dataclass(frozen=True)
class CorpusStamp:
    """What the cloud collection was built from: `<meta_collection>/index`."""

    built_from_commit: str
    built_at: str | None
    mode: str | None
    embedder_id: str | None
    repo_id: str | None = None  # the root commit(s) of the repository that wrote it (the write path's, optional)
    chunker_version: int | None = None

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
    """Ranked doc chunks from the cloud collection, and the `status` lines about it.

    `embedder` embeds the query; `client` stands in for `firestore.Client` (tests), otherwise one is
    built on first use. `corpus_for` (the server's) lets `status` count only the doc files among the
    branch-changed paths. `clock` times the caches and `deadline_s` is how long `hits` waits for the cloud
    (default: `cfg.deadline_s`, the config's `timeout_s` and 5 s more).
    """

    def __init__(
        self,
        cfg: CloudCfg,
        embedder: VertexEmbedder,
        client: Any = None,
        *,
        corpus_for: Callable[[Path], Corpus] | None = None,
        clock: Callable[[], float] = time.monotonic,
        deadline_s: float | None = None,
    ) -> None:
        if not cfg.firestore.project:
            raise CloudUnavailable("no project (set cloud.firestore.project or GOOGLE_CLOUD_PROJECT)")
        if client is None:
            import_module("google.cloud.firestore")
        self._cfg = cfg
        self._embedder = embedder
        self._db = LazyClient(self._make_db, clock=clock) if client is None else LazyClient(lambda: client)
        self._corpus_for = corpus_for
        self._clock = clock
        self._deadline_s = cfg.deadline_s if deadline_s is None else deadline_s
        self._lock = threading.Lock()
        self._stamp: CorpusStamp | None = None
        self._stamp_at: float | None = None
        self._stamp_failure: tuple[float, str] | None = None  # (when, why) of the last failed read
        self._down: tuple[float, str] | None = None  # (when, header note) of the last failed search
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
            document = self._db.get().collection(self._cfg.firestore.meta_collection).document(STAMP_DOC)
            snapshot = document.get(timeout=self._cfg.timeout_s, retry=None)
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
        """Up to `limit` doc chunks nearest to `query`, best first, and a note for the header or None.

        Never from outside `allowed`, and never for a path that differs from the stamp commit in
        `worktree`. `limit` is the number of chunks to ask the collection for. A single entry in
        `doc_types` also filters the collection on `docType`. Any failure is a note, not an error.

        The wait is bounded by `deadline_s`. After a failure (a timeout, a 5xx, no credentials, ...; not a
        400 about this one request) the cloud is not asked again for FAILURE_MEMORY_S: the same note comes
        back at once.
        """
        with self._lock:
            down = self._down
        if down is not None and self._clock() - down[0] < FAILURE_MEMORY_S:
            return [], down[1]
        try:
            return self._within_deadline(lambda: self._hits(query, allowed, Path(worktree), limit, tuple(doc_types)))
        except Exception as err:  # noqa: BLE001 - the remote leg degrades to a note, it never takes the search down
            logger.debug("doc-search: cloud leg failed", exc_info=True)
            note = f"cloud failed: {describe(err)}"
            if not rejected(err):
                with self._lock:
                    self._down = (self._clock(), note)
            return [], note

    def _within_deadline(self, work: Callable[[], tuple[list[Hit], str | None]]) -> tuple[list[Hit], str | None]:
        """`work()` on a daemon thread, waited for at most `deadline_s`; TimeoutError when it is still running.

        A call stuck in a library (a credential refresh has no timeout of ours) is left behind, not killed.
        """
        outcome: dict[str, Any] = {}

        def run() -> None:
            try:
                outcome["value"] = work()
            except Exception as err:  # noqa: BLE001 - handed to the caller's thread
                outcome["error"] = err

        worker = threading.Thread(target=run, name="doc-search-cloud", daemon=True)
        worker.start()
        worker.join(min(self._deadline_s, threading.TIMEOUT_MAX))  # a huge `cloud.timeout_s` is valid, an overflow is not
        if worker.is_alive():
            raise TimeoutError(f"no answer within {self._deadline_s:g} s")
        if "error" in outcome:
            raise outcome["error"]
        return outcome["value"]

    def _hits(
        self, query: str, allowed: set[str], worktree: Path, limit: int, doc_types: tuple[str, ...]
    ) -> tuple[list[Hit], str | None]:
        stamp = self.stamp()
        if stamp is None:
            return [], f"cloud skipped: no corpus stamp ({self._cfg.firestore.meta_collection}/{STAMP_DOC})"
        changed = self.changed_paths(worktree, stamp)
        if changed is None:
            return [], f"cloud skipped: stamp {stamp.short} not fetched"
        vector = self._embedder.embed_query(query)
        rows = self._nearest(vector, min(max(1, limit), MAX_FIRESTORE_LIMIT), doc_types)
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
                start, end = _locate(worktree, path, text, read)
            out.append(Hit("doc", path, start, end, text, legs=("cloud",)))
        return out, None

    def _nearest(self, vector: Any, limit: int, doc_types: tuple[str, ...]) -> list[dict[str, Any]]:
        collection = self._db.get().collection(self._cfg.firestore.collection)
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
        return [snapshot.to_dict() or {} for snapshot in nearest.get(timeout=self._cfg.timeout_s, retry=None)]

    # -- status --------------------------------------------------------------------------------

    def status_lines(self, worktree: Path) -> list[str]:
        """The `status` tool's cloud lines: the stamp, its relation to `base_ref`, the branch-changed count.

        Reads the stamp document and git only. The collection is never scanned.
        """
        worktree = Path(worktree)
        fs = self._cfg.firestore
        lines = [
            f"cloud: Firestore {fs.project}/{fs.database} collection {fs.collection}, embedder {self._embedder.id}"
        ]
        try:
            stamp = self.stamp()
        except Exception as err:  # noqa: BLE001 - status reports a failure, it does not raise one
            return lines + [f"cloud: corpus stamp unreadable ({describe(err)})"]
        if stamp is None:
            return lines + [f"cloud: no corpus stamp ({fs.meta_collection}/{STAMP_DOC}): the cloud leg is skipped"]
        parts = [f"built {stamp.built_at}"] if stamp.built_at else []
        if stamp.mode:
            parts.append(f"mode {stamp.mode}")
        lines.append(f"cloud: corpus stamp {stamp.short}" + (f" ({', '.join(parts)})" if parts else ""))
        if stamp.embedder_id and stamp.embedder_id != self._embedder.id:
            lines.append(
                f"cloud: stamp embedder {stamp.embedder_id} is not this server's {self._embedder.id}: "
                "query vectors may not match the collection's"
            )
        try:
            return lines + self._git_lines(worktree, stamp)
        except GitError as err:
            return lines + [f"cloud: git failed: {describe(err)}"]

    def _git_lines(self, worktree: Path, stamp: CorpusStamp) -> list[str]:
        sha = rev_parse(worktree, stamp.built_from_commit)
        if sha is None:
            return [
                f"cloud: stamp commit {stamp.short} is not fetched in this worktree: git fetch, then retry "
                "(the cloud leg is skipped until then)"
            ]
        lines = [self._relation_line(worktree, sha)]
        changed = self.changed_paths(worktree, stamp)
        if changed is not None:
            if self._corpus_for is not None:
                changed = changed & set(self._corpus_for(worktree).files())
            lines.append(f"cloud: {len(changed)} branch-changed docs, served by the local index only")
        return lines

    def _relation_line(self, worktree: Path, stamp_sha: str) -> str:
        base = resolve_base_ref(worktree, self._cfg.firestore.base_ref)
        if base is None:
            return "cloud: base_ref unknown (no origin/HEAD; set cloud.firestore.base_ref)"
        base_sha = rev_parse(worktree, base)
        if base_sha is None:
            return f"cloud: base_ref {base} not found here (git fetch)"
        if stamp_sha == base_sha:
            return f"cloud: stamp is current with {base}"
        if not is_ancestor(worktree, stamp_sha, base_sha):
            return f"cloud: stamp is not an ancestor of {base}"
        behind = git(worktree, "rev-list", "--count", f"{stamp_sha}..{base_sha}").strip()
        return f"cloud: stamp is behind {base} by {behind}"


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
    """Stands in for a cloud leg that could not be built: every answer says why, and the local legs carry on."""

    def __init__(self, reason: str) -> None:
        self.reason = reason

    def hits(
        self,
        query: str,
        allowed: set[str],
        worktree: Path,
        limit: int,
        doc_types: Sequence[str] = (),
    ) -> tuple[list[Hit], str | None]:
        return [], f"cloud failed: {self.reason}"

    def status_lines(self, worktree: Path) -> list[str]:
        return [f"cloud: unavailable: {self.reason}"]


def build_cloud_leg(cfg: CloudCfg, *, corpus_for: Callable[[Path], Corpus] | None = None) -> CloudLeg | DegradedLeg:
    """The cloud leg for `cfg`, or a degraded one when it cannot be built (no extra, no project).

    Building does not touch the network and loads no credentials: those are resolved at the first search.
    """
    try:
        return CloudLeg(cfg, VertexEmbedder(cfg), corpus_for=corpus_for)
    except Exception as err:  # noqa: BLE001 - a leg that cannot be built must not stop the server
        return DegradedLeg(describe(err))
