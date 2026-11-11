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
