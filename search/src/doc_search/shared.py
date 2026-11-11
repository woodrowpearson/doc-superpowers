"""The shared server's client side: `serve`'s proxy (design: docs/superpowers/specs/2026-11-10-doc-search-shared-server-design.md).

One doc-search server (daemon.py) runs per repository, configuration and environment on a host. Each
session's `serve` runs this proxy, which finds that server's Unix socket (or starts the server), sends
a hello line, then pipes the session's stdio to it. The proxy keeps the MCP handshake: when the server
goes away it answers the calls still waiting with STOPPED, starts or finds a new server, replays the
handshake, and carries on. When no server can be had, it runs the in-process server as a child.

Standard library only, so the proxy stays small: nothing here imports the MCP SDK, semble or numpy.
"""

from __future__ import annotations

import errno
import hashlib
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import IO, BinaryIO, Protocol

from . import __version__

try:
    import fcntl
except ImportError:  # Windows: no flock, no shared server
    fcntl = None  # type: ignore[assignment]

PROTOCOL = 1
CONFIG_REL = "docs/search/config.json"  # config.CONFIG_REL; a test keeps them equal
STOPPED = "doc-search: the shared server stopped; retry the call"
KEY_ENV_PREFIXES = ("DOC_SEARCH_", "SEMBLE_", "HF_", "GOOGLE_", "CLOUDSDK_", "GIT_")
KEY_ENV_NAMES = frozenset({"HOME", "XDG_CACHE_HOME"})  # semble's and doc-search's caches live under them
KEY_ENV_SKIP = frozenset({"DOC_SEARCH_CLIENT_CWD"})
# `python -P`: the daemon and the fallback child run in the repository, whose top must never shadow a module
CHILD = (sys.executable, "-P", "-m", "doc_search.entry")
RECONNECT_WAIT_S = 20.0
HELLO_RETRIES = 3
SUN_PATH_MAX = 103 if sys.platform == "darwin" else 107  # sockaddr_un's sun_path, less its NUL
MAX_LINE = 64 * 1024 * 1024
LOG_MAX_BYTES = 5 * 1024 * 1024


def shared_wanted(env: Mapping[str, str]) -> bool:
    """Whether `serve` tries the shared server: `DOC_SEARCH_SHARED` decides, else not in a cloud session."""
    if not hasattr(socket, "AF_UNIX") or fcntl is None:
        return False
    switch = env.get("DOC_SEARCH_SHARED", "").strip()
    if switch in ("0", "1"):
        return switch == "1"
    return not env.get("CLAUDE_CODE_REMOTE")


def daemon_key(top: Path, config: bytes, env: Mapping[str, str]) -> str:
    """The key of the server a session may share: equal only when a server of each would behave the same."""
    parts = [
        str(top),
        hashlib.sha256(config).hexdigest(),
        __version__,
        _code_stamp(),
        sys.executable,
        sorted(
            (name, value)
            for name, value in env.items()
            if (name.startswith(KEY_ENV_PREFIXES) or name in KEY_ENV_NAMES) and name not in KEY_ENV_SKIP
        ),
    ]
    return hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:16]


def _code_stamp() -> str:
    """The package's path and its modules' sizes and times: a source checkout's edit gets a new daemon,
    though its version stays the same."""
    here = Path(__file__).resolve().parent
    stamp = hashlib.sha256(str(here).encode())
    for path in sorted(here.rglob("*.py")):
        try:
            st = path.stat()
        except OSError:
            continue
        stamp.update(f"{path.relative_to(here)}:{st.st_size}:{st.st_mtime_ns};".encode())
    return stamp.hexdigest()


def _darwin_user_temp() -> str | None:
    """macOS's per-user temporary directory, whatever TMPDIR a session was given."""
    try:
        done = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return (done.stdout.strip() or None) if done.returncode == 0 else None


def runtime_dir(env: Mapping[str, str]) -> Path:
    if env.get("DOC_SEARCH_RUNTIME_DIR"):
        return Path(env["DOC_SEARCH_RUNTIME_DIR"])
    if sys.platform == "darwin":
        base = _darwin_user_temp() or env.get("TMPDIR")
        if base:
            return Path(base) / "doc-search"  # per user on macOS
    if env.get("XDG_RUNTIME_DIR"):
        return Path(env["XDG_RUNTIME_DIR"]) / "doc-search"
    return Path("/tmp") / f"doc-search-{os.getuid()}"


def unsafe_dir(path: Path) -> str | None:
    """Why `path` must not hold the sockets, or None: it must be a real directory of this user, closed to others."""
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode):
        return f"{path} is not a directory"
    if st.st_uid != os.getuid():
        return f"{path} belongs to another user"
    if st.st_mode & 0o077:
        return f"{path} is open to others (mode {stat.S_IMODE(st.st_mode):o})"
    return None


