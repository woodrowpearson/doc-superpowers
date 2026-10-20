"""Rank fusion: RRF, one hit per file, and the per-kind floor of the interleave."""

from __future__ import annotations

import math

import pytest

from doc_search.fusion import collapse_by_file, fuse_by_file, interleave_with_floor, rrf
from doc_search.types import Hit


def doc(path: str, start: int = 1, end: int = 10) -> Hit:
    return Hit(kind="doc", path=path, start_line=start, end_line=end, snippet=f"{path}:{start}")


def code(path: str, start: int = 1, end: int = 10) -> Hit:
    return Hit(kind="code", path=path, start_line=start, end_line=end, snippet=f"{path}:{start}")


# --- rrf ---------------------------------------------------------------------------------


def test_rrf_known_values() -> None:
    fused = rrf([["a", "b", "c"], ["b", "d"]])
    assert [key for key, _ in fused] == ["b", "a", "d", "c"]
    scores = dict(fused)
    assert scores["b"] == pytest.approx(1 / 62 + 1 / 61, abs=1e-9)
    assert scores["a"] == pytest.approx(1 / 61, abs=1e-9)
    assert scores["d"] == pytest.approx(1 / 62, abs=1e-9)
    assert scores["c"] == pytest.approx(1 / 63, abs=1e-9)


def test_rrf_swapped_pair_is_an_exact_tie_kept_in_first_appearance_order() -> None:
    # [a, b, c] and [b, a]: a = 1/61 + 1/62 = b, so the first list's order decides: a, b, then c
    fused = rrf([["a", "b", "c"], ["b", "a"]])
    assert [key for key, _ in fused] == ["a", "b", "c"]
    scores = dict(fused)
    assert scores["a"] == pytest.approx(1 / 61 + 1 / 62, abs=1e-9)
    assert scores["b"] == pytest.approx(1 / 61 + 1 / 62, abs=1e-9)
    assert scores["c"] == pytest.approx(1 / 63, abs=1e-9)


def test_rrf_k_and_single_list_and_empties() -> None:
    assert rrf([]) == []
    assert rrf([[], []]) == []
    assert rrf([["x", "y"]], k=10) == [("x", pytest.approx(1 / 11)), ("y", pytest.approx(1 / 12))]


def test_rrf_counts_a_key_once_per_list() -> None:
    fused = dict(rrf([["a", "a", "b"], ["b"]]))
    assert fused["a"] == pytest.approx(1 / 61)  # the repeat at rank 2 does not count
    assert fused["b"] == pytest.approx(1 / 63 + 1 / 61)


def test_rrf_works_on_hit_keys() -> None:
    fused = rrf([[doc("a.md"), doc("b.md")], [doc("b.md")]])
    assert [hit.path for hit, _ in fused] == ["b.md", "a.md"]


# --- collapse_by_file ----------------------------------------------------------------------


def test_collapse_counts_more_in_file() -> None:
    hits = [doc("a.md", 1, 5), doc("b.md", 1, 5), doc("a.md", 20, 30), doc("a.md", 40, 50), doc("c.md", 1, 2)]
    out = collapse_by_file(hits)
    assert [(h.path, h.start_line, h.more_in_file) for h in out] == [
        ("a.md", 1, 2),  # the best chunk of a.md stays, the two others are counted
        ("b.md", 1, 0),
        ("c.md", 1, 0),
    ]
    assert hits[0].more_in_file == 0, "the input hits are not modified"


def test_collapse_keeps_earlier_counts_and_empty() -> None:
    assert collapse_by_file([]) == []
    first = Hit(kind="doc", path="a.md", start_line=1, end_line=2, snippet="s", more_in_file=3)
    out = collapse_by_file([first, doc("a.md", 9, 12)])
    assert out[0].more_in_file == 4


def test_collapse_merges_legs_of_the_dropped_chunks() -> None:
    a = Hit(kind="doc", path="a.md", start_line=1, end_line=2, snippet="s", legs=("docs",))
    b = Hit(kind="doc", path="a.md", start_line=5, end_line=9, snippet="t", legs=("cloud",))
    (out,) = collapse_by_file([a, b])
    assert out.legs == ("docs", "cloud")
    assert out.more_in_file == 1


