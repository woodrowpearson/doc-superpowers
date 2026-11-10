# doc-search shared server — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One doc-search server per repository per host, behind a per-session stdio proxy, with idle
unload of worktrees. The design is `docs/superpowers/specs/2026-11-10-doc-search-shared-server-design.md`.

**Architecture:** `serve` enters `doc_search.entry`, a light module. It runs the proxy (`shared.py`,
standard library only), which finds or starts a daemon (`daemon.py`) on a Unix socket named by a key,
then pipes stdio to it. The daemon holds one `Runtime` and gives each connection a view with its own
default worktree. `IndexPool` gains idle unload and gives freed heap back to the OS (`memrelief.py`).
Any failure on the shared path runs today's in-process server.

**Tech stack:** Python ≥ 3.11, anyio, the MCP SDK v2 (`mcp>=2.3,<3`), semble 0.7, pytest. Run every
command from `search/`.

## Global constraints

- `shared.py` and `entry.py` import only the standard library and `doc_search/__init__.py` (the proxy must stay ~15 MB).
- No new dependency; `uv.lock` does not change.
- Socket directory mode 0700, owned by the user; socket mode 0600.
- Environment, not config: `DOC_SEARCH_SHARED` (`0`, `1`, unset), `DOC_SEARCH_MAX_WORKTREES` (default 3 shared, 2 in-process), `DOC_SEARCH_IDLE_UNLOAD_S` (default 900, `0` off), `DOC_SEARCH_DAEMON_IDLE_S` (default 600), `DOC_SEARCH_RUNTIME_DIR` (the socket directory; tests and overrides).
- The key's environment: names starting `DOC_SEARCH_`, `SEMBLE_`, `HF_`, `GOOGLE_`, `CLOUDSDK_`, except `DOC_SEARCH_CLIENT_CWD`.
- `CLAUDE_CODE_REMOTE` set: in-process unless `DOC_SEARCH_SHARED=1`.
- Error text for a call cut by a daemon loss: `doc-search: the shared server stopped; retry the call` (JSON-RPC code -32603).
- Tests never reach the network and never leave a daemon running.
- Written prose follows the writing rule (`bash scripts/doc-tools.sh writing check <file>` from the repository top).
- Never name the other measured project in any committed text.

---

### Task 1: Memory relief and idle unload in the pool

**Files:**
- Create: `search/src/doc_search/memrelief.py`
- Modify: `search/src/doc_search/engines.py` (`_Entry.__init__`, `IndexPool.__init__`, `get`, `_touch`; new `unload_idle`, `start_reaper`, `stop_reaper`)
- Test: `search/tests/test_unload.py`

**Interfaces:**
- Produces: `memrelief.release() -> bool`; `IndexPool.unload_idle(idle_s: float) -> list[Path]`;
  `IndexPool.start_reaper(idle_s: float, interval_s: float = 60.0) -> None`; `IndexPool.stop_reaper() -> None`;
  `_Entry.last_used: float` (pool clock).

- [ ] **Step 1: Write the failing tests** — `search/tests/test_unload.py`:

```python
"""Idle unload: the pool drops worktrees nobody asked for in a while, and hands freed heap back."""

from __future__ import annotations

import time

from doc_search import engines as engines_module
from doc_search import memrelief
from doc_search.config import load_config
from doc_search.engines import IndexPool, WorktreeIndexes

from test_engines import FakeClock, seed


def enabled(git_repo, tiny_model):
    import json

    repo = git_repo()
    seed(repo)
    repo.write("docs/search/config.json", json.dumps({"docs": {"model": tiny_model}, "code": {"model": tiny_model}}))
    repo.commit("config")
    return repo, load_config(repo.root)


def test_release_never_raises() -> None:
    assert memrelief.release() in (True, False)


def test_release_without_a_libc_function_is_false(monkeypatch) -> None:
    monkeypatch.setattr(memrelief, "_relief", lambda: None)
    assert memrelief.release() is False


def test_idle_worktree_is_unloaded(git_repo, tiny_model, monkeypatch) -> None:
    repo, cfg = enabled(git_repo, tiny_model)
    released = []
    monkeypatch.setattr(engines_module.memrelief, "release", lambda: released.append(1) or True)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    assert isinstance(pool.get(repo.root, wait_s=60), WorktreeIndexes)

    clock.advance(899)
    assert pool.unload_idle(900) == []
    clock.advance(1)
    assert pool.unload_idle(900) == [repo.root]
    assert pool.resident() == []
    assert released == [1]


def test_a_use_resets_the_idle_time(git_repo, tiny_model) -> None:
    repo, cfg = enabled(git_repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    pool.get(repo.root, wait_s=60)
    clock.advance(800)
    pool.get(repo.root, wait_s=60)
    clock.advance(800)
    assert pool.unload_idle(900) == []


def test_a_building_worktree_is_kept(git_repo, tiny_model, monkeypatch) -> None:
    repo, cfg = enabled(git_repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    pool.get(repo.root, wait_s=60)
    monkeypatch.setattr(engines_module._Entry, "building", lambda self: True)
    clock.advance(10_000)
    assert pool.unload_idle(900) == []


def test_eviction_releases_memory(git_repo, tiny_model, monkeypatch) -> None:
    repo, cfg = enabled(git_repo, tiny_model)
    other = repo.add_worktree("b", "b")
    released = []
    monkeypatch.setattr(engines_module.memrelief, "release", lambda: released.append(1) or True)
    pool = IndexPool(cfg, max_worktrees=1)
    pool.get(repo.root, wait_s=60)
    pool.get(other, wait_s=60)
    assert pool.resident() == [other]
    assert released == [1]


def test_reaper_thread_unloads(git_repo, tiny_model) -> None:
    repo, cfg = enabled(git_repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    pool.get(repo.root, wait_s=60)
    clock.advance(1000)
    pool.start_reaper(900, interval_s=0.01)
    try:
        deadline = time.monotonic() + 5
        while pool.resident() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert pool.resident() == []
    finally:
        pool.stop_reaper()
```

- [ ] **Step 2: Run them; expect failures** — `uv run --frozen --all-extras pytest tests/test_unload.py -q`: `ModuleNotFoundError: doc_search.memrelief`.

- [ ] **Step 3: Write `memrelief.py`:**

