"""The semble engines: a docs index and a code index per worktree, built in the background.

An `IndexPool` keeps the index pair of at most `max_worktrees` worktrees in memory (least
recently used goes first; a worktree whose build is still running is never the victim, so
the pool may briefly hold more). The first `get` for a worktree starts one thread per kind; a call
waits for those threads up to `wait_s`, then answers `Building` and the builds carry on.

semble builds run one at a time across the pool (MAX_CONCURRENT_BUILDS), every worktree and kind:
a build's memory peaks high (~5 GB measured for a large repository's two builds in parallel), and
serial builds lower the peak. Each thread takes its place in line when it starts, so a worktree's
docs build goes before its code build, and the worktrees go in the order they were asked for. A
thread that finds a valid cache loads it without queueing; one that waits for its turn is still
running, so `get` reads it as building.

Loading follows semble's own cache: a cache that still matches the tree is loaded from disk
(`get_validated_cache` then `SembleIndex.load_from_disk`), anything else is rebuilt through
`SembleIndex.from_path`, which re-indexes incrementally, and saved with
`save_index_to_cache`.

A kind is checked again once its last check is older than
`max(search.rescan_seconds, 3 x its last build seconds)`, the cooldown semble's own server
uses. The recheck runs in a thread too, and every call that finds a refresh running (the one
that started it included) waits for it within `wait_s`; a refresh that outlasts the wait, or
fails, leaves the previous index serving.

Nothing here raises to a caller: a build exception is recorded in `WorktreeIndexes.error`.
All times (`built_at`, `build_seconds`, the cooldown) are in units of the injected clock.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import OrderedDict, deque
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder, get_validated_cache, save_index_to_cache
from semble.index.types import PersistencePath

from .config import Config

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


@dataclass
class WorktreeIndexes:
    """A worktree's index pair, as of one `get` call. A snapshot: later refreshes never touch it.

    A kind that is off (`code.enabled` false) is absent from the dicts and its index is None.
    `error[kind]` says the last build or refresh of that kind failed; the index is then None
    (it never built) or the previous one (it is stale).
    """

    docs: SembleIndex | None = None
    code: SembleIndex | None = None
    built_at: dict[str, float] = field(default_factory=dict)
    build_seconds: dict[str, float] = field(default_factory=dict)
    error: dict[str, str] = field(default_factory=dict)


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

    def __init__(self, slots: int) -> None:
        self._cond = threading.Condition()
        self._slots = slots
        self._active = 0
        self._waiting: deque[_Place] = deque()

    def place(self) -> _Place:
        """A place at the back of the line. Its holder builds inside `with place:`, and calls `leave` in any case."""
        place = _Place(self)
        with self._cond:
            self._waiting.append(place)
        return place


class _Place:
    """One build thread's place in a `_BuildLine`: `queued`, then `held` while it builds, then `left`."""

    def __init__(self, line: _BuildLine) -> None:
        self._line = line
        self._state = "queued"

    def __enter__(self) -> _Place:
        """Wait until this place is first in line and a slot is free, then hold the slot."""
        line = self._line
        with line._cond:
            line._cond.wait_for(lambda: line._waiting[0] is self and line._active < line._slots)
            line._waiting.popleft()
            line._active += 1
            self._state = "held"
            line._cond.notify_all()  # the next place may fit in another slot
        return self

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
    """One kind of one worktree. All fields are guarded by the pool's lock."""

    def __init__(self, name: Kind, content: tuple[ContentType, ...], model: str | None) -> None:
        self.name = name
        self.content = content
        self.model = model
        self.settled = threading.Event()  # set while no build thread is running
        self.settled.set()
        self.running = False
        self.index: SembleIndex | None = None
        self.token: tuple[int, int] | None = None  # the on-disk cache state `index` corresponds to
        self.files: frozenset[str] = frozenset()
        self.built_at: float | None = None
        self.build_seconds: float | None = None
        self.error: str | None = None
        self.checked_at: float | None = None  # when the last build thread finished
        self.cool_seconds = 0.0  # what the cooldown scales: the last build, or the slowest recent failure
        self.fatal = False  # a config error: no build can fix it, so none is ever started


class _Entry:
    def __init__(self, worktree: Path, states: dict[Kind, _State]) -> None:
        self.worktree = worktree
        self.states = states

    def building(self) -> bool:
        return any(state.running for state in self.states.values())


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


