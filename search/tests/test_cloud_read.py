"""The cloud docs leg's read path: Vertex embedder, Firestore query, branch suppression, degradation.

Everything runs against `FakeGenai` and `FakeFirestore` (tests/fakes.py): no network, no credentials.
The google libraries are only needed for the real classes the code builds around the fakes
(`types.EmbedContentConfig`, `FieldFilter`, `Vector`), so the module is skipped without the cloud extra.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import pytest
from fakes import DIMS, FakeFirestore, FakeGenai, text_vector, unit

from doc_search.cloud import CloudUnavailable
from doc_search.cloud.read import CloudLeg, CorpusStamp, DegradedLeg, build_cloud_leg, resolve_base_ref
from doc_search.cloud.vertex import VertexEmbedder
from doc_search.config import CloudCfg, Config, FirestoreCfg, VertexCfg, load_config
from doc_search.corpus import Corpus
from doc_search.docindex import DocIndex
from doc_search.engines import IndexPool, WorktreeIndexes
from doc_search.repo import RepoInfo
from doc_search.searcher import Searcher
from doc_search.types import SearchRequest, SearchResponse

pytest.importorskip("google.genai")
pytest.importorskip("google.cloud.firestore")
errors = pytest.importorskip("google.genai.errors")
FailedPrecondition = pytest.importorskip("google.api_core.exceptions").FailedPrecondition

SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

## Rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

SHIPPING = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

INVOICES = """# Invoices

