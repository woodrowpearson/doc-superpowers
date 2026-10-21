"""The encode cache (content-addressed, per host, sqlite WAL) and the host-wide encoder lock."""

from __future__ import annotations

import logging
import os
import sqlite3
import sys
import threading
from collections.abc import Callable, Iterator
from pathlib import Path

import numpy as np
import pytest

from doc_search import encode_cache
from doc_search.encode_cache import (
    CACHE_ENV,
    EncodeCache,
    cache_root,
    cache_size,
    encode_cache_path,
    host_lock,
)
from doc_search.transformer import REGISTRY

SPEC = REGISTRY["gte-modernbert-base"]
DIM = 8
PARAMS = {
    "model_id": "org/model@abc123",
    "variant": "int8",
    "max_tokens": 1024,
    "ort_version": "1.23.2",
    "arch": "x86_64",
}


def vec(seed: int, dim: int = DIM) -> np.ndarray:
    return np.random.default_rng(seed).standard_normal(dim).astype(np.float32)


@pytest.fixture
def open_cache(tmp_path: Path) -> Iterator[Callable[..., EncodeCache]]:
    """Factory for caches that are closed when the test ends (an open sqlite connection is a ResourceWarning)."""
    opened: list[EncodeCache] = []

    def make(path: Path | None = None, *, dim: int = DIM, **overrides: object) -> EncodeCache:
        params = {**PARAMS, **overrides}
        cache = EncodeCache(path or tmp_path / "enc.sqlite", dim=dim, **params)  # type: ignore[arg-type]
        opened.append(cache)
        return cache

    yield make
    for cache in opened:
        cache.close()


def test_cache_root_env_and_default(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
):
    home = tmp_path / "home"
    home.mkdir()
    with monkeypatch.context() as m:
        m.setattr(sys, "platform", "darwin")
        m.setenv("HOME", str(home))

        # set to an absolute path: that path, created on demand
        explicit = tmp_path / "somewhere" / "deep"
        m.setenv(CACHE_ENV, str(explicit))
        assert cache_root() == explicit
        assert explicit.is_dir()

        # unset: the platform default
        m.delenv(CACHE_ENV)
        assert cache_root() == home / "Library" / "Caches" / "doc-search"
        assert (home / "Library" / "Caches" / "doc-search").is_dir()

        # a relative value is ignored, with a warning, and the default stands
        m.setenv(CACHE_ENV, "relative/cache")
        with caplog.at_level(logging.WARNING, logger="doc_search.encode_cache"):
            assert cache_root() == home / "Library" / "Caches" / "doc-search"
        assert [r.getMessage() for r in caplog.records if CACHE_ENV in r.getMessage()]
        assert not Path("relative/cache").exists()


