"""The searcher: legs, filters, enrichment, fusion and the one-line answers, on real semble (tiny model)."""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

import pytest
from semble import ContentType, SembleIndex

from doc_search.config import Config, load_config
from doc_search.corpus import Corpus
from doc_search.docindex import DocIndex
from doc_search.engines import Building, IndexPool, WorktreeIndexes
from doc_search.render import render_search
from doc_search.repo import GitError, RepoInfo
from doc_search.searcher import Searcher, model_label
from doc_search.transformer import TransformerSpec
from doc_search.types import Hit, SearchRequest, SearchResponse
from fakes_transformer import fake_encoder, release_builds, wait_until

SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

## Rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

OTHER_SPEC = """# Invoices

Invoice rules for the payment service, INV-005. An invoice total is the sum of the line amounts.
"""

SHIPPING = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''

SHIPPING_PY = '''def shipping_fee(order):
    """A flat rate per order."""
    return order.rate
'''


def seed(repo) -> None:
    repo.write("docs/specs/SPEC-PAY-004.md", SPEC)
    repo.write("docs/specs/SPEC-PAY-005.md", OTHER_SPEC)
    repo.write("docs/shipping.md", SHIPPING)
    repo.write("src/refund.py", REFUND_PY)
    repo.write("src/shipping.py", SHIPPING_PY)
    repo.write(
        "docs/.doc-index.json",
        json.dumps({"version": 3, "docs": {"docs/specs/SPEC-PAY-004.md": {"code_refs": ["src/refund.py"]}}}),
    )
    repo.commit("seed")


def make_cfg(repo, tiny_model: str, **sections) -> Config:
    raw = {"docs": {"model": tiny_model}, "code": {"model": tiny_model}}
    for key, value in sections.items():
        raw[key] = {**raw.get(key, {}), **value}
    repo.write("docs/search/config.json", json.dumps(raw))
    cfg = load_config(repo.root, {})
    assert cfg is not None
    return cfg


class FakeClock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


@dataclass
class World:
    repo: object
    cfg: Config
    pool: IndexPool
    searcher: Searcher
    corpus: Corpus

    def search(self, query: str, **kw) -> SearchResponse:
        result = self.searcher.search(SearchRequest(query=query, **kw), self.repo.root)
        assert isinstance(result, SearchResponse), result
        return result


def make_world(
    repo, tiny_model: str, *, cloud=None, build: bool = True, corpus_cls=Corpus, clock=None, **sections
) -> World:
    cfg = make_cfg(repo, tiny_model, **sections)
    pool = IndexPool(cfg)
    corpus = corpus_cls(repo.root, cfg, DocIndex(repo.root))
    if build:
        assert isinstance(pool.get(repo.root, wait_s=30), WorktreeIndexes)  # no build thread outlives the test
    extra = {"clock": clock} if clock else {}
    searcher = Searcher(
        cfg, RepoInfo(top=repo.root, common_dir=repo.root / ".git"), pool, lambda top: corpus, cloud=cloud, **extra
    )
    return World(repo, cfg, pool, searcher, corpus)


def paths(resp: SearchResponse, kind: str | None = None) -> list[str]:
    return [hit.path for hit in resp.hits if kind is None or hit.kind == kind]


# --- legs and enrichment -------------------------------------------------------------------------


def test_scope_all_returns_both_kinds_with_links(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)

    resp = world.search("refund rounding total")

    by_path = {hit.path: hit for hit in resp.hits}
    doc = by_path["docs/specs/SPEC-PAY-004.md"]
    assert doc.kind == "doc"
    assert doc.doc_type == "spec" and doc.status == "accepted"
    assert doc.heading_path[0] == "Refunds"
    assert doc.links == ("src/refund.py",)
    assert doc.legs == ("docs",)
    code = by_path["src/refund.py"]
    assert code.kind == "code"
    assert code.links == ("docs/specs/SPEC-PAY-004.md",)
    # a code hit is not a doc: no doc metadata, whatever the file looks like
    assert code.doc_type is None and code.status is None and code.heading_path == ()
    assert by_path["src/shipping.py"].links == ()
    # the header
    assert resp.header.docs_model == Path(tiny_model).name
    assert resp.header.code == IndexPool.semble_version()
    assert resp.header.cloud is None and resp.header.notes == () and not resp.header.truncated
    text = render_search(resp)
    assert text.splitlines()[0].startswith(f"doc-search · docs: semble {Path(tiny_model).name} · code: semble ")


@pytest.mark.parametrize(
    ("model", "label"),
    [
        ("transformer:gte-modernbert-base@e7f32e3c00f9", "transformer:gte-modernbert-base"),
        ("transformer:gte-modernbert-base", "transformer:gte-modernbert-base"),
        ("minishlab/potion-base-8M", "potion-base-8M"),
        ("/models/tiny/", "tiny"),
    ],
)
def test_model_label(model: str, label: str) -> None:
    assert model_label(model) == label


def test_model_label_of_the_default_model(tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SEMBLE_MODEL_NAME", tiny_model)  # semble's default model, as `resolve_model_name` reads it
    assert model_label(None) == Path(tiny_model).name


def test_identifier_query_hits_doc(git_repo, tiny_model: str) -> None:
    # semble's BM25 tokenizer keeps only tokens that start with a letter: SPEC-PAY-004 is "spec" and
    # "pay" to it, so the one doc that spells them out is the lexical match (the digits are lost)
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)

    resp = world.search("SPEC-PAY-004", scope="docs", limit=3)

    assert resp.hits[0].path == "docs/specs/SPEC-PAY-004.md"
    assert all(hit.kind == "doc" for hit in resp.hits)


def test_scope_docs_and_scope_code_return_one_kind(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)

    docs = world.search("refund rounding total", scope="docs")
    assert docs.hits and {hit.kind for hit in docs.hits} == {"doc"}
    code = world.search("refund rounding total", scope="code")
    assert code.hits and {hit.kind for hit in code.hits} == {"code"}
    assert code.hits[0].path == "src/refund.py"


