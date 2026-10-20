"""The semble engines: a docs index and a code index per worktree, built in the background.

An `IndexPool` keeps the index pair of at most `max_worktrees` worktrees in memory (least
recently used goes first; a worktree whose build is still running is never the victim, so
the pool may briefly hold more). The first `get` for a worktree starts one thread per kind; a call
waits for those threads up to `wait_s`, then answers `Building` and the builds carry on.

Loading follows semble's own cache: a cache that still matches the tree is loaded from disk
(`get_validated_cache` then `SembleIndex.load_from_disk`), anything else is rebuilt through
`SembleIndex.from_path`, which re-indexes incrementally, and saved with
`save_index_to_cache`.

A kind is checked again once its last check is older than
`max(search.rescan_seconds, 3 x its last build seconds)`, the cooldown semble's own server
uses. The recheck runs in a thread too, and the call that triggered it waits for it within
`wait_s`; a refresh that outlasts the wait, or fails, leaves the previous index serving.

Nothing here raises to a caller: a build exception is recorded in `WorktreeIndexes.error`.
All times (`built_at`, `build_seconds`, the cooldown) are in units of the injected clock.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import OrderedDict
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

# semble's own server rechecks a path no sooner than this many times its last build took.
REVALIDATE_FACTOR = 3


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
    """

    worktree: Path
    docs_ready: bool
    code_ready: bool


@dataclass
class _Outcome:
    """What one build thread produced: a new or kept index, or an error."""

    index: SembleIndex | None = None
    token: tuple[int, int] | None = None
    files: frozenset[str] = frozenset()
    changed: bool = False
    error: str | None = None


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

    # -- public ------------------------------------------------------------------------

    def get(self, worktree: Path | str, wait_s: float = 20.0) -> WorktreeIndexes | Building:
        """The worktree's indexes, revalidated if due, waiting up to `wait_s` seconds for builds.

        Returns `Building` only while a kind has never finished a build; once every kind has
        (even with an error) the answer is a `WorktreeIndexes`, stale if a refresh is still
        running. Safe to call from several threads.
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

    def _states(self) -> dict[Kind, _State]:
        cfg = self._cfg
        states: dict[Kind, _State] = {"docs": _State("docs", (ContentType.DOCS,), cfg.docs.model)}
        if cfg.code.enabled:
            try:
                states["code"] = _State("code", _content_types(cfg.code.content), cfg.code.model)
            except ValueError as err:  # a config value semble has no content type for
                broken = _State("code", (), cfg.code.model)
                broken.fatal = True
                broken.error = f"invalid code.content: {err}"
                broken.checked_at = self.clock()
                states["code"] = broken
        return states

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

        if not (ready("docs") and ready("code")):
            return Building(entry.worktree, docs_ready=ready("docs"), code_ready=ready("code"))
        out = WorktreeIndexes()
        for name, state in entry.states.items():
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
        """Start a build thread for `state`. The caller holds the lock and has seen it idle."""
        state.running = True
        state.settled.clear()
        thread = threading.Thread(
            target=self._run,
            args=(entry.worktree, state, state.index, state.token),
            name=f"doc-search-{state.name}-{entry.worktree.name}",
            daemon=True,
        )
        try:
            thread.start()
        except RuntimeError as err:  # no thread could be started: settle as a failure, never hang
            self._settle(state, _Outcome(error=_describe(err)), 0.0)

    def _run(
        self,
        worktree: Path,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
    ) -> None:
        start = self.clock()
        outcome = _Outcome(error="build thread ended abnormally")
        try:
            outcome = self._refresh(worktree, state, current, current_token)
        except Exception as err:  # noqa: BLE001 - a build failure is data, not an exception
            outcome = _Outcome(error=_describe(err))
            logger.debug("doc-search: %s index of %s failed", state.name, worktree, exc_info=True)
        finally:
            with self._lock:
                self._settle(state, outcome, self.clock() - start)

    @staticmethod
    def _refresh(
        worktree: Path,
        state: _State,
        current: SembleIndex | None,
        current_token: tuple[int, int] | None,
    ) -> _Outcome:
        path = str(worktree)
        cached = get_validated_cache(path, state.model, state.content)
        if cached is not None:
            token = _stamp(cached)
            if current is not None and token is not None and token == current_token:
                return _Outcome(index=current, token=token)  # the cache is what we already hold
            index = SembleIndex.load_from_disk(cached)
            return _Outcome(index=index, token=token, files=_files_of(index), changed=True)
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