```python
"""Hand freed heap back to the OS after the pool drops a worktree's indexes.

A worktree's indexes are about 1.4 GB of numpy arrays and small Python objects on a large repository.
Once they are freed, the allocator keeps the pages, so the process footprint does not fall. macOS has
`malloc_zone_pressure_relief`, glibc `malloc_trim`; elsewhere this only collects garbage. Never raises.
"""

from __future__ import annotations

import ctypes
import functools
import gc
import sys
from collections.abc import Callable


@functools.cache
def _relief() -> Callable[[], object] | None:
    try:
        if sys.platform == "darwin":
            fn = ctypes.CDLL(None).malloc_zone_pressure_relief
            fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
            fn.restype = ctypes.c_size_t
            return lambda: fn(None, 0)
        if sys.platform.startswith("linux"):
            fn = ctypes.CDLL("libc.so.6").malloc_trim
            fn.argtypes = [ctypes.c_size_t]
            fn.restype = ctypes.c_int
            return lambda: fn(0)
    except (OSError, AttributeError):  # no such library or symbol (musl, say)
        return None
    return None


def release() -> bool:
    """Collect garbage and return freed heap pages to the OS; True when an allocator call ran."""
    gc.collect()
    fn = _relief()
    if fn is None:
        return False
    try:
        fn()
    except Exception:  # noqa: BLE001 - relief is best effort
        return False
    return True
```

- [ ] **Step 4: Change `engines.py`.**
  - Import: `from . import buildlock, encode_cache, memrelief, transformer`.
  - `_Entry.__init__(self, worktree, states, now: float)` sets `self.last_used = now`. Its one caller is `_touch`.
  - `IndexPool.__init__` adds `self._reaper: threading.Thread | None = None` and `self._reaper_stop = threading.Event()`.
  - `_touch` creates entries with `_Entry(top, self._states(), self.clock())`, sets `entry.last_used = self.clock()`
    on every call, and returns `(entry, dropped: bool)`, where `dropped` is True when it evicted anything.
  - `get` unpacks it: `entry, dropped = self._touch(top)`. After the last `with self._lock:` block, and
    before it returns, it runs `memrelief.release()` when `dropped` (outside the lock: a collection may take
    a second).
  - New methods after `resident()`:

```python
    def unload_idle(self, idle_s: float) -> list[Path]:
        """Drop the worktrees no `get` has used for `idle_s` (pool clock) that are not building; return them.

        The next `get` of a dropped worktree loads it from semble's cache again. Freed heap goes back to the OS.
        """
        with self._lock:
            now = self.clock()
            gone = [
                path
                for path, entry in self._entries.items()
                if now - entry.last_used >= idle_s and not entry.building()
            ]
            for path in gone:
                self._evict(self._entries.pop(path))
        if gone:
            logger.info("doc-search: unloaded %d idle worktree(s): %s", len(gone), ", ".join(map(str, gone)))
            memrelief.release()
        return gone

    def start_reaper(self, idle_s: float, interval_s: float = 60.0) -> None:
        """Run `unload_idle(idle_s)` every `interval_s` real seconds on a daemon thread, until `stop_reaper`."""
        if self._reaper is not None or idle_s <= 0:
            return
        self._reaper_stop.clear()

        def loop() -> None:
            while not self._reaper_stop.wait(interval_s):
                try:
                    self.unload_idle(idle_s)
                except Exception:  # noqa: BLE001 - the reaper must outlive one bad pass
                    logger.exception("doc-search: idle unload failed")

        self._reaper = threading.Thread(target=loop, name="doc-search-reaper", daemon=True)
        self._reaper.start()

    def stop_reaper(self) -> None:
        self._reaper_stop.set()
        if self._reaper is not None:
            self._reaper.join(5)
        self._reaper = None
```

  - Header docstring: add a paragraph after the first: "*Idle unload.* `unload_idle` (and the reaper
    thread a server starts) drops a worktree no `get` has used for a while, unless it is building; an
    eviction or an unload then runs `memrelief.release()`, so the freed heap leaves the footprint." Replace
    "every session runs its own server over one semble cache" with "several servers can share one semble
    cache: in-process servers, or a shared server per repository and configuration (daemon.py)".

- [ ] **Step 5: Run** `uv run --frozen --all-extras pytest tests/test_unload.py tests/test_engines.py tests/test_engines_transformer.py tests/test_buildlock.py -q`. Expected: all pass.

- [ ] **Step 6: Commit** `git add search/src/doc_search/memrelief.py search/src/doc_search/engines.py search/tests/test_unload.py && git commit -m "feat(search): unload idle worktrees and hand freed heap back"`.

### Task 2: Runtime views, limits and the status line

**Files:**
- Modify: `search/src/doc_search/server.py` (`Runtime.__init__`, new `Runtime.view`, `limits`, `build_server_for`)
- Modify: `search/src/doc_search/tools.py` (`DocTools.status`, `_status`: a `server:` line)
- Test: `search/tests/test_server.py` (append)

**Interfaces:**
- Consumes: `IndexPool.start_reaper` (Task 1).
- Produces: `limits(shared: bool, env: Mapping[str, str] = os.environ) -> tuple[int, float]`;
  `Runtime(cwd, pool, wait_s, *, warm=True, fallback=True, client_cwd=None, shared=False)`;
  `Runtime.view(client_cwd: str | None) -> Runtime`; `Runtime.mode: Callable[[], str]` (default
  `lambda: "in-process"`); `build_server_for(rt: Runtime) -> MCPServer`.

- [ ] **Step 1: Write the failing tests** (append to `search/tests/test_server.py`):

```python
from doc_search.server import Runtime, build_server_for, limits


def test_limits_defaults_and_overrides() -> None:
    assert limits(True, {}) == (3, 900.0)
    assert limits(False, {}) == (2, 900.0)
    assert limits(False, {"DOC_SEARCH_MAX_WORKTREES": "1", "DOC_SEARCH_IDLE_UNLOAD_S": "0"}) == (1, 0.0)
    assert limits(True, {"DOC_SEARCH_MAX_WORKTREES": "zero", "DOC_SEARCH_IDLE_UNLOAD_S": "-5"}) == (3, 900.0)


def test_views_share_the_pool_and_keep_their_own_default(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    branch = repo.add_worktree("b", "b")
    rt = Runtime(repo.root, None, 20.0, warm=False, shared=True)
    one, two = rt.view(None), rt.view(str(branch))
    assert one.default == repo.root and two.default == branch
    assert one.pool is rt.pool is two.pool and one.searcher is two.searcher
    assert rt.pool.max_worktrees == 3


def test_status_names_the_server_mode(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    rt = Runtime(repo.root, None, 60.0)
    assert "server: in-process" in call(build_server_for(rt), "status")
    rt.mode = lambda: "shared (pid 7, 2 sessions)"
    assert "server: shared (pid 7, 2 sessions)" in call(build_server_for(rt.view(None)), "status")
```

- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_server.py -q -k "limits or views or mode"`; expect an `ImportError`.

- [ ] **Step 3: Implement in `server.py`.**
  - Imports: `import copy`; `from collections.abc import Callable, Mapping`.
  - Above `Runtime`:

```python
SHARED_MAX_WORKTREES = 3  # a shared server serves every session of a repository
ALONE_MAX_WORKTREES = 2  # a server per session: today's limit
IDLE_UNLOAD_S = 900.0


