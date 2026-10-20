"""In-memory stand-ins for `genai.Client` and `firestore.Client`: the cloud tests never touch the network.

`FakeGenai` embeds text as a hashed bag of words, so two texts that share words are near each other
and the same text is the same vector. `FakeFirestore` keeps documents in dicts and answers
`find_nearest` with a real cosine distance over what is stored. Both count their calls, so a test
can assert what was and was not asked of the cloud.
"""

from __future__ import annotations

import copy
import hashlib
import math
import re
from collections import Counter
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any

DIMS = 128


def text_vector(text: str, dims: int = DIMS) -> list[float]:
    """A deterministic embedding of `text`: each word adds 1 to a coordinate chosen by its hash.

    A bag of hashed words, so the cosine of two texts grows with the words they share. Not
    normalized (the embedder under test normalizes), and never all zero.
    """
    vec = [0.0] * dims
    for word in re.findall(r"[a-z0-9]+", text.lower()):
        vec[int.from_bytes(hashlib.sha256(word.encode()).digest()[:4], "big") % dims] += 1.0
    if not any(vec):
        vec[0] = 1.0
    return [3.0 * x for x in vec]


def unit(vec: Sequence[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec)) or 1.0
    return [x / norm for x in vec]


# -- genai ------------------------------------------------------------------------------------


@dataclass
class EmbedCall:
    model: str
    texts: list[str]
    task_type: str | None
    dims: int | None
    failed: bool = False


class FakeGenai:
    """`genai.Client` as far as the embedder uses it: `client.models.embed_content(...)`.

    `script` is a list of exceptions: each call first pops one and raises it, until the list is empty.
    """

    def __init__(self, dims: int = DIMS, script: Iterable[Exception] = ()) -> None:
        self.dims = dims
        self.script = list(script)
        self.calls: list[EmbedCall] = []
        self.models = SimpleNamespace(embed_content=self._embed_content)

    def _embed_content(self, *, model: str, contents: list[str], config: Any = None) -> Any:
        call = EmbedCall(
            model=model,
            texts=list(contents),
            task_type=getattr(config, "task_type", None),
            dims=getattr(config, "output_dimensionality", None),
        )
        self.calls.append(call)
        if self.script:
            call.failed = True
            raise self.script.pop(0)
        dims = call.dims or self.dims
        return SimpleNamespace(embeddings=[SimpleNamespace(values=text_vector(t, dims)) for t in contents])

    @property
    def sizes(self) -> list[int]:
        """The batch size of each call that succeeded."""
        return [len(call.texts) for call in self.calls if not call.failed]


# -- firestore --------------------------------------------------------------------------------


class FakeSnapshot:
    def __init__(self, doc_id: str, data: dict[str, Any] | None) -> None:
        self.id = doc_id
        self._data = data
        self.exists = data is not None

    def to_dict(self) -> dict[str, Any] | None:
        return copy.deepcopy(self._data) if self._data is not None else None


class FakeDocumentRef:
    def __init__(self, fs: FakeFirestore, collection: FakeCollection, doc_id: str) -> None:
        self._fs = fs
        self._collection = collection
        self.id = doc_id

    def get(self, field_paths: Any = None, transaction: Any = None, **_: Any) -> FakeSnapshot:
        self._fs._count("document_get")
        self._fs._maybe_fail("document_get")
        return FakeSnapshot(self.id, self._collection.docs.get(self.id))

    def set(self, data: dict[str, Any], merge: bool = False) -> None:
        self._fs._count("document_set")
        self._collection._write(self.id, data, merge)

    def update(self, data: dict[str, Any]) -> None:
        self._fs._count("document_update")
        if self.id not in self._collection.docs:
            raise KeyError(f"no document {self.id} to update")
        self._collection._write(self.id, data, True)

    def delete(self) -> None:
        self._fs._count("document_delete")
        self._collection.docs.pop(self.id, None)


