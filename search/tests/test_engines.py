"""The semble engines: one docs index and one code index per worktree, built in the background.

Real semble runs on the tiny offline Model2Vec model. Time is injected, so the revalidation
cooldown is driven by a fake clock; the bounded wait is real time.
"""

from __future__ import annotations

import importlib.metadata
import json
import os
import threading
import time

import pytest
from semble import ContentType, SembleIndex

from doc_search.config import Config, load_config
from doc_search.engines import Building, IndexPool, WorktreeIndexes

REFUNDS_MD = """# Refund rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

SHIPPING_MD = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''


class FakeClock:
    """A monotonic clock that only moves when a test says so."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def seed(repo) -> None:
    repo.write("docs/refunds.md", REFUNDS_MD)
    repo.write("docs/shipping.md", SHIPPING_MD)
    repo.write("src/refund.py", REFUND_PY)
    repo.commit("seed")


def make_cfg(repo, tiny_model: str, **sections) -> Config:
    """The repo's config: both models are the tiny one unless a section overrides them."""
    raw = {"docs": {"model": tiny_model}, "code": {"model": tiny_model}}
    for key, value in sections.items():
        raw[key] = {**raw.get(key, {}), **value}
    repo.write("docs/search/config.json", json.dumps(raw))
    cfg = load_config(repo.root, {})
    assert cfg is not None
    return cfg


class CountingFromPath:
    """Wraps SembleIndex.from_path: counts the calls, optionally sleeping inside each."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, delay: float = 0.0) -> None:
        self.calls: list[tuple[str, ...]] = []
        self._lock = threading.Lock()
        original = SembleIndex.from_path
        counter = self

        def wrapper(cls, path, content=(), *args, **kwargs):
            with counter._lock:
                counter.calls.append(tuple(c.value for c in ([content] if hasattr(content, "value") else content)))
            if delay:
                time.sleep(delay)
            return original(path, content, *args, **kwargs)

        monkeypatch.setattr(SembleIndex, "from_path", classmethod(wrapper))

    @property
    def count(self) -> int:
        with self._lock:
            return len(self.calls)


def top_hit_text(index: SembleIndex, query: str) -> str:
    hits = index.search(query, top_k=3)
    assert hits, f"no hits for {query!r}"
    return hits[0].chunk.content


def ready(result: WorktreeIndexes | Building) -> WorktreeIndexes:
    assert isinstance(result, WorktreeIndexes), f"still building: {result}"
    return result


def test_builds_both_and_reuses_cache(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    counter = CountingFromPath(monkeypatch)

    first = ready(IndexPool(cfg).get(repo.root))
    assert first.docs is not None and first.code is not None
    assert first.error == {}
    assert set(first.built_at) == {"docs", "code"}
    assert set(first.build_seconds) == {"docs", "code"}
    assert all(seconds >= 0 for seconds in first.build_seconds.values())
    assert sorted(counter.calls) == [("code",), ("docs",)]
    assert first.docs.search("refund rounding", top_k=1)[0].chunk.file_path == "docs/refunds.md"
    assert first.code.search("refund total", top_k=1)[0].chunk.file_path == "src/refund.py"

    # a brand-new pool (a restarted server) finds the saved indexes and builds nothing
    second = ready(IndexPool(cfg).get(repo.root))
    assert counter.count == 2, "the second pool rebuilt instead of loading from disk"
    assert second.docs is not None and second.code is not None
    assert second.docs.loaded_from_disk and second.code.loaded_from_disk
    assert second.docs.search("refund rounding", top_k=1)[0].chunk.file_path == "docs/refunds.md"
    assert second.error == {}


def test_revalidate_after_edit(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)  # rescan_seconds defaults to 5
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)

    before = ready(pool.get(repo.root))
    assert before.docs is not None
    assert "currency" not in " ".join(c.content for c in before.docs.chunks)

    edited = repo.write("docs/refunds.md", REFUNDS_MD + "\nRefunds are issued in the order currency.\n")
    stat = edited.stat()
    os.utime(edited, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))  # never the same mtime

    # inside the cooldown nothing is rechecked: the edit is not seen yet
    clock.advance(4.9)
    same = ready(pool.get(repo.root))
    assert same.docs is before.docs
    assert "currency" not in " ".join(c.content for c in same.docs.chunks)

    # past it, the call revalidates, rebuilds incrementally and the new text is searchable
    clock.advance(0.2)
    after = ready(pool.get(repo.root))
    assert after.docs is not None and after.docs is not before.docs
    assert "currency" in top_hit_text(after.docs, "order currency")
    assert after.built_at["docs"] > before.built_at["docs"]
    # the code index was unchanged: validated, kept as the very same object
    assert after.code is before.code
    assert after.built_at["code"] == before.built_at["code"]
    # and the snapshot handed out earlier is untouched by the refresh
    assert "currency" not in " ".join(c.content for c in before.docs.chunks)


def test_picks_up_an_index_saved_by_another_process(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A valid cache is not proof our in-memory index is current: another writer may have saved it."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    before = ready(pool.get(repo.root))

    edited = repo.write("docs/refunds.md", REFUNDS_MD + "\nRefunds are issued in the order currency.\n")
    stat = edited.stat()
    os.utime(edited, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))
    ready(IndexPool(cfg).get(repo.root))  # a second server rebuilds and saves the cache for the edited tree

    counter = CountingFromPath(monkeypatch)
    clock.advance(10)
    after = ready(pool.get(repo.root))
    assert counter.count == 0, "the cache already matched the tree: load it, do not rebuild"
    assert after.docs is not before.docs and after.docs is not None
    assert after.docs.loaded_from_disk
    assert "currency" in top_hit_text(after.docs, "order currency")


def test_cooldown_scales_with_build_time(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    """The recheck waits max(rescan_seconds, 3 x the last build's seconds)."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    real_from_path = SembleIndex.from_path

    def slow_docs_build(cls, path, content=(), *args, **kwargs):
        if ContentType.DOCS in content:
            clock.advance(10)  # the docs build "takes" 10 clock seconds
        return real_from_path(path, content, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(slow_docs_build))
    first = ready(pool.get(repo.root))
    monkeypatch.undo()
    assert first.build_seconds["docs"] == 10

    edited = repo.write("docs/shipping.md", SHIPPING_MD + "\nShipping fee currency.\n")
    stat = edited.stat()
    os.utime(edited, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))

    clock.advance(29)  # inside 3 x 10
    assert ready(pool.get(repo.root)).docs is first.docs
    clock.advance(2)  # past 3 x 10 since the build finished
    assert ready(pool.get(repo.root)).docs is not first.docs


