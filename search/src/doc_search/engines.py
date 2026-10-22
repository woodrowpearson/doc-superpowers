"""The semble engines: a docs index and a code index per worktree, built in the background.

An `IndexPool` keeps the index pair of at most `max_worktrees` worktrees in memory (least
recently used goes first; a worktree whose build is still running is never the victim, so
the pool may briefly hold more). The first `get` for a worktree starts one thread per kind; a call
waits for those threads up to `wait_s`, then answers `Building` and the builds carry on.

semble builds run one at a time across the pool (MAX_CONCURRENT_BUILDS), every worktree and kind:
a build's memory peaks high (~5 GB measured for a large repository's two builds in parallel), and
serial builds lower the peak. Each thread takes its place in this *build line* when it starts, so a
worktree's docs build goes before its code build, and the worktrees go in the order they were asked
for. A thread that finds a valid cache loads it without queueing; one that waits for its turn is
still running, so `get` reads a first build in line as building. A refresh in line is not waited
for: the previous index serves until the rebuild gets its slot.

Loading follows semble's own cache: a cache that still matches the tree is loaded from disk
(`get_validated_cache` then `SembleIndex.load_from_disk`), anything else is rebuilt through
`SembleIndex.from_path`, which re-indexes incrementally, and saved with
`save_index_to_cache`.

A kind is checked again once its last check is older than
`max(search.rescan_seconds, 3 x its last build seconds)`, the cooldown semble's own server
uses. The recheck runs in a thread too, and every call that finds a refresh running (the one
that started it included) waits for it within `wait_s`, unless it waits in line behind another
build; a refresh that is in line, outlasts the wait, or fails, leaves the previous index serving.

A transformer docs model (`docs.model: "transformer:<name>"`, transformer.py) changes the docs kind:

- *The transformer lane.* Its builds take their places in a lane of their own (one build at a time
  per pool), never in the build line: a first build encodes for hours, and the code index and the
  other worktrees' static builds must not wait behind it. Inside its slot a build holds the host's
  encoder lock (`encode_cache.host_lock`, one encoder per host across processes; a build waiting
  for another process reads `waiting`), and it is timed from the lock: waiting is not build time.
  A first build waits for the lock however long another process holds it; a refresh of a saved
  transformer index of this model waits at most HOST_LOCK_REFRESH_WAIT_S, then encodes without it
  (one info line: an incremental encode is small, and an edit must not wait hours behind another
  worktree's first build), and saves without it too. A build that had to wait checks the cache again
  once it holds the lock (or gave up on it), and loads what the holder saved for this worktree
  instead of encoding it again.
- *What serves while it builds.* The docs thread loads a transformer index saved for the worktree:
  a valid one is the answer (no lane); a stale one serves while its refresh, incremental, queues in
  the lane. When none is saved (nothing is, or semble's docs folder holds another model's), or the
  saved one does not load (its model files missing, say), and none is in memory, a pool with
  `fallback` on (a server; the command line builds what the config names, in the foreground) starts
  a hidden static docs state (semble's default model, kept on the entry), waits for its first build
  and the code index's, then queues in the lane. The fallback builds in the place the docs state
  reserved in the build line when it started with nothing to serve (so before the code build), or,
  when that place was given back (a stale saved index that then did not load), at the back of the
  line. While the transformer index builds, the static one answers for docs
  (`WorktreeIndexes.docs_fallback`) and refreshes on its own cooldown, except that it is never
  rebuilt while semble's docs folder holds a transformer index (one that does not load): it keeps
  serving as it is. While an index serves docs, a `get` waits at most TRANSFORMER_REFRESH_WAIT_S
  for a transformer build, and not at all while it waits in the lane or for another process's lock.
- *The swap.* A built transformer index is validated (chunks, `(chunks, dim)` vectors, all finite)
  before it serves. It is then saved before the encoder lock is let go (so a build of the same
  worktree in another process, waiting for the lock, loads it), which replaces the static index
  (semble keeps one docs folder per worktree, whatever the model). The two save under the entry's
  `save_lock`, and a static save is skipped once a transformer index is saved, so a late static
  refresh never overwrites it. Once a transformer index serves (a built one, a loaded one, or a
  stale saved one while it refreshes) the fallback is dropped, never to refresh again. A failed or
  invalid build is recorded (`transformer_error`; a failed validation is also a warning in the
  log), the fallback keeps serving, the static index stays on disk, and the build is retried on
  the cooldown, whose base is capped at TRANSFORMER_COOLDOWN_CAP_S (a first encode takes hours; a
  refresh from the encode cache, about a minute). After a failure the base is that cap, however
  quickly the build failed, doubled with each further failure in a row (60, 120, 240 ... s), up to
  TRANSFORMER_BACKOFF_CAP_S; a success returns it to the build's own seconds.
- *Eviction.* Only a transformer build that holds its lane slot (encoding, or waiting there for the
  host lock) or saves keeps its worktree resident. One waiting in the lane is cancelled by an
  eviction (as is the build-line place it reserved for a fallback that has not started): its places
  are given back, its thread wakes and leaves without building, and the evicted indexes go with it.
  While it waits for the static builds it cannot be evicted: those builds keep the worktree
  resident themselves.
- *Memory.* Once a transformer build thread's own `SembleIndex.from_path` has run at least one
  forward batch through the encoder (whether the build then succeeded or failed: its `_Reporter`
  saw a chunk encoded, not only read from the encode cache), the pool drops the encoder's onnxruntime
  session (`transformer.release_session`), which keeps GBs after an encode; the next encode, the
  first query after the build or the next build, makes a new one. A thread that only loads a saved
  index, rechecks one that has not changed, or refreshes entirely from the encode cache releases
  nothing: the session serves the queries, and another worktree's build may be encoding on it.
- *Progress.* Each transformer build has its own `progress.BuildProgress` (queued, waiting,
  encoding, saving), published for other processes and retired when the build ends; `progress()`
  and `WorktreeIndexes.transformer` read it. Its total is known for a first build only, and only
  from a static docs index (the fallback's, or one saved before); an incremental refresh encodes
  what changed. Its rate and ETA run on real time, not the pool clock. The first first-build of a
  pool on an Intel Mac logs a warning.

Nothing here raises to a caller: a build exception is recorded in `WorktreeIndexes.error` (a
transformer docs build's in `WorktreeIndexes.transformer_error`).
All times (`built_at`, `build_seconds`, the cooldown) are in units of the injected clock. A build
is timed from when it gets its slot: time in line is not build time.

Locks: the pool lock (an RLock) guards every `_State` and `_Entry` field except `transformer_saved`,
and is never held while a thread waits for a build, a first build, the encoder lock or a save;
under it a thread takes only a line's condition (to take or give back a place) or a progress's own
lock (for a view). The others nest in one order only: a lane slot, then the host's encoder lock (a
transformer build validates and saves before it lets the lock go), then an entry's `save_lock`,
which a static fallback save takes alone. The encoder's own locks (transformer.py: its registry's,
its session's) are taken inside a build or a query and hold nothing else. So no two threads can
wait on each other's locks.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections import OrderedDict, deque
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

import numpy as np
from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder, get_validated_cache, save_index_to_cache
from semble.index.types import PersistencePath
from semble.utils import resolve_model_name

from . import encode_cache, transformer
from .config import Config
from .progress import BuildProgress, ProgressView, intel_mac
from .transformer import MISSING_EXTRA, TransformerSpec

logger = logging.getLogger(__name__)

Kind = Literal["docs", "code"]
CacheState = Literal["valid", "stale", "absent"]

# semble's own server rechecks a path no sooner than this many times its last build took.
REVALIDATE_FACTOR = 3

# How long a command-line verb waits for a build: effectively forever (a finite value, because
# `threading.Event.wait` rejects infinity). The server's calls wait 20 s instead.
FOREGROUND_WAIT_S = 7 * 24 * 3600.0

# How many `SembleIndex.from_path` builds a pool runs at once, across its worktrees and kinds.
MAX_CONCURRENT_BUILDS = 1

# How long a `get` waits for a transformer docs refresh when an index already serves (the previous
# transformer index, or the static fallback): an encode can take hours, and the answer is there.
TRANSFORMER_REFRESH_WAIT_S = 2.0

# The most of a transformer build's seconds its cooldown scales (success and failure alike): a first
# encode takes hours, and 3 x that would hold a docs edit back for most of a day.
TRANSFORMER_COOLDOWN_CAP_S = 60.0

# Each transformer build that fails in a row doubles that base (60, 120, 240 ... s), up to this: a
# build that keeps failing (offline, a broken model file) is not retried every 3 min for days.
TRANSFORMER_BACKOFF_CAP_S = 3600.0

# How long a refresh of a saved transformer index waits for another process's encoder lock before it
# encodes without it. A first build waits however long it takes: one cold encoder per host.
HOST_LOCK_REFRESH_WAIT_S = 10.0

INTEL_WARNING = (
    "doc-search: the transformer docs model runs ~3.6 chunks/s on Intel (M-series: ~16); this first build may take hours"
)

_UNLOADABLE = "doc-search: the saved transformer docs index of %s does not load (%s): the static index serves meanwhile"


class _Cancelled(Exception):
    """A transformer build whose worktree was evicted before it built: it leaves without building."""


@dataclass
class WorktreeIndexes:
    """A worktree's index pair, as of one `get` call. A snapshot: later refreshes never touch it.

    A kind that is off (`code.enabled` false) is absent from the dicts and its index is None.
    `error[kind]` says the last build or refresh of that kind failed; the index is then None
    (it never built) or the previous one (it is stale). It is the error of the index served: the
    static fallback's own while that serves for docs.

    `docs_model` is the semble model path of the docs index served (None when none is);
    `docs_fallback` says that index is semble's static one, serving while the transformer index
    builds; `transformer` is the transformer docs build under way, if any; `transformer_error`
    is the last transformer docs build's error (None after a success, or without a transformer).
    """

    docs: SembleIndex | None = None
    code: SembleIndex | None = None
    built_at: dict[str, float] = field(default_factory=dict)
    build_seconds: dict[str, float] = field(default_factory=dict)
    error: dict[str, str] = field(default_factory=dict)
    docs_model: str | None = None
    docs_fallback: bool = False
    transformer: ProgressView | None = None
    transformer_error: str | None = None


@dataclass(frozen=True)
class Building:
    """`get` ran out of time: at least one kind has not finished its first build.

    A kind that is switched off counts as ready, there being nothing to wait for.
    `partial` carries the kinds that did finish (an index, or the error that ended its build),
    so a caller can answer from the ready half; it is None when no kind has finished. It takes
    no part in equality or hashing.
    """

    worktree: Path
    docs_ready: bool
    code_ready: bool
    partial: WorktreeIndexes | None = field(default=None, compare=False)


@dataclass
class _Outcome:
    """What one build thread produced: a new or kept index, or an error."""

    index: SembleIndex | None = None
    token: tuple[int, int] | None = None
    files: frozenset[str] = frozenset()
    changed: bool = False
    error: str | None = None


class _BuildLine:
    """At most `slots` semble builds at once, granted in the order the places were taken (first in, first out)."""

    def __init__(self, slots: int, clock: Callable[[], float]) -> None:
        self._cond = threading.Condition()
        self._slots = slots
        self._clock = clock
        self._active = 0
        self._waiting: deque[_Place] = deque()

    def place(self, in_line: threading.Event | None = None) -> _Place:
        """A place at the back of the line. Its holder builds inside `with place:`, and calls `leave` in any case.

        `in_line`, when given, is set while the holder waits for its turn, and cleared when it gets the slot.
        """
        place = _Place(self, in_line)
        with self._cond:
            self._waiting.append(place)
        return place


class _Place:
    """One build thread's place in a `_BuildLine`: `queued`, then `held` while it builds, then `left`."""

    def __init__(self, line: _BuildLine, in_line: threading.Event | None) -> None:
        self._line = line
        self._in_line = in_line
        self._state = "queued"
        self.held_at: float | None = None  # when the slot was granted, on the line's clock

    def __enter__(self) -> _Place:
        """Wait until this place is first in line and a slot is free, then hold the slot.

        Raises `_Cancelled` when the place is left from another thread (an eviction) before it gets the slot.
        """
        line = self._line
        with line._cond:
            if not self._ready():
                if self._in_line is not None:
                    self._in_line.set()
                line._cond.wait_for(self._ready)
                if self._in_line is not None:
                    self._in_line.clear()
            if self._state == "left":
                raise _Cancelled
            line._waiting.popleft()
            line._active += 1
            self._state = "held"
            self.held_at = line._clock()
            line._cond.notify_all()  # the next place may fit in another slot
        return self

    def _ready(self) -> bool:
        return self._state == "left" or self._turn()

    def _turn(self) -> bool:
        line = self._line
        return line._waiting[0] is self and line._active < line._slots

    def __exit__(self, *exc: object) -> None:
        self.leave()

    def leave(self) -> None:
        """Give the slot back, or the place in line when it never built. Safe to call again."""
        line = self._line
        with line._cond:
            if self._state == "held":
                line._active -= 1
            elif self._state == "queued":
                line._waiting.remove(self)
            self._state = "left"
            line._cond.notify_all()