def limits(shared: bool, env: Mapping[str, str] = os.environ) -> tuple[int, float]:
    """The pool's worktree cap and its idle-unload seconds, from the environment (memory is the host's).

    A value that is not a whole number of worktrees ≥ 1, or seconds ≥ 0, keeps the default, with a warning.
    """
    cap = SHARED_MAX_WORKTREES if shared else ALONE_MAX_WORKTREES
    idle = IDLE_UNLOAD_S
    raw = env.get("DOC_SEARCH_MAX_WORKTREES", "").strip()
    if raw:
        if raw.isdigit() and int(raw) >= 1:
            cap = int(raw)
        else:
            logger.warning("doc-search: DOC_SEARCH_MAX_WORKTREES=%r is not a count ≥ 1; using %d", raw, cap)
    raw = env.get("DOC_SEARCH_IDLE_UNLOAD_S", "").strip()
    if raw:
        try:
            value = float(raw)
        except ValueError:
            value = -1.0
        if value >= 0:
            idle = value
        else:
            logger.warning("doc-search: DOC_SEARCH_IDLE_UNLOAD_S=%r is not seconds ≥ 0; using %g", raw, idle)
    return cap, idle
```

  - `Runtime.__init__` takes `shared: bool = False`, sets `self.mode: Callable[[], str] = lambda: "in-process"`,
    and builds the pool as
    `cap, idle = limits(shared)`, `self.pool = pool if pool is not None else IndexPool(self.cfg, max_worktrees=cap, fallback=fallback)`.
    After the searcher and tools are built: `if warm and pool is None: self.pool.start_reaper(idle)`.
    A test's own pool gets no reaper. The daemon passes `warm=False` and starts the reaper itself (Task 4).
  - The view, after `corpus_for`:

```python
    def view(self, client_cwd: str | None) -> Runtime:
        """This runtime for one more client: the same config, pool, searcher, tools and corpora, its own default.

        A shared server gives every session a view, so each keeps the default worktree its own server would
        have chosen (`client_cwd`, as `DOC_SEARCH_CLIENT_CWD`). Starts the new default's builds, as `warm` does.
        """
        other = copy.copy(self)  # shallow: everything but the default is shared, the corpora's lock included
        if self.repo is not None and self.pool is not None and self.fixed is None:
            other.default, other.default_note = _default_worktree(self.repo, client_cwd)
            self.pool.get(other.default, wait_s=0)
        return other
```

  - `Runtime.status` passes `mode=self.mode()` to `self.tools.status`.
  - Split `build_server`: its body after `rt = Runtime(...)` moves into
    `def build_server_for(rt: Runtime) -> MCPServer:`, and `build_server` becomes
    `return build_server_for(Runtime(cwd, pool, wait_s, client_cwd=client_cwd))`.

- [ ] **Step 4: Implement in `tools.py`.** `status(self, worktree, *, warm=True, default_note=None, mode=None)`
  passes `mode` to `_status`, which adds `*([f"server: {flat(mode)}"] if mode else [])` right after the
  `semble …` line. The CLI's `status` passes no mode, so its output does not change.

- [ ] **Step 5: Run** `uv run --frozen --all-extras pytest tests/test_server.py tests/test_tools.py tests/test_cli.py -q`. Expected: all pass.

- [ ] **Step 6: Commit** `git commit -am "feat(search): runtime views for shared sessions, env limits, the server line in status"`.

### Task 3: The proxy, the key and the start protocol

**Files:**
- Create: `search/src/doc_search/shared.py`
- Test: `search/tests/test_shared.py`

**Interfaces:**
- Produces (all in `doc_search.shared`):
  - `PROTOCOL = 1`, `CONFIG_REL = "docs/search/config.json"`, `STOPPED = "doc-search: the shared server stopped; retry the call"`.
  - `shared_wanted(env: Mapping[str, str]) -> bool`.
  - `daemon_key(top: Path, config: bytes, env: Mapping[str, str]) -> str` (16 hex characters).
  - `runtime_dir(env: Mapping[str, str]) -> Path`; `unsafe_dir(path: Path) -> str | None`.
  - `@dataclass(frozen=True) class Place: key: str; dir: Path` with properties `sock`, `alive`, `start`, `log`.
  - `place_for(top: Path, config: bytes, env) -> Place | str` (a string says why the shared path is off).
  - `class StartError(Exception)`; `class HelloRefused(Exception)`.
  - `connect(place: Place, spawn: Callable[[], None], wait_s: float = 60.0) -> socket.socket`.
  - `hello(sock: socket.socket, key: str, client_cwd: str | None, wait_s: float = 60.0) -> BinaryIO` (the reader to keep).
  - `hold_alive(place: Place) -> IO[str] | None` (the daemon's life lock, or None when another daemon holds it).
  - `class Backend(Protocol)`: `send(data: bytes)`, `readline() -> bytes`, `close_write()`, `close()`; `SocketBackend(sock, reader)`, `ChildBackend.start(cwd: Path, env: Mapping[str, str])`.
  - `class Proxy(stdin: BinaryIO, stdout: BinaryIO, reopen: Callable[[], Backend], fallback: Callable[[], Backend], backoff: tuple[float, ...] = (1.0, 2.0, 4.0))` with `run(first: Backend) -> int`.
  - `serve_shared(env=os.environ, cwd: Path | None = None) -> int | None` (None: not taken, serve in-process).
  - `spawn_daemon(place: Place, top: Path, env: Mapping[str, str]) -> None`.

- [ ] **Step 1: Write the failing tests** — `search/tests/test_shared.py`:

```python
"""The shared server's client side: the key, the socket directory, the start protocol and the proxy."""

from __future__ import annotations

import io
import json
import os
import socket
import threading
import time
from pathlib import Path

import pytest

from doc_search import shared
from doc_search.config import CONFIG_REL
from doc_search.shared import Place, Proxy, StartError


def short_dir() -> Path:
    import tempfile

    return Path(tempfile.mkdtemp(prefix="dst-", dir="/tmp"))


def test_config_rel_matches_the_config_module() -> None:
    assert shared.CONFIG_REL == CONFIG_REL


@pytest.mark.parametrize(
    ("env", "wanted"),
    [({}, True), ({"DOC_SEARCH_SHARED": "0"}, False), ({"CLAUDE_CODE_REMOTE": "true"}, False),
     ({"CLAUDE_CODE_REMOTE": "true", "DOC_SEARCH_SHARED": "1"}, True)],
)
def test_shared_wanted(env, wanted) -> None:
    assert shared.shared_wanted(env) is wanted


