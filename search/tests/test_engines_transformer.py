"""The pool with a transformer docs model: its own build lane, the host lock, the static fallback and the swap.

Real semble builds the static indexes (the fallback and the code index) on the tiny offline model;
the transformer is the fake encoder of tests/fakes_transformer.py, whose `gate` holds a transformer
build mid-encode. The cooldown runs on a fake clock where a test needs it; every wait is bounded,
and no build thread outlives its test (conftest's `spec` fixture opens the gates and joins them).
"""

from __future__ import annotations

import gc
import json
import logging
import os
import threading
import time
import weakref
from collections import Counter
from collections.abc import Callable
from pathlib import Path
from typing import TypeVar

import pytest
from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder
from semble.index.types import PersistencePath

from doc_search import engines as engines_module
from doc_search import transformer
from doc_search.config import Config, load_config
from doc_search.progress import read_progress
from doc_search.engines import (
    FOREGROUND_WAIT_S,
    INTEL_WARNING,
    TRANSFORMER_REFRESH_WAIT_S,
    Building,
    IndexPool,
    WorktreeIndexes,
)
from doc_search.transformer import BATCH, MISSING_EXTRA, TransformerSpec
from fakes_transformer import FakeEncoder, fake_encoder, release_builds

T = TypeVar("T")

WORDS = (
    "refund rounding total amount line price tax rate discount fee payment invoice order customer "
    "account balance credit charge currency"
).split()

FILES = 16  # 4 sections each: 64 docs chunks, four encoder batches

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''


def guide(i: int) -> str:
    """One doc of four sections, each a chunk of its own (semble cuts markdown near 750 characters)."""
    parts = [f"# Guide {i}\n"]
    for j in range(4):
        body = " ".join(WORDS[(i * 7 + j * 3 + k) % len(WORDS)] for k in range(90))
        parts.append(f"\n## Section {j} of guide {i}\n\nRule {i}.{j}: {body}.\n")
    return "".join(parts)


def seed(repo) -> None:
    for i in range(FILES):
        repo.write(f"docs/guide-{i:02d}.md", guide(i))
    repo.write("src/refund.py", REFUND_PY)
    repo.commit("seed")


DOC_FILES = {f"docs/guide-{i:02d}.md" for i in range(FILES)}


def make_cfg(repo, tiny_model: str, **sections) -> Config:
    """The repo's config: the transformer docs model, the tiny static model for code."""
    raw = {"docs": {"model": "transformer:test-tiny"}, "code": {"model": tiny_model}}
    for key, value in sections.items():
        raw[key] = {**raw.get(key, {}), **value}
    repo.write("docs/search/config.json", json.dumps(raw))
    cfg = load_config(repo.root, {})
    assert cfg is not None
    return cfg


class FakeClock:
    """A monotonic clock that only moves when a test says so."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def touch(path: Path, extra: str = "\nRefunds are issued in the order currency.\n") -> None:
    stat = path.stat()
    path.write_text(path.read_text(encoding="utf-8") + extra, encoding="utf-8")
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))  # never the same mtime


def wait_until(check: Callable[[], T | None], what: str, timeout: float = 30.0) -> T:
    """Poll `check` until it returns something truthy, and return that; fail after `timeout` seconds."""
    deadline = time.monotonic() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out after {timeout:g} s waiting for {what}")
        time.sleep(0.01)


def ready(result: WorktreeIndexes | Building) -> WorktreeIndexes:
    assert isinstance(result, WorktreeIndexes), f"still building: {result}"
    return result


def phase(pool: IndexPool, top: Path, wanted: str) -> Callable[[], object]:
    """A `wait_until` check: the worktree's transformer build is in phase `wanted` (returns its view)."""

    def check():
        view = pool.progress(top)
        return view if view is not None and view.phase == wanted else None

    return check


def swapped(pool: IndexPool, top: Path) -> Callable[[], WorktreeIndexes | None]:
    """A `wait_until` check: the transformer index serves the worktree's docs (returns the indexes)."""

    def check():
        got = pool.get(top, wait_s=0.2)
        if isinstance(got, WorktreeIndexes) and got.docs is not None and not got.docs_fallback:
            return got
        return None

    return check


def saved_docs_model(top: Path) -> str:
    """The model path of the docs index semble has saved for `top`."""
    metadata = PersistencePath.from_path(find_index_from_cache_folder(str(top), (ContentType.DOCS,))).metadata
    return json.loads(metadata.read_text(encoding="utf-8"))["model_path"]


def chunk_texts(index: SembleIndex) -> set[str]:
    return {chunk.content for chunk in index.chunks}


class FromPathProbe:
    """Wraps SembleIndex.from_path: records each call as (path, content values, model_path).

    `hold_if(call)`, when set and true for a call, makes it wait on `release` (set `held` first).
    """

    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self.calls: list[tuple[str, tuple[str, ...], str | None]] = []
        self.hold_if: Callable[[tuple[str, tuple[str, ...], str | None]], bool] | None = None
        self.held = threading.Event()
        self.release = threading.Event()
        self.release.set()
        self.returned = threading.Event()  # set when a held call has returned
        lock = threading.Lock()
        original = SembleIndex.from_path
        probe = self

        def wrapper(cls, path, content=(), *args, **kwargs):
            call = (str(path), tuple(c.value for c in content), kwargs.get("model_path"))
            with lock:
                probe.calls.append(call)
            hold = probe.hold_if is not None and probe.hold_if(call)
            if hold:
                probe.held.set()
                if not probe.release.wait(60):
                    raise TimeoutError("FromPathProbe: never released")
            try:
                return original(path, content, *args, **kwargs)
            finally:
                if hold:
                    probe.returned.set()

        monkeypatch.setattr(SembleIndex, "from_path", classmethod(wrapper))

    def static_docs(self) -> list[tuple[str, tuple[str, ...], str | None]]:
        """The calls that built a static docs index (the fallback's)."""
        return [call for call in self.calls if call[1] == ("docs",) and call[2] is None]


# -- the fallback and the swap ------------------------------------------------------------------------


