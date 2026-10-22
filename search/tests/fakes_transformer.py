"""A transformer encoder that loads no model, for the tests of everything around the encoder.

`FakeEncoder` replaces only what loads and runs the model (`__init__` and `_forward`): the encode
cache, the length-sorted batches, the progress reports and the query detection are the real
`Encoder`'s. Its vectors are hashed bags of words (tests/fakes.py's `text_vector`), so equal
texts give equal vectors and a test can tell which texts were encoded and which were read from
the cache (`forwarded`). The `fake_transformer` fixture in conftest.py wires it in.
"""

from __future__ import annotations

import platform
import threading
import time
from collections.abc import Callable, Sequence
from typing import Any, TypeVar

import numpy as np

from doc_search import transformer
from doc_search.encode_cache import EncodeCache, encode_cache_path
from doc_search.transformer import Encoder, TransformerSpec
from fakes import text_vector, unit

# The spec `fake_transformer` registers: `docs.model: "transformer:test-tiny"`.
TEST_SPEC = TransformerSpec(
    name="test-tiny",
    source="doc-search-tests/test-tiny",
    revision="0123456789abcdef0123456789abcdef01234567",
    onnx_file="model.onnx",
    variant="fake",
    tokenizer_file="tokenizer.json",
    dim=16,
    max_tokens=512,
)

T = TypeVar("T")

# The names of a pool's build threads (engines.py), for a test to join before it ends.
BUILD_THREADS = ("doc-search-docs", "doc-search-code", "doc-search-static", "doc-search-transformer")

# How long `_forward` waits for a closed gate before it fails: a test that never opens it fails
# its build instead of hanging the run.
GATE_TIMEOUT_S = 60.0


class FakeEncoder(Encoder):
    """An `Encoder` whose forward pass is a hash. A test steers it through three attributes:

    - `gate`: an indexing call's `_forward` waits for it first (set by default; clear it to hold a
      build mid-encode). Queries never wait: one encoder serves its model's builds and searches,
      so a search of the previous index answers while a refresh is held.
    - `nan`: `_forward` returns NaN rows (a broken model), for queries too.
    - `forwarded`: every batch `_forward` ran, in order, queries included; `calls`: every `encode`
      call, `(texts, kwargs)`; `releases`: how many times the pool released its session (it has
      none: `_forward` never needs one).
    """

    def __init__(self, spec: TransformerSpec, cache: EncodeCache | None, *, threads: int = 1) -> None:
        self.spec = spec
        self.name = spec.model_path
        self.dim = spec.dim
        self.threads = threads
        self.cache = cache
        self.gate = threading.Event()
        self.gate.set()
        self.nan = False
        self.forwarded: list[list[str]] = []
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.retired = False
        self.releases = 0
        self._session = None
        self._session_lock = threading.Lock()
        self._local = threading.local()  # `indexing`: this thread's encode call is an indexing one

    def release_session(self) -> None:
        with self._session_lock:
            self.releases += 1
        super().release_session()

    def encode(self, sentences: str | Sequence[str], **kwargs: Any) -> np.ndarray:
        self.calls.append(([sentences] if isinstance(sentences, str) else list(sentences), dict(kwargs)))
        self._local.indexing = "use_multiprocessing" in kwargs  # the Encoder's own test for an indexing call
        try:
            return super().encode(sentences, **kwargs)
        finally:
            self._local.indexing = False

    def _forward(self, texts: list[str]) -> np.ndarray:
        if getattr(self._local, "indexing", False) and not self.gate.wait(GATE_TIMEOUT_S):
            raise TimeoutError(f"FakeEncoder gate still closed after {GATE_TIMEOUT_S:.0f} s")
        if self.retired:
            raise RuntimeError("FakeEncoder used after its test ended")
        self.forwarded.append(list(texts))
        if self.nan:
            return np.full((len(texts), self.dim), np.nan, dtype=np.float32)
        return np.array([unit(text_vector(text, self.dim)) for text in texts], dtype=np.float32)

    def retire(self) -> None:
        """End of test: a build still held at the gate is let go, and fails (it must not save after the test)."""
        self.retired = True
        self.gate.set()
        self.close()


def fake_cache(spec: TransformerSpec) -> EncodeCache:
    """A real encode cache for `spec`, at its real path (in the test's cache location), keyed to no onnxruntime."""
    return EncodeCache(
        encode_cache_path(spec),
        model_id=spec.model_id,
        variant=spec.variant,
        max_tokens=spec.max_tokens,
        ort_version="fake",
        arch=platform.machine(),
        dim=spec.dim,
    )


def fake_encoder(spec: TransformerSpec = TEST_SPEC) -> FakeEncoder:
    """The encoder a build of `spec` uses, made now if no build has made it yet (set its `gate` or `nan` first)."""
    encoder = transformer._encoder_for(spec)
    assert isinstance(encoder, FakeEncoder), "fake_encoder() needs the fake_transformer fixture"
    return encoder


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


def release_builds(timeout: float = 60.0) -> None:
    """End of a test: every fake encoder's gate is opened and the pools' build threads are joined."""
    for encoder in list(transformer._encoders.values()):
        if isinstance(encoder, FakeEncoder):
            encoder.gate.set()
    deadline = time.monotonic() + timeout
    for thread in threading.enumerate():
        if thread.name.startswith(BUILD_THREADS):
            thread.join(max(0.0, deadline - time.monotonic()))
    alive = [thread.name for thread in threading.enumerate() if thread.name.startswith(BUILD_THREADS)]
    assert not alive, f"build threads still running: {alive}"
