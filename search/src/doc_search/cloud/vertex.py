"""Vertex AI embeddings through `google-genai` (design section 8).

Query vectors use the `RETRIEVAL_QUERY` task type and document vectors `RETRIEVAL_DOCUMENT`, both
`gemini-embedding-001` at the configured dimensions (768). The API does not normalize a truncated
vector, so every row is L2-normalized here. Documents go in batches of 200; a 429, a 5xx or a
deadline is retried 3 times with exponential backoff and jitter.
"""

from __future__ import annotations

import random
import time
from collections.abc import Callable, Sequence
from typing import Any

import numpy as np

from ..config import CloudCfg
from . import CLOUD_TIMEOUT_S, CloudUnavailable, LazyClient, import_module

BATCH_SIZE = 200
RETRIES = 3
BACKOFF_S = 1.0  # the first retry waits about this long, the next twice that, ...
BACKOFF_CAP_S = 30.0

QUERY_TASK = "RETRIEVAL_QUERY"
DOCUMENT_TASK = "RETRIEVAL_DOCUMENT"


class VertexEmbedder:
    """Unit-length embeddings of queries and documents.

    `client` stands in for `genai.Client` (tests); without it the client is built on first use, with
    Application Default Credentials. `sleep`, `jitter` and `clock` are the retries' delay, random source and time.

    Every call to the API is cut off after CLOUD_TIMEOUT_S. A query is embedded while a search waits, so
    its retries share one budget of that length: a timed-out call is not tried again, a quick 429 or 503 is.
    """

    def __init__(
        self,
        cfg: CloudCfg,
        client: Any = None,
        *,
        sleep: Callable[[float], None] = time.sleep,
        jitter: Callable[[], float] = random.random,
        backoff_s: float = BACKOFF_S,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        vertex = cfg.vertex
        if not vertex.project:
            raise CloudUnavailable("no project (set cloud.vertex.project or GOOGLE_CLOUD_PROJECT)")
        if client is None:
            import_module("google.genai")  # a missing extra is known now, credentials only at the first call
        self._vertex = vertex
        self._client = LazyClient(self._make_client) if client is None else LazyClient(lambda: client)
        self._sleep = sleep
        self._jitter = jitter
        self._backoff_s = backoff_s
        self._clock = clock
        self.id = f"vertex:{vertex.model}/{vertex.dimensions}"

    def _make_client(self) -> Any:
        genai = import_module("google.genai")
        types = import_module("google.genai.types")
        return genai.Client(
            vertexai=True,
            project=self._vertex.project,
            location=self._vertex.location,
            http_options=types.HttpOptions(timeout=int(CLOUD_TIMEOUT_S * 1000)),  # milliseconds
        )

    # -- public ------------------------------------------------------------------------------

    def embed_query(self, text: str) -> np.ndarray:
        """The unit vector of one query, shape (dimensions,)."""
        return self._embed([text], QUERY_TASK, budget_s=CLOUD_TIMEOUT_S)[0]

    def embed_documents(self, texts: Sequence[str]) -> np.ndarray:
        """The unit vectors of `texts`, shape (len(texts), dimensions), embedded 200 at a time."""
        items = list(texts)
        parts = [self._embed(items[i : i + BATCH_SIZE], DOCUMENT_TASK) for i in range(0, len(items), BATCH_SIZE)]
        if not parts:
            return np.zeros((0, self._vertex.dimensions), dtype=np.float32)
        return np.concatenate(parts)

    # -- one batch ---------------------------------------------------------------------------

    def _embed(self, batch: list[str], task_type: str, budget_s: float | None = None) -> np.ndarray:
        types = import_module("google.genai.types")
        config = types.EmbedContentConfig(task_type=task_type, output_dimensionality=self._vertex.dimensions)
        client = self._client.get()
        response = self._with_retries(
            lambda: client.models.embed_content(model=self._vertex.model, contents=batch, config=config), budget_s
        )
        vectors = [list(item.values) for item in (response.embeddings or [])]
        if len(vectors) != len(batch):
            raise CloudUnavailable(f"embedder returned {len(vectors)} vectors for {len(batch)} texts")
        matrix = np.asarray(vectors, dtype=np.float32)
        if matrix.ndim != 2 or matrix.shape[1] != self._vertex.dimensions:
            raise CloudUnavailable(
                f"embedder returned vectors of shape {matrix.shape[1:]}, expected ({self._vertex.dimensions},)"
            )
        norms = np.linalg.norm(matrix, axis=1, keepdims=True)
        norms[norms == 0] = 1.0  # an all-zero vector stays zero
        return matrix / norms

    def _with_retries(self, call: Callable[[], Any], budget_s: float | None) -> Any:
        started = self._clock()
        for attempt in range(RETRIES + 1):
            try:
                return call()
            except Exception as err:  # noqa: BLE001 - only the transient kinds are retried, the rest re-raised
                if attempt == RETRIES or not _transient(err):
                    raise
                delay = min(BACKOFF_CAP_S, self._backoff_s * 2**attempt) + self._jitter() * self._backoff_s
                if budget_s is not None and self._clock() - started + delay >= budget_s:
                    raise
                self._sleep(delay)
        raise AssertionError("unreachable")  # pragma: no cover


def _transient(err: BaseException) -> bool:
    """429, 5xx (a deadline is a 504) and client-side timeouts: worth another try."""
    if isinstance(err, TimeoutError):
        return True
    try:
        errors = import_module("google.genai.errors")
    except CloudUnavailable:
        return False
    if isinstance(err, errors.APIError):
        code = err.code
        return isinstance(code, int) and (code == 429 or code >= 500)
    try:
        import httpx  # a dependency of google-genai
    except ImportError:
        return False
    return isinstance(err, httpx.TimeoutException)


def rejected(err: BaseException) -> bool:
    """True for a 400 the API answered for this request alone: the service itself is reachable and well."""
    try:
        errors = import_module("google.genai.errors")
    except CloudUnavailable:
        return False
    return isinstance(err, errors.ClientError) and err.code == 400