class FakeVectorQuery:
    def __init__(self, fs: FakeFirestore, source: FakeQuery, args: dict[str, Any]) -> None:
        self._fs = fs
        self._source = source
        self._args = args

    def get(self, **_: Any) -> list[FakeSnapshot]:
        fs, args = self._fs, self._args
        fs._count("find_nearest")
        fs._maybe_fail("find_nearest")
        filters = [(f.field_path, f.op_string, f.value) for f in self._source.filters]
        fs.vector_queries.append({**args, "filters": filters, "collection": self._source.collection.name})
        if filters and fs.reject_filtered is not None:
            raise fs.reject_filtered
        query = [float(x) for x in args["query_vector"]]
        scored: list[tuple[float, str, dict[str, Any]]] = []
        for doc_id, data in self._source.matching():
            stored = [float(x) for x in data["embedding"]]
            scored.append((_cosine_distance(query, stored), doc_id, data))
        scored.sort(key=lambda item: (item[0], item[1]))
        out = []
        for distance, doc_id, data in scored[: args["limit"]]:
            row = copy.deepcopy(data)
            if args.get("distance_result_field"):
                row[args["distance_result_field"]] = distance
            out.append(FakeSnapshot(doc_id, row))
        return out

    def stream(self) -> Iterator[FakeSnapshot]:
        yield from self.get()


class FakeQuery:
    def __init__(self, collection: FakeCollection, filters: list[Any]) -> None:
        self.collection = collection
        self.filters = filters

    def where(
        self, field_path: str | None = None, op_string: str | None = None, value: Any = None, *, filter: Any = None
    ):
        if filter is None:
            filter = SimpleNamespace(field_path=field_path, op_string=op_string, value=value)
        if filter.op_string not in ("==", "in"):
            raise NotImplementedError(f"FakeFirestore does not model {filter.op_string!r} filters")
        return FakeQuery(self.collection, [*self.filters, filter])

    def matching(self) -> list[tuple[str, dict[str, Any]]]:
        def keep(data: dict[str, Any]) -> bool:
            for f in self.filters:
                have = data.get(f.field_path)
                if not (have == f.value if f.op_string == "==" else have in f.value):
                    return False
            return True

        return [(doc_id, data) for doc_id, data in sorted(self.collection.docs.items()) if keep(data)]

    def find_nearest(
        self,
        vector_field: str,
        query_vector: Any,
        limit: int,
        distance_measure: Any,
        *,
        distance_result_field: str | None = None,
        distance_threshold: float | None = None,
    ) -> FakeVectorQuery:
        assert vector_field == "embedding", vector_field
        assert getattr(distance_measure, "name", str(distance_measure)).endswith("COSINE"), distance_measure
        args = {
            "vector_field": vector_field,
            "query_vector": list(query_vector),
            "limit": limit,
            "distance_result_field": distance_result_field,
        }
        return FakeVectorQuery(self.collection.fs, self, args)

    def stream(self, **_: Any) -> Iterator[FakeSnapshot]:
        self.collection.fs._count("stream")
        self.collection.fs._maybe_fail("stream")
        for doc_id, data in self.matching():
            yield FakeSnapshot(doc_id, data)


class FakeCollection(FakeQuery):
    def __init__(self, fs: FakeFirestore, name: str) -> None:
        super().__init__(self, [])
        self.fs = fs
        self.name = name
        self.docs: dict[str, dict[str, Any]] = {}

    def document(self, doc_id: str) -> FakeDocumentRef:
        return FakeDocumentRef(self.fs, self, doc_id)

    def _write(self, doc_id: str, data: dict[str, Any], merge: bool) -> None:
        if merge and doc_id in self.docs:
            self.docs[doc_id] = {**self.docs[doc_id], **copy.deepcopy(data)}
        else:
            self.docs[doc_id] = copy.deepcopy(data)