# --- interleave_with_floor ---------------------------------------------------------------------


def test_interleave_without_scores_alternates_docs_first() -> None:
    docs = [doc(f"d{i}.md") for i in range(4)]
    codes = [code(f"c{i}.py") for i in range(4)]
    out = interleave_with_floor(docs, codes, 6)
    assert [h.path for h in out] == ["d0.md", "c0.py", "d1.md", "c1.py", "d2.md", "c2.py"]


def test_floor_guarantees_each_kind() -> None:
    docs = [doc(f"d{i}.md") for i in range(10)]
    codes = [code(f"c{i}.py") for i in range(10)]
    # the docs are far stronger: by score alone the top 10 would be all docs
    out = interleave_with_floor(docs, codes, 10, docs_scores=[1.0 - i * 0.01 for i in range(10)])
    assert len(out) == 10
    assert sum(h.kind == "code" for h in out) >= math.ceil(10 / 3)
    assert sum(h.kind == "doc" for h in out) >= math.ceil(10 / 3)
    # the floor takes the best code hits, and the output stays in score order
    assert [h.path for h in out if h.kind == "code"] == ["c0.py", "c1.py", "c2.py", "c3.py"]
    assert [h.path for h in out if h.kind == "doc"] == [f"d{i}.md" for i in range(6)]
    assert [h.path for h in out][:6] == [f"d{i}.md" for i in range(6)]


def test_floor_protects_docs_when_code_is_stronger() -> None:
    docs = [doc(f"d{i}.md") for i in range(10)]
    codes = [code(f"c{i}.py") for i in range(10)]
    out = interleave_with_floor(docs, codes, 9, docs_scores=[0.001 - i * 1e-5 for i in range(10)])
    assert sum(h.kind == "doc" for h in out) == 3  # ceil(9/3)
    assert len(out) == 9


def test_floor_when_one_kind_short() -> None:
    docs = [doc(f"d{i}.md") for i in range(10)]
    # one code hit only: it is kept (below its floor of 4, but nothing else is on offer)
    out = interleave_with_floor(docs, [code("only.py")], 10, docs_scores=[1.0 - i * 0.01 for i in range(10)])
    assert len(out) == 10
    assert [h.path for h in out if h.kind == "code"] == ["only.py"]
    assert sum(h.kind == "doc" for h in out) == 9
    # no code at all: the docs fill the list
    assert [h.path for h in interleave_with_floor(docs, [], 4)] == ["d0.md", "d1.md", "d2.md", "d3.md"]
    # no docs at all
    assert [h.path for h in interleave_with_floor([], [code("a.py"), code("b.py")], 5)] == ["a.py", "b.py"]
    assert interleave_with_floor([], [], 5) == []


def test_floor_counts_kind_not_list() -> None:
    """A doc hit that came through the code leg counts as a doc, so the docs floor can bring it in."""
    codes = [code("c0.py"), code("c1.py"), code("c2.py"), doc("via-code.md")]
    assert [h.path for h in interleave_with_floor([], codes, 3)] == ["c0.py", "c1.py", "via-code.md"]
    # nothing to bring in: plain order
    assert [h.path for h in interleave_with_floor([], codes[:3], 3)] == ["c0.py", "c1.py", "c2.py"]


def test_limit_one_and_short_lists() -> None:
    docs = [doc("d0.md"), doc("d1.md")]
    codes = [code("c0.py")]
    assert [h.path for h in interleave_with_floor(docs, codes, 1)] == ["d0.md"]
    assert [h.path for h in interleave_with_floor(docs, codes, 50)] == ["d0.md", "c0.py", "d1.md"]


def test_scores_must_match_the_docs() -> None:
    with pytest.raises(ValueError):
        interleave_with_floor([doc("a.md")], [], 3, docs_scores=[1.0, 2.0])


# --- fuse_by_file ----------------------------------------------------------------------------------