@dataclass(frozen=True)
class Place:
    key: str
    dir: Path

    @property
    def sock(self) -> Path:
        return self.dir / f"{self.key}.sock"

    @property
    def alive(self) -> Path:
        return self.dir / f"{self.key}.alive"

    @property
    def start(self) -> Path:
        return self.dir / f"{self.key}.start"

    @property
    def log(self) -> Path:
        return self.dir / f"{self.key}.log"


def place_for(top: Path, config: bytes, env: Mapping[str, str]) -> Place | str:
    """The daemon's files for this session, or why the shared path is off here."""
    where = runtime_dir(env)
    try:
        where.mkdir(mode=0o700, parents=True, exist_ok=True)
        reason = unsafe_dir(where)
    except OSError as err:
        reason = f"cannot use {where}: {err.strerror or err}"
    if reason:
        return reason
    place = Place(daemon_key(top, config, env), where)
    if len(os.fsencode(str(place.sock))) > SUN_PATH_MAX:
        return f"the socket path is too long: {place.sock}"
    return place


class StartError(Exception):
    """No shared server could be reached or started."""


class HelloRefused(Exception):
    """The server at the socket is not the one this session asked for."""


class HelloLost(HelloRefused):
    """The server closed the connection before its hello: it was exiting. Another try starts a new one."""


def _try_connect(path: Path) -> socket.socket | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(str(path))
    except OSError as err:
        sock.close()
        if err.errno in (errno.ENOENT, errno.ECONNREFUSED):
            return None
        raise
    return sock