def test_lru_two_worktrees(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    wt_a = repo.add_worktree("a", "branch-a")
    wt_b = repo.add_worktree("b", "branch-b")
    cfg = make_cfg(repo, tiny_model)
    pool = IndexPool(cfg, max_worktrees=2)

    for top in (repo.root, wt_a):
        assert isinstance(pool.get(top), WorktreeIndexes)
    assert pool.resident() == [repo.root, wt_a]

    # the third evicts the least recently used one (the main checkout)
    assert isinstance(pool.get(wt_b), WorktreeIndexes)
    assert pool.resident() == [wt_a, wt_b]
    assert pool.indexed_files(repo.root, "docs") == set()

    # a get is a use: touching wt_a makes wt_b the next victim
    assert isinstance(pool.get(wt_a), WorktreeIndexes)
    counter = CountingFromPath(monkeypatch)
    again = ready(pool.get(repo.root))
    assert pool.resident() == [wt_a, repo.root]
    assert again.docs is not None and again.docs.search("refund rounding", top_k=1)
    assert counter.count == 0, "an evicted worktree is reloaded from its disk cache, not rebuilt"

    # every worktree searched its own tree
    docs_a = ready(pool.get(wt_a)).docs
    assert docs_a is not None
    assert docs_a.search("refund rounding", top_k=1)[0].chunk.file_path == "docs/refunds.md"


def test_code_disabled(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    counter = CountingFromPath(monkeypatch)
    pool = IndexPool(cfg)

    result = ready(pool.get(repo.root))
    assert result.docs is not None
    assert result.code is None
    assert "code" not in result.built_at and "code" not in result.build_seconds
    assert result.error == {}
    assert counter.calls == [("docs",)]
    assert pool.indexed_files(repo.root, "code") == set()
    assert pool.indexed_files(repo.root, "docs") == {"docs/refunds.md", "docs/shipping.md"}


def test_code_disabled_counts_as_ready_while_building(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, code={"enabled": False})
    CountingFromPath(monkeypatch, delay=0.5)

    building = IndexPool(cfg).get(repo.root, wait_s=0.05)
    assert building == Building(repo.root, docs_ready=False, code_ready=True)


def test_build_error_captured(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model, docs={"model": str(repo.root / "no-such-model")})
    pool = IndexPool(cfg)

    result = ready(pool.get(repo.root))  # must not raise
    assert result.docs is None
    assert result.error["docs"]
    assert "docs" not in result.built_at
    # the other kind is unaffected
    assert result.code is not None
    assert "code" not in result.error
    assert pool.indexed_files(repo.root, "docs") == set()


def test_build_error_retried_after_cooldown(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    clock = FakeClock()
    real_from_path = SembleIndex.from_path
    state = {"fail": True, "calls": 0}

    def flaky(cls, *args, **kwargs):
        state["calls"] += 1
        if state["fail"]:
            raise RuntimeError("model hub unreachable")
        return real_from_path(*args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(flaky))
    pool = IndexPool(cfg, clock=clock)

    failed = ready(pool.get(repo.root))
    assert failed.docs is None and failed.code is None
    assert "model hub unreachable" in failed.error["docs"] and "model hub unreachable" in failed.error["code"]
    assert state["calls"] == 2

    clock.advance(1)  # inside the cooldown: no new attempt, same answer
    assert ready(pool.get(repo.root)).error.keys() == {"docs", "code"}
    assert state["calls"] == 2

    state["fail"] = False
    clock.advance(10)
    healed = ready(pool.get(repo.root))
    assert healed.docs is not None and healed.code is not None
    assert healed.error == {}
    assert state["calls"] == 4


def test_failed_refresh_keeps_the_previous_index(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    before = ready(pool.get(repo.root))

    edited = repo.write("docs/refunds.md", REFUNDS_MD + "\nMore text.\n")
    stat = edited.stat()
    os.utime(edited, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))

    def broken(cls, *args, **kwargs):
        raise OSError("disk went away")

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(broken))
    clock.advance(10)
    after = ready(pool.get(repo.root))
    assert after.docs is before.docs, "a failed refresh must keep serving the last good index"
    assert "disk went away" in after.error["docs"]
    assert "code" not in after.error


def test_get_returns_building_after_wait(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    counter = CountingFromPath(monkeypatch, delay=1.0)
    pool = IndexPool(cfg)

    started = time.monotonic()
    result = pool.get(repo.root, wait_s=0.1)
    assert time.monotonic() - started < 0.9
    assert result == Building(repo.root, docs_ready=False, code_ready=False)

    # the build carries on in the background; waiting longer picks up the same one
    done = ready(pool.get(repo.root, wait_s=30))
    assert done.docs is not None and done.code is not None
    assert counter.count == 2, "a second call must wait on the running build, not start another"


def test_wait_zero_never_blocks(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    CountingFromPath(monkeypatch, delay=0.5)

    started = time.monotonic()
    result = IndexPool(cfg).get(repo.root, wait_s=0)
    assert time.monotonic() - started < 0.4
    assert isinstance(result, Building)


def test_concurrent_gets_share_one_build(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    counter = CountingFromPath(monkeypatch, delay=0.3)
    pool = IndexPool(cfg)
    results: list[object] = []
    errors: list[BaseException] = []
    barrier = threading.Barrier(5)

    def call() -> None:
        try:
            barrier.wait()
            results.append(pool.get(repo.root, wait_s=30))
        except BaseException as err:  # noqa: BLE001 - the test reports whatever escaped
            errors.append(err)

    threads = [threading.Thread(target=call) for _ in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(60)

    assert errors == []
    assert len(results) == 5 and all(isinstance(r, WorktreeIndexes) for r in results)
    assert counter.count == 2, "five concurrent first calls must share one docs build and one code build"


def test_indexed_files_and_version(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    pool = IndexPool(cfg)

    assert pool.indexed_files(repo.root, "docs") == set(), "nothing is built before the first get"
    ready(pool.get(repo.root))
    docs = pool.indexed_files(repo.root, "docs")
    assert docs == {"docs/refunds.md", "docs/shipping.md"}
    assert pool.indexed_files(repo.root, "code") == {"src/refund.py"}

    docs.add("mutated")  # a caller's copy never leaks back into the pool
    assert "mutated" not in pool.indexed_files(repo.root, "docs")

    assert pool.semble_version() == importlib.metadata.version("semble")
