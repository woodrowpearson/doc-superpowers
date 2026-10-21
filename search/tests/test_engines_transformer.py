"""The pool with a transformer docs model: its own build lane, the host lock, the static fallback and the swap.

Real semble builds the static indexes (the fallback and the code index) on the tiny offline model;
the transformer is the fake encoder of tests/fakes_transformer.py, whose `gate` holds a transformer
build mid-encode. The cooldown runs on a fake clock where a test needs it; every wait is bounded,
and no build thread outlives its test (the `spec` fixture opens the gates and joins them).
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from collections import Counter
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import TypeVar

import pytest
from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder
from semble.index.types import PersistencePath

from doc_search import engines as engines_module
from doc_search import transformer
from doc_search.config import Config, load_config
from doc_search.engines import (
    FOREGROUND_WAIT_S,
    INTEL_WARNING,
    TRANSFORMER_REFRESH_WAIT_S,
    Building,
    IndexPool,
    WorktreeIndexes,
)
from doc_search.transformer import BATCH, MISSING_EXTRA, TransformerSpec
from fakes_transformer import FakeEncoder, fake_encoder

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


BUILD_THREADS = ("doc-search-docs", "doc-search-code", "doc-search-static", "doc-search-transformer")


def build_threads() -> list[threading.Thread]:
    return [thread for thread in threading.enumerate() if thread.name.startswith(BUILD_THREADS)]


def join_builds(timeout: float = 60.0) -> None:
    deadline = time.monotonic() + timeout
    for thread in build_threads():
        thread.join(max(0.0, deadline - time.monotonic()))
    alive = [thread.name for thread in build_threads() if thread.is_alive()]
    assert not alive, f"build threads still running: {alive}"


@pytest.fixture
def spec(fake_transformer: TransformerSpec) -> Iterator[TransformerSpec]:
    """The fake transformer's spec; at the end, every held encode is let go and every build thread joined."""
    yield fake_transformer
    for encoder in list(transformer._encoders.values()):
        if isinstance(encoder, FakeEncoder):
            encoder.gate.set()
    join_builds()


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


def test_static_kept_until_validated(git_repo, tiny_model: str, spec: TransformerSpec) -> None:
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
        return got if "docs" in got.error else None

    after = wait_until(failed, "the transformer build to fail")
    assert after.error["docs"].startswith("transformer index failed validation: "), after.error
    assert after.docs is static and after.docs_fallback, "the static index still serves"
    assert after.transformer is None and pool.progress(top) is None
    assert pool.fallback_cache_state(top) == "valid", "the static index is still on disk"
    assert pool.cache_state(top, "docs") == "absent"

    # a failed build is retried on the cooldown, and the fallback serves until one validates
    encoder.nan = False
    clock.advance(3600)
    built = wait_until(swapped(pool, top), "the retried build to swap in")
    assert built.docs is not None and built.docs.model is encoder and built.error == {}
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
        return got if "docs" in got.error else None

    died = wait_until(killed_build, "the first build to die")
    assert "killed mid-build" in died.error["docs"] and died.docs_fallback
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
    join_builds()
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
    monkeypatch.setattr(engines_module, "_intel_mac", lambda: True)
    pool = IndexPool(cfg)
    for top in (repo.root, other):
        wait_until(swapped(pool, top), "the transformer index")
    warned = [r.getMessage() for r in caplog.records if r.name == engines_module.__name__ and r.levelno >= logging.WARNING]
    assert warned == [INTEL_WARNING], "once per pool, at its first transformer build"
    assert INTEL_WARNING == (
        "doc-search: the transformer docs model runs ~3.6 chunks/s on Intel (M-series: ~16); this first build may take hours"
    )

    caplog.clear()
    monkeypatch.setattr(engines_module, "_intel_mac", lambda: False)
    touch(repo.root / "docs" / "guide-04.md")
    fresh = IndexPool(cfg)
    wait_until(swapped(fresh, repo.root), "the rebuilt transformer index")
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