def test_key_inputs() -> None:
    base = shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "1", "PATH": "/bin"})
    assert len(base) == 16
    assert shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "1", "PATH": "/usr/bin"}) == base
    assert shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "1", "DOC_SEARCH_CLIENT_CWD": "/w"}) == base
    for other in (
        shared.daemon_key(Path("/s"), b"{}", {"DOC_SEARCH_X": "1"}),
        shared.daemon_key(Path("/r"), b"{ }", {"DOC_SEARCH_X": "1"}),
        shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "2"}),
        shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "1", "SEMBLE_CACHE_LOCATION": "/c"}),
        shared.daemon_key(Path("/r"), b"{}", {"DOC_SEARCH_X": "1", "GOOGLE_CLOUD_PROJECT": "p"}),
    ):
        assert other != base


def test_runtime_dir_choices(monkeypatch) -> None:
    assert shared.runtime_dir({"DOC_SEARCH_RUNTIME_DIR": "/x"}) == Path("/x")
    monkeypatch.setattr(shared.sys, "platform", "darwin")
    assert shared.runtime_dir({"TMPDIR": "/var/t/"}) == Path("/var/t/doc-search")
    monkeypatch.setattr(shared.sys, "platform", "linux")
    assert shared.runtime_dir({"XDG_RUNTIME_DIR": "/run/user/5"}) == Path("/run/user/5/doc-search")
    assert shared.runtime_dir({}) == Path(f"/tmp/doc-search-{os.getuid()}")


def test_unsafe_dir(tmp_path) -> None:
    good = tmp_path / "ok"
    good.mkdir(mode=0o700)
    assert shared.unsafe_dir(good) is None
    loose = tmp_path / "loose"
    loose.mkdir()
    loose.chmod(0o755)
    assert "open to others" in shared.unsafe_dir(loose)
    link = tmp_path / "link"
    link.symlink_to(good)
    assert "not a directory" in shared.unsafe_dir(link)


def test_place_refuses_a_long_socket_path(tmp_path) -> None:
    deep = tmp_path / ("d" * 120)
    reason = shared.place_for(Path("/r"), b"{}", {"DOC_SEARCH_RUNTIME_DIR": str(deep)})
    assert isinstance(reason, str) and "too long" in reason


def listen(path: Path) -> socket.socket:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(path))
    srv.listen(8)
    return srv


def test_connect_replaces_a_stale_socket() -> None:
    place = Place("k" * 16, short_dir())
    stale = listen(place.sock)
    stale.close()  # the file stays, nobody listens: a crashed daemon's socket
    started = []

    def spawn() -> None:
        assert not place.sock.exists()  # removed before the spawn
        started.append(listen(place.sock))

    conn = shared.connect(place, spawn, wait_s=5)
    assert len(started) == 1
    conn.close()
    started[0].close()


def test_connect_waits_for_a_daemon_that_holds_the_life_lock() -> None:
    place = Place("k" * 16, short_dir())
    lock = shared.hold_alive(place)
    assert lock is not None
    spawned = []
    servers = []

    def late() -> None:  # the "starting" daemon listens after a while
        time.sleep(0.3)
        servers.append(listen(place.sock))

    threading.Thread(target=late).start()
    conn = shared.connect(place, lambda: spawned.append(1), wait_s=5)
    assert spawned == []
    conn.close()
    servers[0].close()
    lock.close()


def test_connect_gives_up() -> None:
    place = Place("k" * 16, short_dir())
    with pytest.raises(StartError):
        shared.connect(place, lambda: None, wait_s=0.3)


def test_only_one_life_lock() -> None:
    place = Place("k" * 16, short_dir())
    first = shared.hold_alive(place)
    assert first is not None and shared.hold_alive(place) is None
    first.close()
    again = shared.hold_alive(place)
    assert again is not None
    again.close()


class FakeBackend:
    """A backend whose replies a test scripts; `die()` ends it as a crashed daemon would."""

    def __init__(self, answer: bool = True) -> None:
        self.sent: list[dict] = []
        self.lines: list[bytes] = []
        self.cond = threading.Condition()
        self.dead = False
        self.answer = answer

    def send(self, data: bytes) -> None:
        msg = json.loads(data)
        with self.cond:
            self.sent.append(msg)
            if self.answer and "id" in msg and "method" in msg:
                self.lines.append(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}).encode() + b"\n")
            self.cond.notify_all()

    def readline(self) -> bytes:
        with self.cond:
            while not self.lines and not self.dead:
                self.cond.wait()
            return self.lines.pop(0) if self.lines else b""

    def die(self) -> None:
        with self.cond:
            self.dead = True
            self.cond.notify_all()

    def close_write(self) -> None:
        self.die()

    def close(self) -> None:
        self.die()


def line(**msg) -> bytes:
    return json.dumps({"jsonrpc": "2.0", **msg}).encode() + b"\n"


class SlowStdin(io.RawIOBase):
    """stdin that hands out its lines, then blocks until released, then reads EOF."""

    def __init__(self, lines: list[bytes]) -> None:
        self.lines = list(lines)
        self.release = threading.Event()

    def readline(self, size: int = -1) -> bytes:
        if self.lines:
            return self.lines.pop(0)
        self.release.wait(10)
        return b""


def wait_for(pred, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not pred() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert pred()


def test_proxy_passes_messages_through() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={}), line(method="notifications/initialized")])
    out = io.BytesIO()
    backend = FakeBackend()
    proxy = Proxy(stdin, out, reopen=lambda: pytest.fail("no reopen"), fallback=lambda: pytest.fail("no fallback"))
    t = threading.Thread(target=proxy.run, args=(backend,))
    t.start()
    wait_for(lambda: len(backend.sent) == 2)
    stdin.release.set()
    t.join(5)
    assert json.loads(out.getvalue().splitlines()[0])["id"] == 1


def test_proxy_recovers_a_lost_daemon() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={"x": 1}), line(method="notifications/initialized"),
                       line(id=2, method="tools/call", params={})])
    out = io.BytesIO()
    first = FakeBackend()
    first.answer = False  # the call never gets an answer: it is in flight when the daemon dies
    second = FakeBackend()
    proxy = Proxy(stdin, out, reopen=lambda: second, fallback=lambda: pytest.fail("no fallback"), backoff=(0.0,))
    t = threading.Thread(target=proxy.run, args=(first,))
    t.start()
    wait_for(lambda: len(first.sent) == 3)
    with first.cond:  # the handshake is answered; the call is not
        first.lines.append(line(id=1, result={}))
        first.cond.notify_all()
    wait_for(lambda: out.getvalue().count(b"\n") == 1)
    first.die()
    wait_for(lambda: len(second.sent) == 2)
    replay, initialized = second.sent
    assert replay["method"] == "initialize" and replay["params"] == {"x": 1} and replay["id"] != 1
    assert initialized["method"] == "notifications/initialized"
    stdin.release.set()
    t.join(5)
    answers = [json.loads(x) for x in out.getvalue().splitlines()]
    assert answers[0]["id"] == 1
    assert answers[1] == {"jsonrpc": "2.0", "id": 2, "error": {"code": -32603, "message": shared.STOPPED}}
    assert all(a.get("id") != replay["id"] for a in answers)  # the replay's answer is dropped


