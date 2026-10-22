"""The local-transformer encoder: the ONNX contract, length-sorted batches, the encode cache, progress, threads.

The real `Encoder` runs on onnxruntime over the tiny model `onnx_tiny` writes (a Gather of a
seeded table: a text's vector is its first word's row, normalized), so these tests check the
real tokenizer, session and pooling path without a model download.
"""

from __future__ import annotations

import dataclasses
import platform
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from doc_search import transformer
from doc_search.encode_cache import EncodeCache
from doc_search.transformer import (
    BATCH,
    MISSING_EXTRA,
    Encoder,
    TransformerSpec,
    default_threads,
    extra_missing,
    report_to,
)
from fakes_transformer import fake_encoder
from onnx_tiny import tiny_spec, vocabulary, write_tiny_model

DIM = 8
WORDS = """
refund total tax amount invoice line price discount fee payment order customer account balance
credit debit charge currency decimal rounding cent half nearest policy limit rule default count
size time date day month year version release build index search config cache queue event token
session login server client
""".split()
ID = {word: i for i, word in enumerate(vocabulary(WORDS))}


@pytest.fixture(scope="module")
def tiny(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, np.ndarray]:
    """The tiny model's directory and its embedding table (written once for the module)."""
    path = tmp_path_factory.mktemp("tiny-onnx")
    return path, write_tiny_model(path, WORDS, DIM)


@pytest.fixture
def spec(tiny: tuple[Path, np.ndarray]) -> TransformerSpec:
    return tiny_spec(tiny[0], DIM)


@pytest.fixture
def open_cache(tmp_path: Path, spec: TransformerSpec) -> Iterator[Callable[..., EncodeCache]]:
    """Factory for encode caches on one path by default (each a connection: a "process"), closed at the end."""
    opened: list[EncodeCache] = []

    def make(path: Path | None = None) -> EncodeCache:
        cache = EncodeCache(
            path or tmp_path / "encode.sqlite",
            model_id=spec.model_id,
            variant=spec.variant,
            max_tokens=spec.max_tokens,
            ort_version="test",
            arch="test",
            dim=spec.dim,
        )
        opened.append(cache)
        return cache

    yield make
    for cache in opened:
        cache.close()


class Sink:
    """A progress sink that records every `add`."""

    def __init__(self) -> None:
        self.adds: list[tuple[int, bool]] = []

    def add(self, n: int, *, cached: bool = False) -> None:
        self.adds.append((n, cached))


def mixed_texts(n: int) -> list[str]:
    """`n` distinct texts of 1 to 9 words, in no length order (each starts on its own word)."""
    texts = [" ".join(WORDS[(i + k) % len(WORDS)] for k in range(1 + (i * 7) % 9)) for i in range(n)]
    assert len(set(texts)) == n
    return texts


def record_forward(monkeypatch: pytest.MonkeyPatch, encoder: Encoder) -> list[list[str]]:
    """Record every batch `encoder._forward` runs (and still run it)."""
    batches: list[list[str]] = []
    forward = encoder._forward

    def recording(texts: list[str]) -> np.ndarray:
        batches.append(list(texts))
        return forward(texts)

    monkeypatch.setattr(encoder, "_forward", recording)
    return batches


def stored(cache: EncodeCache, texts: list[str]) -> set[str]:
    """Which of `texts` the cache holds a vector for."""
    found = cache.get_many([cache.key(text) for text in texts])
    return {text for text in texts if cache.key(text) in found}


def unit_row(table: np.ndarray, word: str) -> np.ndarray:
    row = table[ID[word]]
    return row / np.linalg.norm(row)


def test_tiny_model_loads(tiny: tuple[Path, np.ndarray]) -> None:
    import onnxruntime
    from tokenizers import Tokenizer

    path, table = tiny
    session = onnxruntime.InferenceSession(str(path / "model.onnx"), providers=["CPUExecutionProvider"])
    assert [i.name for i in session.get_inputs()] == ["input_ids", "attention_mask"]
    assert [o.name for o in session.get_outputs()] == ["last_hidden_state"]
    ids = np.array([[ID["refund"], ID["tax"]]], dtype=np.int64)
    (hidden,) = session.run(None, {"input_ids": ids, "attention_mask": np.ones_like(ids)})
    assert hidden.shape == (1, 2, DIM)
    np.testing.assert_array_equal(hidden[0], table[ids[0]])
    tokenizer = Tokenizer.from_file(str(path / "tokenizer.json"))
    assert tokenizer.encode("Refund TAX nope").ids == [ID["refund"], ID["tax"], ID["[UNK]"]]