class _State:
    """One kind of one worktree, or a worktree's static docs fallback. All fields are guarded by the pool's lock."""

    def __init__(self, name: Kind, content: tuple[ContentType, ...], model: str | None) -> None:
        self.name = name
        self.content = content
        self.model = model
        # set while a get need not wait: no build thread runs, or its build is in line while an index serves
        # (for a transformer docs state: or the fallback has finished its first build and answers instead)
        self.answerable = threading.Event()
        self.answerable.set()
        self.settled = threading.Event()  # set by the first build thread to finish, never cleared
        self.running = False
        self.index: SembleIndex | None = None
        self.token: tuple[int, int] | None = None  # the on-disk cache state `index` corresponds to
        self.files: frozenset[str] = frozenset()
        self.built_at: float | None = None
        self.build_seconds: float | None = None
        self.error: str | None = None
        self.checked_at: float | None = None  # when the last build thread finished
        self.cool_seconds = 0.0  # what the cooldown scales: the last build, or the slowest recent failure
        self.failures = 0  # build threads that failed in a row (a transformer docs state's back off)
        self.fatal = False  # a config error: no build can fix it, so none is ever started
        self.spec: TransformerSpec | None = None  # a transformer docs state: it builds in the transformer lane
        self.progress: BuildProgress | None = None  # that state's build under way
        self.busy = False  # that build holds its lane slot or saves: an eviction would cut it short
        self.lane_place: _Place | None = None  # its place while it waits in the lane (an eviction leaves it)
        self.reserved: _Place | None = None  # the build-line place it took for a fallback, until handed or given back
        self.is_fallback = False  # the static docs state that serves while the transformer index builds


