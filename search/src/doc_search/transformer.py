"""The local-transformer docs embedder: the model registry, the ONNX encoder, and its seam in semble.

`docs.model: "transformer:<name>"` names an entry of REGISTRY. `install()` replaces semble's model
loader, `semble.index.dense._load_cached` (private API: tests/test_semble_seam.py pins it), with
one that returns an `Encoder` for a transformer model path and semble's own model for any other,
so semble builds, saves and loads a transformer docs index as it does a static one.

The encoder runs the model's ONNX export on onnxruntime's CPU provider (CoreML splits gte's graph
155 ways and runs ~1 chunk/s) and pools the CLS token, L2-normalized. semble calls it two ways:
`embed_chunks` passes `use_multiprocessing`, an indexing call, which goes through the encode cache
(encode_cache.py) and reports progress to the thread's sink (`report_to`); a search passes the
query text alone, which is encoded and nothing more: query strings are never stored.

config.py imports this module, so it must stay light: onnxruntime, tokenizers, huggingface_hub,
numpy and semble are imported where they are used, never at module level.
"""

from __future__ import annotations

import importlib.util
import os
import platform
import sys
import threading
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

if TYPE_CHECKING:
    import numpy as np

    from .encode_cache import EncodeCache

PREFIX = "transformer:"

MISSING_EXTRA = "docs.model transformer:{name} needs the local-transformer extra"

# Texts per forward pass. Batches are cut from the texts sorted by length, so each pads little.
BATCH = 16

# The floor of the L2 norm a vector is divided by: an all-zero output stays zero instead of NaN.
_NORM_EPSILON = 1e-12


@dataclass(frozen=True)
class TransformerSpec:
    """One pinned model: where its files come from, which of them to run, and what it produces."""

    name: str
    source: str  # a Hugging Face repo id, or an absolute local directory (tests)
    revision: str
    onnx_file: str
    variant: str
    tokenizer_file: str
    dim: int
    max_tokens: int
    pooling: str = "cls"

    @property
    def model_path(self) -> str:
        """What semble records as the index's model path: a new revision here invalidates saved indexes."""
        return f"{PREFIX}{self.name}@{self.revision[:12]}"

    @property
    def model_id(self) -> str:
        return f"{self.source}@{self.revision}"


REGISTRY: dict[str, TransformerSpec] = {
    "gte-modernbert-base": TransformerSpec(
        "gte-modernbert-base",
        "Alibaba-NLP/gte-modernbert-base",
        "e7f32e3c00f91d699e8c43b53106206bcc72bb22",
        "onnx/model_int8.onnx",
        "int8",
        "tokenizer.json",
        768,
        1024,
    ),
}


class UnknownTransformer(ValueError):
    """A `transformer:<name>` value whose name is not in REGISTRY. The message lists the known names."""


def parse_model(value: str | None) -> TransformerSpec | None:
    """The spec a `docs.model` value names; None for null or any value without the `transformer:` prefix."""
    if value is None or not value.startswith(PREFIX):
        return None
    name = value[len(PREFIX) :]
    spec = REGISTRY.get(name)
    if spec is None:
        raise UnknownTransformer(f"unknown transformer model {name!r} (known: {', '.join(REGISTRY)})")
    return spec


def spec_for_path(model_path: str) -> TransformerSpec:
    """The spec behind a semble model path (`spec.model_path`). ValueError when no current registry entry has it."""
    for spec in REGISTRY.values():
        if spec.model_path == model_path:
            return spec
    raise ValueError(f"not a current transformer model path: {model_path!r}")


def extra_missing() -> bool:
    """True when the local-transformer extra is not installed: there is no onnxruntime to import."""
    return importlib.util.find_spec("onnxruntime") is None


