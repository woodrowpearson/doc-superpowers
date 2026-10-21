"""The local-transformer's host-side state: the encode cache and the host-wide encoder lock.

Encoding is the slow part of a transformer docs build, and a worktree's docs repeat from one
build (and one worktree) to the next, so every vector is cached by the content it came from: the
key hashes the text with everything that changes the vector (the model revision, the ONNX
variant, the token budget, the onnxruntime version, the CPU architecture), so a model or runtime
change misses instead of serving a stale vector. One sqlite file per model under the cache root,
shared by every worktree and process on the host (WAL, so a reader and a writer do not block
each other). A cache that cannot be opened or breaks later is dropped for the rest of the run
with one warning: the build encodes without it rather than fail.

`host_lock` keeps two builds of two processes (two sessions, two worktrees) from running the
encoder at once; the builds of one process are already serial (engines.py). It degrades the same
way: a lock that cannot be set up is a warning and an unlocked run.

Nothing here that only names a path (`cache_root`, `encode_cache_path`) creates a directory or
can raise: a directory is created where something is written to it, inside the guarded open of
an `EncodeCache` and inside `host_lock`, so an unwritable cache location degrades those two and
nothing else.

numpy is the only heavy import here; it is a semble dependency.
"""

from __future__ import annotations

import hashlib
import logging
import os
import sqlite3
import sys
import threading
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager, suppress
from pathlib import Path

import numpy as np

from .transformer import TransformerSpec

try:
    import fcntl
except ImportError:  # Windows: no flock; builds in separate processes may encode together
    fcntl = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

CACHE_ENV = "DOC_SEARCH_CACHE_LOCATION"
APP_DIR = "doc-search"

# Relative DOC_SEARCH_CACHE_LOCATION values already warned about: the warning is once per process.
_warned_relative: set[str] = set()

# SQLite's default limit on bound parameters is 999 in older builds; stay well under it.
_CHUNK = 500
_BUSY_TIMEOUT_MS = 60_000


def cache_root() -> Path:
    """doc-search's cache directory: `DOC_SEARCH_CACHE_LOCATION`, else the platform default.

    The resolution mirrors semble's `resolve_cache_folder`, under the name `doc-search`. It only
    computes the path: the directory is not created (the writers create what they write into),
    so an unwritable location is not an error here.
    """
    value = os.environ.get(CACHE_ENV)
    root: Path | None = None
    if value:
        if Path(value).is_absolute():
            root = Path(value)
        elif value not in _warned_relative:
            _warned_relative.add(value)
            logger.warning("doc-search: %s is not an absolute path, ignored: %s", CACHE_ENV, value)
    if root is None:
        if sys.platform == "win32":
            base = os.getenv("LOCALAPPDATA") or os.getenv("APPDATA")
            root = (Path(base) if base else Path.home() / "AppData" / "Local") / APP_DIR / "Cache"
        elif sys.platform == "darwin":
            root = Path.home() / "Library" / "Caches" / APP_DIR
        else:
            xdg = os.getenv("XDG_CACHE_HOME")
            root = (Path(xdg) if xdg else Path.home() / ".cache") / APP_DIR
    return root


def encode_cache_path(spec: TransformerSpec) -> Path:
    """The sqlite file holding `spec`'s cached vectors (a name only: `EncodeCache` creates its directory)."""
    return cache_root() / "encode" / f"{spec.name}.sqlite"


def cache_size(path: Path) -> int | None:
    """Bytes the cache takes on disk (the database and its `-wal` and `-shm` files).

    None when it does not exist or cannot be looked at (a directory in the way that is a file, one that
    may not be read): `status` asks, and must never raise because of the cache location.
    """
    try:
        total = path.stat().st_size
    except OSError:
        return None
    for suffix in ("-wal", "-shm"):
        with suppress(OSError):
            total += path.with_name(path.name + suffix).stat().st_size
    return total