def test_encoder_contract(spec: TransformerSpec, tiny: tuple[Path, np.ndarray]) -> None:
    encoder = Encoder(spec, 2, None)
    assert (encoder.name, encoder.dim, encoder.threads) == (spec.model_path, DIM, 2)
    vectors = encoder.encode(["refund total", "tax"], use_multiprocessing=False)
    assert vectors.shape == (2, DIM)
    assert vectors.dtype == np.float32
    np.testing.assert_allclose(np.linalg.norm(vectors, axis=1), 1.0, atol=1e-5)
    np.testing.assert_allclose(vectors[0], unit_row(tiny[1], "refund"), rtol=1e-6)  # CLS: position 0
    np.testing.assert_allclose(vectors[1], unit_row(tiny[1], "tax"), rtol=1e-6)
    np.testing.assert_allclose(encoder.encode("tax"), vectors[1:], rtol=1e-6)  # one string, a query
    assert encoder.encode([], use_multiprocessing=False).shape == (0, DIM)


class RecordingSession:
    """An onnxruntime session that records every feed it is run with (the tiny graph never reads the mask)."""

    def __init__(self, session: Any) -> None:
        self._session = session
        self.feeds: list[dict[str, np.ndarray]] = []

    def run(self, outputs: Any, feed: dict[str, np.ndarray]) -> Any:
        self.feeds.append({name: value.copy() for name, value in feed.items()})
        return self._session.run(outputs, feed)


def test_padding_does_not_change_vectors(monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec) -> None:
    encoder = Encoder(spec, 1, None)
    session = RecordingSession(encoder._session)
    monkeypatch.setattr(encoder, "_session", session)
    long = " ".join(WORDS[1:21])  # 20 tokens
    alone = encoder.encode(["tax"], use_multiprocessing=False)
    together = encoder.encode([long, "tax"], use_multiprocessing=False)  # one batch: "tax" padded to 20 tokens
    np.testing.assert_allclose(together[1], alone[0], rtol=1e-6)
    feed = session.feeds[-1]
    assert sorted(feed) == ["attention_mask", "input_ids"]  # only what the graph declares: no token_type_ids
    np.testing.assert_array_equal(feed["attention_mask"], [[1] + [0] * 19, [1] * 20])  # shortest first
    np.testing.assert_array_equal(feed["input_ids"][0], [ID["tax"]] + [ID["[PAD]"]] * 19)
    np.testing.assert_array_equal(feed["input_ids"][1], [ID[word] for word in WORDS[1:21]])
    assert feed["input_ids"].dtype == feed["attention_mask"].dtype == np.int64


def test_length_sorted_batches(monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec) -> None:
    encoder = Encoder(spec, 1, None)
    batches = record_forward(monkeypatch, encoder)
    texts = mixed_texts(40)
    vectors = encoder.encode(texts, use_multiprocessing=False)
    assert [len(batch) for batch in batches] == [BATCH, BATCH, 40 - 2 * BATCH]
    lengths = [len(text) for batch in batches for text in batch]
    assert lengths == sorted(lengths)  # non-decreasing within and across batches
    assert sorted(text for batch in batches for text in batch) == sorted(texts)
    rows = np.vstack([Encoder(spec, 1, None).encode([text]) for text in texts])  # one by one, in input order
    np.testing.assert_allclose(vectors, rows, rtol=1e-6)


def test_a_repeated_text_is_encoded_once(monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec) -> None:
    encoder = Encoder(spec, 1, None)
    batches = record_forward(monkeypatch, encoder)
    sink = Sink()
    with report_to(sink):
        vectors = encoder.encode(["tax", "refund total", "tax"], use_multiprocessing=False)
    assert batches == [["tax", "refund total"]]
    np.testing.assert_array_equal(vectors[0], vectors[2])
    assert sink.adds == [(3, False)]  # progress counts chunks, the repeat included