def _lock_free(path: Path) -> bool:
    """True when no process holds the lock file `path` (taken and let go at once)."""
    with open(path, "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        fcntl.flock(handle, fcntl.LOCK_UN)
        return True


def hold_alive(place: Place) -> IO[str] | None:
    """The daemon's life lock, held until the returned file is closed (or the process ends), with its pid in it.
    None when another daemon holds it."""
    handle = open(place.alive, "a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle


def connect(place: Place, spawn: Callable[[], None], wait_s: float = 60.0) -> socket.socket:
    """A connection to the daemon at `place`, started with `spawn` when none is alive.

    Under the start lock: connect; else, while no process holds the life lock, remove the stale socket and
    spawn (once); poll until the socket answers. A crashed daemon has let go of its life lock in the kernel,
    so its socket is found refused and replaced. One that is exiting holds the lock until it is gone.
    """
    sock = _try_connect(place.sock)
    if sock is not None:
        return sock
    deadline = time.monotonic() + wait_s
    with open(place.start, "a") as start:
        while True:
            try:
                fcntl.flock(start, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise StartError(f"another session is starting the shared server ({place.log})") from None
                time.sleep(0.05)
        spawned = False
        while time.monotonic() < deadline:
            sock = _try_connect(place.sock)
            if sock is not None:
                return sock
            if not spawned and _lock_free(place.alive):
                place.sock.unlink(missing_ok=True)
                spawn()
                spawned = True
            time.sleep(0.05)
    raise StartError(f"the shared server did not start within {wait_s:g} s (see {place.log})")


def hello(sock: socket.socket, key: str, client_cwd: str | None, wait_s: float = 60.0) -> BinaryIO:
    """Say which server this session wants and for which working directory; return the reader to keep."""
    sock.settimeout(wait_s)
    sock.sendall((json.dumps({"doc_search_proxy": PROTOCOL, "key": key, "client_cwd": client_cwd}) + "\n").encode())
    reader = sock.makefile("rb")
    try:
        raw = reader.readline(MAX_LINE)
    except OSError as err:
        raise HelloLost(f"no hello from the shared server: {err}") from err
    if not raw.endswith(b"\n"):
        raise HelloLost("the shared server closed the connection before its hello")
    try:
        reply = json.loads(raw)
    except ValueError as err:
        raise HelloRefused(f"the shared server's hello is not JSON: {err}") from err
    sock.settimeout(None)
    if not isinstance(reply, dict) or reply.get("doc_search_daemon") != PROTOCOL or reply.get("key") != key:
        raise HelloRefused(f"the shared server answered {reply!r}")
    return reader


class Backend(Protocol):
    def send(self, data: bytes) -> None: ...
    def readline(self) -> bytes: ...
    def close_write(self) -> None: ...
    def close(self) -> None: ...


class SocketBackend:
    def __init__(self, sock: socket.socket, reader: BinaryIO) -> None:
        self._sock, self._reader = sock, reader

    def send(self, data: bytes) -> None:
        self._sock.sendall(data)

    def readline(self) -> bytes:
        try:
            return self._reader.readline(MAX_LINE)
        except (OSError, ValueError):  # ValueError: read after close
            return b""

    def close_write(self) -> None:
        try:
            self._sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def close(self) -> None:
        self._reader.close()
        self._sock.close()


class ChildBackend:
    """The in-process server as a child process, for a session whose shared server cannot be had back."""

    def __init__(self, proc: subprocess.Popen) -> None:
        self._proc = proc

    @classmethod
    def start(cls, cwd: Path, env: Mapping[str, str]) -> ChildBackend:
        proc = subprocess.Popen(
            [*CHILD, "serve", "--in-process"],
            cwd=cwd, env=dict(env), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        return cls(proc)

    def send(self, data: bytes) -> None:
        self._proc.stdin.write(data)
        self._proc.stdin.flush()

    def readline(self) -> bytes:
        try:
            return self._proc.stdout.readline(MAX_LINE)
        except (OSError, ValueError):
            return b""

    def close_write(self) -> None:
        try:
            self._proc.stdin.close()
        except OSError:
            pass

    def close(self) -> None:
        self.close_write()
        try:
            self._proc.wait(10)
        except subprocess.TimeoutExpired:
            self._proc.kill()


def _id_key(value: object) -> str:
    return json.dumps(value, sort_keys=True)


class Proxy:
    """stdio ⇄ a backend, surviving the backend's loss (module docstring)."""

    def __init__(
        self,
        stdin: BinaryIO,
        stdout: BinaryIO,
        reopen: Callable[[], Backend],
        fallback: Callable[[], Backend],
        backoff: tuple[float, ...] = (1.0, 2.0, 4.0),
    ) -> None:
        self._stdin, self._stdout = stdin, stdout
        self._reopen, self._fallback, self._backoff = reopen, fallback, backoff
        self._cond = threading.Condition()
        self._backend: Backend | None = None
        self._dead = False
        self._stdin_done = False
        self._pending: dict[str, object] = {}
        self._init: dict | None = None
        self._initialized: bytes | None = None
        self._replays: set[str] = set()
        self._out_lock = threading.Lock()

    def run(self, first: Backend) -> int:
        self._backend = first
        down = threading.Thread(target=self._pump_down, name="doc-search-proxy-down", daemon=True)
        down.start()
        self._pump_up()
        down.join(30)
        return 0

    # -- the client's side --------------------------------------------------------------------

    def _pump_up(self) -> None:
        while True:
            data = self._stdin.readline()
            if not data:
                break
            self._send(data)
        with self._cond:
            self._stdin_done = True
            backend = self._backend
        if backend is not None:
            backend.close_write()

    def _note_up(self, data: bytes) -> list[object]:
        """Remember the handshake; return the ids of the requests in `data` (answered or STOPPED later)."""
        ids = []
        for msg in _messages(data):
            method = msg.get("method")
            if method == "initialize" and "id" in msg:
                self._init = msg
            elif method == "notifications/initialized":
                self._initialized = data
            elif method == "notifications/cancelled":
                params = msg.get("params")
                if isinstance(params, dict) and "requestId" in params:
                    with self._cond:
                        self._pending.pop(_id_key(params["requestId"]), None)
            if method is not None and "id" in msg:
                ids.append(msg["id"])
        return ids

    def _send(self, data: bytes) -> None:
        ids = self._note_up(data)
        with self._cond:  # recording and sending under the lock a recovery swaps the backend under: one answer each
            while self._backend is None and not self._dead:
                self._cond.wait()
            backend = self._backend
            if backend is None:
                for request_id in ids:  # nothing left to serve this session
                    self._write(_stopped(request_id))
                return
            for request_id in ids:
                self._pending[_id_key(request_id)] = request_id
            try:
                backend.send(data)
            except OSError:
                pass  # the reader sees the loss and recovers; this call is pending and gets STOPPED

    # -- the server's side --------------------------------------------------------------------

    def _pump_down(self) -> None:
        while True:
            with self._cond:
                backend = self._backend
            if backend is None:
                return
            data = backend.readline()
            if data.endswith(b"\n"):
                if self._note_down(data):
                    self._write(data)
                continue
            # end of file, or a line cut short by the server's loss: never forward a fragment
            with self._cond:
                done = self._stdin_done
            if done or not self._recover(backend):
                return

    def _note_down(self, data: bytes) -> bool:
        """Clear answered calls; False for the answer to a replayed handshake, which the client never sent."""
        for msg in _messages(data):
            if "id" in msg and "method" not in msg:
                key = _id_key(msg["id"])
                with self._cond:
                    if key in self._replays:
                        self._replays.discard(key)
                        return False
                    self._pending.pop(key, None)
        return True

    def _write(self, data: bytes) -> None:
        with self._out_lock:
            self._stdout.write(data)
            self._stdout.flush()

    def _recover(self, lost: Backend) -> bool:
        init_id = _id_key(self._init["id"]) if self._init is not None else None
        with self._cond:
            self._backend = None
            stranded = [value for key, value in self._pending.items() if key != init_id]
            init_pending = init_id is not None and init_id in self._pending
            self._pending = {init_id: self._init["id"]} if init_pending else {}
            self._replays.clear()  # the lost server's answers never come
        lost.close()
        for request_id in stranded:
            self._write(_stopped(request_id))
        backend = None
        for delay in self._backoff:
            time.sleep(delay)
            try:
                backend = self._reopen()
                break
            except (StartError, HelloRefused, OSError) as err:
                print(f"doc-search: reconnecting to the shared server failed: {err}", file=sys.stderr)
        if backend is None:
            try:
                backend = self._fallback()
            except OSError as err:
                print(f"doc-search: cannot start the in-process server: {err}", file=sys.stderr)
                with self._cond:
                    self._dead = True
                    self._cond.notify_all()
                return False
        try:
            if self._init is not None and init_pending:
                backend.send((json.dumps(self._init) + "\n").encode())  # its answer goes to the client
            elif self._init is not None:
                replay = dict(self._init, id=f"doc-search-proxy-replay-{time.monotonic_ns()}")
                with self._cond:
                    self._replays.add(_id_key(replay["id"]))
                backend.send((json.dumps(replay) + "\n").encode())
            if self._initialized is not None:
                backend.send(self._initialized)
        except OSError:
            pass  # lost again at once: the next readline reads EOF and recovers again
        with self._cond:
            self._backend = backend
            self._cond.notify_all()
            done = self._stdin_done
        if done:
            backend.close_write()  # the client left while we reconnected
        return True


def _stopped(request_id: object) -> bytes:
    error = {"code": -32603, "message": STOPPED}
    return (json.dumps({"jsonrpc": "2.0", "id": request_id, "error": error}) + "\n").encode()


def _messages(data: bytes) -> list[dict]:
    try:
        parsed = json.loads(data)
    except ValueError:
        return []
    items = parsed if isinstance(parsed, list) else [parsed]
    return [item for item in items if isinstance(item, dict)]


def launch_top(cwd: Path) -> Path | None:
    try:
        done = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], cwd=cwd, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return Path(done.stdout.strip()).resolve() if done.returncode == 0 and done.stdout.strip() else None


def spawn_daemon(place: Place, top: Path, env: Mapping[str, str]) -> None:
    """Start the daemon detached: its own session, no stdin, its output in `place.log` (cut when it grows)."""
    child_env = {name: value for name, value in env.items() if name != "DOC_SEARCH_CLIENT_CWD"}
    mode = "wb" if place.log.exists() and place.log.stat().st_size > LOG_MAX_BYTES else "ab"
    with open(place.log, mode) as log:
        subprocess.Popen(
            [*CHILD, "daemon", "--key", place.key, "--dir", str(place.dir)],
            cwd=top, env=child_env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True,
        )


def serve_shared(env: Mapping[str, str] = os.environ, cwd: Path | None = None) -> int | None:
    """Serve this session through the shared server; None when the in-process server should serve it instead."""
    if not shared_wanted(env):
        return None
    here = Path(cwd or os.getcwd())
    top = launch_top(here)
    if top is None:
        return None  # not a repository: the in-process server answers its one line
    try:
        config = (top / CONFIG_REL).read_bytes()
    except OSError:
        return None  # inert (or unreadable): nothing worth sharing
    place = place_for(top, config, env)
    if isinstance(place, str):
        print(f"doc-search: serving in-process: {place}", file=sys.stderr)
        return None
    client_cwd = env.get("DOC_SEARCH_CLIENT_CWD") or None

    def reopen(wait_s: float = RECONNECT_WAIT_S) -> Backend:
        sock = connect(place, lambda: spawn_daemon(place, top, env), wait_s=wait_s)
        try:
            return SocketBackend(sock, hello(sock, place.key, client_cwd))
        except BaseException:
            sock.close()
            raise

    first = None
    for attempt in range(HELLO_RETRIES):
        try:
            first = reopen(60.0)  # a first start imports and listens: allow a loaded host its minute
            break
        except HelloLost as err:  # the server was exiting as we connected: the next try starts another
            if attempt == HELLO_RETRIES - 1:
                print(f"doc-search: serving in-process: {err}", file=sys.stderr)
                return None
            time.sleep(0.2)
        except (StartError, HelloRefused, OSError) as err:
            print(f"doc-search: serving in-process: {err}", file=sys.stderr)
            return None
    return Proxy(sys.stdin.buffer, sys.stdout.buffer, reopen, lambda: ChildBackend.start(here, env)).run(first)
