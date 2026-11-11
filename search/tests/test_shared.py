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


@pytest.fixture
def short_dir():
    """A directory short enough for AF_UNIX socket paths (pytest's tmp paths are not, on macOS)."""
    import shutil
    import tempfile

    made = []

    def make() -> Path:
        made.append(Path(tempfile.mkdtemp(prefix="dst-", dir="/tmp")))
        return made[-1]

    yield make
    for path in made:
        shutil.rmtree(path, ignore_errors=True)


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
    monkeypatch.setattr(shared, "_darwin_user_temp", lambda: "/var/u/")
    assert shared.runtime_dir({"TMPDIR": "/session/t/"}) == Path("/var/u/doc-search")  # not a session's own TMPDIR
    monkeypatch.setattr(shared, "_darwin_user_temp", lambda: None)
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


def test_connect_replaces_a_stale_socket(short_dir) -> None:
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


def test_connect_waits_for_a_daemon_that_holds_the_life_lock(short_dir) -> None:
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


def test_connect_gives_up(short_dir) -> None:
    place = Place("k" * 16, short_dir())
    with pytest.raises(StartError):
        shared.connect(place, lambda: None, wait_s=0.3)


def test_only_one_life_lock(short_dir) -> None:
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


def serve_once(path: Path, reply: bytes | None) -> socket.socket:
    """A listener that reads one hello and answers `reply` (None: closes without a word)."""
    srv = listen(path)

    def go() -> None:
        conn, _ = srv.accept()
        conn.makefile("rb").readline()
        if reply is not None:
            conn.sendall(reply)
        conn.close()

    threading.Thread(target=go, daemon=True).start()
    return srv


@pytest.mark.parametrize(
    ("reply", "error"),
    [(b'{"doc_search_daemon": 1, "key": "other"}\n', shared.HelloRefused),
     (b'{"doc_search_daemon": 2, "key": "KEY"}\n', shared.HelloRefused),
     (None, shared.HelloLost)],
)
def test_hello_refusals(short_dir, reply, error) -> None:
    place = Place("KEY", short_dir())
    srv = serve_once(place.sock, reply)
    sock = shared.connect(place, lambda: None, wait_s=5)
    with pytest.raises(error):
        shared.hello(sock, "KEY", None, wait_s=5)
    sock.close()
    srv.close()


def test_hello_accepted(short_dir) -> None:
    place = Place("KEY", short_dir())
    srv = serve_once(place.sock, b'{"doc_search_daemon": 1, "key": "KEY", "version": "x"}\n')
    sock = shared.connect(place, lambda: None, wait_s=5)
    assert shared.hello(sock, "KEY", "/w", wait_s=5) is not None
    sock.close()
    srv.close()


def test_a_pending_initialize_is_sent_again_under_its_own_id() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={})])
    out = io.BytesIO()
    first, second = FakeBackend(answer=False), FakeBackend()
    proxy = Proxy(stdin, out, reopen=lambda: second, fallback=lambda: pytest.fail("no fallback"), backoff=(0.0,))
    t = threading.Thread(target=proxy.run, args=(first,))
    t.start()
    wait_for(lambda: len(first.sent) == 1)
    first.die()  # the server died while it built: the client's initialize is still waiting
    wait_for(lambda: out.getvalue().count(b"\n") == 1)
    stdin.release.set()
    t.join(5)
    assert second.sent[0]["id"] == 1
    assert json.loads(out.getvalue()) == {"jsonrpc": "2.0", "id": 1, "result": {}}


def test_a_cut_line_is_never_forwarded() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={}), line(id=2, method="tools/call", params={})])
    out = io.BytesIO()
    first, second = FakeBackend(answer=False), FakeBackend()
    proxy = Proxy(stdin, out, reopen=lambda: second, fallback=lambda: pytest.fail("no fallback"), backoff=(0.0,))
    t = threading.Thread(target=proxy.run, args=(first,))
    t.start()
    wait_for(lambda: len(first.sent) == 2)
    with first.cond:
        first.lines.append(line(id=1, result={}))
        first.lines.append(b'{"jsonrpc": "2.0", "id": 2, "res')  # the server died mid-line
        first.dead = True
        first.cond.notify_all()
    wait_for(lambda: out.getvalue().count(b"\n") == 2)
    stdin.release.set()
    t.join(5)
    answers = [json.loads(x) for x in out.getvalue().splitlines()]
    assert answers == [{"jsonrpc": "2.0", "id": 1, "result": {}},
                       {"jsonrpc": "2.0", "id": 2, "error": {"code": -32603, "message": shared.STOPPED}}]


def test_a_cancelled_call_is_not_answered_on_loss() -> None:
    stdin = SlowStdin([line(id=1, method="initialize", params={}), line(id=2, method="tools/call", params={}),
                       line(method="notifications/cancelled", params={"requestId": 2})])
    out = io.BytesIO()
    first, second = FakeBackend(answer=False), FakeBackend()
    proxy = Proxy(stdin, out, reopen=lambda: second, fallback=lambda: pytest.fail("no fallback"), backoff=(0.0,))
    t = threading.Thread(target=proxy.run, args=(first,))
    t.start()
    wait_for(lambda: len(first.sent) == 3)
    with first.cond:
        first.lines.append(line(id=1, result={}))
        first.cond.notify_all()
    wait_for(lambda: out.getvalue().count(b"\n") == 1)
    first.die()
    wait_for(lambda: len(second.sent) == 1)
    stdin.release.set()
    t.join(5)
    assert [json.loads(x)["id"] for x in out.getvalue().splitlines()] == [1]