def test_proxy_falls_back_after_the_retries() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={})])
    out = io.BytesIO()
    first, child = FakeBackend(), FakeBackend()

    def reopen():
        raise StartError("no daemon")

    proxy = Proxy(stdin, out, reopen=reopen, fallback=lambda: child, backoff=(0.0, 0.0))
    t = threading.Thread(target=proxy.run, args=(first,))
    t.start()
    wait_for(lambda: len(first.sent) == 1)
    first.die()
    wait_for(lambda: len(child.sent) == 1)
    assert child.sent[0]["method"] == "initialize"
    stdin.release.set()
    t.join(5)
```

- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_shared.py -q`; expect `ImportError`.

- [ ] **Step 3: Write `shared.py`:**

```python
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
import fcntl
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

PROTOCOL = 1
CONFIG_REL = "docs/search/config.json"  # config.CONFIG_REL; a test keeps them equal
STOPPED = "doc-search: the shared server stopped; retry the call"
KEY_ENV_PREFIXES = ("DOC_SEARCH_", "SEMBLE_", "HF_", "GOOGLE_", "CLOUDSDK_")
KEY_ENV_SKIP = frozenset({"DOC_SEARCH_CLIENT_CWD"})
SUN_PATH_MAX = 103 if sys.platform == "darwin" else 107  # sockaddr_un's sun_path, less its NUL
MAX_LINE = 64 * 1024 * 1024
LOG_MAX_BYTES = 5 * 1024 * 1024


def shared_wanted(env: Mapping[str, str]) -> bool:
    """Whether `serve` tries the shared server: `DOC_SEARCH_SHARED` decides, else not in a cloud session."""
    if not hasattr(socket, "AF_UNIX"):
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
        str(Path(__file__).resolve().parent),
        sys.executable,
        sorted(
            (name, value)
            for name, value in env.items()
            if name.startswith(KEY_ENV_PREFIXES) and name not in KEY_ENV_SKIP
        ),
    ]
    return hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:16]


def runtime_dir(env: Mapping[str, str]) -> Path:
    if env.get("DOC_SEARCH_RUNTIME_DIR"):
        return Path(env["DOC_SEARCH_RUNTIME_DIR"])
    if sys.platform == "darwin" and env.get("TMPDIR"):
        return Path(env["TMPDIR"]) / "doc-search"  # per user on macOS
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
        reply = json.loads(reader.readline(MAX_LINE) or b"null")
    except (ValueError, OSError) as err:
        raise HelloRefused(f"no hello from the shared server: {err}") from err
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
        except OSError:
            return b""

    def close_write(self) -> None:
        try:
            self._sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def close(self) -> None:
        self._sock.close()


class ChildBackend:
    """The in-process server as a child process, for a session whose shared server cannot be had back."""

    def __init__(self, proc: subprocess.Popen) -> None:
        self._proc = proc

    @classmethod
    def start(cls, cwd: Path, env: Mapping[str, str]) -> ChildBackend:
        proc = subprocess.Popen(
            [sys.executable, "-m", "doc_search.entry", "serve", "--in-process"],
            cwd=cwd, env=dict(env), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        return cls(proc)

    def send(self, data: bytes) -> None:
        self._proc.stdin.write(data)
        self._proc.stdin.flush()

    def readline(self) -> bytes:
        return self._proc.stdout.readline(MAX_LINE)

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
            self._note_up(data)
            self._send(data)
        with self._cond:
            self._stdin_done = True
            backend = self._backend
        if backend is not None:
            backend.close_write()

    def _note_up(self, data: bytes) -> None:
        for msg in _messages(data):
            method = msg.get("method")
            if method == "initialize" and "id" in msg:
                self._init = msg
            elif method == "notifications/initialized":
                self._initialized = data
            if method is not None and "id" in msg:
                with self._cond:
                    self._pending[_id_key(msg["id"])] = msg["id"]

    def _send(self, data: bytes) -> None:
        with self._cond:
            while self._backend is None and not self._dead:
                self._cond.wait()
            backend = self._backend
        if backend is None:
            return  # nothing left to serve this session; the pending call is answered below
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
            if data:
                if self._note_down(data):
                    self._write(data)
                continue
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
        with self._cond:
            self._backend = None
            stranded = list(self._pending.values())
            self._pending.clear()
        lost.close()
        for request_id in stranded:
            error = {"code": -32603, "message": STOPPED}
            self._write((json.dumps({"jsonrpc": "2.0", "id": request_id, "error": error}) + "\n").encode())
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
            if self._init is not None:
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
        return True


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
            [sys.executable, "-m", "doc_search.entry", "daemon", "--key", place.key, "--dir", str(place.dir)],
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

    def reopen() -> Backend:
        sock = connect(place, lambda: spawn_daemon(place, top, env))
        try:
            return SocketBackend(sock, hello(sock, place.key, client_cwd))
        except BaseException:
            sock.close()
            raise

    try:
        first = reopen()
    except (StartError, HelloRefused, OSError) as err:
        print(f"doc-search: serving in-process: {err}", file=sys.stderr)
        return None
    return Proxy(sys.stdin.buffer, sys.stdout.buffer, reopen, lambda: ChildBackend.start(here, env)).run(first)
```

- [ ] **Step 4: Run** `uv run --frozen --all-extras pytest tests/test_shared.py -q`. Expected: all pass.

- [ ] **Step 5: Commit** `git add search/src/doc_search/shared.py search/tests/test_shared.py && git commit -m "feat(search): the shared server's proxy, key and start protocol"`.

### Task 4: The daemon, the entry point and process tests

**Files:**
- Create: `search/src/doc_search/daemon.py`, `search/src/doc_search/entry.py`
- Modify: `search/pyproject.toml` (`doc-search = "doc_search.entry:main"`); `search/src/doc_search/cli.py` (`serve --in-process`, `_serve` through `entry.run_serve`)
- Modify: `search/tests/conftest.py` (autouse: `DOC_SEARCH_SHARED=0`, a short `DOC_SEARCH_RUNTIME_DIR`, daemons stopped at teardown)
- Test: `search/tests/test_daemon.py`; `search/tests/test_server.py::test_stdio_smoke` parametrized over both modes