Invoice rules for the payment service, INV-005. An invoice total is the sum of the line amounts.
"""

SPEC_PATH = "docs/specs/SPEC-PAY-004.md"
SHIPPING_PATH = "docs/shipping.md"
INVOICES_PATH = "docs/invoices.md"
ALL = {SPEC_PATH, SHIPPING_PATH, INVOICES_PATH}

# the chunk texts as the cloud's chunker would cut them, and where they sit in the files above
SPEC_CHUNK = (
    "Refunds round half up to the nearest cent. The refund total is the sum of the\n"
    "rounded line amounts, never the rounded sum."
)
SHIPPING_CHUNK = "Orders ship from the nearest warehouse. The shipping fee is a flat rate per order."
NO_PROJECT = "no project (set cloud.vertex.project or GOOGLE_CLOUD_PROJECT)"


def cloud_cfg(*, base_ref: str | None = None, **vertex) -> CloudCfg:
    base = VertexCfg(project="p", location="us-central1", model="gemini-embedding-001", dimensions=DIMS)
    firestore = FirestoreCfg(
        project="p", database="(default)", collection="doc_chunks", meta_collection="corpus_meta", base_ref=base_ref
    )
    return CloudCfg(vertex=replace(base, **vertex), firestore=firestore)


def no_sleep(_: float) -> None:
    pass


def api_error(code: int, status: str) -> Exception:
    cls = errors.ClientError if code < 500 else errors.ServerError
    return cls(code, {"error": {"code": code, "message": f"{status} test", "status": status}})


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


# --- the Vertex embedder ----------------------------------------------------------------------------


def test_vertex_batches_retries_normalizes() -> None:
    genai = FakeGenai(script=[api_error(429, "RESOURCE_EXHAUSTED")])
    slept: list[float] = []
    embedder = VertexEmbedder(cloud_cfg(), client=genai, sleep=slept.append, jitter=lambda: 0.5)
    texts = [f"term{i} refund payment" for i in range(450)]

    out = embedder.embed_documents(texts)

    assert genai.sizes == [200, 200, 50]
    assert [len(call.texts) for call in genai.calls] == [200, 200, 200, 50], "the first batch failed once, then ran"
    assert genai.calls[0].failed and not any(call.failed for call in genai.calls[1:])
    assert slept == [1.5], "one backoff: a 1 s base plus a jitter of half a second"
    assert out.shape == (450, DIMS)
    assert np.allclose(np.linalg.norm(out, axis=1), 1.0, atol=1e-5), "every row is a unit vector"
    assert np.allclose(out[7], unit(text_vector(texts[7])), atol=1e-5), "rows keep the order of the texts"
    assert {call.task_type for call in genai.calls} == {"RETRIEVAL_DOCUMENT"}
    assert {call.dims for call in genai.calls} == {DIMS}
    assert {call.model for call in genai.calls} == {"gemini-embedding-001"}

    query = embedder.embed_query("refund rounding")
    assert query.shape == (DIMS,)
    assert np.isclose(np.linalg.norm(query), 1.0, atol=1e-5)
    assert genai.calls[-1].task_type == "RETRIEVAL_QUERY" and genai.calls[-1].texts == ["refund rounding"]
    assert embedder.id == f"vertex:gemini-embedding-001/{DIMS}"
    assert embedder.embed_documents([]).shape == (0, DIMS)


def test_vertex_retry_policy() -> None:
    # 429, 5xx and timeouts are retried three times with a doubling delay; a 400 is not retried at all
    slept: list[float] = []
    genai = FakeGenai(script=[api_error(503, "UNAVAILABLE")] * 4)
    embedder = VertexEmbedder(cloud_cfg(), client=genai, sleep=slept.append, jitter=lambda: 0.0)
    with pytest.raises(errors.ServerError):
        embedder.embed_query("q")
    assert len(genai.calls) == 4 and slept == [1.0, 2.0, 4.0]

    genai = FakeGenai(script=[TimeoutError("read timed out"), api_error(504, "DEADLINE_EXCEEDED")])
    assert VertexEmbedder(cloud_cfg(), client=genai, sleep=no_sleep).embed_query("q").shape == (DIMS,)
    assert len(genai.calls) == 3

    slept.clear()
    genai = FakeGenai(script=[api_error(400, "INVALID_ARGUMENT")])
    with pytest.raises(errors.ClientError):
        VertexEmbedder(cloud_cfg(), client=genai, sleep=slept.append).embed_query("q")
    assert len(genai.calls) == 1 and slept == []


def test_vertex_unavailable_reasons(monkeypatch: pytest.MonkeyPatch) -> None:
    with pytest.raises(CloudUnavailable, match="no project"):
        VertexEmbedder(cloud_cfg(project=None), client=FakeGenai())
    with monkeypatch.context() as patch:
        patch.setitem(sys.modules, "google.genai", None)  # what an install without the extra looks like
        with pytest.raises(CloudUnavailable, match="cloud extra not installed"):
            VertexEmbedder(cloud_cfg())

    short = FakeGenai()
    short.models.embed_content = lambda **_: type("Response", (), {"embeddings": []})()
    with pytest.raises(CloudUnavailable, match="0 vectors for 1 texts"):
        VertexEmbedder(cloud_cfg(), client=short).embed_query("q")


def test_vertex_builds_its_client_on_first_use(monkeypatch: pytest.MonkeyPatch) -> None:
    from google import genai

    built: list[dict] = []

    def fake_client(**kwargs):
        built.append(kwargs)
        return FakeGenai()

    monkeypatch.setattr(genai, "Client", fake_client)
    embedder = VertexEmbedder(cloud_cfg(project="proj", location="europe-west4"))
    assert built == [], "constructing the embedder loads no credentials"

    embedder.embed_query("q")
    embedder.embed_query("q")

    assert built == [{"vertexai": True, "project": "proj", "location": "europe-west4"}]


def test_fake_firestore_models_the_client_surface() -> None:
    """The write path's tests build on the fake too: pin what it promises."""
    from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
    from google.cloud.firestore_v1.vector import Vector

    fs = FakeFirestore()
    fs.add_chunk("a.md", "alpha beta", doc_type="spec")
    fs.add_chunk("b.md", "gamma delta")
    docs = fs.collection("doc_chunks")

    nearest = docs.find_nearest(
        vector_field="embedding",
        query_vector=Vector(unit(text_vector("alpha beta"))),
        limit=2,
        distance_measure=DistanceMeasure.COSINE,
        distance_result_field="vector_distance",
    )
    rows = [snap.to_dict() for snap in nearest.get()]
    assert [r["path"] for r in rows] == ["a.md", "b.md"]
    assert rows[0]["vector_distance"] == pytest.approx(0.0, abs=1e-6) and rows[1]["vector_distance"] > 0.5

    batch = fs.batch()
    batch.set(docs.document("x"), {"v": 1})
    batch.delete(docs.document("a.md__0"))
    assert "x" not in docs.docs, "nothing is written before commit"
    batch.commit()
    assert docs.docs["x"] == {"v": 1} and "a.md__0" not in docs.docs and fs.commit_sizes == [2]

    tx = fs.transaction()
    tx.update(docs.document("x"), {"v": tx.get(docs.document("x")).to_dict()["v"] + 1})
    tx.commit()
    assert docs.docs["x"] == {"v": 2} and fs.calls["transaction_commit"] == 1

    assert [snap.id for snap in docs.stream()] == ["b.md__0", "x"] and fs.calls["stream"] == 1
    assert not docs.document("missing").get().exists