def test_cache_root_other_platforms(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    home = tmp_path / "home"
    with monkeypatch.context() as m:
        m.delenv(CACHE_ENV)
        m.setenv("HOME", str(home))

        m.setattr(sys, "platform", "linux")
        m.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
        assert cache_root() == tmp_path / "xdg" / "doc-search"
        m.delenv("XDG_CACHE_HOME")
        assert cache_root() == home / ".cache" / "doc-search"

        m.setattr(sys, "platform", "win32")
        m.setenv("LOCALAPPDATA", str(tmp_path / "local"))
        m.setenv("APPDATA", str(tmp_path / "roaming"))
        assert cache_root() == tmp_path / "local" / "doc-search" / "Cache"
        m.delenv("LOCALAPPDATA")
        assert cache_root() == tmp_path / "roaming" / "doc-search" / "Cache"
        m.delenv("APPDATA")
        assert cache_root() == home / "AppData" / "Local" / "doc-search" / "Cache"


def test_encode_cache_path_is_per_model(doc_search_cache: Path):
    assert encode_cache_path(SPEC) == doc_search_cache / "encode" / "gte-modernbert-base.sqlite"


def test_round_trip_and_wal(tmp_path: Path, open_cache):
    path = tmp_path / "enc.sqlite"
    first = open_cache(path)
    keys = [first.key("alpha"), first.key("beta")]
    rows = [(keys[0], vec(1)), (keys[1], vec(2))]
    first.put_many(rows)
    first.close()

    second = open_cache(path)
    got = second.get_many([*keys, second.key("never stored")])
    assert set(got) == set(keys)
    for key, expected in rows:
        assert got[key].dtype == np.float32
        assert np.array_equal(got[key], expected)

    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    finally:
        conn.close()


def test_put_many_commits_every_call(tmp_path: Path, open_cache):
    # a build killed between batches keeps every finished batch: the rows are visible to another
    # connection (another process) while the writer is still open
    writer = open_cache()
    reader = open_cache(tmp_path / "enc.sqlite")
    key = writer.key("one batch")
    writer.put_many([(key, vec(3))])
    assert np.array_equal(reader.get_many([key])[key], vec(3))


def test_put_many_replaces_and_empty_calls_are_noops(open_cache):
    cache = open_cache()
    key = cache.key("same text")
    cache.put_many([])
    assert cache.get_many([]) == {}
    cache.put_many([(key, vec(1))])
    cache.put_many([(key, vec(2))])
    assert np.array_equal(cache.get_many([key])[key], vec(2))


def test_get_many_beyond_one_chunk(open_cache):
    cache = open_cache()
    keys = [cache.key(f"text {i}") for i in range(1203)]
    cache.put_many([(k, vec(i)) for i, k in enumerate(keys)])
    got = cache.get_many(keys)
    assert len(got) == len(keys)
    assert np.array_equal(got[keys[1202]], vec(1202))


def test_key_material(open_cache, tmp_path: Path):
    base = open_cache(tmp_path / "a.sqlite")
    same = open_cache(tmp_path / "b.sqlite")
    assert base.key("some text") == same.key("some text")
    assert len(base.key("some text")) == 32
    assert base.key("some text") != base.key("other text")

    changes: dict[str, object] = {
        "model_id": "org/model@def456",
        "variant": "fp32",
        "max_tokens": 512,
        "ort_version": "1.24.0",
        "arch": "arm64",
    }
    for field, value in changes.items():
        other = open_cache(tmp_path / f"{field}.sqlite", **{field: value})
        assert other.key("some text") != base.key("some text"), field

    # the parts are separated: moving a character between two of them is a different key
    left = open_cache(tmp_path / "left.sqlite", model_id="ab", variant="c")
    right = open_cache(tmp_path / "right.sqlite", model_id="a", variant="bc")
    assert left.key("t") != right.key("t")

    # a lone surrogate (from a lossy decode upstream) is keyed, not raised on
    assert len(base.key("broken \ud800 text")) == 32
    assert base.key("broken \ud800 text") != base.key("broken  text")


def test_wrong_length_blob_is_a_miss(tmp_path: Path, open_cache):
    path = tmp_path / "enc.sqlite"
    cache = open_cache(path)
    good, short, long = cache.key("good"), cache.key("short"), cache.key("long")
    cache.put_many([(good, vec(1)), (short, vec(2, DIM - 1)), (long, vec(3, DIM + 1))])
    # the same bytes in a differently sized model's cache never come back as a vector
    assert set(cache.get_many([good, short, long])) == {good}
    conn = sqlite3.connect(path)
    try:
        conn.execute("INSERT OR REPLACE INTO vectors VALUES (?, ?)", (good, b"\x00" * 5))
        conn.commit()
    finally:
        conn.close()
    assert cache.get_many([good]) == {}


def test_cache_size(tmp_path: Path, open_cache):
    path = tmp_path / "enc.sqlite"
    assert cache_size(path) is None
    cache = open_cache(path)
    cache.put_many([(cache.key(f"t{i}"), vec(i)) for i in range(50)])
    size = cache_size(path)
    assert size is not None
    assert size >= path.stat().st_size > 0
    wal = path.with_name(path.name + "-wal")
    if wal.exists():  # WAL mode, the writer still open: the -wal file counts
        assert size >= path.stat().st_size + wal.stat().st_size


@pytest.mark.parametrize("broken", ["directory", "garbage"])
def test_unusable_cache_degrades(tmp_path: Path, broken: str, caplog: pytest.LogCaptureFixture):
    path = tmp_path / "enc.sqlite"
    if broken == "directory":
        path.mkdir()
    else:
        path.write_bytes(b"this is not a sqlite database\n" * 200)
    with caplog.at_level(logging.WARNING, logger="doc_search.encode_cache"):
        cache = EncodeCache(path, dim=DIM, **PARAMS)
        try:
            assert cache.usable is False
            key = cache.key("text")
            assert cache.get_many([key]) == {}
            cache.put_many([(key, vec(1))])
            assert cache.get_many([key]) == {}
        finally:
            cache.close()
        cache.close()  # idempotent
    warnings = [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert len(warnings) == 1
    assert warnings[0].getMessage().startswith("doc-search: encode cache unusable")


def test_cache_that_fails_later_degrades_once(tmp_path: Path, open_cache, caplog: pytest.LogCaptureFixture):
    path = tmp_path / "enc.sqlite"
    cache = open_cache(path)
    key = cache.key("text")
    cache.put_many([(key, vec(1))])
    assert cache.usable
    other = sqlite3.connect(path)
    try:
        other.execute("DROP TABLE vectors")
        other.commit()
    finally:
        other.close()
    with caplog.at_level(logging.WARNING, logger="doc_search.encode_cache"):
        assert cache.get_many([key]) == {}
        assert cache.usable is False
        cache.put_many([(key, vec(2))])
        assert cache.get_many([key]) == {}
    assert len([r for r in caplog.records if r.levelno >= logging.WARNING]) == 1


def test_threads_share_one_cache(open_cache):
    cache = open_cache()
    errors: list[BaseException] = []

    def work(worker: int) -> None:
        try:
            for batch in range(10):
                rows = [(cache.key(f"w{worker}-b{batch}-{i}"), vec(worker * 1000 + batch * 16 + i)) for i in range(16)]
                cache.put_many(rows)
                got = cache.get_many([k for k, _ in rows])
                assert len(got) == 16
        except BaseException as err:  # noqa: BLE001 - reported to the test thread
            errors.append(err)

    threads = [threading.Thread(target=work, args=(w,)) for w in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert not errors
    assert cache.usable
    assert len(cache.get_many([cache.key(f"w3-b9-{i}") for i in range(16)])) == 16


def test_host_lock_contention():
    held, release, waiting, got_it = (threading.Event() for _ in range(4))
    order: list[str] = []
    waited_for: list[int | None] = []

    def holder() -> None:
        with host_lock(SPEC):
            held.set()
            release.wait(10)
            order.append("A out")

    def contender() -> None:
        def on_wait(pid: int | None) -> None:
            waited_for.append(pid)
            waiting.set()

        with host_lock(SPEC, on_wait):
            order.append("B in")
            got_it.set()

    a = threading.Thread(target=holder)
    a.start()
    assert held.wait(10)
    b = threading.Thread(target=contender)
    b.start()
    try:
        assert waiting.wait(10)
        assert not got_it.wait(0.3), "B acquired while A still held the lock"
        assert waited_for == [os.getpid()]
    finally:
        release.set()
        a.join(10)
        b.join(10)
    assert got_it.is_set()
    assert order == ["A out", "B in"]


def test_host_lock_uncontended_writes_pid_and_releases(doc_search_cache: Path):
    calls: list[int | None] = []
    lock_file = doc_search_cache / "encode" / "gte-modernbert-base.lock"
    with host_lock(SPEC, calls.append):
        assert lock_file.read_text().strip() == str(os.getpid())
    assert calls == []
    # released: taken again at once, still without waiting; a stale pid in the file does not count as a holder
    lock_file.write_text("999999999\n")
    with host_lock(SPEC, calls.append):
        assert lock_file.read_text().strip() == str(os.getpid())
    assert calls == []


def test_host_lock_is_released_when_the_body_raises():
    calls: list[int | None] = []
    with pytest.raises(RuntimeError):
        with host_lock(SPEC):
            raise RuntimeError("boom")
    with host_lock(SPEC, calls.append):
        pass
    assert calls == []


def test_host_lock_without_fcntl_is_a_noop(monkeypatch: pytest.MonkeyPatch, doc_search_cache: Path):
    monkeypatch.setattr(encode_cache, "fcntl", None)
    calls: list[int | None] = []
    with host_lock(SPEC, calls.append):
        pass
    assert calls == []
    assert not (doc_search_cache / "encode").exists()
