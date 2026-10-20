"""The markdown rendering of a search response: exact format, snippet trimming and the size cap."""

from __future__ import annotations

from doc_search.render import render_search
from doc_search.types import HeaderInfo, Hit, SearchResponse


def header(**kw) -> HeaderInfo:
    base = dict(docs_model="potion-code-16M-v2", code="0.7.0", cloud=None, notes=(), truncated=False)
    base.update(kw)
    return HeaderInfo(**base)


def test_render_golden() -> None:
    doc = Hit(
        kind="doc",
        path="docs/specs/SPEC-PAY-004.md",
        start_line=41,
        end_line=78,
        snippet="Refunds round half up to the nearest cent.\nThe total is the sum of the rounded lines.\n",
        heading_path=("Refunds", "Rounding"),
        doc_type="spec",
        status="accepted",
        links=("functions/src/refunds.ts", "Sources/Payments/Refund.swift"),
        more_in_file=2,
    )
    code = Hit(
        kind="code",
        path="functions/src/refunds.ts",
        start_line=120,
        end_line=161,
        snippet="export function refundTotal(lines) {\n  return sum(lines.map(round));\n}",
        links=("docs/specs/SPEC-PAY-004.md",),
    )
    resp = SearchResponse(
        hits=[doc, code],
        header=header(cloud="gemini-embedding-001", notes=("code index building",)),
    )
    assert render_search(resp) == (
        "doc-search · docs: semble potion-code-16M-v2 (+cloud: gemini-embedding-001) · code: semble 0.7.0 · 2 hits\n"
        "note: code index building\n"
        "1. [doc] docs/specs/SPEC-PAY-004.md:41-78 · Refunds › Rounding · spec · accepted (+2 more in this file)\n"
        "   Refunds round half up to the nearest cent.\n"
        "   The total is the sum of the rounded lines.\n"
        "   code: functions/src/refunds.ts, Sources/Payments/Refund.swift\n"
        "2. [code] functions/src/refunds.ts:120-161\n"
        "   export function refundTotal(lines) {\n"
        "     return sum(lines.map(round));\n"
        "   }\n"
        "   documented by: docs/specs/SPEC-PAY-004.md"
    )


def test_render_minimal_hit_and_off_header() -> None:
    hit = Hit(kind="doc", path="README.md", start_line=1, end_line=3, snippet="# Title")
    out = render_search(SearchResponse(hits=[hit], header=header(code="off")))
    assert out == (
        "doc-search · docs: semble potion-code-16M-v2 · code: off · 1 hits\n1. [doc] README.md:1-3\n   # Title"
    )


def test_render_empty() -> None:
    out = render_search(SearchResponse(hits=[], header=header(notes=("a", "b"))))
    assert out == (
        "doc-search · docs: semble potion-code-16M-v2 · code: semble 0.7.0 · 0 hits\nnote: a\nnote: b"
    )


def test_render_trims_snippets_to_six_lines_and_drops_blank_edges() -> None:
    snippet = "\n\n" + "\n".join(f"line {i}" for i in range(1, 11)) + "\n\n"
    hit = Hit(kind="code", path="a.py", start_line=1, end_line=10, snippet=snippet)
    out = render_search(SearchResponse(hits=[hit], header=header())).splitlines()
    assert out[1:] == ["1. [code] a.py:1-10"] + [f"   line {i}" for i in range(1, 7)]


def test_render_keeps_inner_blank_lines_without_trailing_spaces() -> None:
    hit = Hit(kind="doc", path="a.md", start_line=1, end_line=3, snippet="one\n\ntwo")
    out = render_search(SearchResponse(hits=[hit], header=header())).splitlines()
    assert out[2:] == ["   one", "", "   two"]


def test_render_link_lines_show_three_then_the_rest_counted() -> None:
    links = tuple(f"src/f{i}.py" for i in range(5))
    doc = Hit(kind="doc", path="a.md", start_line=1, end_line=2, snippet="s", links=links)
    docs = tuple(f"docs/{i}.md" for i in range(4))
    code = Hit(kind="code", path="b.py", start_line=1, end_line=2, snippet="s", links=docs)
    out = render_search(SearchResponse(hits=[doc, code], header=header())).splitlines()
    assert "   code: src/f0.py, src/f1.py, src/f2.py (+2)" in out
    assert "   documented by: docs/0.md, docs/1.md, docs/2.md (+1)" in out


def test_render_one_line_per_field_even_with_odd_characters() -> None:
    hit = Hit(
        kind="doc",
        path="docs/a\nb.md",
        start_line=1,
        end_line=2,
        snippet="s",
        heading_path=("A\nB", "C"),
        links=("x\ny.py",),
    )
    out = render_search(SearchResponse(hits=[hit], header=header(notes=("n1\nn2",)))).splitlines()
    assert out[1] == "note: n1 n2"
    assert out[2] == "1. [doc] docs/a b.md:1-2 · A B › C"
    assert out[4] == "   code: x y.py"


def test_render_caps_long_snippet_lines() -> None:
    hit = Hit(kind="code", path="min.js", start_line=1, end_line=1, snippet="x" * 5000)
    out = render_search(SearchResponse(hits=[hit], header=header()))
    assert len(out) < 600
    assert out.splitlines()[2].endswith("…")


def test_render_cap() -> None:
    hits = [
        Hit(
            kind="doc",
            path=f"docs/file{i}.md",
            start_line=1,
            end_line=40,
            snippet="\n".join(f"snippet line {j} of file {i} " + "w" * 60 for j in range(6)),
            links=("src/a.py",),
        )
        for i in range(40)
    ]
    resp = SearchResponse(hits=hits, header=header())
    full = render_search(resp, cap=10**9)
    assert len(full) > 8000 and "truncated" not in full

    out = render_search(resp)
    assert len(out) <= 8000
    assert out.splitlines()[-1] == "(truncated at 8000 chars)"
    assert out.startswith(
        "doc-search · docs: semble potion-code-16M-v2 · code: semble 0.7.0 · 40 hits\n1. [doc] docs/file0.md:1-40"
    )
    # whole hits only: the line before the notice is the end of a hit block, and later hits are simply absent
    body = out.splitlines()[:-1]
    assert body[-1] == "   code: src/a.py"
    shown = [line for line in body if line[:1].isdigit()]
    assert 1 < len(shown) < 40
    assert shown[-1].startswith(f"{len(shown)}. ")

    small = render_search(resp, cap=1000)
    assert len(small) <= 1000
    assert small.splitlines()[-1] == "(truncated at 1000 chars)"


def test_render_cap_smaller_than_one_hit_still_fits() -> None:
    hit = Hit(kind="code", path="a.py", start_line=1, end_line=2, snippet="x\n" * 6)
    resp = SearchResponse(hits=[hit], header=header())
    out = render_search(resp, cap=120)
    assert len(out) <= 120
    assert out.splitlines()[-1] == "(truncated at 120 chars)"


def test_render_header_flag_forces_the_notice() -> None:
    hit = Hit(kind="code", path="a.py", start_line=1, end_line=2, snippet="x")
    out = render_search(SearchResponse(hits=[hit], header=header(truncated=True)))
    assert out.splitlines()[-1] == "(truncated at 8000 chars)"