class EncodeCache:
    """Vectors by content key. Thread-safe; any sqlite or file error makes it unusable (one warning), never raise.

    `put_many` commits every call: the encoder calls it once per batch, so a build that is killed
    keeps every batch it finished, and it stores only vectors of `dim` values. A stored value that
    is not `dim` float32 values (a blob of another length, another type) reads as a miss.
    """

    def __init__(
        self,
        path: Path,
        *,
        model_id: str,
        variant: str,
        max_tokens: int,
        ort_version: str,
        arch: str,
        dim: int,
    ) -> None:
        self.path = path
        self.dim = dim
        self.usable = True
        self._prefix = b"\0".join(p.encode("utf-8") for p in (model_id, variant, str(max_tokens), ort_version, arch))
        self._prefix += b"\0"
        self._lock = threading.Lock()
        self._conn: sqlite3.Connection | None = None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(path, check_same_thread=False)
            self._conn = conn
            # busy_timeout first: several processes open the file at once, and switching to WAL needs a lock
            conn.execute(f"PRAGMA busy_timeout={_BUSY_TIMEOUT_MS}")
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute("CREATE TABLE IF NOT EXISTS vectors (key BLOB PRIMARY KEY, vec BLOB NOT NULL) WITHOUT ROWID")
            conn.commit()
        except (sqlite3.Error, OSError) as err:
            self._fail(err)

    def key(self, text: str) -> bytes:
        """The content key of `text` under this cache's model parameters (sha256, 32 bytes)."""
        return hashlib.sha256(self._prefix + text.encode("utf-8", "surrogatepass")).digest()

    def get_many(self, keys: Sequence[bytes]) -> dict[bytes, np.ndarray]:
        """The cached vectors among `keys` (misses are absent). Each is a float32 array of length `dim`."""
        found: dict[bytes, np.ndarray] = {}
        if not keys:
            return found
        width = self.dim * 4
        with self._lock:
            conn = self._conn
            if not self.usable or conn is None:
                return found
            try:
                for start in range(0, len(keys), _CHUNK):
                    chunk = keys[start : start + _CHUNK]
                    marks = ",".join("?" * len(chunk))
                    for key, blob in conn.execute(f"SELECT key, vec FROM vectors WHERE key IN ({marks})", chunk):
                        if isinstance(blob, bytes) and len(blob) == width:  # a foreign writer may store any type
                            found[bytes(key)] = np.frombuffer(blob, dtype=np.float32).copy()
            except (sqlite3.Error, OSError) as err:
                self._fail(err)
                return {}
        return found

    def put_many(self, rows: Sequence[tuple[bytes, np.ndarray]]) -> None:
        """Store `(key, vector)` rows, replacing any with the same key, and commit."""
        if not rows:
            return
        data: list[tuple[bytes, bytes]] = []
        for key, vector in rows:
            values = np.ascontiguousarray(vector, dtype=np.float32)
            if values.size == self.dim:
                data.append((key, values.tobytes()))
        if len(data) < len(rows):
            logger.debug("doc-search: encode cache skipped %d vectors not of size %d", len(rows) - len(data), self.dim)
        if not data:
            return
        with self._lock:
            conn = self._conn
            if not self.usable or conn is None:
                return
            try:
                conn.executemany("INSERT OR REPLACE INTO vectors (key, vec) VALUES (?, ?)", data)
                conn.commit()
            except (sqlite3.Error, OSError) as err:
                self._fail(err)

    def close(self) -> None:
        """Close the connection (safe to call twice). A closed cache reads as unusable: `usable` is False."""
        with self._lock:
            conn, self._conn = self._conn, None
            self.usable = False
            if conn is not None:
                with suppress(sqlite3.Error):
                    conn.close()

    def _fail(self, err: BaseException) -> None:
        """Drop the cache for the rest of the run, with one warning. Call with the lock held (or before sharing)."""
        conn, self._conn = self._conn, None
        if conn is not None:
            with suppress(sqlite3.Error):
                conn.close()
        if self.usable:
            self.usable = False
            reason = f"{self.path}: {type(err).__name__}: {err}"
            logger.warning("doc-search: encode cache unusable (%s): encoding without it", reason)


def _holder_pid(fd: int) -> int | None:
    """The pid a lock holder wrote into the lock file; None when the file is empty or not a pid."""
    try:
        words = os.pread(fd, 64, 0).split()
        return int(words[0]) if words else None
    except (OSError, ValueError):
        return None


def _acquire(spec: TransformerSpec, on_wait: Callable[[int | None], None] | None) -> int | None:
    """Take the lock; return its file descriptor, or None when it cannot be set up (one warning)."""
    path = cache_root() / "encode" / f"{spec.name}.lock"
    fd: int | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if on_wait is not None:
                try:
                    on_wait(_holder_pid(fd))
                except Exception as err:  # the notice is informational: failing to deliver it keeps the lock
                    logger.warning("doc-search: encoder lock wait notice failed (%s: %s)", type(err).__name__, err)
            fcntl.flock(fd, fcntl.LOCK_EX)
    except BaseException as err:
        if fd is not None:
            with suppress(OSError):
                os.close(fd)
        if not isinstance(err, OSError):  # an interrupt: not ours to absorb
            raise
        reason = f"{path}: {type(err).__name__}: {err}"
        logger.warning("doc-search: encoder lock unavailable (%s): encoding without it", reason)
        return None
    with suppress(OSError):  # the pid is informational: a full disk does not cost the lock
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
    return fd


@contextmanager
def host_lock(spec: TransformerSpec, on_wait: Callable[[int | None], None] | None = None) -> Iterator[None]:
    """Hold the host-wide encoder lock for `spec` (an exclusive `flock` on a file under the cache root).

    Taken without blocking first. When another process (or another open of the file) holds it,
    `on_wait(pid)` is called with the holder's pid (None when unreadable), then this blocks until
    the holder lets go. Once held, the lock file records this process's pid.

    The lock is a convenience, never a reason to fail a build: where `fcntl` is missing (Windows)
    it is a no-op, and when it cannot be set up (the cache location is unwritable, the filesystem
    has no flock) the body runs without it after one warning. A failing `on_wait` is a warning
    too, and the wait goes on.
    """
    fd = _acquire(spec, on_wait) if fcntl is not None else None
    try:
        yield
    finally:
        if fd is not None:
            with suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