def chunk(path: str, start: int, leg: str) -> Hit:
    text = f"{leg}:{path}:{start}"
    return Hit(kind="doc", path=path, start_line=start, end_line=start + 5, snippet=text, legs=(leg,))


def test_fuse_by_file_ranks_files_not_chunks() -> None:
    """A file with many chunks in a leg is one entry there: it does not push the other files down."""
    docs = [chunk("a.md", 1, "docs"), chunk("a.md", 20, "docs"), chunk("b.md", 1, "docs"), chunk("a.md", 40, "docs")]
    docs.append(chunk("c.md", 1, "docs"))
    hits, scores = fuse_by_file({"docs": docs}, rank_order=["docs"], prefer=["docs"])
    assert [h.path for h in hits] == ["a.md", "b.md", "c.md"]
    assert scores == pytest.approx([1 / 61, 1 / 62, 1 / 63])
    assert (hits[0].start_line, hits[0].more_in_file) == (1, 2), "the best chunk stays, the others are counted"
    assert hits[1].more_in_file == 0


def test_fuse_by_file_legs_agree_on_a_file_whatever_the_chunk_lines() -> None:
    docs = [chunk("a.md", 1, "docs"), chunk("b.md", 1, "docs")]
    cloud = [chunk("b.md", 300, "cloud"), chunk("c.md", 1, "cloud")]  # the cloud chunker cuts elsewhere
    order = ["docs", "cloud"]
    hits, scores = fuse_by_file({"docs": docs, "cloud": cloud}, rank_order=order, prefer=order)
    assert [h.path for h in hits] == ["b.md", "a.md", "c.md"]
    assert scores == pytest.approx([1 / 62 + 1 / 61, 1 / 61, 1 / 62])
    assert (hits[0].start_line, hits[0].legs) == (1, ("docs", "cloud")), "the local chunk represents the file"


def test_fuse_by_file_representative_follows_the_preference_not_the_rank_order() -> None:
    ident = [chunk("a.md", 1, "ident"), chunk("b.md", 1, "ident")]
    docs = [chunk("b.md", 7, "docs")]
    cloud = [chunk("a.md", 90, "cloud")]
    hits, scores = fuse_by_file(
        {"ident": ident, "docs": docs, "cloud": cloud},
        rank_order=["ident", "docs", "cloud"],
        prefer=["docs", "cloud", "ident"],
    )
    by_path = {h.path: h for h in hits}
    assert (by_path["b.md"].start_line, by_path["b.md"].legs) == (7, ("docs", "ident"))
    assert (by_path["a.md"].start_line, by_path["a.md"].legs) == (90, ("cloud", "ident"))
    # a ties with b? a: ident 1 + cloud 1 = 1/61 + 1/61; b: ident 2 + docs 1 = 1/62 + 1/61
    assert [h.path for h in hits] == ["a.md", "b.md"]
    assert scores == pytest.approx([2 / 61, 1 / 62 + 1 / 61])


def test_fuse_by_file_ties_go_to_the_earlier_rank_order_leg() -> None:
    ident = [chunk("x.md", 1, "ident")]
    docs = [chunk("y.md", 1, "docs")]
    hits, _ = fuse_by_file({"ident": ident, "docs": docs}, rank_order=["ident", "docs"], prefer=["docs", "ident"])
    assert [h.path for h in hits] == ["x.md", "y.md"]


def test_fuse_by_file_missing_and_empty_legs() -> None:
    assert fuse_by_file({}, rank_order=["docs", "cloud"], prefer=["docs", "cloud"]) == ([], [])
    hits, scores = fuse_by_file(
        {"cloud": [chunk("c.md", 3, "cloud")]}, rank_order=["docs", "cloud"], prefer=["docs", "cloud"]
    )
    assert [(h.path, h.legs) for h in hits] == [("c.md", ("cloud",))]
    assert scores == pytest.approx([1 / 61])


def test_fuse_by_file_needs_a_preference_for_every_leg() -> None:
    with pytest.raises(ValueError):
        fuse_by_file({}, rank_order=["docs", "cloud"], prefer=["docs"])