def test_cache_hits_across_worktrees(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec, open_cache: Callable[..., EncodeCache]
) -> None:
    texts = mixed_texts(20)
    first = Encoder(spec, 1, open_cache())  # one process (one worktree's build)
    expected = first.encode(texts, use_multiprocessing=False)
    second = Encoder(spec, 1, open_cache())  # another, on the same cache file
    batches = record_forward(monkeypatch, second)
    np.testing.assert_allclose(second.encode(texts, use_multiprocessing=False), expected, rtol=1e-6)
    assert batches == []
    edited = [*texts[:-1], "refund policy"]
    np.testing.assert_allclose(second.encode(edited, use_multiprocessing=False)[:-1], expected[:-1], rtol=1e-6)
    assert batches == [["refund policy"]]


def test_query_never_stored(spec: TransformerSpec, open_cache: Callable[..., EncodeCache]) -> None:
    cache = open_cache()
    encoder = Encoder(spec, 1, cache)
    sink = Sink()
    with report_to(sink):
        encoder.encode(["refund total"])
        encoder.encode("refund total")
    assert stored(cache, ["refund total"]) == set()
    assert sink.adds == []
    encoder.encode(["refund total"], use_multiprocessing=False, max_length=None)  # semble's embed_chunks
    assert stored(cache, ["refund total"]) == {"refund total"}


def test_resume_after_kill(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec, open_cache: Callable[..., EncodeCache]
) -> None:
    texts = mixed_texts(40)
    killed = Encoder(spec, 1, open_cache())
    forward = killed._forward
    done: list[list[str]] = []

    def dies_after_two(batch: list[str]) -> np.ndarray:
        if len(done) == 2:
            raise RuntimeError("killed")
        done.append(list(batch))
        return forward(batch)

    monkeypatch.setattr(killed, "_forward", dies_after_two)
    with pytest.raises(RuntimeError, match="killed"):
        killed.encode(texts, use_multiprocessing=False)
    encoded = {text for batch in done for text in batch}
    assert len(encoded) == 2 * BATCH
    cache = open_cache()  # a new process
    assert stored(cache, texts) == encoded
    resumed = Encoder(spec, 1, cache)
    batches = record_forward(monkeypatch, resumed)
    resumed.encode(texts, use_multiprocessing=False)
    assert sorted(text for batch in batches for text in batch) == sorted(set(texts) - encoded)
    assert stored(cache, texts) == set(texts)


def test_non_finite_vectors_not_stored(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec, open_cache: Callable[..., EncodeCache]
) -> None:
    cache = open_cache()
    encoder = Encoder(spec, 1, cache)
    forward = encoder._forward

    def nan_for_tax(batch: list[str]) -> np.ndarray:
        vectors = forward(batch)
        vectors[[i for i, text in enumerate(batch) if text == "tax"]] = np.nan
        return vectors

    monkeypatch.setattr(encoder, "_forward", nan_for_tax)
    vectors = encoder.encode(["tax", "refund"], use_multiprocessing=False)
    assert np.isnan(vectors[0]).all()  # returned as encoded: the caller's validation sees it
    assert stored(cache, ["tax", "refund"]) == {"refund"}  # but never cached for the next build


def test_reports_progress(spec: TransformerSpec, open_cache: Callable[..., EncodeCache]) -> None:
    texts = mixed_texts(20)
    encoder = Encoder(spec, 1, open_cache())
    encoder.encode(texts[:4], use_multiprocessing=False)  # outside report_to: reported nowhere
    sink = Sink()
    with report_to(sink):
        encoder.encode(texts, use_multiprocessing=False)
    assert sink.adds[0] == (4, True)
    assert all(not cached for _, cached in sink.adds[1:])
    assert sum(n for n, _ in sink.adds[1:]) == 16
    assert [n for n, _ in sink.adds[1:]] == [BATCH]  # one add per batch written


def test_report_to_is_per_thread_and_nests(spec: TransformerSpec) -> None:
    encoder = Encoder(spec, 1, None)
    outer, inner = Sink(), Sink()
    with report_to(outer):
        with report_to(inner):
            encoder.encode(["tax"], use_multiprocessing=False)
        worker = threading.Thread(target=encoder.encode, args=(["refund"],), kwargs={"use_multiprocessing": False})
        worker.start()
        worker.join()
        encoder.encode(["fee", "price"], use_multiprocessing=False)
    assert inner.adds == [(1, False)]
    assert outer.adds == [(2, False)]  # not the other thread's encode