# --- the leg on its own --------------------------------------------------------------------------------


def seed_repo(repo) -> str:
    repo.write(SPEC_PATH, SPEC)
    repo.write(SHIPPING_PATH, SHIPPING)
    repo.write(INVOICES_PATH, INVOICES)
    repo.write("src/refund.py", "def refund_total(lines):\n    return sum(lines)\n")
    return repo.commit("seed")


def seed_chunks(fs: FakeFirestore) -> None:
    fs.add_chunk(SPEC_PATH, SPEC_CHUNK, doc_type="spec", start=10, end=11)
    fs.add_chunk(SHIPPING_PATH, SHIPPING_CHUNK, doc_type="guide")  # no line range: located in the file
    fs.add_chunk(INVOICES_PATH, "text that the file never had", doc_type="guide")  # not found either: 1-1


@dataclass
class Scene:
    repo: object
    stamp: str
    fs: FakeFirestore
    genai: FakeGenai
    leg: CloudLeg
    clock: Clock

    @property
    def root(self) -> Path:
        return self.repo.root


def scene(git_repo, *, chunks: bool = True, **cfg_kw) -> Scene:
    repo = git_repo()
    head = seed_repo(repo)
    fs, genai, clock, cfg = FakeFirestore(), FakeGenai(), Clock(), cloud_cfg(**cfg_kw)
    fs.set_stamp(head)
    if chunks:
        seed_chunks(fs)
    leg = CloudLeg(cfg, VertexEmbedder(cfg, client=genai, sleep=no_sleep), client=fs, clock=clock)
    return Scene(repo, head, fs, genai, leg, clock)


def test_cloud_hits_and_doc_type_prefilter(git_repo) -> None:
    w = scene(git_repo)

    hits, note = w.leg.hits("refund rounding half up nearest cent", ALL | {"docs/other.md"}, w.root, 30)

    assert note is None
    assert hits[0].path == SPEC_PATH, "nearest first"
    assert sorted(h.path for h in hits) == sorted(ALL)
    by_path = {h.path: h for h in hits}
    spec = by_path[SPEC_PATH]
    assert (spec.kind, spec.legs, spec.snippet) == ("doc", ("cloud",), SPEC_CHUNK)
    assert (spec.start_line, spec.end_line) == (10, 11), "the chunk's own line range"
    ship = by_path[SHIPPING_PATH]
    assert (ship.start_line, ship.end_line) == (3, 3), "no range: located in the working tree file"
    inv = by_path[INVOICES_PATH]
    assert (inv.start_line, inv.end_line) == (1, 1), "not found there either: 1-1"
    (query,) = w.fs.vector_queries
    assert query["limit"] == 30 and query["filters"] == [] and query["collection"] == "doc_chunks"
    assert query["distance_result_field"] == "vector_distance"
    assert w.genai.calls[-1].task_type == "RETRIEVAL_QUERY"

    # a chunk of a path outside the allowed set never comes back, whatever the cloud holds
    w.fs.add_chunk("docs/secret.md", SPEC_CHUNK, doc_type="spec", start=1, end=2)
    hits, _ = w.leg.hits("refund rounding", ALL, w.root, 30)
    assert "docs/secret.md" not in {h.path for h in hits}

    # one requested type filters the collection too, by its lowercase name
    w.fs.vector_queries.clear()
    hits, _ = w.leg.hits("refund rounding", ALL, w.root, 30, doc_types=("SPEC",))
    assert [h.path for h in hits] == [SPEC_PATH]
    assert w.fs.vector_queries[0]["filters"] == [("docType", "==", "spec")]
    # several types, or none, do not (the exact filter is the allowed set)
    w.fs.vector_queries.clear()
    hits, _ = w.leg.hits("refund rounding", ALL, w.root, 30, doc_types=("spec", "guide"))
    assert len(hits) == 3 and w.fs.vector_queries[0]["filters"] == []


