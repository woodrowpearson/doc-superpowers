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
from doc_search.searcher import Searcher
from doc_search.types import Hit, SearchRequest, SearchResponse

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

    def hits(self, query: str, allowed: set[str], worktree: Path, limit: int) -> tuple[list[Hit], str | None]:
        self.calls.append((query, set(allowed), worktree, limit))
        if self.raises:
            raise self.raises
        return list(self.answer), self.note


def cloud_hit(path: str, start: int = 1, end: int = 5, **kw) -> Hit:
    text = f"cloud text of {path}"
    return Hit(kind="doc", path=path, start_line=start, end_line=end, snippet=text, legs=("cloud",), **kw)


def test_cloud_leg_is_fused_filtered_and_noted(git_repo, tiny_model: str) -> None:
    repo = git_repo()
    seed(repo)
    plain = make_world(repo, tiny_model)
    base = plain.search("shipping fee flat rate", scope="docs", limit=10)
    first = base.hits[0]
    # the cloud finds the very chunk the local docs leg ranks LAST, and one path the filters forbid
    last = base.hits[-1]
    assert last.path != first.path
    cloud = FakeCloud(
        answer=[
            cloud_hit("docs/not-allowed.md"),
            replace(last, snippet="remote copy", legs=("cloud",), heading_path=(), doc_type=None, links=()),
        ],
        note="cloud leg skipped 3 branch-changed paths",
    )
    world = make_world(repo, tiny_model, cloud=cloud)

    resp = world.search("shipping fee flat rate", scope="docs", limit=10)

    assert [call[0] for call in cloud.calls] == ["shipping fee flat rate"]
    _, allowed, worktree, fetch = cloud.calls[0]
    assert allowed == {"docs/specs/SPEC-PAY-004.md", "docs/specs/SPEC-PAY-005.md", "docs/shipping.md"}
    assert worktree == repo.root and fetch == 30  # limit x 3
    assert "docs/not-allowed.md" not in paths(resp)
    # found by both legs, so it climbs above the chunks only the docs leg found
    assert resp.hits[0].path == last.path
    assert resp.hits[0].legs == ("docs", "cloud")
    assert resp.hits[0].snippet == last.snippet, "the local chunk wins the text"
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