**Interfaces:**
- Consumes: `Runtime(…, warm=False, shared=True)`, `Runtime.view`, `Runtime.mode`, `build_server_for`, `limits` (Task 2); `Place`, `hold_alive`, `PROTOCOL`, `serve_shared` (Task 3); `IndexPool.start_reaper` (Task 1).
- Produces: `entry.main(argv: list[str] | None = None) -> int`; `entry.run_serve(in_process: bool) -> int`;
  `daemon.main(argv: list[str]) -> int`; `daemon.DAEMON_IDLE_S = 600.0`.

- [ ] **Step 1: conftest.** Add an autouse fixture:

```python
@pytest.fixture(autouse=True)
def shared_runtime(monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """No test shares a server unless it asks (DOC_SEARCH_SHARED=1); every daemon a test starts is stopped.

    The socket directory is short and under /tmp: pytest's own tmp paths exceed AF_UNIX's 104 bytes on macOS.
    """
    import signal
    import tempfile

    where = Path(tempfile.mkdtemp(prefix="dsr-", dir="/tmp"))
    monkeypatch.setenv("DOC_SEARCH_RUNTIME_DIR", str(where))
    monkeypatch.setenv("DOC_SEARCH_SHARED", "0")
    monkeypatch.setenv("DOC_SEARCH_DAEMON_IDLE_S", "3")
    yield where
    for alive in where.glob("*.alive"):
        try:
            os.kill(int(alive.read_text().split()[0]), signal.SIGTERM)
        except (ValueError, IndexError, ProcessLookupError, PermissionError):
            pass
    shutil.rmtree(where, ignore_errors=True)
```

  (`import shutil` at the top if absent.)

- [ ] **Step 2: Write the failing process tests** — `search/tests/test_daemon.py`:

```python
"""The shared server as processes: one daemon for many sessions, its loss, its idle exit, and when it is off."""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from pathlib import Path

import anyio
import pytest
from mcp.client.client import Client
from mcp.client.stdio import StdioServerParameters

from test_server import seed

pytestmark = pytest.mark.slow


def params(cwd: Path, **env: str) -> StdioServerParameters:
    return StdioServerParameters(
        command=sys.executable, args=["-m", "doc_search.entry", "serve"], cwd=cwd, env={**os.environ, **env}
    )


async def ask(p: StdioServerParameters, *calls: tuple[str, dict]) -> list[str]:
    with anyio.fail_after(120):
        async with Client(p) as client:
            out = []
            for name, args in calls:
                result = await client.call_tool(name, args)
                out.append(result.content[0].text)
            return out


def daemons(where: Path) -> list[int]:
    pids = []
    for alive in where.glob("*.alive"):
        try:
            pid = int(alive.read_text().split()[0])
            os.kill(pid, 0)
        except (ValueError, IndexError, ProcessLookupError):
            continue
        pids.append(pid)
    return pids


def test_two_sessions_share_one_daemon_with_their_own_defaults(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    branch = repo.add_worktree("b", "b")

    async def both():
        async with anyio.create_task_group() as tg:
            got = {}

            async def one(name, p):
                got[name] = await ask(p, ("status", {}), ("search", {"query": "refund rounding"}))

            tg.start_soon(one, "main", params(repo.root, DOC_SEARCH_SHARED="1"))
            tg.start_soon(one, "b", params(repo.root, DOC_SEARCH_SHARED="1", DOC_SEARCH_CLIENT_CWD=str(branch)))
        return got

    got = anyio.run(both)
    assert len(daemons(shared_runtime)) == 1
    assert f"default worktree: {branch}" in got["b"][0]
    assert "default worktree:" not in got["main"][0]
    assert "server: shared (pid" in got["main"][0]
    assert "docs/specs/SPEC-PAY-004.md" in got["main"][1] and "docs/specs/SPEC-PAY-004.md" in got["b"][1]


def test_a_killed_daemon_is_replaced_within_the_session(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    p = params(repo.root, DOC_SEARCH_SHARED="1")

    async def go():
        with anyio.fail_after(120):
            async with Client(p) as client:
                await client.call_tool("search", {"query": "refund rounding"})
                (first,) = daemons(shared_runtime)
                os.kill(first, signal.SIGKILL)
                await anyio.sleep(0.5)
                result = await client.call_tool("search", {"query": "refund rounding"})
                return first, result

    first, result = anyio.run(go)
    assert not result.is_error and "docs/specs/SPEC-PAY-004.md" in result.content[0].text
    assert daemons(shared_runtime) and first not in daemons(shared_runtime)


def test_an_idle_daemon_exits(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    anyio.run(ask, params(repo.root, DOC_SEARCH_SHARED="1"), ("search", {"query": "refund"}))
    assert daemons(shared_runtime)
    deadline = time.monotonic() + 30
    while daemons(shared_runtime) and time.monotonic() < deadline:
        time.sleep(0.2)
    assert daemons(shared_runtime) == [] and list(shared_runtime.glob("*.sock")) == []


@pytest.mark.parametrize("env", [{"DOC_SEARCH_SHARED": "0"}, {"DOC_SEARCH_SHARED": "", "CLAUDE_CODE_REMOTE": "true"}])
def test_in_process_when_off(git_repo, tiny_model, shared_runtime, env) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    (status,) = anyio.run(ask, params(repo.root, **env), ("status", {}))
    assert "server: in-process" in status
    assert daemons(shared_runtime) == []


def test_a_config_edit_gets_its_own_daemon(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    p = params(repo.root, DOC_SEARCH_SHARED="1")
    anyio.run(ask, p, ("status", {}))
    config = repo.root / "docs/search/config.json"
    data = json.loads(config.read_text())
    data["search"] = {"default_limit": 5}
    config.write_text(json.dumps(data))
    anyio.run(ask, p, ("status", {}))
    assert len(daemons(shared_runtime)) == 2
```

  Parametrize the existing `test_stdio_smoke` with `@pytest.mark.parametrize("shared", ["0", "1"])` and add
  `"DOC_SEARCH_SHARED": shared` to its `env`.

- [ ] **Step 3: Run** `uv run --frozen --all-extras pytest tests/test_daemon.py -q`; expect failures (`No module named doc_search.entry`).

- [ ] **Step 4: Write `entry.py`:**

