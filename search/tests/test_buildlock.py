"""The cross-process build lock: one build of one saved index at a time, whatever the number of servers.

Two `IndexPool`s in one process stand in for two servers: `flock` locks belong to an open file, so
two opens conflict within a process as they do across processes. A real child process holds the
lock where a test needs one to die (`kill -9`) or hang.
"""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest
from semble import ContentType
from semble.cache import find_index_from_cache_folder
from test_engines import REFUNDS_MD, BuildProbe, FakeClock, make_cfg, ready, seed, top_hit_text

from doc_search import buildlock
from doc_search.engines import Building, IndexPool

pytestmark = pytest.mark.skipif(buildlock.fcntl is None, reason="no flock on this platform")


def docs_dir(repo) -> Path:
    return find_index_from_cache_folder(str(repo.root), (ContentType.DOCS,))


class Holder:
    """A child process that holds the build lock of `index_dir` until it is killed."""

    def __init__(self, index_dir: Path) -> None:
        code = textwrap.dedent(
            """
            import sys, time
            from doc_search import buildlock
            with buildlock.index_lock(sys.argv[1], timeout=0):
                print("held", flush=True)
                time.sleep(600)
            """
        )
        self.proc = subprocess.Popen(
            [sys.executable, "-c", code, str(index_dir)], stdout=subprocess.PIPE, text=True
        )
        assert self.proc.stdout is not None
        assert self.proc.stdout.readline().strip() == "held"

    def kill(self) -> None:
        if self.proc.poll() is None:
            os.kill(self.proc.pid, signal.SIGKILL)  # a crash: no cleanup runs
        self.proc.wait(10)
        if self.proc.stdout is not None:
            self.proc.stdout.close()


@pytest.fixture
def holders():
    started: list[Holder] = []

    def start(index_dir: Path) -> Holder:
        holder = Holder(index_dir)
        started.append(holder)
        return holder

    yield start
    for holder in started:  # no child outlives the test
        holder.kill()


# -- the lock itself -------------------------------------------------------------------


def test_one_lock_for_every_spelling_of_a_symlinked_cache(tmp_path: Path, caplog) -> None:
    """A cache reached through a symlink (or named by SEMBLE_CACHE_LOCATION) keys the one lock of its physical path."""
    physical = tmp_path / "offload" / "semble"
    physical.mkdir(parents=True)
    link = tmp_path / "Caches-semble"
    link.symlink_to(physical)
    by_link = link / "abc123" / "index-docs"
    by_path = physical / "abc123" / "index-docs"

    assert buildlock.lock_path(by_link) == buildlock.lock_path(by_path) == physical.resolve() / "abc123" / "index-docs.lock"
    with buildlock.index_lock(by_link, timeout=0) as waited:
        assert waited is False
        with caplog.at_level(logging.WARNING, logger="doc_search.buildlock"):
            with buildlock.index_lock(by_path, timeout=0.2) as second:
                assert second is True, "the other spelling must find the lock held"
        assert "building without it" in caplog.text
        assert f"pid {os.getpid()}" in caplog.text, "the holder's pid is named"
    with buildlock.index_lock(by_path, timeout=0) as again:
        assert again is False, "released on exit"
    assert not by_link.exists(), "the lock creates its own file, never the index directory"


def test_a_lock_that_cannot_be_set_up_runs_the_body(tmp_path: Path, caplog) -> None:
    blocked = tmp_path / "file"
    blocked.write_text("not a directory")
    with caplog.at_level(logging.WARNING, logger="doc_search.buildlock"):
        with buildlock.index_lock(blocked / "key" / "index", timeout=0) as waited:
            assert waited is False
    assert "build lock unavailable" in caplog.text


# -- through the pool --------------------------------------------------------------------


def test_two_servers_build_each_index_once(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    """Two servers over one worktree: one builds each kind, the other waits and loads what it saved."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    probe = BuildProbe(monkeypatch, delay=1.0)  # each build lasts long enough for the other server to arrive
    first, second = IndexPool(cfg), IndexPool(cfg)

    assert isinstance(first.get(repo.root, wait_s=0), Building)
    time.sleep(0.3)  # the first server's docs build holds the lock
    assert isinstance(second.get(repo.root, wait_s=0), Building)
    a = ready(first.get(repo.root, wait_s=60))
    b = ready(second.get(repo.root, wait_s=60))

    root = str(repo.root)
    assert sorted(probe.starts) == [(root, "code"), (root, "docs")], f"one build per kind, not {probe.starts}"
    assert probe.peak == 1
    built, loaded = (a, b) if not a.docs.loaded_from_disk else (b, a)
    assert not built.docs.loaded_from_disk
    assert loaded.docs.loaded_from_disk and loaded.code.loaded_from_disk, "the waiter loads the saved index"
    assert "rounded" in top_hit_text(loaded.docs, "refund rounding")


def test_a_waiting_first_build_reads_as_building(git_repo, tiny_model: str, holders) -> None:
    """While another process builds, a call answers `Building` within its wait, as for any first build."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    holders(docs_dir(repo))
    pool = IndexPool(cfg)

    started = time.monotonic()
    answer = pool.get(repo.root, wait_s=0.5)
    assert time.monotonic() - started < 3.0
    assert answer == Building(repo.root, docs_ready=False, code_ready=True)


def test_a_holder_that_dies_mid_build_lets_the_waiter_build(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, holders
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    probe = BuildProbe(monkeypatch, delay=0.0)
    holder = holders(docs_dir(repo))
    pool = IndexPool(cfg)

    assert isinstance(pool.get(repo.root, wait_s=0.5), Building)
    assert probe.starts == [], "it waits for the holder"
    holder.kill()  # killed mid-build: nothing was saved
    got = ready(pool.get(repo.root, wait_s=60))

    assert probe.starts == [(str(repo.root), "docs")]
    assert got.docs is not None and not got.docs.loaded_from_disk
    assert "docs" not in got.error


def test_a_stuck_holder_is_waited_for_a_bounded_time(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, holders, caplog
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    probe = BuildProbe(monkeypatch, delay=0.0)
    holder = holders(docs_dir(repo))
    pool = IndexPool(cfg, build_lock_wait_s=0.5)

    with caplog.at_level(logging.WARNING, logger="doc_search.buildlock"):
        got = ready(pool.get(repo.root, wait_s=60))
    assert probe.starts == [(str(repo.root), "docs")], "past the bound it builds without the lock"
    assert got.docs is not None
    assert f"pid {holder.proc.pid}" in caplog.text


def test_a_refresh_waiting_for_the_lock_serves_the_current_index(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, holders
) -> None:
    """A refresh held up by another process's build lets its callers go with the index it has."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    before = ready(pool.get(repo.root))

    edited = repo.write("docs/refunds.md", REFUNDS_MD + "\nRefunds are issued in the order currency.\n")
    stat = edited.stat()
    os.utime(edited, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
    holder = holders(docs_dir(repo))
    probe = BuildProbe(monkeypatch, delay=0.0)
    clock.advance(cfg.search.rescan_seconds + 1)

    started = time.monotonic()
    during = ready(pool.get(repo.root, wait_s=10))
    assert time.monotonic() - started < 5.0, "a refresh in wait is not waited for"
    assert during.docs is before.docs
    assert probe.starts == []

    holder.kill()
    deadline = time.monotonic() + 60
    while not probe.starts and time.monotonic() < deadline:
        time.sleep(0.05)
    after = ready(pool.get(repo.root, wait_s=60))
    assert probe.starts == [(str(repo.root), "docs")]
    assert after.docs is not before.docs
    assert "currency" in top_hit_text(after.docs, "order currency")