def default_threads(sys_platform: str = sys.platform) -> int:
    """onnxruntime's thread count when `docs.threads` is not set: the performance cores less two, at least 2.

    Two cores stay free for the host through an hours-long first build, and efficiency cores slow
    a CPU-bound encode down (on an M1 Pro: 6 threads ran 14.9 chunks/s, 8 ran 14.1, and 10, the
    efficiency cores included, 8.1). macOS counts its performance cores in
    `hw.perflevel0.physicalcpu` (since macOS 12; `hw.physicalcpu` where it is absent); elsewhere
    the CPUs this process may run on are what there is (`_usable_cpus`).
    """
    cores = None
    if sys_platform == "darwin":
        cores = _sysctl_int("hw.perflevel0.physicalcpu") or _sysctl_int("hw.physicalcpu")
    if not cores:
        cores = _usable_cpus()
    return max(2, cores - 2)


def _usable_cpus() -> int:
    """The CPUs this process may run on: its affinity mask where the OS has one (Linux: a container or
    `taskset` limits it below the machine's count), else `os.cpu_count()`; 0 when neither says."""
    affinity = getattr(os, "sched_getaffinity", None)
    if affinity is not None:
        try:
            return len(affinity(0))
        except OSError:
            pass
    return os.cpu_count() or 0