```python
"""The `doc-search` console script: `serve` and the hidden `daemon` verb without the CLI's imports.

`serve` runs the shared server's proxy (shared.py) unless `--in-process` is given or the shared path is off,
then today's in-process server. `daemon` (started by a proxy, never by hand) takes the life lock before it
imports the server. Every other verb goes to cli.main.
"""

from __future__ import annotations

import sys
from pathlib import Path


def run_serve(in_process: bool) -> int:
    if not in_process:
        from .shared import serve_shared

        code = serve_shared()
        if code is not None:
            return code
    from .server import serve

    serve(Path.cwd())
    return 0


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args[:1] == ["serve"] and set(args[1:]) <= {"--in-process"}:
        return run_serve("--in-process" in args[1:])
    if args[:1] == ["daemon"]:
        from .daemon import main as daemon_main

        return daemon_main(args[1:])
    from .cli import main as cli_main

    return cli_main(args)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Write `daemon.py`:**

```python
"""The shared server: one `Runtime` for every session of a repository, configuration and environment on a host.

A proxy (shared.py) starts it detached in the launch worktree with `--key` and `--dir`. It takes the life
lock first (another daemon holds it: exit), removes a stale socket, listens, then builds the `Runtime`;
connections queue meanwhile. Each connection sends a hello line, gets one back, and is then served one MCP
session over newline-delimited JSON, through a view with its own default worktree. With no session for
DOC_SEARCH_DAEMON_IDLE_S it removes its socket and exits. Its output is the log file the proxy opened.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import time
from pathlib import Path

import anyio
import anyio.to_thread
from anyio.streams.buffered import BufferedByteReceiveStream
from mcp import types
from mcp.shared.message import SessionMessage
from mcp.shared.memory import create_context_streams  # the helper stdio_server uses; see Step 5 note

from .server import Runtime, build_server_for, limits
from .shared import MAX_LINE, PROTOCOL, Place, hold_alive

logger = logging.getLogger(__name__)

DAEMON_IDLE_S = 600.0
HELLO_WAIT_S = 30.0
WAIT_S = 20.0  # a call's wait for a first build, as the in-process server's


def idle_seconds() -> float:
    raw = os.environ.get("DOC_SEARCH_DAEMON_IDLE_S", "").strip()
    try:
        value = float(raw) if raw else DAEMON_IDLE_S
    except ValueError:
        value = DAEMON_IDLE_S
    return value if value > 0 else DAEMON_IDLE_S


class Daemon:
    def __init__(self, place: Place, top: Path) -> None:
        self.place, self.top = place, top
        self.sessions = 0
        self.last_left = time.monotonic()
        self.ready = anyio.Event()
        self.rt: Runtime | None = None
        self.idle_s = idle_seconds()

    async def serve(self) -> None:
        listener = await anyio.create_unix_listener(self.place.sock)
        os.chmod(self.place.sock, 0o600)
        async with anyio.create_task_group() as tg:
            tg.start_soon(self._build)
            tg.start_soon(self._watch_idle, tg.cancel_scope)
            tg.start_soon(listener.serve, self._connection)

    async def _build(self) -> None:
        rt = await anyio.to_thread.run_sync(lambda: Runtime(self.top, None, WAIT_S, warm=False, shared=True))
        rt.mode = lambda: f"shared (pid {os.getpid()}, {self.sessions} session{'s' if self.sessions != 1 else ''})"
        if rt.pool is not None:
            rt.pool.start_reaper(limits(True)[1])
        self.rt = rt
        self.ready.set()
        logger.info("doc-search: shared server ready for %s (pid %d)", self.top, os.getpid())

    async def _watch_idle(self, scope: anyio.CancelScope) -> None:
        while True:
            await anyio.sleep(min(5.0, self.idle_s))
            if self.sessions == 0 and time.monotonic() - self.last_left >= self.idle_s:
                logger.info("doc-search: no session for %g s; exiting", self.idle_s)
                self.place.sock.unlink(missing_ok=True)
                scope.cancel()
                return

    async def _connection(self, stream) -> None:
        self.sessions += 1
        try:
            buffered = BufferedByteReceiveStream(stream)
            with anyio.fail_after(HELLO_WAIT_S):
                first = await buffered.receive_until(b"\n", MAX_LINE)
            try:
                hello = json.loads(first)
            except ValueError:
                hello = None
            ok = isinstance(hello, dict) and hello.get("doc_search_proxy") == PROTOCOL and hello.get("key") == self.place.key
            reply = {"doc_search_daemon": PROTOCOL, "key": self.place.key, "version": __import__("doc_search").__version__}
            if not ok:
                reply["error"] = "not this server"
            await stream.send((json.dumps(reply) + "\n").encode())
            if not ok:
                return
            await self.ready.wait()
            client_cwd = hello.get("client_cwd") if isinstance(hello.get("client_cwd"), str) else None
            view = await anyio.to_thread.run_sync(self.rt.view, client_cwd)
            await serve_stream(build_server_for(view), buffered, stream)
        except (anyio.EndOfStream, anyio.IncompleteRead, anyio.BrokenResourceError, TimeoutError):
            pass
        finally:
            self.sessions -= 1
            self.last_left = time.monotonic()
            await stream.aclose()


async def serve_stream(server, receive: BufferedByteReceiveStream, stream) -> None:
    """One MCP session over a connection's newline-delimited JSON (the framing of mcp.server.stdio)."""
    read_writer, read_stream = create_context_streams[SessionMessage | Exception](0)
    write_stream, write_reader = create_context_streams[SessionMessage](0)

    async def reader() -> None:
        async with read_writer:
            while True:
                try:
                    line = await receive.receive_until(b"\n", MAX_LINE)
                except (anyio.EndOfStream, anyio.IncompleteRead, anyio.BrokenResourceError):
                    return
                try:
                    message = types.jsonrpc_message_adapter.validate_json(line, by_name=False)
                except Exception as exc:  # noqa: BLE001 - the session answers a parse error itself
                    await read_writer.send(exc)
                    continue
                await read_writer.send(SessionMessage(message))

    async def writer() -> None:
        async with write_reader:
            async for message in write_reader:
                data = message.message.model_dump_json(by_alias=True, exclude_unset=True)
                await stream.send((data + "\n").encode())

    lowlevel = server._lowlevel_server  # noqa: SLF001 - what MCPServer.run_stdio_async runs; mcp is pinned < 3
    async with anyio.create_task_group() as tg:
        tg.start_soon(reader)
        tg.start_soon(writer)
        await lowlevel.run(read_stream, write_stream, lowlevel.create_initialization_options())
        tg.cancel_scope.cancel()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="doc-search daemon")
    parser.add_argument("--key", required=True)
    parser.add_argument("--dir", required=True, type=Path)
    args = parser.parse_args(argv)
    place = Place(args.key, args.dir)
    life = hold_alive(place)
    if life is None:
        return 0  # another daemon has this key
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    place.sock.unlink(missing_ok=True)  # ours to replace: we hold the life lock
    try:
        anyio.run(Daemon(place, Path.cwd()).serve)
    finally:
        place.sock.unlink(missing_ok=True)
        life.close()
    return 0