def test_long_doc_collapses_to_its_best_chunk(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    sections = "\n".join(f"## Part {i}\n\n" + "refund rounding line amount total. " * 12 for i in range(8))
    repo.write("docs/guides/long.md", "# Long guide\n\n" + sections)
    repo.commit("long")
    world = make_world(repo, tiny_model)

    resp = world.search("refund rounding line amount", scope="docs", limit=10)

    long_hits = [hit for hit in resp.hits if hit.path == "docs/guides/long.md"]
    assert len(long_hits) == 1, "one hit per file"
    assert long_hits[0].more_in_file >= 1
    assert len(set(paths(resp))) == len(resp.hits)
    assert long_hits[0].heading_path[0] == "Long guide"
    assert long_hits[0].doc_type == "guide"


def test_limit_is_clamped(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    assert len(world.search("refund", scope="docs", limit=0).hits) == 1
    assert len(world.search("refund", scope="docs", limit=-4).hits) == 1
    assert len(world.search("refund", scope="docs", limit=500).hits) == 3  # all three docs, far below 50


# --- filters ---------------------------------------------------------------------------------------


def test_filters_are_exact(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    for i in range(12):
        status = "deprecated" if i < 8 else "accepted"
        body = f"---\nstatus: {status}\n---\n# Policy {i}\n\nrefund rounding policy for order {i}.\n"
        repo.write(f"docs/pol{i:02d}.md", body)
    repo.write("src/a.py", "x = 1\n")
    repo.commit("policies")
    world = make_world(repo, tiny_model)

    live = world.search("refund rounding policy", scope="docs", limit=5)
    assert len(live.hits) == 4
    assert all(hit.status == "accepted" for hit in live.hits)

    everything = world.search("refund rounding policy", scope="docs", limit=5, include_terminal=True)
    assert len(everything.hits) == 5


def test_doc_type_and_path_prefix_filters(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)

    specs = world.search("payment service", scope="docs", doc_type=("spec",))
    assert sorted(paths(specs)) == ["docs/specs/SPEC-PAY-004.md", "docs/specs/SPEC-PAY-005.md"]
    one = world.search("payment service", scope="docs", path_prefix="docs/specs/SPEC-PAY-005")
    assert paths(one) == ["docs/specs/SPEC-PAY-005.md"]


def test_path_prefix_also_limits_code(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("lib/refund_helper.py", "def helper(refund):\n    return refund\n")
    repo.commit("lib")
    world = make_world(repo, tiny_model)

    resp = world.search("refund", path_prefix="lib/")
    assert paths(resp) == ["lib/refund_helper.py"]
    # a prefix that matches no indexed file is an empty answer, not an unfiltered one
    assert world.search("refund", path_prefix="nowhere/").hits == []


def test_empty_allowed_set_returns_no_docs(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    """Review focus 1: semble drops its filter when none of the given paths is indexed, so never call it."""
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    calls: list[tuple[frozenset, object]] = []
    original = SembleIndex.search

    def spy(self, query, *args, **kwargs):
        calls.append((frozenset(self.content), kwargs.get("filter_paths")))
        return original(self, query, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", spy)

    resp = world.search("refund rounding", doc_type=("adr",))

    assert paths(resp, "doc") == []
    assert paths(resp, "code"), "the code leg still answers"
    assert [content for content, _ in calls] == [frozenset({ContentType.CODE})], "the docs index was searched"

    calls.clear()
    docs_only = world.search("refund rounding", scope="docs", doc_type=("adr",))
    assert docs_only.hits == [] and calls == []


def test_allowed_but_not_indexed_calls_no_docs_search(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A corpus file semble's docs index lacks leaves nothing to filter on: still no call."""
    repo = git_repo()
    seed(repo)
    repo.write("docs/wire.jsx", "export const wire = () => refund;\n")
    repo.commit("jsx")
    world = make_world(repo, tiny_model, docs={"include": ["docs/**/*.md", "docs/**/*.jsx"]})
    assert "docs/wire.jsx" not in world.pool.indexed_files(repo.root, "docs")
    calls = []
    original = SembleIndex.search

    def spy(self, query, *args, **kwargs):
        calls.append(frozenset(self.content))
        return original(self, query, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", spy)

    resp = world.search("wire refund", path_prefix="docs/wire")

    assert frozenset({ContentType.DOCS}) not in calls
    assert paths(resp) == ["docs/wire.jsx"]


def test_code_hit_under_corpus_becomes_doc(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/wire.jsx", "export const wire = () => refund;\n")
    repo.commit("jsx")
    world = make_world(
        repo,
        tiny_model,
        docs={"include": ["docs/**/*.md", "docs/**/*.jsx"], "types": [{"glob": "docs/wire.jsx", "type": "ui"}]},
    )

    resp = world.search("wire refund")

    wire = [hit for hit in resp.hits if hit.path == "docs/wire.jsx"]
    assert len(wire) == 1
    assert wire[0].kind == "doc"
    assert wire[0].doc_type == "ui"
    assert wire[0].legs == ("code",)
    assert wire[0].heading_path == ("wire",)

    # filtered out of the docs: dropped, not shown as code
    other_type = world.search("wire refund", doc_type=("spec",))
    assert "docs/wire.jsx" not in paths(other_type)
    # scope=code is code only
    assert "docs/wire.jsx" not in paths(world.search("wire refund", scope="code"))


def test_scope_code_off_one_line(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model, code={"enabled": False})

    answer = world.searcher.search(SearchRequest(query="refund", scope="code"), repo.root)
    assert answer == "doc-search: code search is off (code.enabled is false)"

    resp = world.search("refund")
    assert resp.header.code == "off"
    assert paths(resp, "code") == [] and paths(resp, "doc")
    assert resp.header.notes == ()


def test_code_index_failure_is_off_with_the_reason(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model, code={"model": str(repo.root / "no-such-model")})

    answer = world.searcher.search(SearchRequest(query="refund", scope="code"), repo.root)
    assert isinstance(answer, str) and answer.startswith("doc-search: code search is off (index failed: ")
    resp = world.search("refund")
    assert resp.header.code == "off"
    assert paths(resp, "doc")
    assert len(resp.header.notes) == 1 and resp.header.notes[0].startswith("code index unavailable (")


def test_docs_index_failure(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model, docs={"model": str(repo.root / "no-such-model")})

    answer = world.searcher.search(SearchRequest(query="refund", scope="docs"), repo.root)
    assert isinstance(answer, str) and answer.startswith("doc-search: docs search is off (index failed: ")
    resp = world.search("refund")  # scope=all answers from the code half
    assert paths(resp, "doc") == [] and paths(resp, "code")
    assert resp.header.notes[0].startswith("docs index unavailable (")


# --- one-line answers -----------------------------------------------------------------------------


class FakePool:
    """A pool that answers what the test says."""

    def __init__(self, answer, docs=frozenset(), code=frozenset()) -> None:
        self.answer = answer
        self.waits: list[float] = []
        self._files = {"docs": set(docs), "code": set(code)}

    def get(self, worktree, wait_s: float = 20.0):
        self.waits.append(wait_s)
        return self.answer

    def indexed_files(self, worktree, kind):
        return set(self._files[kind])

    @staticmethod
    def semble_version() -> str:
        return "9.9.9"


def stub_searcher(cfg: Config, repo, pool, **kw) -> Searcher:
    corpus = Corpus(repo.root, cfg, DocIndex(repo.root))
    return Searcher(cfg, RepoInfo(top=repo.root, common_dir=repo.root / ".git"), pool, lambda top: corpus, **kw)


@pytest.mark.parametrize("scope", ["all", "docs"])
def test_building_returns_line(git_repo, tiny_model: str, scope: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    pool = FakePool(Building(repo.root, docs_ready=False, code_ready=True))
    searcher = stub_searcher(cfg, repo, pool)

    answer = searcher.search(SearchRequest(query="refund", scope=scope), repo.root)

    assert answer == f"doc-search: index building for {repo.root} (docs building, code ready); retry shortly"
    assert pool.waits == [20.0], "a first build is waited for 20 seconds"


def test_building_line_names_each_half(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    done = WorktreeIndexes()  # the docs half is done, but holds no index: it failed
    done.error["docs"] = "boom"
    pool = FakePool(Building(repo.root, docs_ready=True, code_ready=False, partial=done))
    answer = stub_searcher(cfg, repo, pool).search(SearchRequest(query="refund"), repo.root)
    assert answer == f"doc-search: index building for {repo.root} (docs ready, code building); retry shortly"

    pool = FakePool(Building(repo.root, docs_ready=False, code_ready=False))
    answer = stub_searcher(cfg, repo, pool).search(SearchRequest(query="refund", scope="code"), repo.root)
    assert answer == f"doc-search: index building for {repo.root} (docs building, code building); retry shortly"


def test_scope_code_needs_the_code_index_not_the_docs(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    only_docs = WorktreeIndexes()  # no real index needed: the answer is decided before a search
    pool = FakePool(Building(repo.root, docs_ready=True, code_ready=False, partial=only_docs))
    answer = stub_searcher(cfg, repo, pool).search(SearchRequest(query="refund", scope="code"), repo.root)
    assert answer == f"doc-search: index building for {repo.root} (docs ready, code building); retry shortly"


def test_partial_answers_from_the_ready_half(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)
    original = SembleIndex.from_path
    gate = threading.Event()  # the code build waits here

    def gated_code(cls, path, content=(), *args, **kwargs):
        if ContentType.CODE in (content if isinstance(content, (list, tuple)) else [content]):
            gate.wait(30)
        return original(path, content, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(gated_code))
    pool = IndexPool(cfg)
    corpus = Corpus(repo.root, cfg, DocIndex(repo.root))
    searcher = Searcher(
        cfg, RepoInfo(top=repo.root, common_dir=repo.root / ".git"), pool, lambda top: corpus, wait_s=0.2
    )
    try:
        deadline = time.monotonic() + 30
        got = pool.get(repo.root, wait_s=0)
        while isinstance(got, Building) and not got.docs_ready and time.monotonic() < deadline:
            got = pool.get(repo.root, wait_s=0.2)
        assert isinstance(got, Building) and got.docs_ready

        resp = searcher.search(SearchRequest(query="refund rounding"), repo.root)
        assert isinstance(resp, SearchResponse)
        assert paths(resp, "doc") and paths(resp, "code") == []
        assert resp.header.notes == ("code index building",)
        assert "note: code index building" in render_search(resp).splitlines()

        docs_only = searcher.search(SearchRequest(query="refund rounding", scope="docs"), repo.root)
        assert isinstance(docs_only, SearchResponse) and docs_only.header.notes == ()

        answer = searcher.search(SearchRequest(query="refund rounding", scope="code"), repo.root)
        assert answer == f"doc-search: index building for {repo.root} (docs ready, code building); retry shortly"
    finally:
        gate.set()  # let the build finish inside this test, so no thread outlives it
    assert isinstance(pool.get(repo.root, wait_s=30), WorktreeIndexes)
    full = searcher.search(SearchRequest(query="refund rounding"), repo.root)
    assert isinstance(full, SearchResponse) and paths(full, "code") and full.header.notes == ()


def test_invalid_requests_are_one_line(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    run = lambda **kw: world.searcher.search(SearchRequest(**kw), repo.root)  # noqa: E731
    assert run(query="   ") == "doc-search: invalid request: query is empty"
    assert run(query="x", scope="everything") == (
        "doc-search: invalid request: scope must be all, docs or code (got 'everything')"
    )


def test_git_failure_is_one_line(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cfg = make_cfg(repo, tiny_model)

    class Broken(Corpus):
        def files(self):
            raise GitError("git ls-files failed (128): not a git repository")

        def allowed(self, *args, **kwargs):
            raise GitError("git ls-files failed (128): not a git repository")

    world = make_world(repo, tiny_model, corpus_cls=Broken)
    answer = world.searcher.search(SearchRequest(query="refund", scope="docs"), repo.root)
    assert answer == "doc-search: git failed: git ls-files failed (128): not a git repository"
    assert cfg is not None


# --- the cloud leg ------------------------------------------------------------------------------


@dataclass
class FakeCloud:
    answer: list[Hit] = field(default_factory=list)
    note: str | None = None
    raises: Exception | None = None
    calls: list[tuple] = field(default_factory=list)
    doc_types: list[tuple[str, ...]] = field(default_factory=list)

    def hits(
        self, query: str, allowed: set[str], worktree: Path, limit: int, doc_types: tuple[str, ...] = ()
    ) -> tuple[list[Hit], str | None]:
        self.calls.append((query, set(allowed), worktree, limit))
        self.doc_types.append(tuple(doc_types))
        if self.raises:
            raise self.raises
        return list(self.answer), self.note


def test_git_failure_with_multiline_stderr_is_one_line(git_repo, tiny_model: str) -> None:
    """git's stderr can hold several lines (`fatal:` and `hint:`); the answer stays one line."""
    repo = git_repo()
    seed(repo)

    class Broken(Corpus):
        def files(self):
            raise GitError("git ls-files failed (128): fatal: not a git repository\nhint: run it in a work tree")

        def allowed(self, *args, **kwargs):
            raise GitError("git ls-files failed (128): fatal: not a git repository\nhint: run it in a work tree")

    world = make_world(repo, tiny_model, corpus_cls=Broken)
    answer = world.searcher.search(SearchRequest(query="refund", scope="docs"), repo.root)
    assert answer == (
        "doc-search: git failed: git ls-files failed (128): fatal: not a git repository hint: run it in a work tree"
    )


def cloud_hit(path: str, start: int = 1, end: int = 5, **kw) -> Hit:
    text = f"cloud text of {path}"
    return Hit(kind="doc", path=path, start_line=start, end_line=end, snippet=text, legs=("cloud",), **kw)


def test_cloud_leg_is_fused_filtered_and_noted(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    plain = make_world(repo, tiny_model)
    base = plain.search("shipping fee flat rate", scope="docs", limit=10)
    first, last = base.hits[0], base.hits[-1]
    assert last.path != first.path
    # the cloud finds the file the local docs leg ranks LAST, in a chunk with other lines (its chunker
    # cuts differently), and one path the filters forbid
    remote = replace(last, start_line=100, end_line=130, snippet="remote copy", legs=("cloud",))
    cloud = FakeCloud(
        answer=[cloud_hit("docs/not-allowed.md"), remote],
        note="cloud leg skipped 3 branch-changed paths",
    )
    world = make_world(repo, tiny_model, cloud=cloud)

    resp = world.search("shipping fee flat rate", scope="docs", limit=10)

    assert [call[0] for call in cloud.calls] == ["shipping fee flat rate"]
    _, allowed, worktree, fetch = cloud.calls[0]
    assert allowed == {"docs/specs/SPEC-PAY-004.md", "docs/specs/SPEC-PAY-005.md", "docs/shipping.md"}
    assert worktree == repo.root and fetch == 30  # limit x 3
    assert cloud.doc_types == [()], "the request's own doc_type filter goes along (none here)"
    assert "docs/not-allowed.md" not in paths(resp)
    assert len(set(paths(resp))) == len(resp.hits)
    # both legs name the file, so it climbs above the files only the docs leg found
    assert resp.hits[0].path == last.path
    assert resp.hits[0].legs == ("docs", "cloud")
    assert (resp.hits[0].start_line, resp.hits[0].snippet) == (last.start_line, last.snippet), "the local chunk wins"
    assert resp.hits[0].more_in_file == last.more_in_file
    assert resp.header.notes == ("cloud leg skipped 3 branch-changed paths",)
    assert resp.header.cloud == "cloud"  # no cloud config: the label is generic
    assert render_search(resp).splitlines()[0].count("(+cloud: cloud)") == 1


def test_cloud_hits_are_enriched_like_local_ones(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cloud = FakeCloud(answer=[cloud_hit("docs/new.md", 5, 6), cloud_hit("docs/specs/SPEC-PAY-004.md", 8, 11)])
    world = make_world(repo, tiny_model, cloud=cloud, code={"enabled": False}, search={"rescan_seconds": 3600})
    # a doc the local index has not seen yet: only the cloud leg can name it
    repo.write("docs/new.md", "# New doc\n\n## Section\n\nbody text of the new doc\n")

    resp = world.search("zzz unmatched words", scope="docs", limit=10)

    new = next(h for h in resp.hits if h.path == "docs/new.md")
    assert new.legs == ("cloud",)
    assert new.heading_path == ("New doc", "Section")
    assert new.doc_type == "other" and new.status is None and new.links == ()
    assert new.snippet == "cloud text of docs/new.md", "the cloud text is kept when only the cloud has the chunk"
    spec = next(h for h in resp.hits if h.path == "docs/specs/SPEC-PAY-004.md")
    assert spec.doc_type == "spec" and spec.status == "accepted" and spec.links == ("src/refund.py",)


def test_cloud_failure_is_a_note_not_an_error(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cloud = FakeCloud(raises=RuntimeError("boom"))
    world = make_world(repo, tiny_model, cloud=cloud)

    resp = world.search("refund")

    assert paths(resp)
    assert resp.header.notes == ("cloud leg failed (RuntimeError)",)


def test_cloud_not_called_when_nothing_is_allowed_or_for_code(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    cloud = FakeCloud()
    world = make_world(repo, tiny_model, cloud=cloud)
    world.search("refund", scope="code")
    world.search("refund", doc_type=("adr",))
    assert cloud.calls == []


@dataclass
class SlowCloud(FakeCloud):
    """A cloud leg that takes `delay` seconds to answer, and says when it was asked."""

    delay: float = 0.5
    asked: threading.Event = field(default_factory=threading.Event)
    threads: list[str] = field(default_factory=list)

    def hits(self, query, allowed, worktree, limit, doc_types=()):
        self.asked.set()
        self.threads.append(threading.current_thread().name)
        time.sleep(self.delay)
        return super().hits(query, allowed, worktree, limit, doc_types)


def slow_local_search(monkeypatch: pytest.MonkeyPatch, delay: float, *, before=None) -> None:
    """Every semble search (the docs and code legs) takes `delay` seconds longer; `before` runs first."""
    real = SembleIndex.search

    def slow(self, *args, **kwargs):
        if before is not None:
            before()
        time.sleep(delay)
        return real(self, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", slow)


def test_the_cloud_leg_runs_while_the_local_legs_do(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    plain = make_world(repo, tiny_model, code={"enabled": False})
    last = plain.search("shipping fee flat rate", scope="docs", limit=10).hits[-1]
    cloud = SlowCloud(answer=[replace(last, start_line=100, end_line=130, snippet="remote", legs=("cloud",))])
    world = make_world(repo, tiny_model, cloud=cloud, code={"enabled": False})
    slow_local_search(monkeypatch, 0.5)  # the one local leg takes as long as the cloud

    started = time.monotonic()
    resp = world.search("shipping fee flat rate", scope="docs", limit=10)
    took = time.monotonic() - started

    assert 0.5 <= took < 0.9, f"max(local, cloud), not their sum: {took:.2f} s"
    assert resp.hits[0].path == last.path and resp.hits[0].legs == ("docs", "cloud"), "the cloud hits are fused"
    assert cloud.threads == ["doc-search-cloud-leg"], "off the searching thread"


def test_the_cloud_leg_starts_before_the_local_legs(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    seed(repo)
    cloud = SlowCloud(delay=0.0)
    world = make_world(repo, tiny_model, cloud=cloud)
    seen: list[bool] = []
    slow_local_search(monkeypatch, 0.0, before=lambda: seen.append(cloud.asked.wait(2)))

    world.search("shipping fee flat rate", scope="all")

    assert seen and all(seen), "the cloud had been asked by the time each local leg ran"


def test_a_cloud_leg_that_never_answers_is_a_note_after_its_deadline(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    release = threading.Event()

    class Hung:
        def hits(self, query, allowed, worktree, limit, doc_types=()):
            release.wait(30)
            return [cloud_hit("docs/shipping.md")], None

    searcher = Searcher(
        world.cfg,
        RepoInfo(top=repo.root, common_dir=repo.root / ".git"),
        world.pool,
        lambda top: world.corpus,
        cloud=Hung(),
        cloud_wait_s=0.2,
    )
    try:
        started = time.monotonic()
        resp = searcher.search(SearchRequest(query="refund rounding", scope="docs"), repo.root)
        took = time.monotonic() - started
    finally:
        release.set()  # let the abandoned worker finish

    assert isinstance(resp, SearchResponse) and resp.hits, "the local legs answered"
    assert resp.header.notes == ("cloud failed: TimeoutError: no answer within 0.2 s",), "as the leg words its own"
    assert all(hit.legs != ("cloud",) for hit in resp.hits)
    assert took < 5


def test_a_huge_cloud_wait_is_not_an_overflow(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    cloud = FakeCloud(answer=[cloud_hit("docs/shipping.md")])
    searcher = Searcher(
        world.cfg,
        RepoInfo(top=repo.root, common_dir=repo.root / ".git"),
        world.pool,
        lambda top: world.corpus,
        cloud=cloud,
        cloud_wait_s=1e300,  # what a `cloud.timeout_s` of 1e300 amounts to: valid, if absurd
    )

    resp = searcher.search(SearchRequest(query="shipping fee", scope="docs"), repo.root)

    assert isinstance(resp, SearchResponse) and resp.header.notes == ()
    assert "docs/shipping.md" in paths(resp)


def test_the_cloud_wait_follows_the_configured_timeout(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)
    info = RepoInfo(top=repo.root, common_dir=repo.root / ".git")

    def waits(cfg: Config) -> float:
        return Searcher(cfg, info, world.pool, lambda top: world.corpus, cloud=FakeCloud()).cloud_wait_s

    configured = make_cfg(
        repo, tiny_model, cloud={"timeout_s": 12, "vertex": {"project": "p"}, "firestore": {"project": "p"}}
    )
    assert configured.cloud.deadline_s == 17
    # the leg's own deadline (timeout + 5 s) fires first, so its note is the one a search reports
    assert waits(configured) == 18
    assert waits(world.cfg) == 26, "no cloud config: the default timeout"


def test_code_hits_for_a_doc_the_cloud_shows_are_not_repeated(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    for i in range(4):
        repo.write(f"docs/d{i}.md", f"# Doc {i}\n\nrefund rounding {i}.\n")
        repo.write(f"src/c{i}.py", f"def refund_{i}():\n    return {i}\n")
    repo.commit("many")
    cfg = make_cfg(repo, tiny_model)
    docs = FakeIndex([FakeChunk("docs/d0.md", 1, 3, "d0 local")])
    # the code index holds a corpus file: d3 comes back from it too, and only the cloud shows d3 otherwise
    code = FakeIndex([FakeChunk("docs/d3.md", 1, 3, "d3 via code"), FakeChunk("src/c0.py", 1, 2, "c0")])
    cloud = FakeCloud(answer=[cloud_hit("docs/d3.md", 40, 60)])
    searcher = fake_searcher(repo, cfg, docs, code, cloud=cloud)

    resp = searcher.search(SearchRequest(query="refund rounding", limit=10), repo.root)

    assert isinstance(resp, SearchResponse)
    assert paths(resp).count("docs/d3.md") == 1
    d3 = next(h for h in resp.hits if h.path == "docs/d3.md")
    assert d3.legs == ("cloud",) and d3.snippet == "cloud text of docs/d3.md"
    assert "src/c0.py" in paths(resp)


# --- fusion across kinds ----------------------------------------------------------------------------


def test_cloud_docs_dominating_still_leave_room_for_code(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    for i in range(10):
        repo.write(f"docs/d{i}.md", f"# Doc {i}\n\nrefund rounding total amount {i}.\n")
        repo.write(f"src/c{i}.py", f"def refund_total_{i}(amount):\n    return amount\n")
    repo.commit("many")
    plain = make_world(repo, tiny_model)
    local = plain.search("refund rounding total amount", scope="docs", limit=10).hits
    assert len(local) == 10
    # the cloud confirms every local doc chunk: all ten docs now score twice
    cloud = FakeCloud(answer=[replace(hit, legs=("cloud",)) for hit in local])
    world = make_world(repo, tiny_model, cloud=cloud)

    resp = world.search("refund rounding total amount", limit=10)

    assert len(resp.hits) == 10
    assert len(paths(resp, "code")) >= 4  # ceil(10 / 3)
    assert len(paths(resp, "doc")) >= 4


# --- the allowed-set memo ---------------------------------------------------------------------------


class CountingCorpus(Corpus):
    allowed_calls = 0
    phantom: list[str] = []

    def allowed(self, *args, **kwargs):
        type(self).allowed_calls += 1
        return super().allowed(*args, **kwargs)

    def files(self):
        return super().files() + list(self.phantom)


def test_allowed_set_is_memoized(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    clock = FakeClock()
    CountingCorpus.allowed_calls = 0
    world = make_world(repo, tiny_model, corpus_cls=CountingCorpus, clock=clock)
    corpus = world.corpus
    assert isinstance(corpus, CountingCorpus)
    calls = lambda: CountingCorpus.allowed_calls  # noqa: E731

    first = world.search("refund", scope="docs")
    world.search("shipping", scope="docs")
    world.search("refund", scope="all")
    assert calls() == 1, "the same filters are computed once"

    world.search("refund", scope="docs", include_terminal=True)
    assert calls() == 2
    world.search("refund", scope="docs", doc_type=("SPEC",))
    world.search("refund", scope="docs", doc_type=("spec",))
    assert calls() == 3, "doc_type is matched without case, so these share one entry"
    world.search("refund", scope="docs", path_prefix="docs/")
    assert calls() == 4

    clock.now += 4.9
    world.search("refund", scope="docs")
    assert calls() == 4
    clock.now += 0.2  # past search.rescan_seconds (5): a status edit is seen
    world.search("refund", scope="docs")
    assert calls() == 5

    corpus.phantom = ["docs/appeared.md"]  # the listing changed: not served from the memo
    world.search("refund", scope="docs")
    assert calls() == 6
    assert paths(first)  # the memo never changed an answer


def test_status_edit_is_seen_after_the_rescan_interval(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    clock = FakeClock()
    world = make_world(repo, tiny_model, clock=clock)
    assert "docs/shipping.md" in paths(world.search("shipping", scope="docs"))

    repo.write("docs/shipping.md", "---\nstatus: deprecated\n---\n" + SHIPPING)
    clock.now += 6
    assert "docs/shipping.md" not in paths(world.search("shipping", scope="docs"))
    assert "docs/shipping.md" in paths(world.search("shipping", scope="docs", include_terminal=True))


# --- file-level fusion ---------------------------------------------------------------------------------


@dataclass
class FakeChunk:
    file_path: str
    start_line: int
    end_line: int
    content: str


@dataclass
class FakeResult:
    chunk: FakeChunk
    score: float = 0.0


class FakeIndex:
    """A semble-shaped index that answers in a fixed order and records its calls."""

    def __init__(self, chunks: list[FakeChunk]) -> None:
        self.chunks = chunks
        self.calls: list[tuple[str, int, list[str] | None]] = []

    def search(self, query, top_k=10, filter_paths=None, **kwargs):
        self.calls.append((query, top_k, None if filter_paths is None else list(filter_paths)))
        found = [FakeResult(c) for c in self.chunks if filter_paths is None or c.file_path in filter_paths]
        return found[:top_k]


def fake_searcher(repo, cfg: Config, docs: FakeIndex | None, code: FakeIndex | None, **kw) -> Searcher:
    indexes = WorktreeIndexes(docs=docs, code=code)
    pool = FakePool(
        indexes,
        docs={c.file_path for c in docs.chunks} if docs else (),
        code={c.file_path for c in code.chunks} if code else (),
    )
    return stub_searcher(cfg, repo, pool, **kw)


def test_a_long_doc_does_not_push_docs_below_their_fair_share(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    for i in range(10):
        repo.write(f"docs/d{i}.md", f"# Doc {i}\n\nrefund rounding {i}.\n")
        repo.write(f"src/c{i}.py", f"def refund_{i}():\n    return {i}\n")
    repo.commit("many")
    cfg = make_cfg(repo, tiny_model)
    # d0 has three chunks among the top ones: by chunk rank d1 would be 4th and d2 6th
    docs = FakeIndex(
        [
            FakeChunk("docs/d0.md", 1, 3, "d0 a"),
            FakeChunk("docs/d0.md", 4, 6, "d0 b"),
            FakeChunk("docs/d1.md", 1, 3, "d1 a"),
            FakeChunk("docs/d0.md", 7, 9, "d0 c"),
            FakeChunk("docs/d2.md", 1, 3, "d2 a"),
        ]
        + [FakeChunk(f"docs/d{i}.md", 1, 3, f"d{i} a") for i in range(3, 10)]
    )
    code = FakeIndex([FakeChunk(f"src/c{i}.py", 1, 2, f"c{i}") for i in range(10)])
    searcher = fake_searcher(repo, cfg, docs, code)

    resp = searcher.search(SearchRequest(query="refund rounding", limit=10), repo.root)

    assert isinstance(resp, SearchResponse)
    assert paths(resp) == [
        "docs/d0.md", "src/c0.py", "docs/d1.md", "src/c1.py", "docs/d2.md",
        "src/c2.py", "docs/d3.md", "src/c3.py", "docs/d4.md", "src/c4.py",
    ]  # fmt: skip
    assert len(paths(resp, "doc")) == len(paths(resp, "code")) == 5
    assert resp.hits[0].more_in_file == 2 and resp.hits[0].snippet == "d0 a"


def test_cloud_agreement_counts_per_file_in_scope_all(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    for i in range(6):
        repo.write(f"docs/d{i}.md", f"# Doc {i}\n\nrefund rounding {i}.\n")
        repo.write(f"src/c{i}.py", f"def refund_{i}():\n    return {i}\n")
    repo.commit("many")
    cfg = make_cfg(repo, tiny_model)
    docs = FakeIndex([FakeChunk(f"docs/d{i}.md", 1, 3, f"d{i} local") for i in range(6)])
    code = FakeIndex([FakeChunk(f"src/c{i}.py", 1, 2, f"c{i}") for i in range(6)])
    # the cloud's chunk of d3 has other lines than the local one, and its rank is 1
    cloud = FakeCloud(answer=[cloud_hit("docs/d3.md", 40, 60), cloud_hit("docs/d1.md", 70, 90)])
    searcher = fake_searcher(repo, cfg, docs, code, cloud=cloud)

    resp = searcher.search(SearchRequest(query="refund rounding", limit=6), repo.root)

    assert isinstance(resp, SearchResponse)
    docs_hits = [h for h in resp.hits if h.kind == "doc"]
    # d1 (docs rank 2, cloud rank 2: 2/62) and d3 (docs rank 4, cloud rank 1: 1/64 + 1/61) rise above d0 (1/61)
    assert [h.path for h in docs_hits][:3] == ["docs/d1.md", "docs/d3.md", "docs/d0.md"]
    assert {h.path: h.legs for h in docs_hits}["docs/d3.md"] == ("docs", "cloud")
    assert {h.path: h.start_line for h in docs_hits}["docs/d3.md"] == 1, "the local chunk represents the file"


# --- the exact-identifier docs leg ---------------------------------------------------------------------


def write_notes(repo, count: int = 6) -> None:
    for i in range(count):
        repo.write(f"docs/note{i}.md", f"# Note {i}\n\nqueue event handler {i}.\n")


@pytest.mark.parametrize("scope", ["docs", "all"])
@pytest.mark.parametrize("limit", [1, 10])
def test_ident_in_a_filename_only(git_repo, tiny_model: str, scope: str, limit: int) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    repo.write("docs/adr/ADR-114-foo.md", "# Caching decision\n\nWe use a queue for the event handler.\n")
    repo.commit("adr")
    world = make_world(repo, tiny_model)

    resp = world.search("ADR-114", scope=scope, limit=limit)

    assert resp.hits[0].path == "docs/adr/ADR-114-foo.md"
    assert "ident" in resp.hits[0].legs
    assert resp.hits[0].doc_type == "adr"


def test_ident_in_the_title_only(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    repo.write("docs/retention.md", "# SPEC-DATA-005: data retention\n\nWe keep the data for a year.\n")
    repo.write("docs/other.md", "# SPEC-DATA-006: other data\n\nWe keep the data for a year.\n")
    repo.commit("titles")
    world = make_world(repo, tiny_model)

    for limit in (1, 10):
        resp = world.search("spec-data-005", scope="docs", limit=limit)
        assert resp.hits[0].path == "docs/retention.md"
        assert "ident" in resp.hits[0].legs


def test_ident_in_front_matter_only(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    repo.write("docs/items/a.md", "---\nkey: chat-70\nstatus: open\n---\n# Streaming replies\n\nevent handler.\n")
    repo.write("docs/items/b.md", "---\nkey: chat-700\n---\n# Other\n\nevent handler.\n")
    repo.write("docs/items/c.md", "---\nkey: chat-71\n---\n# Another\n\nevent handler.\n")
    repo.commit("items")
    world = make_world(repo, tiny_model)

    resp = world.search("chat-70", scope="docs", limit=1)
    assert [h.path for h in resp.hits] == ["docs/items/a.md"]
    assert "ident" in resp.hits[0].legs
    # equality, not substring: chat-700 and chat-71 are other keys
    everything = world.search("chat-70", scope="docs", limit=10)
    idents = [h.path for h in everything.hits if "ident" in h.legs]
    assert idents == ["docs/items/a.md"]


def test_ident_plain_words_add_nothing(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/adr/ADR-114-foo.md", "# Caching decision\n\nWe use a queue.\n")
    repo.commit("adr")
    world = make_world(repo, tiny_model)

    for scope in ("docs", "all"):
        resp = world.search("refund rounding total of the order", scope=scope, limit=10)
        assert resp.hits
        assert all("ident" not in hit.legs for hit in resp.hits)


def test_ident_respects_the_filters(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/adr/ADR-114-foo.md", "---\nstatus: deprecated\n---\n# Caching decision\n\nWe use a queue.\n")
    repo.commit("adr")
    world = make_world(repo, tiny_model)
    adr = "docs/adr/ADR-114-foo.md"

    def ids(**kw) -> list[str]:
        resp = world.search("ADR-114", scope="docs", limit=10, **kw)
        return [h.path for h in resp.hits if "ident" in h.legs]

    assert ids() == [], "a deprecated doc is out unless terminal docs are asked for"
    assert ids(include_terminal=True) == [adr]
    assert ids(include_terminal=True, doc_type=("adr",)) == [adr]
    assert ids(include_terminal=True, doc_type=("spec",)) == []
    assert ids(include_terminal=True, path_prefix="docs/adr/") == [adr]
    assert ids(include_terminal=True, path_prefix="docs/specs/") == []


def test_ident_tiers_then_shorter_path_then_path_order(git_repo, tiny_model: str, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    names = ["docs/zed-9.md", "docs/y/zed-9.md", "docs/x/zed-9.md", "docs/zed-9-longer-name.md"]
    for name in names:
        repo.write(name, f"# Page {name}\n\nqueue event handler.\n")
    repo.write("docs/title-hit.md", "# About ZED-9\n\nqueue event handler.\n")
    repo.write("docs/fm-hit.md", "---\nkey: Zed-9\n---\n# Front matter\n\nqueue event handler.\n")
    repo.write("docs/miss.md", "# Nothing\n\nqueue event handler zed.\n")
    repo.commit("zed")
    world = make_world(repo, tiny_model)
    original = SembleIndex.search

    def docs_say_nothing(self, query, *args, **kwargs):  # the docs leg out of the way: only the ident leg speaks
        return [] if ContentType.CODE not in self.content else original(self, query, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", docs_say_nothing)

    resp = world.search("ZED-9", scope="docs", limit=10)

    assert paths(resp) == [
        "docs/fm-hit.md",  # a front-matter value equal to the token: an explicit key
        "docs/zed-9.md",  # then the path, shorter first, then in path order
        "docs/x/zed-9.md",
        "docs/y/zed-9.md",
        "docs/zed-9-longer-name.md",
        "docs/title-hit.md",  # then the title
    ]
    assert all(hit.legs == ("ident",) for hit in resp.hits)
    # no docs-leg chunk: the file's first chunk from the docs index stands in
    first = next(h for h in resp.hits if h.path == "docs/title-hit.md")
    assert (first.start_line, first.snippet.splitlines()[0]) == (1, "# About ZED-9")
    assert first.heading_path == ("About ZED-9",)


def ident_paths(world: World, query: str, **kw) -> list[str]:
    resp = world.search(query, scope="docs", limit=kw.pop("limit", 10), **kw)
    return [h.path for h in resp.hits if "ident" in h.legs]


def test_ident_matches_whole_identifiers_not_substrings(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    # the sibling with the shorter name would win a substring match
    repo.write("docs/adr/ADR-114.md", "# Other decision\n\nWe use a queue.\n")
    repo.write("docs/adr/ADR-11-caching-layer-decision.md", "# Caching layer\n\nWe use a cache.\n")
    repo.write("docs/specs/SPEC-OPS-021-ledger.md", "# Ledger\n\nqueue event handler.\n")
    repo.write("docs/titles.md", "# ADR-1140: a title\n\nqueue event handler.\n")
    repo.commit("adrs")
    world = make_world(repo, tiny_model)

    assert ident_paths(world, "ADR-11") == ["docs/adr/ADR-11-caching-layer-decision.md"]
    assert ident_paths(world, "adr-114") == ["docs/adr/ADR-114.md"]  # not ADR-1140 in a title either
    assert ident_paths(world, "spec-ops-021") == ["docs/specs/SPEC-OPS-021-ledger.md"]
    first = world.search("ADR-11", scope="docs", limit=1)
    assert [h.path for h in first.hits] == ["docs/adr/ADR-11-caching-layer-decision.md"]
    # a boundary is a non-alphanumeric character or an end: letters and digits do not make one
    assert ident_paths(world, "dr-114") == []


def test_ident_title_matches_at_boundaries_too(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/t1.md", "# Decision (ADR-114) on caching\n\nqueue.\n")
    repo.write("docs/t2.md", "# Decision ADR-1141 on caching\n\nqueue.\n")
    repo.commit("titles")
    world = make_world(repo, tiny_model)
    assert ident_paths(world, "ADR-114") == ["docs/t1.md"]


def test_a_front_matter_key_beats_a_path_collision(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    repo.write("docs/plans/chat-700.md", "# Plan 700\n\nqueue event handler.\n")
    repo.write("docs/plans/chat-70-notes.md", "# Notes\n\nqueue event handler.\n")  # a path hit of the same token
    repo.write("docs/items/a.md", "---\nkey: chat-70\n---\n# Streaming replies\n\nevent handler.\n")
    repo.commit("items")
    world = make_world(repo, tiny_model)

    assert ident_paths(world, "chat-70") == ["docs/items/a.md", "docs/plans/chat-70-notes.md"]
    assert [h.path for h in world.search("chat-70", scope="docs", limit=1).hits] == ["docs/items/a.md"]
    assert "docs/plans/chat-700.md" not in ident_paths(world, "chat-70")


def test_a_token_that_matches_many_files_is_dropped(git_repo, tiny_model: str) -> None:
    from doc_search.searcher import IDENT_MAX_FILES

    repo = git_repo()
    seed(repo)
    for i in range(IDENT_MAX_FILES + 2):
        repo.write(f"docs/plans/2026-01-{i + 1:02d}-plan.md", f"# Plan {i}\n\nqueue event handler {i}.\n")
    repo.commit("dated")
    world = make_world(repo, tiny_model)

    for scope in ("docs", "all"):
        resp = world.search("2026 pricing model", scope=scope, limit=1)
        assert all("ident" not in hit.legs for hit in resp.hits)
    assert ident_paths(world, "2026 pricing model") == []
    # the count is over the allowed files: a filter that leaves few of them makes the token selective
    assert len(ident_paths(world, "2026", limit=50, path_prefix="docs/plans/2026-01-0")) == 9
    # the other tokens of the query still count: SPEC-PAY-004 is selective
    assert ident_paths(world, "2026 SPEC-PAY-004") == ["docs/specs/SPEC-PAY-004.md"]
    # path-like tokens that name a whole directory go the same way
    for i in range(IDENT_MAX_FILES + 1):
        repo.write(f"docs/specs/SPEC-X-{i:03d}.md", f"# Spec {i}\n\nqueue.\n")
    repo.commit("specs")
    world = make_world(repo, tiny_model)
    assert ident_paths(world, "docs/ docs/specs") == []


def test_a_token_matching_exactly_the_limit_is_kept(git_repo, tiny_model: str) -> None:
    from doc_search.searcher import IDENT_MAX_FILES

    repo = git_repo()
    seed(repo)
    for i in range(IDENT_MAX_FILES):
        repo.write(f"docs/plans/2026-01-{i + 1:02d}-plan.md", f"# Plan {i}\n\nqueue event handler {i}.\n")
    repo.commit("dated")
    world = make_world(repo, tiny_model)

    assert len(ident_paths(world, "2026", limit=50)) == IDENT_MAX_FILES


def test_a_dot_slash_path_matches_the_file(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/guides/setup-notes.md", "# Setup\n\nqueue event handler.\n")
    repo.commit("guide")
    world = make_world(repo, tiny_model)
    for query in ("./docs/guides/setup-notes.md", "see './docs/guides/setup-notes.md'.", "docs/guides/setup-notes.md"):
        assert ident_paths(world, query) == ["docs/guides/setup-notes.md"], query


def test_english_hyphenated_words_do_not_trip_the_ident_leg(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    write_notes(repo)
    repo.write("docs/guides/end-to-end-testing.md", "# End-to-end testing\n\nqueue event handler.\n")
    repo.write("docs/guides/sign-in.md", "# Sign-in\n\nqueue event handler.\n")
    repo.commit("guides")
    world = make_world(repo, tiny_model)

    # a hyphen alone is how English writes a compound word, not an identifier
    assert ident_paths(world, "how does end-to-end sign-in work") == []
    assert ident_paths(world, "read-only multi-provider access") == []
    # a path that names the file is one, hyphens and all
    assert ident_paths(world, "docs/guides/sign-in.md") == ["docs/guides/sign-in.md"]
    # and so is a hyphenated key with a number
    repo.write("docs/items/a.md", "---\nkey: chat-70\n---\n# Streaming replies\n\nevent handler.\n")
    repo.commit("item")
    world = make_world(repo, tiny_model)
    assert ident_paths(world, "sign-in for chat-70") == ["docs/items/a.md"]


class FrontMatterCountingCorpus(Corpus):
    head_calls = 0  # title and front matter in one read
    separate_calls = 0  # a front_matter() call on its own

    def title_and_front_matter(self, path):
        type(self).head_calls += 1
        return super().title_and_front_matter(path)

    def front_matter(self, path):
        type(self).separate_calls += 1
        return super().front_matter(path)


def test_ident_view_of_the_corpus_is_shared_by_the_filters_and_refreshes_with_the_interval(
    git_repo, tiny_model: str
) -> None:
    repo = git_repo()
    seed(repo)
    clock = FakeClock()
    FrontMatterCountingCorpus.head_calls = FrontMatterCountingCorpus.separate_calls = 0
    world = make_world(repo, tiny_model, corpus_cls=FrontMatterCountingCorpus, clock=clock)
    calls = lambda: FrontMatterCountingCorpus.head_calls  # noqa: E731
    files = len(world.corpus.files())

    world.search("zed-9", scope="docs")
    assert calls() == files, "one head read per corpus file"
    world.search("zed-9 again", scope="docs", include_terminal=True)
    world.search("zed-9", scope="docs", doc_type=("spec",))
    world.search("refund rounding", scope="docs")  # no identifier: nothing gathered
    assert calls() == files, "other filters and other queries reuse it"

    repo.write("docs/items.md", "---\nkey: zed-9\n---\n# Items\n\nevent handler.\n")
    clock.now += 6  # past search.rescan_seconds
    world.corpus._listed_at = 0.0  # let the corpus see the new file now (its own clock is real time)
    resp = world.search("zed-9", scope="docs")
    assert calls() == 2 * files + 1
    assert [h.path for h in resp.hits if "ident" in h.legs] == ["docs/items.md"]
    assert FrontMatterCountingCorpus.separate_calls == 0, "title and front matter come from one head read"


def test_ident_hit_for_a_doc_the_index_lacks_is_synthetic(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model, search={"rescan_seconds": 3600})
    repo.write("docs/ZED-9-new.md", "# Brand new page\n\nnot indexed yet\n")  # after the build

    resp = world.search("zed-9", scope="docs")

    hit = resp.hits[0]
    assert hit.path == "docs/ZED-9-new.md"
    assert (hit.start_line, hit.end_line, hit.snippet, hit.legs) == (1, 1, "Brand new page", ("ident",))
    assert hit.heading_path == ("Brand new page",)


def test_ident_shares_the_docs_leg_chunk_when_there_is_one(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    world = make_world(repo, tiny_model)

    resp = world.search("SPEC-PAY-004 rounding", scope="docs")

    spec = next(h for h in resp.hits if h.path == "docs/specs/SPEC-PAY-004.md")
    assert spec.legs == ("docs", "ident")
    index = world.pool.get(repo.root, wait_s=30).docs
    assert any(c.content == spec.snippet for c in index.chunks if c.file_path == spec.path)


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        ("ADR-114", ["ADR-114"]),
        ('see "ADR-114", and (SPEC-DATA-005).', ["ADR-114", "SPEC-DATA-005"]),
        ("refund rounding total", []),
        ("a-b x1 ab", []),  # under 4 characters, or no digit and no _ . /
        ("ab-1 v1.2 tool_x src/a.py", ["ab-1", "v1.2", "tool_x", "src/a.py"]),
        # a hyphen alone does not make an identifier: it is how English compounds are written
        ("end-to-end sign-in read-only multi-provider", []),
        ("an end-to-end, read-only (multi-provider) sign-in.", []),
        ("SPEC-OPS-021 chat-70 import.meta.env /run snake_case_name docs/a.md", [
            "SPEC-OPS-021", "chat-70", "import.meta.env", "/run", "snake_case_name", "docs/a.md",
        ]),  # fmt: skip
        ("sign-in for chat-70", ["chat-70"]),
        ("the /run command, not /ru", ["/run"]),  # four characters is enough, three is not
        ("chat-70 CHAT-70 chat-70", ["chat-70"]),  # once, whatever the case
        ("./docs/a.md", ["docs/a.md"]),
        ("'./docs/a.md', ././docs/b.md.", ["docs/a.md", "docs/b.md"]),
        ("see ./docs/a.md.", ["docs/a.md"]),
        ("(\"ADR-114\".)", ["ADR-114"]),
        (".github/ci.yml ...", [".github/ci.yml"]),  # a leading dot of a name stays
        ("  ", []),
    ],
)
def test_identifier_tokens(query: str, expected: list[str]) -> None:
    from doc_search.searcher import identifier_tokens

    assert identifier_tokens(query) == expected


def test_identifier_tokens_are_capped() -> None:
    from doc_search.searcher import MAX_IDENT_TOKENS, identifier_tokens

    many = " ".join(f"id-{i}" for i in range(50))
    assert len(identifier_tokens(many)) == MAX_IDENT_TOKENS


# --- scope=docs also looks at corpus files with a code file type ------------------------------------------


def test_scope_docs_reaches_a_corpus_file_the_code_index_holds(git_repo, tiny_model: str, monkeypatch) -> None:
    repo = git_repo()
    seed(repo)
    repo.write("docs/wire.jsx", "export const wire = () => refund;\n")
    repo.commit("jsx")
    world = make_world(
        repo,
        tiny_model,
        docs={"include": ["docs/**/*.md", "docs/**/*.jsx"], "types": [{"glob": "docs/wire.jsx", "type": "ui"}]},
    )
    calls: list[tuple[frozenset, object]] = []
    original = SembleIndex.search

    def spy(self, query, *args, **kwargs):
        calls.append((frozenset(self.content), kwargs.get("filter_paths")))
        return original(self, query, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", spy)

    resp = world.search("wire refund", scope="docs")

    wire = [h for h in resp.hits if h.path == "docs/wire.jsx"]
    assert len(wire) == 1
    assert (wire[0].kind, wire[0].legs, wire[0].doc_type) == ("doc", ("code",), "ui")
    assert all(h.kind == "doc" for h in resp.hits)
    # the code index saw exactly the corpus files it holds: nothing else of the repo
    assert [paths for content, paths in calls if content == frozenset({ContentType.CODE})] == [["docs/wire.jsx"]]

    # the filters still apply: not a spec, not under the prefix
    assert "docs/wire.jsx" not in paths(world.search("wire refund", scope="docs", doc_type=("spec",)))
    assert "docs/wire.jsx" not in paths(world.search("wire refund", scope="docs", path_prefix="docs/specs/"))
    # scope=code stays code only
    assert "docs/wire.jsx" not in paths(world.search("wire refund", scope="code"))


def test_scope_docs_never_calls_the_code_index_with_an_empty_selection(
    git_repo, tiny_model: str, monkeypatch
) -> None:
    repo = git_repo()
    seed(repo)  # every corpus file is markdown: none is in the code index
    world = make_world(repo, tiny_model)
    calls = []
    original = SembleIndex.search

    def spy(self, query, *args, **kwargs):
        calls.append(frozenset(self.content))
        return original(self, query, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "search", spy)

    assert world.search("refund", scope="docs").hits
    assert calls == [frozenset({ContentType.DOCS})]
    calls.clear()
    assert world.search("refund", scope="docs", doc_type=("adr",)).hits == []  # nothing allowed at all
    assert calls == []


# --- a transformer docs model ---------------------------------------------------------------------------

FALLBACK_NOTE = "docs: semble's static index while the transformer index builds (see status)"


@pytest.fixture
def spec(fake_transformer: TransformerSpec):
    """The fake transformer's spec; at the end every held encode is let go and every build thread joined."""
    yield fake_transformer
    release_builds()


def test_header_names_the_static_model_while_the_transformer_index_builds(
    git_repo, tiny_model: str, spec: TransformerSpec
) -> None:
    repo = git_repo()
    seed(repo)
    encoder = fake_encoder(spec)
    encoder.gate.clear()  # the transformer build holds mid-encode
    world = make_world(repo, tiny_model, build=False, docs={"model": "transformer:test-tiny"})
    top = repo.root
    served = world.pool.get(top, wait_s=60)
    assert isinstance(served, WorktreeIndexes) and served.docs_fallback

    resp = world.search("refund rounding total")

    static = Path(tiny_model).name  # semble's default model: the static index answers
    assert resp.header.docs_model == static and resp.header.notes == (FALLBACK_NOTE,)
    assert paths(resp, "doc"), "docs answer from the static index"
    lines = render_search(resp).splitlines()
    assert lines[0].startswith(f"doc-search · docs: semble {static} · code: semble ")
    assert f"note: {FALLBACK_NOTE}" in lines
    docs_only = world.search("refund rounding total", scope="docs")
    assert docs_only.header.docs_model == static and docs_only.header.notes == (FALLBACK_NOTE,)
    code_only = world.search("refund rounding total", scope="code")
    assert code_only.header.notes == (), "a code search does not touch the docs index"

    encoder.gate.set()  # the transformer index validates and replaces the static one

    def swapped():
        got = world.pool.get(top, wait_s=0.2)
        return isinstance(got, WorktreeIndexes) and got.docs is not None and not got.docs_fallback

    wait_until(swapped, "the swap")
    done = world.search("refund rounding total")
    assert done.header.docs_model == "transformer:test-tiny" and done.header.notes == ()
    head = render_search(done).splitlines()[0]
    assert head.startswith("doc-search · docs: semble transformer:test-tiny · code: semble ")