def test_static_serves_while_transformer_builds(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    probe = FromPathProbe(monkeypatch)
    encoder = fake_encoder(spec)
    encoder.gate.clear()  # the transformer build holds mid-encode
    pool = IndexPool(cfg)
    top = repo.root

    started = time.monotonic()
    got = ready(pool.get(top, wait_s=30))
    took = time.monotonic() - started
    assert took < 15, f"the call waited {took:.1f} s: the fallback answers once it is built"
    assert got.docs_fallback is True
    assert got.docs is not None and not isinstance(got.docs.model, FakeEncoder)
    assert got.docs_model == tiny_model  # semble's default model (SEMBLE_MODEL_NAME): the static index
    assert got.code is not None
    assert got.error == {}
    assert pool.indexed_files(top, "docs") == DOC_FILES

    view = wait_until(phase(pool, top, "encoding"), "the transformer build to encode")
    assert view.total == len(got.docs.chunks)
    again = ready(pool.get(top, wait_s=0))
    assert again.docs is got.docs and again.docs_fallback
    assert again.transformer is not None and again.transformer.phase == "encoding"
    assert len(probe.static_docs()) == 1, "one fallback build, however many gets"
    assert pool.fallback_cache_state(top) == "valid"
    assert pool.cache_state(top, "docs") == "absent", "the saved docs index is the static model's"


def test_swap_once_built(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    pool = IndexPool(cfg)
    top = repo.root
    static = ready(pool.get(top, wait_s=10)).docs
    assert static is not None
    wait_until(phase(pool, top, "encoding"), "the transformer build to encode")

    encoder.gate.set()
    built = wait_until(swapped(pool, top), "the swap")
    assert built.docs is not static and built.docs.model is encoder
    assert built.docs_model == spec.model_path
    assert chunk_texts(built.docs) == chunk_texts(static)
    assert built.transformer is None and pool.progress(top) is None
    assert built.error == {}
    assert pool.indexed_files(top, "docs") == DOC_FILES
    assert pool.cache_state(top, "docs") == "valid"
    assert pool.fallback_cache_state(top) == "absent", "the static index was replaced, once the transformer one built"
    assert saved_docs_model(top) == spec.model_path

    # a restarted server loads it from disk: no build, no fallback, no indexing encode
    probe = FromPathProbe(monkeypatch)
    calls = len(encoder.calls)
    fresh = IndexPool(cfg)
    loaded = ready(fresh.get(top, wait_s=30))
    assert probe.calls == []
    assert loaded.docs is not None and loaded.docs.loaded_from_disk and loaded.docs.model is encoder
    assert not loaded.docs_fallback and loaded.docs_model == spec.model_path
    assert [texts for texts, kwargs in encoder.calls[calls:] if "use_multiprocessing" in kwargs] == []
    assert fresh.progress(top) is None


def test_static_kept_until_validated(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    encoder = fake_encoder(spec)
    encoder.nan = True  # a broken model: every vector is NaN
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    top = repo.root
    static = ready(pool.get(top, wait_s=10)).docs

    def failed():
        got = ready(pool.get(top, wait_s=0.2))
        return got if got.transformer_error else None

    after = wait_until(failed, "the transformer build to fail")
    assert after.transformer_error.startswith("transformer index failed validation: "), after.transformer_error
    assert after.error == {}, "the static index serves, and it has no error of its own"
    assert after.docs is static and after.docs_fallback, "the static index still serves"
    assert after.transformer is None and pool.progress(top) is None
    assert pool.fallback_cache_state(top) == "valid", "the static index is still on disk"
    assert pool.cache_state(top, "docs") == "absent"
    logged = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    logged = [message for message in logged if "failed validation" in message]
    assert len(logged) == 1 and logged[0].startswith("doc-search: "), "hours of encoding lost: the server log says so"

    # no masking either way: a failing static refresh is the docs error, and the transformer's stays its own
    real_from_path = SembleIndex.from_path
    broken = {"static": True}

    def static_fails(cls, path, content=(), *args, **kwargs):
        if broken["static"] and kwargs.get("model_path") is None and list(content) == [ContentType.DOCS]:
            raise OSError("disk went away")
        return real_from_path(path, content, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(static_fails))
    touch(top / "docs" / "guide-07.md")
    clock.advance(3600)

    def both_failed():
        got = ready(pool.get(top, wait_s=0.2))
        return got if "docs" in got.error and got.transformer_error and pool.progress(top) is None else None

    both = wait_until(both_failed, "the static refresh and the transformer retry to fail")
    assert "disk went away" in both.error["docs"]
    assert both.transformer_error.startswith("transformer index failed validation: ")
    assert both.docs is static and both.docs_fallback

    # a failed build is retried on the cooldown, and the fallback serves until one validates
    broken["static"] = False
    encoder.nan = False
    clock.advance(3600)
    built = wait_until(swapped(pool, top), "the retried build to swap in")
    assert built.docs is not None and built.docs.model is encoder and built.error == {}
    assert built.transformer_error is None
    assert saved_docs_model(top) == spec.model_path


def test_restart_mid_build_serves_static_and_resumes(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    killed = fake_encoder(spec)
    forward = killed._forward
    encoded: list[list[str]] = []

    def dies_after_two(texts: list[str]):
        if getattr(killed._local, "indexing", False):
            if len(encoded) == 2:
                raise RuntimeError("killed mid-build")
            encoded.append(list(texts))
        return forward(texts)

    monkeypatch.setattr(killed, "_forward", dies_after_two)
    first = IndexPool(cfg)
    static = ready(first.get(top, wait_s=30)).docs
    assert static is not None and len(static.chunks) > 3 * BATCH

    def killed_build():
        got = ready(first.get(top, wait_s=0.2))
        return got if got.transformer_error else None

    died = wait_until(killed_build, "the first build to die")
    assert "killed mid-build" in died.transformer_error and died.docs_fallback and died.error == {}
    before_kill = {text for batch in encoded for text in batch}
    assert len(before_kill) == 2 * BATCH
    assert saved_docs_model(top) == tiny_model, "the static index is what is saved"

    transformer._reset_encoders()  # a new process, on the same encode cache
    probe = FromPathProbe(monkeypatch)
    resumed = fake_encoder(spec)
    assert resumed is not killed
    resumed.gate.clear()
    second = IndexPool(cfg)
    served = ready(second.get(top, wait_s=30))
    assert served.docs_fallback and served.docs is not None and served.docs.loaded_from_disk
    assert probe.static_docs() == [], "the saved static index is loaded, not built"
    view = wait_until(phase(second, top, "encoding"), "the resumed build to encode")
    hits = wait_until(lambda: (v := second.progress(top)) is not None and v.from_cache, "the encode cache hits")
    assert hits == 2 * BATCH and view.total == len(static.chunks)

    resumed.gate.set()
    built = wait_until(swapped(second, top), "the resumed build to swap in")
    texts = chunk_texts(built.docs)
    after_restart = {text for batch in resumed.forwarded for text in batch if text in texts}
    assert after_restart.isdisjoint(before_kill), "what was encoded before the kill is read from the encode cache"
    assert after_restart | before_kill == texts
    assert probe.calls == [(str(top), ("docs",), spec.model_path)]


def test_fallback_save_never_overwrites_transformer(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    probe = FromPathProbe(monkeypatch)
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    ready(pool.get(top, wait_s=30))
    wait_until(phase(pool, top, "encoding"), "the transformer build to encode")

    caplog.set_level(logging.DEBUG, logger="doc_search.engines")
    touch(top / "docs" / "guide-00.md")  # docs edited during the first build: the fallback refreshes
    probe.hold_if = lambda call: call[1] == ("docs",) and call[2] is None
    probe.release.clear()
    try:
        clock.advance(3600)
        during = ready(pool.get(top, wait_s=0.5))
        assert during.docs_fallback
        assert probe.held.wait(30), "the fallback refresh never started"
        encoder.gate.set()  # the transformer build finishes, validates and saves while the static one is held
        built = wait_until(swapped(pool, top), "the swap")
        assert saved_docs_model(top) == spec.model_path
    finally:
        probe.release.set()
    assert probe.returned.wait(30)
    release_builds()
    assert saved_docs_model(top) == spec.model_path, "the late static save overwrote the transformer index"
    skipped = [record for record in caplog.records if "is not saved" in record.getMessage()]
    assert skipped, "the fallback refresh never reached its save"
    after = ready(pool.get(top, wait_s=0))
    assert after.docs is built.docs and not after.docs_fallback, "the dropped fallback came back"


# -- lanes and the host lock --------------------------------------------------------------------------


def test_code_build_not_behind_transformer(git_repo, tiny_model: str, spec: TransformerSpec) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    before = ready(pool.get(top, wait_s=30))
    wait_until(phase(pool, top, "encoding"), "the transformer build to encode")

    repo.write("src/rates.py", "def tax_rate(order):\n    return order.rate\n")
    clock.advance(3600)
    started = time.monotonic()
    after = ready(pool.get(top, wait_s=20))
    took = time.monotonic() - started
    assert after.code is not None and after.code is not before.code
    assert "src/rates.py" in pool.indexed_files(top, "code")
    assert took < 10, f"the code refresh waited {took:.1f} s"
    view = pool.progress(top)
    assert view is not None and view.phase == "encoding", "the transformer build is still held"
    assert after.docs_fallback


def test_host_lock_serialises_two_pools(git_repo, tiny_model: str, spec: TransformerSpec) -> None:
    repo = git_repo()
    seed(repo)
    other = repo.add_worktree("b", "branch-b")
    cfg = make_cfg(repo, tiny_model)
    encoder = fake_encoder(spec)  # one per model in the process: both pools' builds use it
    encoder.gate.clear()
    first, second = IndexPool(cfg), IndexPool(cfg)
    ready(first.get(repo.root, wait_s=30))
    wait_until(phase(first, repo.root, "encoding"), "the first pool to hold the encoder lock")

    served = ready(second.get(other, wait_s=30))
    assert served.docs_fallback and served.docs is not None, "the second pool serves its static index"
    waiting = wait_until(phase(second, other, "waiting"), "the second pool to wait for the encoder lock")
    assert waiting.holder_pid == os.getpid()
    assert ready(second.get(other, wait_s=0)).transformer.phase == "waiting"

    encoder.gate.set()
    a = wait_until(swapped(first, repo.root), "the first pool's swap")
    b = wait_until(swapped(second, other), "the second pool's swap")
    texts = chunk_texts(a.docs)
    assert chunk_texts(b.docs) == texts
    forwarded = Counter(text for batch in encoder.forwarded for text in batch)
    assert set(forwarded) == texts
    assert all(n == 1 for n in forwarded.values()), "the second build encoded what the first had already encoded"


def test_no_fallback_in_foreground(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    probe = FromPathProbe(monkeypatch)
    encoder = fake_encoder(spec)
    pool = IndexPool(cfg, fallback=False)

    got = ready(pool.get(top, wait_s=FOREGROUND_WAIT_S))
    assert got.docs is not None and got.docs.model is encoder
    assert not got.docs_fallback and got.docs_model == spec.model_path
    assert probe.static_docs() == [], "no static docs index is built in the foreground"
    assert pool.progress(top) is None
    assert saved_docs_model(top) == spec.model_path


def test_missing_extra_is_fatal(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    monkeypatch.setattr(transformer, "extra_missing", lambda: True)
    installs: list[object] = []
    monkeypatch.setattr(transformer, "install", lambda threads=None: installs.append(threads))
    probe = FromPathProbe(monkeypatch)
    checked: list[tuple[str, ...]] = []
    original = engines_module.get_validated_cache

    def counting(path, model, content):
        checked.append(tuple(c.value for c in content))
        return original(path, model, content)

    monkeypatch.setattr(engines_module, "get_validated_cache", counting)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)

    got = ready(pool.get(top, wait_s=30))
    assert got.docs is None and got.error == {"docs": MISSING_EXTRA.format(name="test-tiny")}
    assert got.transformer_error == MISSING_EXTRA.format(name="test-tiny")
    assert got.code is not None
    assert not got.docs_fallback and got.transformer is None and pool.progress(top) is None
    clock.advance(3600)
    assert ready(pool.get(top, wait_s=30)).error == {"docs": MISSING_EXTRA.format(name="test-tiny")}, "never retried"
    assert [call[1] for call in probe.calls] == [("code",)], "no docs build, no fallback"
    assert ("docs",) not in checked, "no docs thread ran"
    assert installs == []


def test_refresh_wait_bounded(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    probe = FromPathProbe(monkeypatch)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    ready(pool.get(top, wait_s=30))
    built = wait_until(swapped(pool, top), "the transformer index to serve")
    assert len(probe.static_docs()) == 1

    touch(top / "docs" / "guide-03.md")
    encoder.gate.clear()  # the refresh holds mid-encode
    clock.advance(3600)
    started = time.monotonic()
    during = ready(pool.get(top, wait_s=20))
    took = time.monotonic() - started
    assert TRANSFORMER_REFRESH_WAIT_S - 0.25 <= took < TRANSFORMER_REFRESH_WAIT_S + 1.0, f"the call waited {took:.2f} s"
    assert during.docs is built.docs and not during.docs_fallback
    wait_until(phase(pool, top, "encoding"), "the refresh to encode")

    encoder.gate.set()

    def refreshed():
        got = ready(pool.get(top, wait_s=0.2))
        return got if got.docs is not built.docs else None

    after = wait_until(refreshed, "the refreshed index")
    assert any("order currency" in text for text in chunk_texts(after.docs))
    assert after.docs.model is encoder and not after.docs_fallback
    assert len(probe.static_docs()) == 1, "the fallback was dropped at the swap: it never refreshes again"


# -- the disk, the warning, the callers ---------------------------------------------------------------


def test_cache_states_with_a_transformer(git_repo, tiny_model: str, spec: TransformerSpec) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/search/config.json", json.dumps({"docs": {"model": None}, "code": {"model": tiny_model}}))
    static = load_config(repo.root, {})  # semble's default docs model: the fallback's
    assert static is not None
    top = repo.root
    assert IndexPool(static).fallback_cache_state(top) is None, "no transformer docs model, no fallback"

    cfg = make_cfg(repo, tiny_model)
    pool = IndexPool(cfg)
    assert (pool.cache_state(top, "docs"), pool.fallback_cache_state(top)) == ("absent", "absent")

    ready(IndexPool(static).get(top, wait_s=30))  # semble's static docs index, saved
    assert (pool.cache_state(top, "docs"), pool.fallback_cache_state(top)) == ("absent", "valid")
    touch(top / "docs" / "guide-01.md")
    assert (pool.cache_state(top, "docs"), pool.fallback_cache_state(top)) == ("absent", "stale")

    wait_until(swapped(pool, top), "the transformer index")
    assert (pool.cache_state(top, "docs"), pool.fallback_cache_state(top)) == ("valid", "absent")
    touch(top / "docs" / "guide-02.md")
    assert (pool.cache_state(top, "docs"), pool.fallback_cache_state(top)) == ("stale", "absent")


def test_intel_warning_once_per_pool(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    repo = git_repo()
    seed(repo)
    other = repo.add_worktree("b", "branch-b")
    cfg = make_cfg(repo, tiny_model)
    caplog.set_level(logging.WARNING, logger="doc_search.engines")
    monkeypatch.setattr(engines_module, "intel_mac", lambda: True)
    pool = IndexPool(cfg)
    for top in (repo.root, other):
        wait_until(swapped(pool, top), "the transformer index")
    warned = [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
    assert warned == [INTEL_WARNING], "once per pool, at its first transformer build"
    assert INTEL_WARNING == (
        "doc-search: the transformer docs model runs ~3.6 chunks/s on Intel (M-series: ~16); this first build may take hours"
    )

    # a refresh of a saved transformer index is no first build: no warning, even on Intel
    caplog.clear()
    touch(repo.root / "docs" / "guide-04.md")
    fresh = IndexPool(cfg)

    def refreshed():
        got = fresh.get(repo.root, wait_s=0.2)
        ok = isinstance(got, WorktreeIndexes) and got.docs is not None and fresh.progress(repo.root) is None
        return got if ok and any("order currency" in c.content for c in got.docs.chunks) else None

    wait_until(refreshed, "the refreshed transformer index")
    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []

    caplog.clear()
    monkeypatch.setattr(engines_module, "intel_mac", lambda: False)
    third = repo.add_worktree("c", "branch-c")
    wait_until(swapped(IndexPool(cfg), third), "a first build off Intel")
    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []


def test_runtime_and_cli_pass_fallback(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    from doc_search import cli, server

    repo = git_repo()
    seed(repo)
    make_cfg(repo, tiny_model)
    made: list[bool] = []
    real = server.IndexPool

    def recording(cfg, *args, **kwargs):
        made.append(kwargs.get("fallback", True))
        return real(cfg, *args, **kwargs)

    monkeypatch.setattr(server, "IndexPool", recording)
    server.Runtime(repo.root, None, 0.0, warm=False)
    server.Runtime(repo.root, None, 0.0, warm=False, fallback=False)
    monkeypatch.chdir(repo.root)
    rt = cli._runtime()
    assert not isinstance(rt, int), rt
    assert made == [True, False, False], "the server falls back to the static index; the command line does not"


# -- what serves while a transformer index builds, the cooldown, eviction ----------------------------


def test_transformer_cooldown_capped(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    """A transformer build's cooldown scales at most TRANSFORMER_COOLDOWN_CAP_S of it, success and failure alike."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)  # rescan_seconds 5: the cooldown is 3 x the capped 60 s
    top = repo.root
    encoder = fake_encoder(spec)
    clock = FakeClock()
    real_from_path = SembleIndex.from_path

    def slow_encode(cls, path, content=(), *args, **kwargs):
        if kwargs.get("model_path") == spec.model_path:
            clock.advance(1000)  # every transformer build "takes" 1000 clock seconds
        return real_from_path(path, content, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(slow_encode))
    checks: list[str] = []
    original = engines_module.get_validated_cache

    def counting(path, model, content):
        if model == spec.model_path:
            checks.append(str(path))
        return original(path, model, content)

    monkeypatch.setattr(engines_module, "get_validated_cache", counting)
    assert engines_module.TRANSFORMER_COOLDOWN_CAP_S == 60.0
    pool = IndexPool(cfg, clock=clock)
    built = wait_until(swapped(pool, top), "the transformer index")
    assert built.build_seconds["docs"] == 1000

    def recheck_after(seconds: float) -> bool:
        before = len(checks)
        clock.advance(seconds)
        ready(pool.get(top, wait_s=0))
        return len(checks) > before

    touch(top / "docs" / "guide-08.md")
    encoder.nan = True  # the refresh will fail, after another 1000 clock seconds
    assert not recheck_after(179), "rechecked inside 3 x the capped 60 s"
    assert recheck_after(2), "a 1000 s build held its refresh back past 3 x 60 s"
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error and pool.progress(top) is None and g,
               "the refresh to fail")
    encoder.nan = False
    assert not recheck_after(179), "a slow failure is capped too: no retry inside 3 x 60 s"
    assert recheck_after(2), "a 1000 s failure held its retry back past 3 x 60 s"

    def refreshed():
        got = ready(pool.get(top, wait_s=0.2))
        done = got.transformer_error is None and pool.progress(top) is None
        return got if done and got.docs is not built.docs else None

    wait_until(refreshed, "the retry to land")


def test_a_stale_transformer_index_serves_while_it_refreshes(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    before = wait_until(swapped(IndexPool(cfg), top), "the transformer index")
    touch(top / "docs" / "guide-06.md")  # the saved transformer index is stale now

    encoder = fake_encoder(spec)
    encoder.gate.clear()  # its refresh holds mid-encode
    probe = FromPathProbe(monkeypatch)
    restarted = IndexPool(cfg)
    started = time.monotonic()
    got = ready(restarted.get(top, wait_s=20))
    took = time.monotonic() - started
    assert took < 5, f"the call waited {took:.1f} s for the refresh"
    assert got.docs is not None and got.docs.loaded_from_disk and got.docs.model is encoder
    assert not got.docs_fallback and got.docs_model == spec.model_path
    assert chunk_texts(got.docs) == chunk_texts(before.docs), "the saved index serves until its refresh lands"
    assert restarted.indexed_files(top, "docs") == DOC_FILES
    view = wait_until(phase(restarted, top, "encoding"), "the refresh to encode")
    assert view.total is None, "an incremental refresh has no total: it encodes what changed"
    started = time.monotonic()
    again = ready(restarted.get(top, wait_s=20))
    assert time.monotonic() - started < TRANSFORMER_REFRESH_WAIT_S + 1.0
    assert again.docs is got.docs and again.transformer is not None
    assert probe.static_docs() == [], "no static fallback: the stale transformer index serves"

    encoder.gate.set()

    def refreshed():
        now = ready(restarted.get(top, wait_s=0.2))
        return now if now.docs is not got.docs else None

    after = wait_until(refreshed, "the refreshed index")
    assert any("order currency" in text for text in chunk_texts(after.docs))
    assert probe.static_docs() == []
    assert [call for call in probe.calls if call[2] == spec.model_path] == [(str(top), ("docs",), spec.model_path)]


@pytest.mark.parametrize("edited", [False, True], ids=["valid", "stale"])
def test_an_unloadable_transformer_index_falls_back_to_static(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, edited: bool
) -> None:
    """A saved transformer index whose model cannot be had (offline, no model files): the static index serves."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    wait_until(swapped(IndexPool(cfg), top), "the transformer index")
    if edited:
        touch(top / "docs" / "guide-09.md")
    transformer._reset_encoders()  # a new process, whose model files are gone
    make = transformer._make_encoder
    offline = {"on": True}

    def no_model_files(model: TransformerSpec, threads: int):
        if offline["on"]:
            raise OSError("no model files (offline)")
        return make(model, threads)

    monkeypatch.setattr(transformer, "_make_encoder", no_model_files)
    probe = FromPathProbe(monkeypatch)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)

    def failed():
        got = ready(pool.get(top, wait_s=0.2))
        return got if got.transformer_error and pool.progress(top) is None else None

    got = wait_until(failed, "the transformer build to fail")
    assert got.docs_fallback and got.docs is not None and not isinstance(got.docs.model, FakeEncoder)
    assert "no model files" in got.transformer_error and got.error == {}
    assert len(probe.static_docs()) == 1
    assert saved_docs_model(top) == spec.model_path, "the static index did not replace the saved transformer one"

    offline["on"] = False
    clock.advance(3600)
    built = wait_until(swapped(pool, top), "the transformer index, once its model loads")
    assert built.docs is not None and built.docs.model is fake_encoder(spec)


def test_fallback_builds_before_code(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    """The docs state reserves its fallback's place in the build line when it starts: before the code build."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    probe = FromPathProbe(monkeypatch)
    pool = IndexPool(cfg)
    wait_until(swapped(pool, top), "the transformer index")
    assert probe.calls == [
        (str(top), ("docs",), None),
        (str(top), ("code",), tiny_model),
        (str(top), ("docs",), spec.model_path),
    ]


def test_a_reservation_not_needed_is_given_back(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch) -> None:
    """A docs state that loads its transformer index needs no fallback: the code build behind its reservation runs."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    wait_until(swapped(IndexPool(cfg), top), "the transformer index")
    repo.write("src/rates.py", "def tax_rate(order):\n    return order.rate\n")  # the code index must build
    probe = FromPathProbe(monkeypatch)
    got = ready(IndexPool(cfg).get(top, wait_s=30))
    assert got.docs is not None and got.docs.loaded_from_disk and not got.docs_fallback
    assert got.code is not None and probe.calls == [(str(top), ("code",), tiny_model)]


def test_evicting_a_queued_transformer_build_cancels_it(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    second, third = repo.add_worktree("b", "branch-b"), repo.add_worktree("c", "branch-c")
    cfg = make_cfg(repo, tiny_model)
    probe = FromPathProbe(monkeypatch)
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    pool = IndexPool(cfg, max_worktrees=1)
    ready(pool.get(repo.root, wait_s=30))
    wait_until(phase(pool, repo.root, "encoding"), "the first worktree's build to hold the lane")

    queued = ready(pool.get(second, wait_s=30))  # its static indexes serve; its transformer build queues
    assert queued.docs_fallback
    view = wait_until(lambda: (v := pool.progress(second)) is not None and v.total is not None and v, "it to queue")
    assert view.phase == "queued"
    assert pool.resident() == [repo.root, second], "the first holds its lane slot: it stays, as does the newest"
    gone = [weakref.ref(queued.docs), weakref.ref(queued.code)]
    del queued
    threads = [t for t in threading.enumerate() if t.name == f"doc-search-transformer-{second.name}"]
    assert len(threads) == 1

    ready(pool.get(third, wait_s=30))  # the queued build does not keep its worktree resident: it is cancelled
    assert pool.resident() == [repo.root, third]
    threads[0].join(5)
    assert not threads[0].is_alive(), "the cancelled build's thread is still waiting"
    assert read_progress(second) is None, "its progress was retired"
    gc.collect()
    assert [ref() for ref in gone] == [None, None], "something still holds the evicted indexes"

    encoder.gate.set()
    wait_until(swapped(pool, third), "the lane to serve the next worktree")
    built = [call[0] for call in probe.calls if call[2] == spec.model_path]
    assert built == [str(repo.root), str(third)], "the cancelled build never encoded"


def test_waiting_for_another_process_serves_the_previous_index(
    git_repo, tiny_model: str, spec: TransformerSpec
) -> None:
    repo = git_repo()
    seed(repo)
    other = repo.add_worktree("b", "branch-b")
    cfg = make_cfg(repo, tiny_model)
    encoder = fake_encoder(spec)
    clock = FakeClock()
    waiter = IndexPool(cfg, clock=clock)
    built = wait_until(swapped(waiter, other), "its transformer index")

    encoder.gate.clear()
    repo.write("docs/holder-only.md", guide(99))  # texts the encode cache has not seen: the holder encodes them
    holder = IndexPool(cfg)  # another process, encoding a first build
    ready(holder.get(repo.root, wait_s=30))
    wait_until(phase(holder, repo.root, "encoding"), "the holder to hold the encoder lock")
    touch(other / "docs" / "guide-05.md")
    clock.advance(3600)
    started = time.monotonic()
    during = ready(waiter.get(other, wait_s=20))
    took = time.monotonic() - started
    assert during.docs is built.docs
    assert took < TRANSFORMER_REFRESH_WAIT_S - 0.5, f"the call waited {took:.2f} s for a build behind another process"
    wait_until(phase(waiter, other, "waiting"), "the refresh to wait for the lock")
    started = time.monotonic()
    again = ready(waiter.get(other, wait_s=20))
    took = time.monotonic() - started
    assert again.docs is built.docs and took < 0.5, f"a call while it waits took {took:.2f} s"

    encoder.gate.set()

    def refreshed():
        got = ready(waiter.get(other, wait_s=0.2))
        return got if got.docs is not built.docs else None

    after = wait_until(refreshed, "the refresh, once the lock is free")
    assert any("order currency" in text for text in chunk_texts(after.docs))


def test_a_build_that_waited_loads_what_the_holder_saved(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two processes on one worktree: the second, once it has the encoder lock, loads the first's index."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    probe = FromPathProbe(monkeypatch)
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    first = IndexPool(cfg)
    ready(first.get(top, wait_s=30))
    wait_until(phase(first, top, "encoding"), "the first to hold the encoder lock")
    second = IndexPool(cfg)
    served = ready(second.get(top, wait_s=30))
    assert served.docs_fallback and served.docs is not None and served.docs.loaded_from_disk
    wait_until(phase(second, top, "waiting"), "the second to wait for the lock")

    encoder.gate.set()
    wait_until(swapped(first, top), "the first's index")
    loaded = wait_until(swapped(second, top), "the second's index")
    assert loaded.docs is not None and loaded.docs.loaded_from_disk and loaded.docs.model is encoder
    assert [call for call in probe.calls if call[2] == spec.model_path] == [(str(top), ("docs",), spec.model_path)]
    assert len(probe.static_docs()) == 1, "the second's fallback loaded the first's static index"


def test_refresh_wait_capped_while_the_fallback_serves(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    encoder.nan = True
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    static = ready(pool.get(top, wait_s=10)).docs
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error and pool.progress(top) is None and g,
               "the first build to fail")
    encoder.nan = False

    release = threading.Event()  # the retry stalls before it says the fallback answers
    original = engines_module._saved_docs

    def stalled(path: str):
        release.wait(30)
        return original(path)

    monkeypatch.setattr(engines_module, "_saved_docs", stalled)
    try:
        clock.advance(3600)
        started = time.monotonic()
        during = ready(pool.get(top, wait_s=20))
        took = time.monotonic() - started
    finally:
        release.set()
    assert TRANSFORMER_REFRESH_WAIT_S - 0.25 <= took < TRANSFORMER_REFRESH_WAIT_S + 1.0, f"the call waited {took:.2f} s"
    assert during.docs is static and during.docs_fallback
    wait_until(swapped(pool, top), "the retry to swap in")


def test_a_fallback_thread_that_cannot_start(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    real_start = threading.Thread.start

    def start(self: threading.Thread) -> None:
        if self.name.startswith("doc-search-static-docs"):
            raise RuntimeError("can't start new thread")
        real_start(self)

    monkeypatch.setattr(threading.Thread, "start", start)
    encoder = fake_encoder(spec)
    encoder.gate.clear()
    pool = IndexPool(cfg)
    got = ready(pool.get(top, wait_s=30))
    assert got.code is not None, "the reserved place was given back: the code build ran"
    assert got.docs is None and not got.docs_fallback and "can't start new thread" in got.error["docs"]
    assert got.transformer_error is None
    wait_until(phase(pool, top, "encoding"), "the transformer build to go on")
    encoder.gate.set()
    built = wait_until(swapped(pool, top), "the transformer index")
    assert built.docs is not None and built.docs.model is encoder and built.error == {}


# -- the encoder session, the host lock's bounded wait, the back-off, the dropped fallback ----------


def counting_checks(monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec) -> list[str]:
    """Record the worktree of every validation of a saved transformer index (a recheck, a load, a build's start)."""
    checks: list[str] = []
    original = engines_module.get_validated_cache

    def counting(path, model, content):
        if model == spec.model_path:
            checks.append(str(path))
        return original(path, model, content)

    monkeypatch.setattr(engines_module, "get_validated_cache", counting)
    return checks


def bump_mtime(path: Path) -> None:
    """Change a file's mtime only: semble re-chunks it, and every chunk text is one the encode cache holds."""
    stat = path.stat()
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))


def test_the_session_is_released_only_after_the_threads_own_encode(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A build or a refresh that ran a forward batch releases the session once, built or failed; a load, a recheck
    of an unchanged index or a refresh served entirely from the encode cache never does (the next query would
    pay a new session for nothing)."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    checks = counting_checks(monkeypatch, spec)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    built = wait_until(swapped(pool, top), "the transformer index")
    assert encoder.releases == 1, "released once the build's encode ran, before the index was announced"
    assert built.docs.search("refund rounding", top_k=3), "a query after the release still answers"

    for n in range(5):  # rechecks with nothing changed: each finds the saved index as it holds it
        before = len(checks)
        clock.advance(3600)
        assert ready(pool.get(top, wait_s=5)).docs is built.docs
        release_builds()
        assert len(checks) == before + 1, f"recheck {n} did not run"
    assert encoder.releases == 1, "a recheck that encoded nothing released the session"

    transformer._reset_encoders()  # a new process: its thread loads the valid saved index, encoding nothing
    encoder = fake_encoder(spec)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    loaded = ready(pool.get(top, wait_s=30))
    assert loaded.docs is not None and loaded.docs.loaded_from_disk
    release_builds()
    assert encoder.releases == 0, "a thread that only loaded the index released the session the queries use"

    bump_mtime(top / "docs" / "guide-07.md")  # a refresh whose chunks are all in the encode cache
    clock.advance(3600)
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).docs is not loaded.docs and pool.progress(top) is None
               and g, "the all-hits refresh")
    release_builds()
    assert encoder.forwarded == [], "the refresh read every chunk from the encode cache"
    assert encoder.releases == 0, "a refresh served entirely from the encode cache released the session"
    hits = ready(pool.get(top, wait_s=5))

    touch(top / "docs" / "guide-07.md")
    encoder.nan = True  # the refresh encodes, and fails validation
    clock.advance(3600)
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error and pool.progress(top) is None and g,
               "the refresh to fail")
    assert encoder.releases == 1, "a failed encode releases it too"
    encoder.nan = False
    clock.advance(3600)
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error is None and pool.progress(top) is None
               and g.docs is not hits.docs and g, "the retry to land")
    release_builds()
    assert len(encoder.forwarded) >= 1, "the retry encoded the edited chunks (a NaN vector is never cached)"
    assert encoder.releases == 2, "the refresh that encoded released it once"


def test_a_recheck_of_one_worktree_leaves_another_worktrees_encode_its_session(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    other = repo.add_worktree("b", "branch-b")
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    built = wait_until(swapped(pool, top), "worktree A's transformer index")
    assert encoder.releases == 1
    checks = counting_checks(monkeypatch, spec)

    (other / "docs" / "b-only.md").write_text(guide(98), encoding="utf-8")  # texts the cache lacks: B encodes
    encoder.gate.clear()  # B's first build holds mid-encode, on the session A's queries share
    assert ready(pool.get(other, wait_s=30)).docs_fallback
    wait_until(phase(pool, other, "encoding"), "B's build to encode")
    for _ in range(3):  # A is rechecked meanwhile: its saved index has not changed
        clock.advance(3600)
        assert ready(pool.get(top, wait_s=5)).docs is built.docs
    wait_until(lambda: checks.count(str(top)) >= 3, "A's rechecks")
    wait_until(lambda: not any(t.name == f"doc-search-transformer-{top.name}" for t in threading.enumerate()),
               "A's recheck threads to end")
    assert encoder.releases == 1, "a recheck of A dropped the session under B's encode"
    assert pool.progress(other).phase == "encoding"

    encoder.gate.set()
    wait_until(swapped(pool, other), "B's transformer index")
    release_builds()
    assert encoder.releases == 2, "B's own encode released it, once"


def hold_host_lock(spec: TransformerSpec) -> tuple[threading.Event, threading.Thread]:
    """Another process's encoder lock: held by a thread of this one (another open of the lock file) until the
    returned event is set."""
    from doc_search import encode_cache

    held, release = threading.Event(), threading.Event()

    def holder() -> None:
        with encode_cache.host_lock(spec):
            held.set()
            release.wait(60)

    thread = threading.Thread(target=holder, name="test-host-lock-holder", daemon=True)
    thread.start()
    assert held.wait(10)
    return release, thread


def test_a_refresh_waits_for_another_process_lock_only_so_long(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    """A refresh of a saved transformer index waits HOST_LOCK_REFRESH_WAIT_S for the lock, then encodes without it."""
    assert engines_module.HOST_LOCK_REFRESH_WAIT_S == 10.0
    monkeypatch.setattr(engines_module, "HOST_LOCK_REFRESH_WAIT_S", 0.5)
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    built = wait_until(swapped(pool, top), "the transformer index")

    caplog.set_level(logging.INFO, logger="doc_search.encode_cache")
    release, holder = hold_host_lock(spec)
    try:
        touch(top / "docs" / "guide-10.md")
        clock.advance(3600)
        ready(pool.get(top, wait_s=0))
        wait_until(phase(pool, top, "waiting"), "the refresh to wait for the lock")

        def refreshed():
            got = ready(pool.get(top, wait_s=0.2))
            return got if got.docs is not built.docs and pool.progress(top) is None else None

        after = wait_until(refreshed, "the refresh, without the lock", timeout=15)
        assert holder.is_alive(), "the other process still holds the lock: the refresh ran without it"
        assert pool.cache_state(top, "docs") == "valid", "it saved without the lock too"
    finally:
        release.set()
        holder.join(10)
    assert any("order currency" in text for text in chunk_texts(after.docs))
    assert after.transformer_error is None and not after.docs_fallback
    said = [r.getMessage() for r in caplog.records if r.name == "doc_search.encode_cache"]
    assert len(said) == 1 and said[0].endswith(f"is still held by pid {os.getpid()} after 0.5 s: encoding without it")
    assert caplog.records[-1].levelno == logging.INFO


def test_a_first_build_waits_for_another_process_lock_however_long(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(engines_module, "HOST_LOCK_REFRESH_WAIT_S", 0.2)  # a first build ignores it
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    release, holder = hold_host_lock(spec)
    try:
        pool = IndexPool(cfg)
        served = ready(pool.get(top, wait_s=30))
        assert served.docs_fallback, "the static index serves while the first build waits"
        wait_until(phase(pool, top, "waiting"), "the first build to wait for the lock")
        time.sleep(1.5)  # many times the refresh's bound
        assert pool.progress(top).phase == "waiting", "a first build gave up waiting for the lock"
        assert ready(pool.get(top, wait_s=0)).docs_fallback
        assert not any(batch for batch in encoder.forwarded), "nothing was encoded while the lock was held"
    finally:
        release.set()
        holder.join(10)
    built = wait_until(swapped(pool, top), "the first build, once the lock is free")
    assert built.docs.model is encoder


@pytest.mark.parametrize("build_s", [1000.0, 0.0], ids=["slow", "fast"])
def test_failures_in_a_row_back_off(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch, build_s: float
) -> None:
    """A failure backs off from the 60 s cap, however fast it failed, doubling per failure in a row (60, 120, 240 s:
    3 x that between checks), up to TRANSFORMER_BACKOFF_CAP_S; a success returns to the build's own seconds."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    encoder = fake_encoder(spec)
    clock = FakeClock()
    real_from_path = SembleIndex.from_path

    def timed_encode(cls, path, content=(), *args, **kwargs):
        if kwargs.get("model_path") == spec.model_path:
            clock.advance(build_s)  # every transformer build "takes" build_s clock seconds
        return real_from_path(path, content, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(timed_encode))
    checks = counting_checks(monkeypatch, spec)
    pool = IndexPool(cfg, clock=clock)
    wait_until(swapped(pool, top), "the transformer index")
    after_success = 3 * 60 if build_s else cfg.search.rescan_seconds  # 3 x the capped build, or the rescan floor

    def recheck_after(seconds: float) -> bool:
        before = len(checks)
        clock.advance(seconds)
        ready(pool.get(top, wait_s=0))
        return len(checks) > before

    def settled(what: str, failed: bool) -> None:
        def check():
            got = ready(pool.get(top, wait_s=0.2))
            return got if pool.progress(top) is None and bool(got.transformer_error) is failed else None

        wait_until(check, what)

    touch(top / "docs" / "guide-11.md")
    encoder.nan = True
    assert not recheck_after(after_success - 1) and recheck_after(2), "after a success: the build's own seconds"
    settled("failure 1", failed=True)
    assert not recheck_after(179) and recheck_after(2), "one failure: 3 x 60 s"
    settled("failure 2", failed=True)
    assert not recheck_after(359) and recheck_after(2), "two in a row: 3 x 120 s"
    settled("failure 3", failed=True)
    assert not recheck_after(719) and recheck_after(2), "three in a row: 3 x 240 s"
    settled("failure 4", failed=True)
    encoder.nan = False
    assert not recheck_after(1439) and recheck_after(2), "four in a row: 3 x 480 s"
    settled("the success", failed=False)
    touch(top / "docs" / "guide-12.md")
    assert not recheck_after(after_success - 1) and recheck_after(2), "a success returns to the build's own seconds"
    settled("the next refresh", failed=False)

    state = pool._entries[top].states["docs"]
    assert engines_module.TRANSFORMER_BACKOFF_CAP_S == 3600.0
    state.failures = 400  # long past the cap: no overflow either
    assert not pool._due(state, state.checked_at + 3 * 3600 - 1)
    assert pool._due(state, state.checked_at + 3 * 3600)


def go_offline(monkeypatch: pytest.MonkeyPatch) -> dict[str, bool]:
    """A new process whose model files are gone until the returned switch's "on" is set False."""
    transformer._reset_encoders()
    make = transformer._make_encoder
    offline = {"on": True}

    def no_model_files(model: TransformerSpec, threads: int):
        if offline["on"]:
            raise OSError("no model files (offline)")
        return make(model, threads)

    monkeypatch.setattr(transformer, "_make_encoder", no_model_files)
    return offline


def test_a_stale_transformer_index_that_serves_drops_the_fallback(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A fallback left by a run whose saved index did not load is dropped once that index serves stale."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    wait_until(swapped(IndexPool(cfg), top), "the transformer index")
    touch(top / "docs" / "guide-13.md")  # stale
    offline = go_offline(monkeypatch)
    probe = FromPathProbe(monkeypatch)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error and pool.progress(top) is None and g,
               "the transformer build to fail")
    assert pool._entries[top].fallback is not None and len(probe.static_docs()) == 1

    offline["on"] = False
    encoder = fake_encoder(spec)
    encoder.gate.clear()  # the refresh holds mid-encode while the stale index serves
    clock.advance(3600)
    stale = wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).docs is not None and not g.docs_fallback and g,
                       "the stale transformer index to serve")
    wait_until(phase(pool, top, "encoding"), "its refresh to encode")
    assert pool._entries[top].fallback is None, "the fallback was not dropped when the stale index began serving"
    clock.advance(3600)  # the fallback's own cooldown is long past: it would refresh if it were still there
    assert ready(pool.get(top, wait_s=0.5)).docs is stale.docs
    assert len(probe.static_docs()) == 1

    encoder.gate.set()
    after = wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).docs is not stale.docs and g, "the refresh")
    assert any("order currency" in text for text in chunk_texts(after.docs))
    assert len(probe.static_docs()) == 1


def test_a_fallback_never_rebuilds_while_a_transformer_index_is_saved(
    git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Its saved transformer index does not load: the fallback serves, and an edit does not rebuild it (a static
    index that would never be saved, built again on every cooldown)."""
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    top = repo.root
    wait_until(swapped(IndexPool(cfg), top), "the transformer index")
    go_offline(monkeypatch)
    probe = FromPathProbe(monkeypatch)
    clock = FakeClock()
    pool = IndexPool(cfg, clock=clock)
    first = wait_until(lambda: (g := ready(pool.get(top, wait_s=0.2))).transformer_error and pool.progress(top) is None
                       and g, "the transformer build to fail")
    assert first.docs_fallback and len(probe.static_docs()) == 1

    for doc in ("guide-14.md", "guide-15.md"):  # two rounds of an edit and the cooldowns passing
        touch(top / "docs" / doc)
        clock.advance(3600)
        again = ready(pool.get(top, wait_s=5))
        release_builds()  # the fallback's check and the transformer retry are done
        again = ready(pool.get(top, wait_s=0))
        assert again.docs is first.docs and again.docs_fallback, "the fallback keeps serving as it is"
        assert "no model files" in again.transformer_error, "the transformer build was retried"
    assert len(probe.static_docs()) == 1, "the fallback was rebuilt while the docs folder held a transformer index"
    assert saved_docs_model(top) == spec.model_path
