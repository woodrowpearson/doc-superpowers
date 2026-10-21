"""Progress of a transformer docs build: counts, a windowed rate, an ETA, a first-build estimate, and a
per-worktree file that other processes can read.

The first build of a transformer docs index takes hours (about 3 on an M-series laptop, about 14 on
an Intel Mac), so a status that only says "building" is not enough. `BuildProgress` is the sink the
encoder reports to (`add`), and a `ProgressView` is one consistent reading of it: chunks done, how
many of those came from the encode cache, the encoding rate over the last minute, the ETA the
build's overall pace over that minute gives (cache hits included, so a build that mostly reads the
cache is not quoted hours), and, before anything has been encoded, an estimate from a
per-architecture rate measured on real hardware. `ProgressView.line` is the one status line for it,
shared by `status`, the foreground verbs and the search header.

Status runs in another process than the build (`doc-search status` while the server builds), so the
build also publishes its view to a file under the cache root, one per worktree, written atomically
and at most once a second. `read_progress` reads it back as a view, and treats the file of a process
that is gone (a killed build leaves its file behind) as no file. The rate, ETA and estimate are
fixed in the file at publish time, so reading needs no clock.

Publishing is a side channel and never fails a build: an unwritable cache location is one warning
and no progress file. Nothing here that only names a path creates a directory; `publish` creates its
own.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import platform as _platform
import sys
import tempfile
import threading
import time
from collections import deque
from collections.abc import Callable
from contextlib import suppress
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import TypeGuard

from .encode_cache import cache_root

logger = logging.getLogger(__name__)

# Chunks per second on the first build, measured on real hardware (spec §3): the estimate shown
# before the encoder has produced a rate of its own. A host not listed gets no estimate.
ARCH_RATES: dict[tuple[str, str], float] = {("darwin", "arm64"): 16.0, ("darwin", "x86_64"): 3.6}

# What an encoding line without a total says: the total is the static docs index's chunk count.
NO_TOTAL = "total unknown until a static docs index is saved"

# The rate is the encoder's speed over the last minute: long enough to smooth batch to batch
# differences (a batch is length-sorted, so its cost varies), short enough to follow a slowdown.
RATE_WINDOW_S = 60.0

# At most one progress-file write a second: an add per batch can be faster than that.
PUBLISH_EVERY_S = 1.0


def intel_mac() -> bool:
    """Whether this host is an Intel Mac, the slow row of ARCH_RATES (the warning and `status` name it)."""
    return sys.platform == "darwin" and _platform.machine() == "x86_64"


def arch_rate(platform: str | None = None, machine: str | None = None) -> float | None:
    """The first-build rate in chunks per second for a platform and machine, None where none was measured.

    The defaults are this host's `sys.platform` and `platform.machine()`, read at the call.
    """
    key = (sys.platform if platform is None else platform, _platform.machine() if machine is None else machine)
    return ARCH_RATES.get(key)


def fmt_duration(seconds: float) -> str:
    """`55 s`, `4 min`, `3 h 12 min`, `2 h`: whole units, rounded down.

    Seconds under a minute, minutes under an hour, then hours and minutes (no minutes when exact).
    Callers pass a finite number (`ProgressView.line` checks).
    """
    whole = max(0, int(seconds))
    if whole < 60:
        return f"{whole} s"
    minutes = whole // 60
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes} min" if minutes else f"{hours} h"


def _finite(value: float | None) -> TypeGuard[float]:
    return value is not None and math.isfinite(value)


@dataclass(frozen=True)
class ProgressView:
    """One reading of a build: what `BuildProgress.view` returns and `read_progress` rebuilds from the file.

    `phase` is `queued` (waiting for a place in the transformer lane), `waiting` (for the host's
    encoder lock, held by process `holder_pid` when known), `encoding` or `saving`. `done` counts
    the chunks encoded and the ones read from the encode cache (`from_cache`, a part of `done`).
    `rate` is the encoder's chunks per second over the last minute, `eta_s` the seconds left at the
    build's overall pace over that minute (encoded chunks and cache hits alike), `estimate_s` the
    whole build's seconds at this architecture's first-build rate; each is None while it is
    unknown. `first` says the build makes the worktree's transformer index from nothing (every
    chunk goes through the encoder or the cache); a refresh of a saved one encodes only what
    changed, so it never has a total. `pid` is the process that builds.
    """

    phase: str
    total: int | None
    done: int
    from_cache: int
    rate: float | None
    eta_s: float | None
    estimate_s: float | None
    holder_pid: int | None
    pid: int
    first: bool = True

    def line(self) -> str:
        """The status line for this view, from `docs:` on (callers add any `doc-search: ` prefix).

        A first build without a total says where the total comes from: the command line builds no static
        index, so a first build there knows its chunk count only from a static docs index saved before it.
        """
        head = "docs: transformer index"
        if self.phase == "encoding":
            counts = f"{self.done:,}" if self.total is None else f"{self.done:,} / {self.total:,}"
            text = f"{head} building, {counts} chunks encoded"
            if _finite(self.eta_s):
                text += f", ETA {fmt_duration(self.eta_s)}"
            details = []
            if _finite(self.rate):
                details.append(f"{self.rate:,.1f} chunks/s")
            if self.from_cache > 0:
                details.append(f"{self.from_cache:,} from the encode cache")
            if self.total is None and self.first:
                details.append(NO_TOTAL)
            if details:
                text += f" ({'; '.join(details)})"
            return text
        if self.phase == "queued":
            if self.total and _finite(self.estimate_s) and self.estimate_s > 0:
                rate = self.total / self.estimate_s
                return (
                    f"{head} queued; about {fmt_duration(self.estimate_s)} for {self.total:,} chunks "
                    f"at ~{rate:g} chunks/s on this host (less for chunks already in the encode cache)"
                )
            return f"{head} queued"
        if self.phase == "waiting":
            who = "" if self.holder_pid is None else f" (pid {self.holder_pid})"
            return f"{head} waiting for another doc-search process on this host{who} to finish encoding"
        if self.phase == "saving":
            return f"{head} saving ({self.done:,} chunks encoded)"
        return f"{head} {self.phase}"

    def as_dict(self) -> dict:
        return asdict(self)


class BuildProgress:
    """The progress of one transformer docs build, written by the build's thread and read by any other.

    `add` is the encoder's sink (`transformer.ProgressSink`): once with the cache hits of a call
    (`cached=True`), then once per batch encoded. The build sets `total` (the chunks it will
    process, when known), `phase` and `holder_pid` as it goes, and says at the start whether it is
    a `first` build. A lock makes `add` and `view` atomic, so a view never shows half an add.

    The rate comes from the encoded chunks (not the cache hits, which arrive at once and say
    nothing about the encoder) over the samples of the last `RATE_WINDOW_S`. The ETA comes from
    every chunk done (encoded or read from the cache) over the same window: semble embeds in calls
    of about a thousand chunks, each a burst of hits and then the misses, so a build that mostly
    reads the cache moves far faster than its encoder, and a cold build's pace is its encoder's.
    The window starts with the object and starts again when `phase` becomes `encoding` (the time
    before it is queueing, the host lock and model loading, not encoding), so the first batch
    already has a rate and it is the encoder's. A window with one sample has none: a build that
    has not encoded for a minute loses its rate, and one that has done nothing for a minute its ETA
    too, rather than keep stale ones.

    `publish` writes the view for other processes (see `read_progress`) and `retire` removes it
    when the build ends; a retired build publishes no more, so a late publish from another thread
    cannot bring a finished build's file back. It removes only a file this process wrote, so an
    older server's late `retire` cannot delete a newer server's file.
    """

    def __init__(
        self, worktree: Path, model: str, clock: Callable[[], float] = time.monotonic, *, first: bool = True
    ) -> None:
        self.worktree = Path(worktree)
        self.model = model
        self.first = first
        self.total: int | None = None
        self._phase = "queued"
        self.holder_pid: int | None = None
        self.done = 0
        self.from_cache = 0
        self._clock = clock
        self._lock = threading.Lock()
        self._encoded = 0
        start = clock()
        self._samples: deque[tuple[float, int]] = deque([(start, 0)])  # (time, chunks encoded): the rate
        self._flow: deque[tuple[float, int]] = deque([(start, 0)])  # (time, chunks done): the ETA
        # The file side: one lock for the throttle, the write and the retirement.
        self._file_lock = threading.Lock()
        self._last_publish: float | None = None
        self._retired = False
        self._warned = False
        self._path: Path | None = None

    @property
    def phase(self) -> str:
        return self._phase

    @phase.setter
    def phase(self, value: str) -> None:
        with self._lock:
            if value == "encoding" and self._phase != "encoding":
                # The encoder starts now: what came before (queueing, the host lock, loading the
                # model) is not its speed, so the rate window starts again from here.
                now = self._clock()
                self._samples.clear()
                self._samples.append((now, self._encoded))
                self._flow.clear()
                self._flow.append((now, self.done))
            self._phase = value

    def add(self, n: int, *, cached: bool = False) -> None:
        now = self._clock()
        floor = now - RATE_WINDOW_S
        with self._lock:
            self.done += n
            self._flow.append((now, self.done))
            while self._flow[0][0] < floor:
                self._flow.popleft()
            if cached:
                self.from_cache += n
                return
            self._encoded += n
            self._samples.append((now, self._encoded))
            while self._samples[0][0] < floor:
                self._samples.popleft()

    def view(self) -> ProgressView:
        now = self._clock()
        with self._lock:
            total, phase, holder_pid = self.total, self._phase, self.holder_pid
            done, from_cache = self.done, self.from_cache
            recent = [s for s in self._samples if s[0] >= now - RATE_WINDOW_S]
            flow = [s for s in self._flow if s[0] >= now - RATE_WINDOW_S]
        rate = _pace(recent)  # the encoder's: encoded chunks
        pace = _pace(flow)  # the build's: every chunk done, cache hits included
        eta_s = None if pace is None or total is None else max(0, total - done) / pace
        host_rate = arch_rate()
        estimate_s = None if total is None or host_rate is None else total / host_rate
        return ProgressView(
            phase=phase,
            total=total,
            done=done,
            from_cache=from_cache,
            rate=rate,
            eta_s=eta_s,
            estimate_s=estimate_s,
            holder_pid=holder_pid,
            pid=os.getpid(),
            first=self.first,
        )

    def publish(self, force: bool = False) -> None:
        """Write the view to the worktree's progress file, atomically, at most once a second unless `force`.

        Never raises: a location that cannot be written is one warning per build and no file.
        """
        now = self._clock()
        with self._file_lock:
            if self._retired:
                return
            if not force and self._last_publish is not None and now - self._last_publish < PUBLISH_EVERY_S:
                return
            self._last_publish = now  # a failing location is retried at the same pace, not on every add
            try:
                path = self._target()
                view = self.view()
                data = {**view.as_dict(), "worktree": str(self.worktree), "model": self.model, "pid": os.getpid()}
                path.parent.mkdir(parents=True, exist_ok=True)
                fd, tmp = tempfile.mkstemp(prefix=".progress-", suffix=".tmp", dir=path.parent)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as handle:
                        json.dump(data, handle)
                    os.replace(tmp, path)
                except BaseException:
                    with suppress(OSError):
                        os.unlink(tmp)
                    raise
            except Exception as err:  # a side channel: whatever goes wrong here must not fail the build
                self._failed("build progress not written", err)

    def retire(self) -> None:
        """Remove this process's progress file (the build ended) and publish no more. Never raises; no file is fine."""
        with self._file_lock:
            self._retired = True
            try:
                path = self._target()
                try:
                    owner = json.loads(path.read_text(encoding="utf-8")).get("pid")
                except FileNotFoundError:
                    return
                except (OSError, ValueError, AttributeError):
                    owner = None  # unreadable or not ours to read: nothing says it is another process's
                if _is_pid(owner) and owner != os.getpid():
                    return  # a newer server's file for this worktree: not ours to remove
                path.unlink(missing_ok=True)
            except Exception as err:
                self._failed("build progress file not removed", err)

    def _target(self) -> Path:
        if self._path is None:
            self._path = progress_path(self.worktree)
        return self._path

    def _failed(self, what: str, err: BaseException) -> None:
        """Record a swallowed failure: its traceback at DEBUG every time, one warning per build."""
        logger.debug("doc-search: %s", what, exc_info=err)
        if not self._warned:
            self._warned = True
            logger.warning("doc-search: %s (%s: %s)", what, type(err).__name__, err)