def test_session_options(monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec, tiny: tuple[Path, np.ndarray]) -> None:
    import onnxruntime

    captured: list[tuple[tuple, dict]] = []
    real = onnxruntime.InferenceSession

    def capture(*args: object, **kwargs: object) -> object:
        captured.append((args, kwargs))
        return real(*args, **kwargs)

    monkeypatch.setattr(onnxruntime, "InferenceSession", capture)
    Encoder(spec, 3, None)
    ((args, kwargs),) = captured
    assert args == (str(tiny[0] / "model.onnx"),)
    options = kwargs["sess_options"]
    assert options.intra_op_num_threads == 3
    assert options.inter_op_num_threads == 1
    assert options.graph_optimization_level == onnxruntime.GraphOptimizationLevel.ORT_ENABLE_ALL
    assert kwargs["providers"] == ["CPUExecutionProvider"]


def test_make_encoder_keys_its_cache_to_this_host(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec
) -> None:
    """The real `_make_encoder` (patched elsewhere): the cache at its path, keyed with onnxruntime and the CPU."""
    import onnxruntime

    from doc_search import encode_cache

    encoder = transformer._make_encoder(spec, 1)
    try:
        assert isinstance(encoder, Encoder) and encoder.threads == 1
        assert encoder.cache is not None and encoder.cache.usable
        assert encoder.cache.path == encode_cache.encode_cache_path(spec)
        keyed = {
            "model_id": spec.model_id,
            "variant": spec.variant,
            "max_tokens": spec.max_tokens,
            "arch": platform.machine(),
            "dim": spec.dim,
        }
        here = EncodeCache(Path(encoder.cache.path), ort_version=onnxruntime.__version__, **keyed)
        other = EncodeCache(Path(encoder.cache.path), ort_version="0.0.0", **keyed)
        assert encoder.cache.key("refund") == here.key("refund") != other.key("refund")
        here.close()
        other.close()
    finally:
        encoder.close()

    made: list[EncodeCache] = []

    class Recorded(EncodeCache):
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)
            made.append(self)

    monkeypatch.setattr(encode_cache, "EncodeCache", Recorded)
    with pytest.raises(ValueError, match="pooling"):
        transformer._make_encoder(dataclasses.replace(spec, pooling="mean"), 1)
    assert len(made) == 1 and not made[0].usable  # the encoder failed: its cache is closed, not leaked


def test_files_from_the_hub(monkeypatch: pytest.MonkeyPatch, tiny: tuple[Path, np.ndarray]) -> None:
    """A source that is not a local directory is a Hugging Face repo, read at the pinned revision."""
    import huggingface_hub

    spec = dataclasses.replace(tiny_spec(tiny[0], DIM), source="org/tiny", revision="f" * 40)
    asked: list[tuple[str, str, str | None]] = []

    def download(repo_id: str, filename: str, *, revision: str | None = None) -> str:
        asked.append((repo_id, filename, revision))
        return str(tiny[0] / filename)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", download)
    Encoder(spec, 1, None)
    assert sorted(asked) == [("org/tiny", "model.onnx", "f" * 40), ("org/tiny", "tokenizer.json", "f" * 40)]