def _sysctl_int(name: str) -> int | None:
    """An integer sysctl (macOS), read through libc's `sysctlbyname`; None when it is absent or unreadable.

    ctypes, not the `sysctl` command: this runs on build threads, and spawning processes from
    those has caused trouble before.
    """
    import ctypes

    try:
        sysctlbyname = ctypes.CDLL(None, use_errno=True).sysctlbyname
    except (OSError, AttributeError, TypeError):
        return None
    buf = ctypes.create_string_buffer(8)  # sysctl ints are 4 or 8 bytes; `size` says which
    size = ctypes.c_size_t(len(buf))
    if sysctlbyname(name.encode(), buf, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
        return None
    if size.value not in (4, 8):
        return None
    return int.from_bytes(buf.raw[: size.value], sys.byteorder, signed=True)


class ProgressSink(Protocol):
    """Where an indexing encode reports: `add(n)` chunks encoded, `add(n, cached=True)` read from the encode cache."""

    def add(self, n: int, *, cached: bool = False) -> None: ...


_local = threading.local()


@contextmanager
def report_to(sink: ProgressSink) -> Iterator[None]:
    """Report this thread's indexing encodes to `sink` inside the block (and to the outer sink, if any, after it).

    Per thread: semble embeds in the thread that builds, so a build reports its own encodes and
    no other build's.
    """
    previous = getattr(_local, "sink", None)
    _local.sink = sink
    try:
        yield
    finally:
        _local.sink = previous


def _model_file(spec: TransformerSpec, filename: str) -> str:
    """The local path of one of `spec`'s files: in `source` when that is a local directory, else from the
    Hugging Face cache (downloaded at the pinned revision on first use, which fails offline)."""
    source = Path(spec.source)
    if source.is_absolute() and source.is_dir():
        return str(source / filename)
    from huggingface_hub import hf_hub_download

    return hf_hub_download(spec.source, filename, revision=spec.revision)


class Encoder:
    """semble's model protocol for one transformer: `dim`, and `encode(texts, **kwargs)` -> unit float32 rows.

    `__init__` loads the tokenizer and the onnxruntime session and `_forward` runs one batch;
    `encode` holds the rest (the encode cache, the length-sorted batches, the progress reports),
    so a test double replaces the first two and keeps the third. One encoder serves every build
    and query of its model in the process; the cache it is given stays open as long as it lives.

    The session keeps the memory its largest batches needed once a build has run through it (a
    process held 3.75 GB after encoding a large corpus's longest chunks, 2.7 GB once the session
    was dropped; turning onnxruntime's arena off did not help), so the pool calls `release_session`
    once a build's own encode has run, and `_forward` makes a new session on the next encode: the
    first query after a build pays for it (0.63 s measured on an Intel Mac, against 11 ms for the
    query's encode). A load or a recheck that encodes nothing never releases. Both take the session
    lock, so encodes that start together make one session.
    """

    def __init__(self, spec: TransformerSpec, threads: int, cache: EncodeCache | None) -> None:
        if spec.pooling != "cls":
            raise ValueError(f"doc-search: transformer:{spec.name}: pooling {spec.pooling!r} is not supported")
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.spec = spec
        self.name = spec.model_path
        self.dim = spec.dim
        self.threads = threads
        self.cache = cache
        tokenizer = Tokenizer.from_file(_model_file(spec, spec.tokenizer_file))
        tokenizer.enable_truncation(max_length=spec.max_tokens)
        tokenizer.no_padding()  # a batch pads to its own longest text, in _forward
        self._tokenizer = tokenizer
        self._pad_id = tokenizer.token_to_id("[PAD]") or 0
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self._options = options
        self._onnx_path = _model_file(spec, spec.onnx_file)  # resolved once: a new session needs no download
        self._session_lock = threading.Lock()
        session = self._new_session()
        self._session: Any = session  # None once released, until the next encode makes another
        self._inputs = {i.name for i in session.get_inputs()}
        self._output = session.get_outputs()[0].name

    def _new_session(self) -> Any:
        import onnxruntime as ort

        return ort.InferenceSession(self._onnx_path, sess_options=self._options, providers=["CPUExecutionProvider"])

    def _live_session(self) -> Any:
        """The session, made again (under the lock, so once) when it was released."""
        session = self._session
        if session is None:
            with self._session_lock:
                session = self._session
                if session is None:
                    session = self._session = self._new_session()
        return session

    def release_session(self) -> None:
        """Drop the onnxruntime session and the memory it holds; the next forward pass makes a new one.

        A forward pass under way finishes on the session it started with (its memory goes when it returns);
        a batch after it, of the same encode or another, makes the new one.
        """
        with self._session_lock:
            self._session = None

    def encode(self, sentences: str | Sequence[str], **kwargs: Any) -> np.ndarray:
        """The unit vectors of `sentences`, float32 `(n, dim)`, in input order.

        An indexing call (semble's `embed_chunks`, which passes `use_multiprocessing`) reads the
        encode cache, encodes the misses (each distinct text once) in length-sorted batches of
        BATCH, stores each batch as it finishes, so a killed build keeps what it encoded, and
        reports to the thread's sink: the cache hits once, then each batch. Any other call is a
        query: encoded, never stored, never reported.
        """
        import numpy as np

        texts = [sentences] if isinstance(sentences, str) else list(sentences)
        out = np.empty((len(texts), self.dim), dtype=np.float32)
        if "use_multiprocessing" not in kwargs:
            for start in range(0, len(texts), BATCH):
                out[start : start + BATCH] = self._forward(texts[start : start + BATCH])
            return out

        cache = self.cache if self.cache is not None and self.cache.usable else None
        keys = {text: cache.key(text) for text in dict.fromkeys(texts)} if cache is not None else {}
        found = cache.get_many(list(keys.values())) if cache is not None else {}
        pending: dict[str, list[int]] = {}  # each text to encode -> the rows it fills
        hits = 0
        for row, text in enumerate(texts):
            vector = found.get(keys[text]) if found else None
            if vector is not None:
                out[row] = vector
                hits += 1
            else:
                pending.setdefault(text, []).append(row)
        sink: ProgressSink | None = getattr(_local, "sink", None)
        if sink is not None and hits:
            sink.add(hits, cached=True)

        order = sorted(pending, key=len)  # by length: a batch's texts pad to about the same width
        for start in range(0, len(order), BATCH):
            batch = order[start : start + BATCH]
            vectors = self._forward(batch)
            for text, vector in zip(batch, vectors, strict=True):
                out[pending[text]] = vector
            if cache is not None:
                # a non-finite vector is returned (the build's validation rejects it) but never
                # stored, or every later build would read it back
                finite = np.isfinite(vectors).all(axis=1)
                cache.put_many([(keys[text], vector) for text, vector, ok in zip(batch, vectors, finite) if ok])
            if sink is not None:
                sink.add(sum(len(pending[text]) for text in batch))
        return out

    def _forward(self, texts: list[str]) -> np.ndarray:
        """One forward pass: the CLS vectors of `texts`, L2-normalized, float32 `(len(texts), dim)`."""
        import numpy as np

        encodings = self._tokenizer.encode_batch(texts)
        width = max(1, max(len(encoding.ids) for encoding in encodings))
        ids = np.full((len(texts), width), self._pad_id, dtype=np.int64)
        mask = np.zeros((len(texts), width), dtype=np.int64)
        for row, encoding in enumerate(encodings):
            ids[row, : len(encoding.ids)] = encoding.ids
            mask[row, : len(encoding.ids)] = 1
        feed = {"input_ids": ids, "attention_mask": mask, "token_type_ids": np.zeros_like(ids)}
        session = self._live_session()
        (hidden,) = session.run([self._output], {k: v for k, v in feed.items() if k in self._inputs})
        cls = np.asarray(hidden[:, 0, :], dtype=np.float32)
        return cls / np.maximum(np.linalg.norm(cls, axis=1, keepdims=True), _NORM_EPSILON)

    def close(self) -> None:
        """Close the encode cache: the encoder encodes uncached from then on."""
        if self.cache is not None:
            self.cache.close()


# One encoder per transformer model path for the life of the process: its session holds the model
# in memory, and every build and query of that model shares it. Made under the lock, so builds
# that start together load the model once.
_encoders: dict[str, Encoder] = {}
_encoders_lock = threading.Lock()
_install_lock = threading.Lock()
_threads: int | None = None  # install()'s thread count, for the encoders made after it
_semble_load: Callable[[str], Any] | None = None  # the loader install() replaced (semble's own)


def _make_encoder(spec: TransformerSpec, threads: int) -> Encoder:
    """A new encoder for `spec`, over its encode cache keyed to this host's onnxruntime and CPU (tests patch this)."""
    import onnxruntime

    from .encode_cache import EncodeCache, encode_cache_path

    cache = EncodeCache(
        encode_cache_path(spec),
        model_id=spec.model_id,
        variant=spec.variant,
        max_tokens=spec.max_tokens,
        ort_version=onnxruntime.__version__,
        arch=platform.machine(),
        dim=spec.dim,
    )
    try:
        return Encoder(spec, threads, cache)
    except BaseException:
        cache.close()
        raise


def _encoder_for(spec: TransformerSpec) -> Encoder:
    """The process's encoder for `spec`, made on first use. A failure to make it raises and is not kept."""
    with _encoders_lock:
        encoder = _encoders.get(spec.model_path)
        if encoder is None:
            encoder = _make_encoder(spec, _threads or default_threads())
            _encoders[spec.model_path] = encoder
        return encoder


def release_session(spec: TransformerSpec) -> None:
    """Drop the onnxruntime session of the process's encoder for `spec`, when one was made (none is made here).

    The pool calls it when a transformer build ends; the encoder makes a new session on its next encode.
    """
    with _encoders_lock:
        encoder = _encoders.get(spec.model_path)
    if encoder is not None:
        encoder.release_session()


def _load(model_path: str) -> Any:
    """semble's model loader once `install` has run: an Encoder for a transformer path, semble's own model otherwise."""
    if model_path.startswith(PREFIX):
        return _encoder_for(spec_for_path(model_path))
    load = _semble_load
    if load is None:  # only a direct call gets here before install()
        raise RuntimeError("doc-search: transformer.install() has not run")
    return load(model_path)


def install(threads: int | None = None) -> None:
    """Route semble's model loader through `_load`. Idempotent; semble's own loader serves every other path.

    `threads` (None: `default_threads()`) applies to the encoders made after the call: one made
    already keeps its session. semble's `load_model` reads `_load_cached` as a module global
    when it is called, so replacing the module attribute is enough.
    """
    global _threads, _semble_load
    import semble.index.dense as dense

    with _install_lock:
        _threads = threads
        if dense._load_cached is not _load:
            _semble_load = dense._load_cached
            dense._load_cached = _load


def _reset_encoders() -> None:
    """Drop and close every encoder made so far, as a new process would start (for tests)."""
    with _encoders_lock:
        encoders = list(_encoders.values())
        _encoders.clear()
    for encoder in encoders:
        encoder.close()