def _pace(samples: list[tuple[float, int]]) -> float | None:
    """Chunks per second from the first to the last of `(time, count)` samples; None with fewer than two, no
    time between them, or no chunks."""
    if len(samples) < 2:
        return None
    (t0, n0), (t1, n1) = samples[0], samples[-1]
    if t1 <= t0 or n1 <= n0:
        return None
    pace = (n1 - n0) / (t1 - t0)
    return pace if math.isfinite(pace) else None


def progress_path(worktree: Path) -> Path:
    """Where the build of `worktree` publishes its progress: one file per resolved worktree path.

    Only names the path; `BuildProgress.publish` creates the directory.
    """
    resolved = str(Path(worktree).resolve())
    key = hashlib.sha256(resolved.encode("utf-8", "surrogateescape")).hexdigest()[:16]
    return cache_root() / "encode" / "progress" / f"{key}.json"


def read_progress(worktree: Path) -> ProgressView | None:
    """The published progress of the build of `worktree`, or None.

    None when there is no file, it cannot be read or is not a progress file, or its process is gone
    (a killed build leaves its file behind). A process that is alive but another user's still counts
    as alive. A pid reused by an unrelated process after a crash cannot be told apart.
    """
    try:
        data = json.loads(progress_path(worktree).read_text(encoding="utf-8"))
    except (OSError, ValueError, RuntimeError):
        return None
    view = _view_from(data)
    if view is None or not _pid_alive(view.pid):
        return None
    return view


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_pid(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value < 2**31


def _is_number(value: object) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:  # an int too large for a float
        return False


def _view_from(data: object) -> ProgressView | None:
    """A view from a progress file's JSON, None unless every field is there and of its type."""
    if not isinstance(data, dict):
        return None
    try:
        phase, total, done, from_cache = data["phase"], data["total"], data["done"], data["from_cache"]
        rate, eta_s, estimate_s = data["rate"], data["eta_s"], data["estimate_s"]
        holder_pid, pid, first = data["holder_pid"], data["pid"], data["first"]
    except KeyError:
        return None
    valid = (
        isinstance(phase, str)
        and _is_count(done)
        and _is_count(from_cache)
        and (total is None or _is_count(total))
        and all(v is None or _is_number(v) for v in (rate, eta_s, estimate_s))
        and (holder_pid is None or _is_pid(holder_pid))
        and _is_pid(pid)
        and isinstance(first, bool)
    )
    if not valid:
        return None
    return ProgressView(
        phase=phase,
        total=total,
        done=done,
        from_cache=from_cache,
        rate=None if rate is None else float(rate),
        eta_s=None if eta_s is None else float(eta_s),
        estimate_s=None if estimate_s is None else float(estimate_s),
        holder_pid=holder_pid,
        pid=pid,
        first=first,
    )


def _pid_alive(pid: int) -> bool:
    """Whether a process with this pid exists: `os.kill(pid, 0)` sends no signal, and another user's process exists."""
    if sys.platform == "win32":
        return _pid_alive_windows(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _pid_alive_windows(pid: int) -> bool:
    """On Windows `os.kill(pid, 0)` would terminate the process, so ask the process table instead."""
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel32.GetExitCodeProcess.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            # ERROR_ACCESS_DENIED means it exists and we may not look; anything else, it is gone
            return ctypes.get_last_error() == 5  # type: ignore[attr-defined]
        try:
            code = wintypes.DWORD()
            if kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return code.value == 259  # STILL_ACTIVE
            return True
        finally:
            kernel32.CloseHandle(handle)
    except (AttributeError, OSError):
        return True