```

  Step 5 note: take `create_context_streams` from the module `mcp/server/stdio.py` imports it from
  (`grep -n create_context_streams .venv/lib/python3.12/site-packages/mcp/server/stdio.py`), and keep
  `serve_stream` in step with that file's `stdin_reader` and `stdout_writer`.

- [ ] **Step 6: pyproject and cli.** In `pyproject.toml`: `doc-search = "doc_search.entry:main"`. In `cli.py`:
  `serve = verb("serve", "Run the MCP server over stdio (the shared server per repository unless --in-process).")`,
  `serve.add_argument("--in-process", action="store_true", help="serve in this process, never through the shared server")`,
  and `_serve` becomes `from .entry import run_serve; return run_serve(args.in_process)`.

- [ ] **Step 7: Run** `uv run --frozen --all-extras pytest tests/test_daemon.py tests/test_server.py tests/test_cli.py -q`. Expected: all pass, and `ls /tmp/dsr-*` afterwards shows nothing.

- [ ] **Step 8: Run the whole suite** `uv run --frozen --all-extras pytest -q`; then `pgrep -f "doc_search.entry daemon"` prints nothing.

- [ ] **Step 9: Commit** `git add -A search && git commit -m "feat(search): one shared doc-search server per repository behind a stdio proxy"`.

### Task 5: Measure N clients, then the documentation

**Files:**
- Create: `search/scripts/measure_shared.py`
- Modify: `references/search.md` (*Modes*, *Hardware and performance*, *Privacy*, *Troubleshooting*), `CLAUDE.md` (the `search/` rows, the pytest count), `docs/codebase-guide.md` (the `search/` map, if it lists modules), `scripts/help/search.txt` (only if a line names the server's process model)

- [ ] **Step 1: Write `measure_shared.py`:**

```python
"""Sum the memory of N doc-search sessions, shared or in-process (by hand, not CI).

usage: uv run --project search --frozen --all-extras python search/scripts/measure_shared.py <repo> <mode 0|1> <N> [<worktree>...]

Each client is an MCP stdio session started as a client starts it, through `doc-search serve`, with
DOC_SEARCH_CLIENT_CWD set to the worktrees in turn. After each has run one search, the footprints
(macOS `footprint`, Linux PSS) of every process under this one are summed: proxies, servers, the daemon.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import anyio
from mcp.client.client import Client
from mcp.client.stdio import StdioServerParameters


def descendants(root: int) -> list[int]:
    rows = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n")
    kids: dict[int, list[int]] = {}
    for row in rows:
        if row.strip():
            pid, ppid = map(int, row.split())
            kids.setdefault(ppid, []).append(pid)
    out, todo = [], [root]
    while todo:
        for kid in kids.get(todo.pop(), []):
            out.append(kid)
            todo.append(kid)
    return out


def footprint_mb(pid: int) -> float:
    if sys.platform == "darwin":
        text = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
        m = re.search(r"phys_footprint:\s+([\d.]+) (KB|MB|GB)", text)
        if not m:
            return 0.0
        return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]
    try:
        text = Path(f"/proc/{pid}/smaps_rollup").read_text()
    except OSError:
        return 0.0
    m = re.search(r"^Pss:\s+(\d+) kB", text, re.M)
    return int(m.group(1)) / 1024 if m else 0.0


async def main() -> None:
    repo, mode, n, trees = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4:] or [sys.argv[1]]
    runtime = tempfile.mkdtemp(prefix="dsm-", dir="/tmp")
    env = {**os.environ, "DOC_SEARCH_SHARED": mode, "DOC_SEARCH_RUNTIME_DIR": runtime}
    async with anyio.create_task_group() as tg:
        ready = anyio.Event()
        done = [0]

        async def client(i: int) -> None:
            p = StdioServerParameters(
                command="uv", args=["run", "--project", str(Path(__file__).parents[1]), "--frozen", "--all-extras",
                                    "doc-search", "serve"],
                cwd=repo, env={**env, "DOC_SEARCH_CLIENT_CWD": trees[i % len(trees)]},
            )
            async with Client(p) as c:
                await c.call_tool("search", {"query": "configuration and setup"})
                done[0] += 1
                if done[0] == n:
                    ready.set()
                await ready.wait()
                await anyio.sleep(15)  # held while the parent measures

        for i in range(n):
            tg.start_soon(client, i)
        await ready.wait()
        await anyio.sleep(5)
        pids = descendants(os.getpid())
        total = sum(footprint_mb(pid) for pid in pids)
        print(f"mode={'shared' if mode == '1' else 'in-process'} N={n} processes={len(pids)} total={total:.0f} MB")


anyio.run(main)
```

- [ ] **Step 2: Measure.** First check `memory_pressure` and swap; skip any run whose expected total
  would not fit in free memory, and say so in the commit body.
  - Medium repository: a throwaway clone of this repository under the scratchpad with a `docs/search/config.json`
    (`uv run --project search --frozen doc-search init`); N = 1, 3, 6, both modes.
  - Large repository: one checkout of the measured consumer project. In-process N = 1 is known (1,563 MB);
    run shared N = 3 over three worktrees, and in-process N = 3 only if free memory allows.
  - Idle unload: shared N = 1, `DOC_SEARCH_IDLE_UNLOAD_S=30`, footprint before and 90 s after the search.
  Record the numbers in the notes folder and in the next commit's body.

- [ ] **Step 3: Documentation.**
  - `references/search.md` → *Modes*: a paragraph "**One server per repository.**" (the proxy, the key, the
    files, idle exit, crash recovery, `DOC_SEARCH_SHARED`, cloud sessions, `serve --in-process`).
  - *Hardware and performance*: replace "At most two worktrees' index pairs are in memory per server" with
    the new caps and idle unload, add the measured numbers, and say "Every client session runs its own
    server" no longer holds.
  - *Privacy*: the socket serves repository content to the user's own processes only (directory 0700, socket 0600).
  - *Troubleshooting*: the log (`<runtime dir>/<key>.log`), `DOC_SEARCH_SHARED=0`, and that a stale socket
    is replaced by the next session.
  - `CLAUDE.md`: in the directory tree's `search/src/doc_search/` line add `entry.py (the console script),
    shared.py (the proxy), daemon.py (the shared server), memrelief.py`; in the Key Files `search/` row,
    one sentence on the shared server; update the pytest count from `uv run --frozen --all-extras pytest -q`'s total.
  - Lint each changed prose file with `bash scripts/doc-tools.sh writing check <file>` (no new findings in
    lines this change wrote).

- [ ] **Step 4: Run what CI runs** from the repository top: `bash scripts/check-ci.sh search`, then
  `bash scripts/check-ci.sh --fast`. Expected: green. `self-install` drift does not apply (no CI template
  or `doc-tools.sh` change).

- [ ] **Step 5: Commit** `git add -A && git commit` with the measured numbers in the body.