class _Entry:
    def __init__(self, worktree: Path, states: dict[Kind, _State]) -> None:
        self.worktree = worktree
        self.states = states
        self.fallback: _State | None = None  # a transformer docs model's static fallback, until the swap
        self.evicted = False  # dropped from the pool: a transformer build still waiting is cancelled
        # Every save of the docs folder (fallback and transformer) holds this; it alone guards
        # `transformer_saved`: the folder holds a transformer index, so a static save must not run.
        self.save_lock = threading.Lock()
        self.transformer_saved = False

    def live(self) -> list[_State]:
        """The states a get starts and waits for: the kinds, then the fallback while there is one."""
        states = list(self.states.values())
        if self.fallback is not None:
            states.append(self.fallback)
        return states

    def building(self) -> bool:
        """Whether an eviction would cut a build short: a static build thread runs (in line or building), or a
        transformer build holds its lane slot or saves. A transformer build still waiting is cancelled instead."""
        return any(state.busy if state.spec is not None else state.running for state in self.live())


def _content_types(values: Iterable[str]) -> tuple[ContentType, ...]:
    """`code.content` as semble content types. "all" is every type, as in semble's own CLI."""
    values = tuple(values)
    if "all" in values:
        return (ContentType.CODE, ContentType.DOCS, ContentType.CONFIG)
    return tuple(dict.fromkeys(ContentType(value) for value in values))


def _stamp(index_dir: Path) -> tuple[int, int] | None:
    """A cheap identity for what is saved in a cache directory: its metadata file's mtime and size."""
    try:
        st = PersistencePath.from_path(Path(index_dir)).metadata.stat()
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


def _files_of(index: SembleIndex) -> frozenset[str]:
    return frozenset(chunk.file_path for chunk in index.chunks)


def _describe(err: BaseException) -> str:
    text = str(err).strip()
    return f"{type(err).__name__}: {text}" if text else type(err).__name__