class IndexPool:
    def __init__(
        self,
        cfg: Config,
        max_worktrees: int = 2,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if max_worktrees < 1:
            raise ValueError("max_worktrees must be at least 1")
        self._cfg = cfg
        self._max = max_worktrees
        self.clock = clock
        self._lock = threading.RLock()
        self._entries: OrderedDict[Path, _Entry] = OrderedDict()  # least recently used first
        self._builds = _BuildLine(MAX_CONCURRENT_BUILDS)

    # -- public ------------------------------------------------------------------------

    def get(self, worktree: Path | str, wait_s: float = 20.0) -> WorktreeIndexes | Building:
        """The worktree's indexes, revalidated if due, waiting up to `wait_s` seconds for builds.

        Returns `Building` only while a kind has never finished a build (its `partial` holds
        the kinds that have); once every kind has (even with an error) the answer is a
        `WorktreeIndexes`, stale if a refresh is still running. Safe to call from several threads.
        """
        top = Path(worktree).resolve()
        deadline = time.monotonic() + max(0.0, wait_s)  # real time: the injected clock may not move
        with self._lock:
            entry = self._touch(top)
            now = self.clock()
            waiting = []
            for state in entry.states.values():
                if not state.running and self._due(state, now):
                    self._start(entry, state)
                if state.running:
                    waiting.append(state.settled)
        for event in waiting:
            event.wait(max(0.0, deadline - time.monotonic()))
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

    @property
    def max_worktrees(self) -> int:
        """How many worktrees' index pairs stay in memory (a running build can briefly exceed it)."""
        return self._max

    def indexed_files(self, worktree: Path | str, kind: Kind) -> set[str]:
        """The repo-relative paths with at least one chunk in the worktree's `kind` index.

        Empty when nothing is built (or kept) for that worktree and kind. Never starts a build.
        """
        with self._lock:
            entry = self._entries.get(Path(worktree).resolve())
            state = entry.states.get(kind) if entry else None
            return set(state.files) if state else set()

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
        # would let a later get start a second build into the same semble cache directory.
        for path, other in list(self._entries.items()):
            if len(self._entries) <= self._max:
                break
            if path != top and not other.building():
                del self._entries[path]
        return entry

    def _spec(self, kind: Kind) -> tuple[tuple[ContentType, ...], str | None]:
        """What semble is asked for in `kind`'s index: its content types and model.

        The one place both are decided: the builds and `cache_state` read it, so they cannot drift.
        Raises ValueError for a `code.content` value semble has no content type for.
        """
        cfg = self._cfg
        if kind == "docs":
            return (ContentType.DOCS,), cfg.docs.model
        return _content_types(cfg.code.content), cfg.code.model

    def _states(self) -> dict[Kind, _State]:
        cfg = self._cfg
        states: dict[Kind, _State] = {"docs": _State("docs", *self._spec("docs"))}
        if cfg.code.enabled:
            try:
                states["code"] = _State("code", *self._spec("code"))
            except ValueError as err:  # a config value semble has no content type for
                broken = _State("code", (), cfg.code.model)
                broken.fatal = True
                broken.error = f"invalid code.content: {err}"
                broken.checked_at = self.clock()
                states["code"] = broken
        return states

    def cache_state(self, worktree: Path | str, kind: Kind) -> CacheState:
        """Whether semble's saved index of `kind` for `worktree` could be used as it is, without using it.

        `valid`: `get_validated_cache` accepts it, so a build would load it from disk. `stale`: a complete
        saved index for this path and content exists but does not validate (a file changed, was added or
        removed, another model, a damaged file). `absent`: there is none (or this process cannot tell).
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
            saved = PersistencePath.from_path(find_index_from_cache_folder(path, content))
            return "absent" if saved.non_existing() else "stale"
        except Exception:  # noqa: BLE001 - a question about the cache must not raise (an unusable code.content, a vanished tree)
            logger.debug("doc-search: cannot tell the %s cache of %s", kind, worktree, exc_info=True)
            return "absent"

    def _due(self, state: _State, now: float) -> bool:
        if state.fatal:
            return False
        if state.checked_at is None:
            return True
        cooldown = max(self._cfg.search.rescan_seconds, REVALIDATE_FACTOR * state.cool_seconds)
        return now - state.checked_at >= cooldown

    @staticmethod
    def _result(entry: _Entry) -> WorktreeIndexes | Building:
        def ready(name: Kind) -> bool:
            state = entry.states.get(name)
            return state is None or state.checked_at is not None

        docs_ready, code_ready = ready("docs"), ready("code")
        if docs_ready and code_ready:
            return IndexPool._snapshot(entry)
        finished = IndexPool._snapshot(entry)
        some = any(state.checked_at is not None for state in entry.states.values())
        return Building(entry.worktree, docs_ready, code_ready, partial=finished if some else None)

    @staticmethod
    def _snapshot(entry: _Entry) -> WorktreeIndexes:
        """The indexes of the kinds that have finished a build; a kind still on its first build is left out."""
        out = WorktreeIndexes()
        for name, state in entry.states.items():
            if state.checked_at is None:
                continue
            if name == "docs":
                out.docs = state.index
            else:
                out.code = state.index
            if state.built_at is not None and state.build_seconds is not None:
                out.built_at[name] = state.built_at
                out.build_seconds[name] = state.build_seconds
            if state.error is not None:
                out.error[name] = state.error
        return out

    # -- build threads -----------------------------------------------------------------

    def _start(self, entry: _Entry, state: _State) -> None:
        """Start a build thread for `state`. The caller holds the lock and has seen it idle.

        The thread's place in the build line is taken here, in the caller's order (docs, then code), not
        when the thread gets round to it.
        """
        state.running = True
        state.settled.clear()
        place = self._builds.place()
        thread = threading.Thread(
            target=self._run,
            args=(entry.worktree, state, state.index, state.token, place),
            name=f"doc-search-{state.name}-{entry.worktree.name}",
            daemon=True,
        )
        try:
            thread.start()
        except RuntimeError as err:  # no thread could be started: settle as a failure, never hang
            place.leave()
            self._settle(state, _Outcome(error=_describe(err)), 0.0)

    def _run(
        self,
        worktree: Path,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
        place: _Place,
    ) -> None:
        start = self.clock()
        outcome = _Outcome(error="build thread ended abnormally")
        try:
            outcome = self._refresh(worktree, state, current, current_token, place)
        except Exception as err:  # noqa: BLE001 - a build failure is data, not an exception
            outcome = _Outcome(error=_describe(err))
            logger.debug("doc-search: %s index of %s failed", state.name, worktree, exc_info=True)
        finally:
            place.leave()  # a thread that loaded the cache never built: its place goes to the next in line
            with self._lock:
                self._settle(state, outcome, self.clock() - start)

    @staticmethod
    def _refresh(
        worktree: Path,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
        place: _Place,
    ) -> _Outcome:
        path = str(worktree)
        cached = get_validated_cache(path, state.model, state.content)
        if cached is not None:
            token = _stamp(cached)
            if current is not None and token is not None and token == current_token:
                return _Outcome(index=current, token=token)  # the cache is what we already hold
            index = SembleIndex.load_from_disk(cached)
            return _Outcome(index=index, token=token, files=_files_of(index), changed=True)
        with place:  # one semble build at a time, pool-wide
            index = SembleIndex.from_path(path, content=list(state.content), model_path=state.model)
        try:
            save_index_to_cache(index, path)
        except Exception as err:  # noqa: BLE001 - an index that cannot be cached still serves
            logger.warning("doc-search: could not cache the %s index of %s: %s", state.name, worktree, _describe(err))
        token = _stamp(find_index_from_cache_folder(path, index.content))
        return _Outcome(index=index, token=token, files=_files_of(index), changed=True)

    def _settle(self, state: _State, outcome: _Outcome, elapsed: float) -> None:
        """Record a finished build thread. The caller holds the lock."""
        state.running = False
        state.checked_at = self.clock()
        if outcome.error is not None:
            # keep any previous index serving; a slow failure slows the retries
            state.error = outcome.error
            state.cool_seconds = max(state.cool_seconds, elapsed)
        else:
            state.error = None
            if outcome.changed:
                state.index = outcome.index
                state.token = outcome.token
                state.files = outcome.files
                state.built_at = state.checked_at
                state.build_seconds = elapsed
                state.cool_seconds = elapsed
        state.settled.set()
