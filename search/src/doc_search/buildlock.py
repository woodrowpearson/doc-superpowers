"""The cross-process build lock: one semble build of one saved index at a time, host-wide.

Every Claude session over a worktree runs its own `doc-search serve`, and they share semble's
cache, so after a pull every one of them found the same index stale and rebuilt it at once (seven
builds of one index, 2-4 GB each). `index_lock` serialises them: an exclusive `flock` on a lock
file beside the index directory semble resolves (`<index dir>.lock`), so the first process builds
and saves, and the others wait, then find the saved index valid and load it.

The lock file is named from the index directory's *physical* path: semble's cache root may be
reached through a symlink (a cache moved to another volume) or named by `SEMBLE_CACHE_LOCATION`,
and two processes that spell one directory two ways must still take one lock. The file is never
removed (removing it would let a waiter hold a lock on an unlinked file while a newcomer locks a
new one); it is a few bytes, the holder's pid.

A holder that dies lets go of the lock with its last descriptor, so a crashed build never wedges
the others. A holder that is alive but stuck is bounded by the waiter's `timeout`: past it, the
body runs without the lock (one warning names the holder). The lock is a convenience, never a
reason to fail a build: where `fcntl` is missing (Windows) it is a no-op, and when it cannot be
set up (an unwritable cache, a filesystem without flock) the body runs without it after one warning.

stdlib only.
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager, suppress
from pathlib import Path

try:
    import fcntl
except ImportError:  # Windows: no flock; servers in separate processes may build together
    fcntl = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

# How often a bounded wait tries the lock again, in seconds.
_LOCK_POLL_S = 0.1


def lock_path(index_dir: Path | str) -> Path:
    """The lock file of a semble index directory: `<index dir>.lock`, beside it, on the physical path.

    The directory need not exist yet (a first build); its existing ancestors are resolved through
    symlinks, so every spelling of one cache directory names one lock file. Creates nothing.
    """
    physical = Path(index_dir).expanduser().resolve()
    return physical.with_name(physical.name + ".lock")


def _holder_pid(fd: int) -> int | None:
    """The pid a lock holder wrote into the lock file; None when the file is empty or not a pid."""
    try:
        words = os.pread(fd, 64, 0).split()
        return int(words[0]) if words else None
    except (OSError, ValueError):
        return None


def _try_until(fd: int, deadline: float) -> bool:
    """Try the lock without blocking until it is taken (True) or `deadline` (time.monotonic) passes (False)."""
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            time.sleep(min(_LOCK_POLL_S, left))


def _acquire(path: Path, on_wait: Callable[[int | None], None] | None, timeout: float) -> tuple[int | None, bool]:
    """Take the lock at `path`: (its file descriptor or None, whether another process held it first).

    The descriptor is None when the lock cannot be set up (one warning) or `timeout` seconds pass
    while another holds it (one warning).
    """
    fd: int | None = None
    waited = False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            waited = True
            holder = _holder_pid(fd)
            if on_wait is not None:
                try:
                    on_wait(holder)
                except Exception as err:  # the notice is informational: failing to deliver it keeps the wait
                    logger.warning("doc-search: build lock wait notice failed (%s: %s)", type(err).__name__, err)
            if not _try_until(fd, time.monotonic() + max(0.0, timeout)):
                os.close(fd)
                fd = None
                who = "another process" if holder is None else f"pid {holder}"
                logger.warning(
                    "doc-search: the build lock %s is still held by %s after %g s: building without it",
                    path,
                    who,
                    timeout,
                )
                return None, waited
    except BaseException as err:
        if fd is not None:
            with suppress(OSError):
                os.close(fd)
        if not isinstance(err, OSError):  # an interrupt: not ours to absorb
            raise
        logger.warning("doc-search: build lock unavailable (%s: %s: %s): building without it", path, type(err).__name__, err)
        return None, waited
    with suppress(OSError):  # the pid is informational: a full disk does not cost the lock
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
    return fd, waited


@contextmanager
def index_lock(
    index_dir: Path | str,
    timeout: float,
    on_wait: Callable[[int | None], None] | None = None,
) -> Iterator[bool]:
    """Hold the build lock of the semble index at `index_dir` (an exclusive `flock` on `lock_path(index_dir)`).

    Taken without blocking first. When another process (or another open of the file) holds it,
    `on_wait(pid)` is called with the holder's pid (None when unreadable), then this waits at most
    `timeout` seconds for the holder to let go; past that the body runs without the lock. Yields
    whether it had to wait, so a caller knows the holder may have saved what it came to build.
    """
    if fcntl is None:
        yield False
        return
    fd, waited = _acquire(lock_path(index_dir), on_wait, timeout)
    try:
        yield waited
    finally:
        if fd is not None:
            with suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