def _saved_docs(path: str) -> tuple[str | None, int | None]:
    """The model path and chunk count of the docs index semble has saved for `path`, each None when unknown.

    Reads only the metadata file; nothing saved, or anything unreadable, is (None, None).
    """
    try:
        metadata_file = PersistencePath.from_path(find_index_from_cache_folder(path, (ContentType.DOCS,))).metadata
        metadata = json.loads(metadata_file.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - absent, unreadable or not JSON: nothing is known
        return None, None
    if not isinstance(metadata, dict):
        return None, None
    model = metadata.get("model_path")
    try:
        count: int | None = sum(int(entry["count"]) for entry in metadata["files"].values())
    except Exception:  # noqa: BLE001 - a manifest of another shape: the count is unknown
        count = None
    return (model if isinstance(model, str) else None), count


def _invalid(index: SembleIndex, spec: TransformerSpec) -> str | None:
    """Why a built transformer index must not serve, or None: no chunks, vectors of another shape, non-finite ones."""
    count = len(index.chunks)
    if count == 0:
        return "no chunks"
    vectors = index._semantic_index.vectors
    if tuple(vectors.shape) != (count, spec.dim):
        return f"vectors of shape {tuple(vectors.shape)} for {count} chunks of {spec.dim} dimensions"
    if not np.isfinite(vectors).all():
        return "non-finite vectors"
    return None


class _Reporter:
    """A transformer build's progress sink: each encoder report counts into the build's progress, which is then
    published (at most once a second). `encoded` counts the chunks this build's thread put through a forward pass
    (not the ones read from the encode cache): none, and the session was not used, so it is not released."""

    def __init__(self, build: BuildProgress) -> None:
        self._build = build
        self.encoded = 0

    def add(self, n: int, *, cached: bool = False) -> None:
        if not cached:
            self.encoded += n
        self._build.add(n, cached=cached)
        self._build.publish()


class IndexPool:
    def __init__(
        self,
        cfg: Config,
        max_worktrees: int = 2,
        clock: Callable[[], float] = time.monotonic,
        *,
        fallback: bool = True,
    ) -> None:
        """`fallback` (with a transformer docs model): serve semble's static docs index while the transformer one
        builds. The server keeps it on; the command line turns it off and waits for the transformer build."""
        if max_worktrees < 1:
            raise ValueError("max_worktrees must be at least 1")
        self._cfg = cfg
        self._max = max_worktrees
        self.clock = clock
        self._fallback = fallback
        self._lock = threading.RLock()
        self._entries: OrderedDict[Path, _Entry] = OrderedDict()  # least recently used first
        self._builds = _BuildLine(MAX_CONCURRENT_BUILDS, clock)
        self._lane = _BuildLine(1, clock)  # the transformer lane
        self._intel_warned = False
        spec = cfg.docs.transformer
        self._extra_missing = spec is not None and transformer.extra_missing()
        if spec is not None and not self._extra_missing:
            transformer.install(cfg.docs.threads)

    # -- public ------------------------------------------------------------------------

    def get(self, worktree: Path | str, wait_s: float = 20.0) -> WorktreeIndexes | Building:
        """The worktree's indexes, revalidated if due, waiting up to `wait_s` seconds for builds.

        Returns `Building` only while a kind has never finished a build (its `partial` holds
        the kinds that have); once every kind has (even with an error) the answer is a
        `WorktreeIndexes`, stale if a refresh is still running. A refresh whose build waits in line
        behind another (or, for a transformer docs build, for another process's encoder lock) is not
        waited for, nor a transformer docs build for more than TRANSFORMER_REFRESH_WAIT_S while an
        index serves docs. Safe to call from several threads.
        """
        top = Path(worktree).resolve()
        deadline = time.monotonic() + max(0.0, wait_s)  # real time: the injected clock may not move
        with self._lock:
            entry = self._touch(top)
            now = self.clock()
            waiting: list[tuple[threading.Event, float]] = []
            for state in entry.live():
                if not state.running and self._due(state, now):
                    self._start(entry, state)
                if state.running:
                    until = deadline
                    source = self._source(entry, state) if state.spec is not None else None
                    if source is not None and source.index is not None:  # an index serves: an encode may take hours
                        until = min(deadline, time.monotonic() + TRANSFORMER_REFRESH_WAIT_S)
                    waiting.append((state.answerable, until))
        for event, until in waiting:
            event.wait(max(0.0, until - time.monotonic()))
        with self._lock:
            return self._result(entry)

    def peek(self, worktree: Path | str) -> WorktreeIndexes | Building | None:
        """What `get` would answer for a worktree that is in memory, without using it.

        A read-only look: the entry is not moved in the LRU order, no build or refresh is started and
        nothing waits. None when the worktree is not resident (it is never loaded for a peek).
        """
        with self._lock:
            entry = self._entries.get(Path(worktree).resolve())
            return self._result(entry) if entry is not None else None

    def progress(self, worktree: Path | str) -> ProgressView | None:
        """The transformer docs build of a resident worktree in this process (queued, waiting, encoding or
        saving), or None when none runs. A look, like `peek`."""
        with self._lock:
            entry = self._entries.get(Path(worktree).resolve())
            state = entry.states.get("docs") if entry is not None else None
            build = state.progress if state is not None else None
            return build.view() if build is not None else None

    @property
    def max_worktrees(self) -> int:
        """How many worktrees' index pairs stay in memory (a running build can briefly exceed it)."""
        return self._max

    def indexed_files(self, worktree: Path | str, kind: Kind) -> set[str]:
        """The repo-relative paths with at least one chunk in the worktree's `kind` index (the one served:
        the static fallback's while it serves for docs).

        Empty when nothing is built (or kept) for that worktree and kind. Never starts a build.
        """
        with self._lock:
            entry = self._entries.get(Path(worktree).resolve())
            state = entry.states.get(kind) if entry else None
            if entry is None or state is None:
                return set()
            return set((self._source(entry, state) or state).files)

    def resident(self) -> list[Path]:
        """The worktrees held in memory, least recently used first."""
        with self._lock:
            return list(self._entries)

    @staticmethod
    def semble_version() -> str:
        try:
            from semble.version import __version__

            return str(__version__)
        except Exception:  # noqa: BLE001 - a missing version module must not break status
            from importlib.metadata import version

            return version("semble")

    # -- entries and the cooldown --------------------------------------------------------

    def _touch(self, top: Path) -> _Entry:
        entry = self._entries.get(top)
        if entry is None:
            entry = self._entries[top] = _Entry(top, self._states())
        self._entries.move_to_end(top)
        # Evict least recently used first, but never an entry that is still building: dropping it
        # would let a later get start a second build into the same semble cache directory. A
        # transformer build waiting in the lane does not hold its worktree for hours: the eviction
        # cancels it. (One waiting for the static builds is never a candidate: those builds keep the
        # entry building.)
        for path, other in list(self._entries.items()):
            if len(self._entries) <= self._max:
                break
            if path != top and not other.building():
                del self._entries[path]
                self._evict(other)
        return entry

    @staticmethod
    def _evict(entry: _Entry) -> None:
        """Cancel what an evicted entry's transformer build waits for: its place in the lane, and the build-line
        place it reserved for a fallback. Its thread wakes, leaves without building, and lets the entry go.
        The caller holds the lock."""
        entry.evicted = True
        for state in entry.live():
            for place in (state.lane_place, state.reserved):
                if place is not None:
                    place.leave()
            state.lane_place = state.reserved = None

    @staticmethod
    def _check(entry: _Entry) -> None:
        """Raise `_Cancelled` once the entry has been evicted. The caller holds the lock."""
        if entry.evicted:
            raise _Cancelled

    def _spec(self, kind: Kind) -> tuple[tuple[ContentType, ...], str | None]:
        """What semble is asked for in `kind`'s index: its content types and model.

        The one place both are decided: the builds and `cache_state` read it, so they cannot drift.
        A transformer docs model is asked for by its semble model path (`TransformerSpec.model_path`).
        Raises ValueError for a `code.content` value semble has no content type for.
        """
        cfg = self._cfg
        if kind == "docs":
            spec = cfg.docs.transformer
            return (ContentType.DOCS,), spec.model_path if spec is not None else cfg.docs.model
        return _content_types(cfg.code.content), cfg.code.model

    def _states(self) -> dict[Kind, _State]:
        cfg = self._cfg
        docs = _State("docs", *self._spec("docs"))
        spec = cfg.docs.transformer
        if spec is not None:
            docs.spec = spec
            if self._extra_missing:  # no onnxruntime: no build, and no fallback either
                self._broken(docs, MISSING_EXTRA.format(name=spec.name))
        states: dict[Kind, _State] = {"docs": docs}
        if cfg.code.enabled:
            try:
                states["code"] = _State("code", *self._spec("code"))
            except ValueError as err:  # a config value semble has no content type for
                broken = _State("code", (), cfg.code.model)
                self._broken(broken, f"invalid code.content: {err}")
                states["code"] = broken
        return states

    def _broken(self, state: _State, error: str) -> None:
        """Make `state` a config error: settled now, never built."""
        state.fatal = True
        state.error = error
        state.checked_at = self.clock()
        state.settled.set()

    def cache_state(self, worktree: Path | str, kind: Kind) -> CacheState:
        """Whether semble's saved index of `kind` for `worktree` could be used as it is, without using it.

        `valid`: `get_validated_cache` accepts it, so a build would load it from disk. `stale`: a complete
        saved index for this path and content exists but does not validate (a file changed, was added or
        removed, another model, a damaged file). `absent`: there is none (or this process cannot tell).
        With a transformer docs model, docs is `stale` only for a saved index of that model, and `absent`
        for another model's (the static fallback's: see `fallback_cache_state`).
        Reads the cache and walks the worktree the way a revalidation does; it builds nothing, loads no
        index, starts no thread and does not touch the pool's entries. The code index must be switched on.
        """
        if kind == "code" and not self._cfg.code.enabled:
            raise ValueError("the code index is off (code.enabled is false)")
        path = str(Path(worktree).resolve())
        try:
            content, model = self._spec(kind)
            if get_validated_cache(path, model, content) is not None:
                return "valid"
            if kind == "docs" and self._cfg.docs.transformer is not None:
                return "stale" if _saved_docs(path)[0] == model else "absent"
            saved = PersistencePath.from_path(find_index_from_cache_folder(path, content))
            return "absent" if saved.non_existing() else "stale"
        except Exception:  # noqa: BLE001 - a question about the cache must not raise (an unusable code.content, a vanished tree)
            logger.debug("doc-search: cannot tell the %s cache of %s", kind, worktree, exc_info=True)
            return "absent"

    def fallback_cache_state(self, worktree: Path | str) -> CacheState | None:
        """The disk state of the static docs index that serves while a transformer one builds; None without a
        transformer docs model.

        `valid`: semble's default model's docs index matches the tree. `stale`: one of that model is saved but
        does not match. `absent`: nothing is saved, or the folder holds another model's (the transformer's,
        once it replaced the static one). Reads only, like `cache_state`.
        """
        if self._cfg.docs.transformer is None:
            return None
        path = str(Path(worktree).resolve())
        try:
            if get_validated_cache(path, None, (ContentType.DOCS,)) is not None:
                return "valid"
            return "stale" if _saved_docs(path)[0] == resolve_model_name() else "absent"
        except Exception:  # noqa: BLE001 - a question about the cache must not raise
            logger.debug("doc-search: cannot tell the static docs cache of %s", worktree, exc_info=True)
            return "absent"

    def _due(self, state: _State, now: float) -> bool:
        if state.fatal:
            return False
        if state.checked_at is None:
            return True
        cool = state.cool_seconds
        if state.spec is not None:  # a first encode takes hours; a refresh, from the encode cache, does not
            cool = min(cool, TRANSFORMER_COOLDOWN_CAP_S)
            if state.failures:  # failing: back off from the cap, doubling per failure in a row (exponent bounded)
                cool = min(TRANSFORMER_COOLDOWN_CAP_S * 2 ** min(state.failures - 1, 32), TRANSFORMER_BACKOFF_CAP_S)
        cooldown = max(self._cfg.search.rescan_seconds, REVALIDATE_FACTOR * cool)
        return now - state.checked_at >= cooldown

    @staticmethod
    def _source(entry: _Entry, state: _State) -> _State | None:
        """The state whose index answers for `state`'s kind, or None while none has finished a build.

        `state` itself (a transformer docs state answers with a stale saved index it loaded, before its
        first refresh is done), except for a transformer docs state with no index of its own: the static
        fallback answers once it has finished its first build.
        """
        fallback = entry.fallback if state.spec is not None else None
        if fallback is not None and state.index is None and fallback.checked_at is not None:
            return fallback
        return state if state.checked_at is not None or state.index is not None else None

    @staticmethod
    def _result(entry: _Entry) -> WorktreeIndexes | Building:
        def ready(name: Kind) -> bool:
            state = entry.states.get(name)
            return state is None or IndexPool._source(entry, state) is not None

        docs_ready, code_ready = ready("docs"), ready("code")
        finished = IndexPool._snapshot(entry)
        if docs_ready and code_ready:
            return finished
        some = any(IndexPool._source(entry, state) is not None for state in entry.states.values())
        return Building(entry.worktree, docs_ready, code_ready, partial=finished if some else None)

    @staticmethod
    def _snapshot(entry: _Entry) -> WorktreeIndexes:
        """The indexes of the kinds that have finished a build; a kind still on its first build is left out."""
        out = WorktreeIndexes()
        for name, state in entry.states.items():
            source = IndexPool._source(entry, state)
            if source is None:
                continue
            if name == "docs":
                out.docs = source.index
                if source.index is not None:
                    out.docs_model = source.model if source.model is not None else resolve_model_name()
                    out.docs_fallback = source.is_fallback
            else:
                out.code = source.index
            if source.built_at is not None and source.build_seconds is not None:
                out.built_at[name] = source.built_at
                out.build_seconds[name] = source.build_seconds
            if source.error is not None:  # the served index's own: the fallback's while it serves
                out.error[name] = source.error
        docs = entry.states.get("docs")
        if docs is not None and docs.spec is not None:
            out.transformer_error = docs.error
            if docs.progress is not None:
                out.transformer = docs.progress.view()
        return out

    # -- build threads -----------------------------------------------------------------

    def _start(self, entry: _Entry, state: _State, place: _Place | None = None) -> None:
        """Start a build thread for `state`. The caller holds the lock and has seen it idle.

        A static build's place in the build line is taken here (or handed in: a fallback's, reserved by the
        docs state), in the caller's order (docs, then code), not when the thread gets round to it. A kind
        with an index to serve lets its callers go while it is in line. A transformer docs build takes its
        place in the transformer lane from its thread, once it knows it builds; when it may need a fallback,
        it reserves the fallback's place in the build line here, ahead of the code build.
        """
        state.running = True
        state.answerable.clear()
        if state.spec is not None:
            if self._fallback and state.index is None and entry.fallback is None:
                state.reserved = self._builds.place()
            target: Callable[..., None] = self._run_transformer
            args: tuple[object, ...] = (entry, state, state.index, state.token)
            name = f"doc-search-transformer-{entry.worktree.name}"
        else:
            if place is None:
                place = self._builds.place(state.answerable if state.index is not None else None)
            target, args = self._run, (entry, state, state.index, state.token, place)
            name = f"doc-search-{'static-docs' if state.is_fallback else state.name}-{entry.worktree.name}"
        thread = threading.Thread(target=target, args=args, name=name, daemon=True)
        try:
            thread.start()
        except RuntimeError as err:  # no thread could be started: settle as a failure, never hang
            for taken in (place, state.reserved):
                if taken is not None:
                    taken.leave()
            state.reserved = None
            self._settle(entry, state, _Outcome(error=_describe(err)), 0.0)

    def _run(
        self,
        entry: _Entry,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
        place: _Place,
    ) -> None:
        start = self.clock()
        outcome = _Outcome(error="build thread ended abnormally")
        try:
            outcome = self._refresh(entry, state, current, current_token, place)
        except Exception as err:  # noqa: BLE001 - a build failure is data, not an exception
            outcome = _Outcome(error=_describe(err))
            logger.debug("doc-search: %s index of %s failed", state.name, entry.worktree, exc_info=True)
        finally:
            place.leave()  # a thread that loaded the cache never built: its place goes to the next in line
            if place.held_at is not None:  # a build is timed from its slot, not from its place in line
                start = place.held_at
            with self._lock:
                self._settle(entry, state, outcome, self.clock() - start)

    @staticmethod
    def _refresh(
        entry: _Entry,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
        place: _Place,
    ) -> _Outcome:
        worktree = entry.worktree
        path = str(worktree)
        cached = get_validated_cache(path, state.model, state.content)
        if cached is not None:
            token = _stamp(cached)
            if current is not None and token is not None and token == current_token:
                return _Outcome(index=current, token=token)  # the cache is what we already hold
            index = SembleIndex.load_from_disk(cached)
            return _Outcome(index=index, token=token, files=_files_of(index), changed=True)
        if state.is_fallback and current is not None and IndexPool._holds_transformer(entry, path):
            # The folder holds a transformer index (one that does not load, or the fallback would be gone):
            # a static rebuild would never be saved, and the fallback serves only until that index loads.
            return _Outcome(index=current, token=current_token)
        with place:  # one semble build at a time, pool-wide
            index = SembleIndex.from_path(path, content=list(state.content), model_path=state.model)
        if not state.is_fallback:
            IndexPool._save(state, index, path)
            token = _stamp(find_index_from_cache_folder(path, index.content))
            return _Outcome(index=index, token=token, files=_files_of(index), changed=True)
        with entry.save_lock:  # the static index never replaces a saved transformer index
            if IndexPool._holds_transformer(entry, path, locked=True):
                logger.debug("doc-search: the static docs index of %s is not saved: a transformer index is", worktree)
                return _Outcome(index=index, files=_files_of(index), changed=True)
            IndexPool._save(state, index, path)
            token = _stamp(find_index_from_cache_folder(path, index.content))
        return _Outcome(index=index, token=token, files=_files_of(index), changed=True)

    @staticmethod
    def _holds_transformer(entry: _Entry, path: str, *, locked: bool = False) -> bool:
        """Whether semble's docs folder for the worktree holds a transformer index: one this pool saved or
        found, or one of the docs model on disk. `locked`: the caller holds the entry's `save_lock`."""
        spec = entry.states["docs"].spec
        if locked:
            saved = entry.transformer_saved
        else:
            with entry.save_lock:
                saved = entry.transformer_saved
        return saved or (spec is not None and _saved_docs(path)[0] == spec.model_path)

    @staticmethod
    def _save(state: _State, index: SembleIndex, path: str) -> bool:
        """Save a built index to semble's cache; False (with a warning) when it cannot be: it still serves."""
        try:
            save_index_to_cache(index, path)
        except Exception as err:  # noqa: BLE001 - an index that cannot be cached still serves
            logger.warning("doc-search: could not cache the %s index of %s: %s", state.name, path, _describe(err))
            return False
        return True

    def _run_transformer(
        self, entry: _Entry, state: _State, current: SembleIndex | None, current_token: tuple[int, int] | None
    ) -> None:
        start = self.clock()
        began: list[float] = []  # when the encoder lock was taken: the build is timed from there
        builds: list[BuildProgress] = []
        outcome = _Outcome(error="build thread ended abnormally")
        try:
            outcome = self._transformer_refresh(entry, state, current, current_token, began, builds)
        except _Cancelled:  # evicted while it waited: it settles a state nothing refers to any more
            outcome = _Outcome(error="cancelled: the worktree was evicted before its transformer build ran")
        except Exception as err:  # noqa: BLE001 - a build failure is data, not an exception
            outcome = _Outcome(error=_describe(err))
            logger.debug("doc-search: transformer docs index of %s failed", entry.worktree, exc_info=True)
        finally:
            self._give_back(state)
            for build in builds:
                build.retire()
            with self._lock:
                self._settle(entry, state, outcome, self.clock() - (began[0] if began else start))

    @staticmethod
    def _release(state: _State) -> None:
        """Drop the encoder's onnxruntime session once this thread's own encode ran a forward pass (never raises)."""
        try:
            if state.spec is not None:
                transformer.release_session(state.spec)
        except Exception:  # noqa: BLE001 - memory, not correctness: a session that stays is no failure
            logger.debug("doc-search: the encoder session was not released", exc_info=True)

    def _give_back(self, state: _State) -> None:
        """Leave the places a transformer build no longer needs: the fallback's reserved one, a lane place never entered."""
        with self._lock:
            places = [place for place in (state.reserved, state.lane_place) if place is not None]
            state.reserved = state.lane_place = None
        for place in places:
            place.leave()

    def _transformer_refresh(
        self,
        entry: _Entry,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
        began: list[float],
        builds: list[BuildProgress],
    ) -> _Outcome:
        """One transformer docs thread: load a valid cache, or build in the lane, serving meanwhile a stale saved
        index or the static fallback (started first, when one is due)."""
        spec = state.spec
        assert spec is not None
        path = str(entry.worktree)
        unloadable = False
        cached = get_validated_cache(path, spec.model_path, state.content)
        if cached is not None:  # a transformer index matches the tree: load it, no lane, no fallback
            self._give_back(state)
            with entry.save_lock:
                entry.transformer_saved = True
            token = _stamp(cached)
            if current is not None and token is not None and token == current_token:
                return _Outcome(index=current, token=token)
            try:
                index = SembleIndex.load_from_disk(cached)
            except Exception as err:  # noqa: BLE001 - e.g. its model files missing, offline
                if current is not None or not self._fallback:
                    raise
                logger.warning(_UNLOADABLE, entry.worktree, _describe(err))
                unloadable = True
            else:
                return _Outcome(index=index, token=token, files=_files_of(index), changed=True)

        saved_model, saved_count = _saved_docs(path)
        first = saved_model != spec.model_path  # no index of this model saved: every chunk goes to the encoder
        if self._fallback and current is None and not first and not unloadable:
            self._give_back(state)  # a stale transformer index serves instead of a fallback, if it loads
            current = self._serve_stale(entry, state, path)

        build = BuildProgress(entry.worktree, spec.model_path, first=first)
        builds.append(build)
        with self._lock:
            self._check(entry)
            state.progress = build
            warn = first and not self._intel_warned and intel_mac()
            self._intel_warned = self._intel_warned or warn
        if warn:
            logger.warning(INTEL_WARNING)
        build.publish(force=True)

        in_line: threading.Event | None = None  # the answerable the lane and the host lock may set while waiting
        if self._fallback and current is None:
            # Nothing of this model to serve: the static index answers until the transformer one is built.
            with self._lock:
                self._check(entry)
                fallback = entry.fallback
                if fallback is None:
                    fallback = entry.fallback = _State("docs", (ContentType.DOCS,), None)
                    fallback.is_fallback = True
                    reserved, state.reserved = state.reserved, None
                    self._start(entry, fallback, reserved)
                firsts = [fallback.settled] + [other.settled for name, other in entry.states.items() if name != "docs"]
            self._give_back(state)
            for settled in firsts:  # the static builds go first, and the encode starts once they are done
                settled.wait()
            with self._lock:
                self._check(entry)
                build.total = len(fallback.index.chunks) if fallback.index is not None else saved_count
                state.answerable.set()  # the fallback answers for docs from here on
            build.publish(force=True)
        else:  # a stale transformer index refreshes (incrementally), or the foreground builds what it is asked
            self._give_back(state)
            build.total = saved_count if first else None  # a refresh encodes what changed: its total is unknown
            if current is not None:
                in_line = state.answerable

        with self._lock:
            self._check(entry)
            place = state.lane_place = self._lane.place(in_line)
        waited: list[int | None] = []

        def on_wait(holder: int | None) -> None:  # another process encodes: say whom we wait for
            waited.append(holder)
            build.holder_pid = holder
            build.phase = "waiting"
            if in_line is not None:
                in_line.set()  # waiting behind another process is waiting in line: the index serves meanwhile
            build.publish(force=True)

        saved: Path | None = None  # a valid index the holder of the encoder lock saved for this worktree
        with place:  # one transformer build at a time in this pool; raises _Cancelled on an eviction
            with self._lock:
                state.lane_place = None
                self._check(entry)
                state.busy = True  # from here an eviction waits for this build instead of cancelling it
            # One encoder on this host: a first build waits for it as long as it takes, a refresh at most
            # HOST_LOCK_REFRESH_WAIT_S (then it encodes without it).
            wait_s = None if first else HOST_LOCK_REFRESH_WAIT_S
            with encode_cache.host_lock(spec, on_wait=on_wait, timeout=wait_s):
                began.append(self.clock())
                if in_line is not None:
                    with self._lock:
                        in_line.clear()  # this build runs now: a get waits for it, within the refresh wait
                if waited:  # the holder may have built this very worktree (another process on it)
                    saved = get_validated_cache(path, spec.model_path, state.content)
                if saved is None:
                    build.holder_pid = None
                    build.phase = "encoding"
                    build.publish(force=True)
                    reporter = _Reporter(build)
                    try:
                        with transformer.report_to(reporter):
                            index = SembleIndex.from_path(path, content=list(state.content), model_path=spec.model_path)
                    finally:
                        if reporter.encoded:  # this thread ran the encoder: its session's memory goes (built or failed)
                            self._release(state)
                    problem = _invalid(index, spec)
                    if problem is not None:  # never served, never saved: the static index stays, on disk and serving
                        logger.warning(
                            "doc-search: the transformer docs index of %s failed validation (%s): "
                            "it is neither served nor saved",
                            entry.worktree,
                            problem,
                        )
                        return _Outcome(error=f"transformer index failed validation: {problem}")
                    # Saved before the encoder lock is let go, so a build of this worktree that waited for the
                    # lock (another process) finds it and loads it.
                    build.phase = "saving"
                    build.publish(force=True)
                    with entry.save_lock:
                        if self._save(state, index, path):
                            entry.transformer_saved = True
                        token = _stamp(find_index_from_cache_folder(path, index.content))
                    return _Outcome(index=index, token=token, files=_files_of(index), changed=True)
        index = SembleIndex.load_from_disk(saved)  # what the holder saved, loaded once the lock is let go
        with entry.save_lock:
            entry.transformer_saved = True
        return _Outcome(index=index, token=_stamp(saved), files=_files_of(index), changed=True)

    def _serve_stale(self, entry: _Entry, state: _State, path: str) -> SembleIndex | None:
        """Load the stale transformer index saved for the worktree and serve it while it refreshes.

        None (and a warning) when it does not load: the static fallback serves instead.
        """
        started = self.clock()
        try:
            folder = find_index_from_cache_folder(path, state.content)
            index = SembleIndex.load_from_disk(folder)
        except Exception as err:  # noqa: BLE001 - e.g. its model files missing, offline
            logger.warning(_UNLOADABLE, entry.worktree, _describe(err))
            return None
        with self._lock:
            self._check(entry)
            state.index = index
            state.token = _stamp(folder)
            state.files = _files_of(index)
            state.built_at = self.clock()
            state.build_seconds = state.built_at - started
            state.answerable.set()  # it answers from here on
            entry.fallback = None  # a transformer index serves: a fallback left by an earlier run is dropped
        return index

    def _settle(self, entry: _Entry, state: _State, outcome: _Outcome, elapsed: float) -> None:
        """Record a finished build thread. The caller holds the lock."""
        state.running = False
        state.checked_at = self.clock()
        if outcome.error is not None:
            # keep any previous index serving; a slow failure slows the retries
            state.error = outcome.error
            state.cool_seconds = max(state.cool_seconds, elapsed)
            state.failures += 1
        else:
            state.error = None
            state.failures = 0
            if outcome.changed:
                state.index = outcome.index
                state.token = outcome.token
                state.files = outcome.files
                state.built_at = state.checked_at
                state.build_seconds = elapsed
                state.cool_seconds = elapsed
        if state.spec is not None:
            state.progress = None
            state.busy = False
            if state.index is not None:
                # The swap: a transformer index serves (a refresh that failed keeps the previous one serving).
                # A fallback build still running settles into its own state, which nothing refers to any more.
                entry.fallback = None
        state.settled.set()
        state.answerable.set()