def test_default_threads(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delattr(transformer.os, "sched_getaffinity", raising=False)  # macOS's os has none
    sysctl: dict[str, int] = {}
    monkeypatch.setattr(transformer, "_sysctl_int", sysctl.get)
    sysctl.update({"hw.perflevel0.physicalcpu": 8, "hw.physicalcpu": 10})
    assert default_threads("darwin") == 6
    sysctl.clear()
    sysctl["hw.physicalcpu"] = 6  # no performance levels
    assert default_threads("darwin") == 4
    sysctl["hw.physicalcpu"] = 3
    assert default_threads("darwin") == 2
    sysctl.clear()  # neither readable: the CPU count
    monkeypatch.setattr(transformer.os, "cpu_count", lambda: 12)
    assert default_threads("darwin") == 10
    sysctl["hw.physicalcpu"] = 6
    assert default_threads("linux") == 10  # only macOS asks sysctl
    monkeypatch.setattr(transformer.os, "cpu_count", lambda: 3)
    assert default_threads("linux") == 2
    monkeypatch.setattr(transformer.os, "cpu_count", lambda: None)
    assert default_threads("linux") == 2


def test_default_threads_off_macos_count_the_cpus_this_process_may_use(monkeypatch: pytest.MonkeyPatch) -> None:
    """Linux: the affinity mask (a container or taskset) where there is one, else the CPU count; less two, at least 2."""
    monkeypatch.setattr(transformer.os, "cpu_count", lambda: 12)
    monkeypatch.setattr(transformer.os, "sched_getaffinity", lambda pid: set(range(8)), raising=False)
    assert default_threads("linux") == 6, "8 CPUs allowed of 12"
    monkeypatch.setattr(transformer.os, "sched_getaffinity", lambda pid: {0, 1, 2}, raising=False)
    assert default_threads("linux") == 2

    def unreadable(pid: int) -> set[int]:
        raise OSError("no affinity here")

    monkeypatch.setattr(transformer.os, "sched_getaffinity", unreadable, raising=False)
    assert default_threads("linux") == 10, "an unreadable mask: the CPU count"
    monkeypatch.delattr(transformer.os, "sched_getaffinity")
    assert default_threads("linux") == 10, "no affinity call: the CPU count"
    monkeypatch.setattr(transformer, "_sysctl_int", lambda name: None)
    monkeypatch.setattr(transformer.os, "sched_getaffinity", lambda pid: set(range(4)), raising=False)
    assert default_threads("darwin") == 2, "macOS without its sysctls falls back the same way"


@pytest.mark.skipif(sys.platform != "darwin", reason="sysctlbyname is macOS's")
def test_sysctl_reads_this_mac() -> None:
    cores = transformer._sysctl_int("hw.physicalcpu")
    assert isinstance(cores, int) and cores >= 1
    assert transformer._sysctl_int("hw.memsize") > 2**30  # a 64-bit value reads whole
    assert transformer._sysctl_int("hw.no_such_name") is None
    assert 2 <= default_threads() <= max(2, cores - 2)


def test_missing_extra_line(monkeypatch: pytest.MonkeyPatch) -> None:
    assert MISSING_EXTRA.format(name="gte-modernbert-base") == (
        "docs.model transformer:gte-modernbert-base needs the local-transformer extra"
    )
    assert extra_missing() is False  # the test run has the extra
    monkeypatch.setitem(sys.modules, "onnxruntime", None)
    assert extra_missing() is True


# -- the session, released after a build and made again on the next encode -----------------------------


def count_sessions(monkeypatch: pytest.MonkeyPatch, delay: float = 0.0) -> list[str]:
    """Record the thread of every onnxruntime session made from now on (each made `delay` seconds slower)."""
    import onnxruntime

    made: list[str] = []
    real = onnxruntime.InferenceSession

    def counting(*args: object, **kwargs: object) -> object:
        made.append(threading.current_thread().name)
        if delay:
            time.sleep(delay)  # a window for the encodes that start together to meet
        return real(*args, **kwargs)

    monkeypatch.setattr(onnxruntime, "InferenceSession", counting)
    return made


def test_release_session_drops_it_and_the_next_encode_makes_another(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec
) -> None:
    made = count_sessions(monkeypatch)
    encoder = Encoder(spec, 1, None)
    texts = mixed_texts(20)
    built = encoder.encode(texts, use_multiprocessing=False)
    query = encoder.encode("refund rounding")
    assert len(made) == 1
    encoder.release_session()
    assert encoder._session is None
    encoder.release_session()  # twice is fine
    np.testing.assert_array_equal(encoder.encode("refund rounding"), query)  # a query makes it again
    assert encoder._session is not None and len(made) == 2
    encoder.release_session()
    np.testing.assert_array_equal(encoder.encode(texts, use_multiprocessing=False), built)  # and a build
    assert len(made) == 3
    np.testing.assert_array_equal(encoder.encode(texts, use_multiprocessing=False), built)
    assert len(made) == 3, "a session is made only when there is none"


def test_encodes_that_start_together_after_a_release_make_one_session(
    monkeypatch: pytest.MonkeyPatch, spec: TransformerSpec
) -> None:
    encoder = Encoder(spec, 1, None)
    texts = mixed_texts(40)
    expected = encoder.encode(texts, use_multiprocessing=False)
    encoder.release_session()
    made = count_sessions(monkeypatch, delay=0.2)
    start = threading.Barrier(8)
    results: dict[int, np.ndarray] = {}
    errors: list[BaseException] = []

    def run(i: int) -> None:
        try:
            start.wait(10)
            results[i] = encoder.encode(texts if i % 2 else "refund total", use_multiprocessing=False)
        except BaseException as err:  # noqa: BLE001 - reported to the test thread
            errors.append(err)

    workers = [threading.Thread(target=run, args=(i,), name=f"encode-{i}") for i in range(8)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(30)
    assert not any(worker.is_alive() for worker in workers)
    assert errors == []
    assert len(made) == 1, f"sessions made: {made}"
    for i, vectors in results.items():
        if i % 2:
            np.testing.assert_array_equal(vectors, expected)
        else:
            np.testing.assert_array_equal(vectors, encoder.encode("refund total", use_multiprocessing=False))


def test_an_encode_under_way_keeps_its_session_through_a_release(spec: TransformerSpec) -> None:
    encoder = Encoder(spec, 1, None)
    texts = mixed_texts(10)  # one batch
    expected = encoder.encode(texts, use_multiprocessing=False)

    class Held:
        """The real session, whose `run` waits for `go` (a release lands while it runs)."""

        def __init__(self, inner: Any) -> None:
            self.inner, self.entered, self.go = inner, threading.Event(), threading.Event()

        def run(self, *args: Any, **kwargs: Any) -> Any:
            self.entered.set()
            assert self.go.wait(30)
            return self.inner.run(*args, **kwargs)

    held = encoder._session = Held(encoder._session)
    out: list[np.ndarray] = []
    worker = threading.Thread(target=lambda: out.append(encoder.encode(texts, use_multiprocessing=False)))
    worker.start()
    try:
        assert held.entered.wait(30)
        encoder.release_session()
        assert encoder._session is None
    finally:
        held.go.set()
        worker.join(30)
    assert len(out) == 1
    np.testing.assert_array_equal(out[0], expected)
    assert encoder._session is None, "the encode that was running did not bring the released session back"


def test_release_session_of_a_model_never_loaded_makes_no_encoder(fake_transformer: TransformerSpec) -> None:
    transformer.release_session(fake_transformer)
    assert transformer._encoders == {}
    encoder = fake_encoder(fake_transformer)
    transformer.release_session(fake_transformer)
    assert encoder.releases == 1 and encoder._session is None


def test_install_threads_apply_to_new_encoders(
    monkeypatch: pytest.MonkeyPatch, fake_transformer: TransformerSpec
) -> None:
    transformer.install(3)
    assert fake_encoder(fake_transformer).threads == 3
    transformer.install(5)
    assert fake_encoder(fake_transformer).threads == 3  # an encoder already made keeps its session
    transformer._reset_encoders()
    assert fake_encoder(fake_transformer).threads == 5
    monkeypatch.setattr(transformer, "default_threads", lambda: 7)
    transformer.install()
    transformer._reset_encoders()
    assert fake_encoder(fake_transformer).threads == 7


def test_one_encoder_per_model_path(monkeypatch: pytest.MonkeyPatch, fake_transformer: TransformerSpec) -> None:
    import semble.index.dense as dense

    make = transformer._make_encoder
    made: list[Encoder] = []
    start = threading.Barrier(8)

    def counting(spec: TransformerSpec, threads: int) -> Encoder:
        made.append(make(spec, threads))
        return made[-1]

    monkeypatch.setattr(transformer, "_make_encoder", counting)
    transformer.install()
    loaded: list[object] = []

    def load() -> None:
        start.wait()
        loaded.append(dense._load_cached(fake_transformer.model_path))

    workers = [threading.Thread(target=load) for _ in range(8)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    assert len(made) == 1
    assert all(model is made[0] for model in loaded) and len(loaded) == 8


def test_encoder_load_failure_propagates(monkeypatch: pytest.MonkeyPatch, fake_transformer: TransformerSpec) -> None:
    """Model files that cannot be had (offline, nothing cached) fail the load, and the next load tries again."""
    import semble.index.dense as dense

    make = transformer._make_encoder
    failures = [OSError("no model files")]

    def flaky(spec: TransformerSpec, threads: int) -> Encoder:
        if failures:
            raise failures.pop()
        return make(spec, threads)

    monkeypatch.setattr(transformer, "_make_encoder", flaky)
    transformer.install()
    with pytest.raises(OSError, match="no model files"):
        dense._load_cached(fake_transformer.model_path)
    assert dense._load_cached(fake_transformer.model_path) is fake_encoder(fake_transformer)