class FakeBatch:
    """A `WriteBatch`: operations are applied together at `commit`."""

    def __init__(self, fs: FakeFirestore, kind: str = "batch") -> None:
        self._fs = fs
        self._kind = kind
        self.ops: list[tuple[str, FakeDocumentRef, dict[str, Any] | None, bool]] = []

    def set(self, ref: FakeDocumentRef, data: dict[str, Any], merge: bool = False) -> None:
        self.ops.append(("set", ref, data, merge))

    def update(self, ref: FakeDocumentRef, data: dict[str, Any]) -> None:
        self.ops.append(("update", ref, data, True))

    def delete(self, ref: FakeDocumentRef) -> None:
        self.ops.append(("delete", ref, None, False))

    def __len__(self) -> int:
        return len(self.ops)

    def commit(self) -> list[None]:
        for op, ref, data, merge in self.ops:
            if op == "delete":
                ref._collection.docs.pop(ref.id, None)
            else:
                ref._collection._write(ref.id, data or {}, merge)
        self._fs._count(f"{self._kind}_commit")
        self._fs.commit_sizes.append(len(self.ops))
        self.ops = []
        return []


class FakeTransaction(FakeBatch):
    """A `Transaction` without retries: reads see the store, writes land at `commit`."""

    def __init__(self, fs: FakeFirestore) -> None:
        super().__init__(fs, "transaction")

    def get(self, ref: FakeDocumentRef) -> FakeSnapshot:
        return ref.get(transaction=self)


class FakeFirestore:
    """`firestore.Client` with in-memory collections and call counters.

    `calls` counts operations by name (`find_nearest`, `stream`, `document_get`, `batch_commit`, ...).
    `fail` maps an operation (`find_nearest`, `document_get`, `stream`) to an exception it raises.
    `reject_filtered` is raised by a vector query that has a `where` filter (a missing prefixed index).
    """

    def __init__(self) -> None:
        self.collections: dict[str, FakeCollection] = {}
        self.calls: Counter[str] = Counter()
        self.vector_queries: list[dict[str, Any]] = []
        self.commit_sizes: list[int] = []
        self.fail: dict[str, Exception] = {}
        self.reject_filtered: Exception | None = None

    def _count(self, op: str) -> None:
        self.calls[op] += 1

    def _maybe_fail(self, op: str) -> None:
        if op in self.fail:
            raise self.fail[op]

    def collection(self, name: str) -> FakeCollection:
        if name not in self.collections:
            self.collections[name] = FakeCollection(self, name)
        return self.collections[name]

    def batch(self) -> FakeBatch:
        return FakeBatch(self)

    def transaction(self, max_attempts: int = 5, read_only: bool = False) -> FakeTransaction:
        self._count("transaction")
        return FakeTransaction(self)

    # -- test helpers ----------------------------------------------------------------------

    def put(self, collection: str, doc_id: str, data: dict[str, Any]) -> None:
        self.collection(collection).docs[doc_id] = copy.deepcopy(data)

    def add_chunk(
        self,
        path: str,
        text: str,
        *,
        index: int = 0,
        collection: str = "doc_chunks",
        doc_type: str = "other",
        dims: int = DIMS,
        start: int | None = None,
        end: int | None = None,
    ) -> None:
        """One chunk document, with the schema's fields; the line range only when both ends are given."""
        data: dict[str, Any] = {
            "path": path,
            "chunkIndex": index,
            "text": text,
            "embedding": unit(text_vector(text, dims)),
            "headingPath": "",
            "lastIndexedAt": "2026-01-01T00:00:00Z",
            "fileSha256": hashlib.sha256(text.encode()).hexdigest(),
            "docType": doc_type,
        }
        if start is not None and end is not None:
            data["startLine"], data["endLine"] = start, end
        self.put(collection, f"{path.replace('/', '__')}__{index}", data)

    def set_stamp(
        self,
        commit: str,
        *,
        meta: str = "corpus_meta",
        mode: str = "full",
        embedder_id: str = f"vertex:gemini-embedding-001/{DIMS}",
        built_at: str = "2026-01-01T00:00:00Z",
    ) -> None:
        self.put(
            meta,
            "index",
            {"built_from_commit": commit, "built_at": built_at, "mode": mode, "embedder_id": embedder_id},
        )


def _cosine_distance(a: Sequence[float], b: Sequence[float]) -> float:
    na, nb = math.sqrt(sum(x * x for x in a)), math.sqrt(sum(x * x for x in b))
    if not na or not nb:
        return 1.0
    return 1.0 - sum(x * y for x, y in zip(a, b, strict=True)) / (na * nb)