def test_doc_type_prefilter_falls_back_without_a_prefixed_index(git_repo) -> None:
    w = scene(git_repo)
    w.fs.reject_filtered = FailedPrecondition("The query requires a vector index prefixed by docType")

    hits, note = w.leg.hits("refund rounding", {SPEC_PATH}, w.root, 30, doc_types=("spec",))

    assert note is None and [h.path for h in hits] == [SPEC_PATH]
    assert [q["filters"] for q in w.fs.vector_queries] == [[("docType", "==", "spec")], []]


def test_unusable_line_ranges_are_located_in_the_file(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/crlf.md", "# Crlf\r\n\r\nfirst line\r\nsecond line\r\n")  # CRLF on disk, LF in the cloud's chunk
    repo.write("docs/ranges.md", "# Ranges\n\none\ntwo\nthree\n")
    head = repo.commit("seed")
    fs, cfg = FakeFirestore(), cloud_cfg()
    fs.set_stamp(head)
    fs.add_chunk("docs/crlf.md", "first line\nsecond line")
    fs.add_chunk("docs/ranges.md", "two\nthree", start=0, end=3)  # start below 1
    fs.add_chunk("docs/ranges.md", "one", index=1, start=5, end=2)  # end before start
    fs.add_chunk("docs/ranges.md", "three", index=2, start=4, end=4)  # sane: kept as given
    leg = CloudLeg(cfg, VertexEmbedder(cfg, client=FakeGenai()), client=fs)

    hits, note = leg.hits("one two three first second line", {"docs/crlf.md", "docs/ranges.md"}, repo.root, 30)

    assert note is None
    got = {(h.path, h.snippet): (h.start_line, h.end_line) for h in hits}
    assert got == {
        ("docs/crlf.md", "first line\nsecond line"): (3, 4),
        ("docs/ranges.md", "two\nthree"): (4, 5),
        ("docs/ranges.md", "one"): (3, 3),
        ("docs/ranges.md", "three"): (4, 4),
    }


def test_status_never_streams_collection(git_repo) -> None:
    w = scene(git_repo)

    lines = w.leg.status_lines(w.root)
    w.leg.hits("refund", ALL, w.root, 30)
    w.leg.status_lines(w.root)

    assert w.fs.calls["stream"] == 0
    assert w.fs.calls["document_get"] == 1, "the stamp document is read once and kept"
    assert w.fs.calls["find_nearest"] == 1, "only the search queried the collection"
    assert lines == [
        f"cloud: Firestore p/(default) collection doc_chunks, embedder vertex:gemini-embedding-001/{DIMS}",
        f"cloud: corpus stamp {w.stamp[:7]} (built 2026-01-01T00:00:00Z, mode full)",
        "cloud: base_ref unknown (no origin/HEAD; set cloud.firestore.base_ref)",
        "cloud: 0 branch-changed docs, served by the local index only",
    ]


def test_stamp_is_cached_for_sixty_seconds(git_repo) -> None:
    w = scene(git_repo)
    w.leg.hits("refund", ALL, w.root, 30)
    w.clock.now += 59
    w.leg.hits("refund", ALL, w.root, 30)
    assert w.fs.calls["document_get"] == 1

    w.fs.set_stamp(w.stamp, mode="catch-up")
    w.clock.now += 2
    w.leg.hits("refund", ALL, w.root, 30)

    assert w.fs.calls["document_get"] == 2
    assert w.leg.stamp() == CorpusStamp(
        w.stamp, "2026-01-01T00:00:00Z", "catch-up", f"vertex:gemini-embedding-001/{DIMS}"
    )


def test_status_says_when_the_stamp_embedder_differs(git_repo) -> None:
    w = scene(git_repo)
    w.fs.set_stamp(w.stamp, embedder_id="vertex:text-embedding-004/768")
    assert (
        f"cloud: stamp embedder vertex:text-embedding-004/768 is not this server's vertex:gemini-embedding-001/{DIMS}: "
        "query vectors may not match the collection's"
    ) in w.leg.status_lines(w.root)


def test_status_stamp_relation_to_base_ref(git_repo) -> None:
    repo = git_repo()
    first = seed_repo(repo)
    repo.write("docs/two.md", "# Two\n")
    repo.commit("two")
    repo.write("docs/three.md", "# Three\n")
    third = repo.commit("three")
    repo.git("checkout", "-q", "-b", "side", first)
    repo.write("docs/side.md", "# Side\n")
    side = repo.commit("side")
    repo.git("checkout", "-q", "main")

    def relation(stamp: str, base_ref: str = "main") -> str:
        fs, cfg = FakeFirestore(), cloud_cfg(base_ref=base_ref)
        fs.set_stamp(stamp)
        leg = CloudLeg(cfg, VertexEmbedder(cfg, client=FakeGenai()), client=fs)
        (line,) = [x for x in leg.status_lines(repo.root) if x.startswith("cloud: stamp is") or "base_ref" in x]
        return line

    assert relation(third) == "cloud: stamp is current with main"
    assert relation(first) == "cloud: stamp is behind main by 2"
    assert relation(side) == "cloud: stamp is not an ancestor of main"
    assert relation(first, "origin/gone") == "cloud: base_ref origin/gone not found here (git fetch)"
    assert resolve_base_ref(repo.root, "release") == "release"
    assert resolve_base_ref(repo.root, None) is None, "this repository has no origin/HEAD"


# --- the leg inside the searcher -----------------------------------------------------------------------


@dataclass
class World:
    """A repository with its local index built once, and a searcher per cloud leg tried against it."""

    repo: object
    cfg: Config
    pool: IndexPool
    corpus: Corpus
    clock: Clock

    def leg(self, fs: FakeFirestore, *, genai: FakeGenai | None = None, embedder=None) -> CloudLeg:
        cloud = cloud_cfg()
        embedder = embedder or VertexEmbedder(cloud, client=genai or FakeGenai(), sleep=no_sleep)
        return CloudLeg(cloud, embedder, client=fs, corpus_for=lambda top: self.corpus, clock=self.clock)

    def search(self, leg: CloudLeg, query: str, **kw) -> SearchResponse:
        info = RepoInfo(top=self.repo.root, common_dir=self.repo.root / ".git")
        searcher = Searcher(self.cfg, info, self.pool, lambda top: self.corpus, cloud=leg)
        result = searcher.search(SearchRequest(query=query, **kw), self.repo.root)
        assert isinstance(result, SearchResponse), result
        return result


def make_world(repo, tiny_model: str, **sections) -> World:
    raw = {"docs": {"model": tiny_model}, "code": {"model": tiny_model}, **sections}
    repo.write("docs/search/config.json", json.dumps(raw))
    cfg = load_config(repo.root, {})
    assert cfg is not None
    pool = IndexPool(cfg)
    assert isinstance(pool.get(repo.root, wait_s=30), WorktreeIndexes)  # no build thread outlives the test
    return World(repo, cfg, pool, Corpus(repo.root, cfg, DocIndex(repo.root)), Clock())


def test_branch_changed_paths_suppressed(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    stamp = seed_repo(repo)
    fs = FakeFirestore()
    fs.set_stamp(stamp)
    seed_chunks(fs)
    fs.add_chunk("docs/draft.md", "The draft refund policy.")  # the cloud holds an older copy of a doc...
    repo.write("docs/draft.md", "# Draft\n\nThe draft refund policy.\n")  # ...that is untracked in this worktree
    repo.write(SHIPPING_PATH, SHIPPING + "\nShipping is free over a threshold.\n")  # edited, not committed
    repo.write(INVOICES_PATH, INVOICES + "\nInvoices are numbered.\n")
    repo.git("add", INVOICES_PATH)
    repo.git("commit", "-q", "-m", "edit invoices")  # edited and committed since the stamp
    w = make_world(repo, tiny_model)
    leg = w.leg(fs)

    query = "refund rounding shipping fee invoice draft policy"
    resp = w.search(leg, query, scope="docs", limit=10)
    by_path = {h.path: h for h in resp.hits}

    assert by_path[SPEC_PATH].legs == ("docs", "cloud"), "unchanged since the stamp: both legs found it"
    for changed in (SHIPPING_PATH, INVOICES_PATH, "docs/draft.md"):
        assert by_path[changed].legs == ("docs",), f"{changed} differs from the stamp: only the local leg serves it"
    assert resp.header.notes == ()
    hits, note = leg.hits(query, set(by_path), repo.root, 30)
    assert note is None and [h.path for h in hits] == [SPEC_PATH]

    # status counts the docs among the changes (a changed code file is not one)
    repo.write("src/refund.py", "def refund_total(lines):\n    return 0\n")
    w.clock.now += 10  # past the branch-changed cache
    assert "cloud: 3 branch-changed docs, served by the local index only" in leg.status_lines(repo.root)


def test_cloud_failure_degrades_to_local(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    head = seed_repo(repo)
    w = make_world(repo, tiny_model)
    fs = FakeFirestore()
    fs.set_stamp(head)
    seed_chunks(fs)
    local = [h.path for h in w.search(w.leg(FakeFirestore()), "refund rounding", scope="docs").hits]
    assert local

    # a collection that was never indexed has no stamp: the leg is skipped
    resp = w.search(w.leg(FakeFirestore()), "refund rounding", scope="docs")
    assert resp.header.notes == ("cloud skipped: no corpus stamp (corpus_meta/index)",)

    # no credentials: the embedder cannot run, and the local hits are the answer
    leg = w.leg(fs, embedder=RaisingEmbedder(CloudUnavailable("no credentials")))
    resp = w.search(leg, "refund rounding", scope="docs")
    assert [h.path for h in resp.hits] == local
    assert all(h.legs == ("docs",) for h in resp.hits)
    assert resp.header.notes == ("cloud failed: no credentials",)

    # a stamp commit that was never fetched here
    fs.set_stamp("deadbeef" * 5)
    genai = FakeGenai()
    leg = w.leg(fs, genai=genai)
    resp = w.search(leg, "refund rounding", scope="docs")
    assert [h.path for h in resp.hits] == local
    assert resp.header.notes == ("cloud skipped: stamp deadbee not fetched",)
    assert genai.calls == [], "no query is embedded for a leg that is skipped"
    assert leg.status_lines(repo.root)[-1] == (
        "cloud: stamp commit deadbee is not fetched in this worktree: git fetch, then retry "
        "(the cloud leg is skipped until then)"
    )

    # any other failure of the cloud is one line, whatever it says
    fs.set_stamp(head)
    fs.fail["find_nearest"] = RuntimeError("deadline exceeded\nafter 60s")
    resp = w.search(w.leg(fs), "refund rounding", scope="docs")
    assert [h.path for h in resp.hits] == local
    assert resp.header.notes == ("cloud failed: RuntimeError: deadline exceeded after 60s",)

    # a stamp that cannot be read
    fs.fail.clear()
    fs.fail["document_get"] = ConnectionError("unreachable")
    leg = w.leg(fs)
    assert w.search(leg, "refund rounding", scope="docs").header.notes == (
        "cloud failed: ConnectionError: unreachable",
    )
    assert leg.status_lines(repo.root)[-1] == "cloud: corpus stamp unreadable (ConnectionError: unreachable)"


class RaisingEmbedder:
    id = "vertex:test/1"

    def __init__(self, err: Exception) -> None:
        self.err = err

    def embed_query(self, text: str):
        raise self.err


def test_cloud_leg_fused_in_docs(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed_repo(repo)
    fs = FakeFirestore()
    # the cloud knows the spec and a doc the local index has never seen; only the local legs know shipping
    fs.add_chunk(SPEC_PATH, SPEC_CHUNK, doc_type="spec", start=10, end=11)
    fs.add_chunk("docs/cloud-only.md", "refund rounding policy of the cloud", doc_type="guide", start=3, end=3)
    w = make_world(repo, tiny_model, search={"rescan_seconds": 3600})  # the index is not refreshed under the test
    repo.write("docs/cloud-only.md", "# Cloud only\n\nrefund rounding policy of the cloud\n")
    fs.set_stamp(repo.commit("add cloud-only"))  # in the stamp, so not branch-changed
    leg = w.leg(fs)

    resp = w.search(leg, "refund rounding shipping", scope="docs", limit=10)
    by_path = {h.path: h for h in resp.hits}

    assert by_path["docs/cloud-only.md"].legs == ("cloud",), "found by the cloud alone"
    assert by_path["docs/cloud-only.md"].snippet == "refund rounding policy of the cloud"
    assert by_path[SHIPPING_PATH].legs == ("docs",), "found by the local leg alone"
    assert by_path[SPEC_PATH].legs == ("docs", "cloud")
    assert resp.hits[0].path == SPEC_PATH, "the doc both legs found ranks first"
    assert resp.header.notes == ()

    # the request's doc_type reaches the collection query as a docType filter
    fs.vector_queries.clear()
    w.search(leg, "refund rounding", scope="docs", doc_type=("spec",))
    assert fs.vector_queries[0]["filters"] == [("docType", "==", "spec")]


def test_client_construction_failure_is_remembered(git_repo, monkeypatch: pytest.MonkeyPatch) -> None:
    from google.auth.exceptions import DefaultCredentialsError
    from google.cloud import firestore

    built: list[dict] = []

    def no_credentials(**kwargs):
        built.append(kwargs)
        raise DefaultCredentialsError("Your default credentials were not found.")

    monkeypatch.setattr(firestore, "Client", no_credentials)
    repo = git_repo()
    seed_repo(repo)
    clock, cfg = Clock(), cloud_cfg()
    leg = CloudLeg(cfg, VertexEmbedder(cfg, client=FakeGenai()), clock=clock)
    assert built == [], "nothing is built (so no credential probe starts) before the first query"

    note = "cloud failed: no credentials (run gcloud auth application-default login)"
    assert leg.hits("refund", ALL, repo.root, 30) == ([], note)
    assert leg.hits("refund", ALL, repo.root, 30) == ([], note)
    assert built == [{"project": "p", "database": "(default)"}], "the failure is not retried at once"
    clock.now += 301
    assert leg.hits("refund", ALL, repo.root, 30) == ([], note)
    assert len(built) == 2


# --- building the leg for the server ---------------------------------------------------------------------


def test_build_cloud_leg_makes_no_client(monkeypatch: pytest.MonkeyPatch) -> None:
    from google import genai
    from google.cloud import firestore

    def boom(**kwargs):
        raise AssertionError("a client was built while constructing the leg")

    monkeypatch.setattr(genai, "Client", boom)
    monkeypatch.setattr(firestore, "Client", boom)

    assert isinstance(build_cloud_leg(cloud_cfg()), CloudLeg)

    with monkeypatch.context() as patch:
        patch.setitem(sys.modules, "google.cloud.firestore", None)
        gone = build_cloud_leg(cloud_cfg())
    assert isinstance(gone, DegradedLeg) and "cloud extra not installed" in gone.reason
    cfg = cloud_cfg()
    no_project = build_cloud_leg(replace(cfg, firestore=replace(cfg.firestore, project=None)))
    assert isinstance(no_project, DegradedLeg) and "cloud.firestore.project" in no_project.reason
