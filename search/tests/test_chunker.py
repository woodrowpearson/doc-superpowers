"""The cloud write path's chunker: heading-bounded sections, merge of small ones, overlap, whole fences.

Stdlib only, so these run on the base install too. A chunk's text is always the file's own lines for its
1-based range (front matter excluded), with one exception: a single line longer than the target is cut into
pieces that share its line number.
"""

from __future__ import annotations

from doc_search.chunker import CloudChunk, chunk_lines, chunk_markdown


def block(tag: str, count: int, width: int = 60) -> list[str]:
    """`count` lines of exactly `width` characters each, every one different."""
    return [f"{tag}{i:03d} ".ljust(width, "w") for i in range(count)]


def file_lines(text: str) -> list[str]:
    return text.split("\n")[:-1] if text.endswith("\n") else text.split("\n")


def assert_true_to_file(text: str, chunks: list[CloudChunk]) -> None:
    lines = file_lines(text)
    assert [c.ordinal for c in chunks] == list(range(len(chunks)))
    for chunk in chunks:
        assert 1 <= chunk.start_line <= chunk.end_line <= len(lines)
        assert chunk.text == "\n".join(lines[chunk.start_line - 1 : chunk.end_line]), chunk


def test_sections_bound_chunks_and_small_merge() -> None:
    text = (
        "\n".join(
            [
                "# Guide",
                "",
                *block("intro", 1),
                "## Alpha",
                *block("alpha", 8),
                "## Tiny",
                *block("tiny", 1),
                "## Beta",
                *block("beta", 7),
                "## Gamma",
                *block("gamma", 8),
            ]
        )
        + "\n"
    )

    chunks = chunk_markdown("docs/guide.md", text, "Guide")

    assert_true_to_file(text, chunks)
    assert [c.heading_path for c in chunks] == [
        ("Guide",),
        ("Guide", "Alpha"),
        ("Guide", "Tiny"),
        ("Guide", "Gamma"),
    ], "one chunk per section; the small Tiny section took its next sibling and kept its own path"
    guide, alpha, tiny, gamma = chunks
    assert alpha.text.startswith("## Alpha") and "## Tiny" not in alpha.text
    assert tiny.text.startswith("## Tiny") and "## Beta" in tiny.text and "beta006" in tiny.text
    assert gamma.text.startswith("## Gamma")
    for chunk in (alpha, gamma):
        assert [line for line in chunk.text.split("\n") if line.startswith("#")] == [chunk.text.split("\n")[0]]
    assert guide.end_line < alpha.start_line, "a section is not merged into a child"


def test_small_sections_cascade_but_stop_at_a_parent_boundary() -> None:
    lines = ["# Top", "## A", "a", "## B", "b", "## C", "c", "# Next", "## D", "d"]
    text = "\n".join(lines) + "\n"

    chunks = chunk_markdown("docs/x.md", text, "Top")

    assert_true_to_file(text, chunks)
    # A, B and C are all tiny siblings, so they become one chunk; "# Top" (a lone heading) and
    # "# Next" are level-1 sections and each merges with nothing: their next section is a child
    assert [(c.start_line, c.end_line) for c in chunks] == [(1, 1), (2, 7), (8, 8), (9, 10)]


def test_large_section_overlap() -> None:
    paragraphs: list[str] = []
    for i in range(12):
        paragraphs += [*block(f"p{i:02d}", 3), ""]
    text = "\n".join(["## Big", *paragraphs[:-1]]) + "\n"
    lines = file_lines(text)

    chunks = chunk_markdown("docs/big.md", text, "Big", target=1000)

    assert_true_to_file(text, chunks)
    assert len(chunks) >= 3
    assert all(len(c.text) <= 1000 for c in chunks)
    covered = {n for c in chunks for n in range(c.start_line, c.end_line + 1)}
    assert covered >= {n for n, line in enumerate(lines, 1) if line}, "every non-blank line is in some chunk"
    for before, after in zip(chunks, chunks[1:], strict=False):
        assert lines[before.end_line] == "", "a split lands on a paragraph end"
        overlap = lines[after.start_line - 1 : before.end_line]
        assert overlap and overlap[0], "the overlap is real lines and starts on text"
        assert len("\n".join(overlap)) <= 150, "about 15% of the target, never more"
        assert len(overlap) == 2, "two 60-character lines fit in 150 characters, three do not"
        assert after.start_line > before.start_line, "always progress"
    assert all(c.heading_path == ("Big",) for c in chunks)


def test_fence_whole_until_cap() -> None:
    fence = ["```python", *block("code", 25), "", "# not a heading", *block("more", 25), "```"]
    assert 2500 < len("\n".join(fence)) < 6000
    text = "\n".join(["# Doc", "## Code", *block("pre", 10), "", *fence, "", *block("post", 10)]) + "\n"

    chunks = chunk_markdown("docs/code.md", text, "Doc")

    assert_true_to_file(text, chunks)
    opens = [c for c in chunks if "```python" in c.text]
    assert len(opens) == 1, "the fence opens in one chunk"
    assert opens[0].text.rstrip().endswith("```") and "more024" in opens[0].text, "and closes in the same one"
    assert len(opens[0].text) > 1600, "whole, though over the target"
    assert {c.heading_path for c in chunks} == {("Doc",), ("Doc", "Code")}, "a # inside a fence is not a heading"

    huge = ["~~~", *block("big", 120, 80), "", *block("bigger", 5, 80), "~~~"]
    assert len("\n".join(huge)) > 6000
    text = "\n".join(["## Dump", *huge]) + "\n"
    chunks = chunk_markdown("docs/dump.md", text, "Dump")

    assert_true_to_file(text, chunks)
    assert len(chunks) > 1 and all(len(c.text) <= 1600 for c in chunks), "past 6,000 characters a fence splits"
    last = len(file_lines(text))
    assert not any(c.start_line <= 2 and c.end_line >= last for c in chunks), "no chunk holds it from end to end"


def test_line_ranges_true_to_file() -> None:
    text = (
        "---\ntitle: Refunds\nstatus: draft\n---\n# Refunds\n\nRefund rounding rules.\n\n## Rounding\nRound half up.\n"
    )

    chunks = chunk_markdown("docs/specs/r.md", text, "Refunds")

    assert_true_to_file(text, chunks)
    assert [(c.start_line, c.end_line) for c in chunks] == [(5, 7), (9, 10)]
    assert chunks[0].start_line == 5, "front matter is skipped, and the numbering still counts it"
    assert not any("status: draft" in c.text for c in chunks)
    assert chunks[1].heading_path == ("Refunds", "Rounding")


def test_level4_not_split() -> None:
    text = (
        "\n".join(["# T", "", *block("intro", 8), "#### Deep A", *block("a", 8), "#### Deep B", *block("b", 8)]) + "\n"
    )
    assert len(text) < 1600

    chunks = chunk_markdown("docs/t.md", text, "T")
    assert_true_to_file(text, chunks)
    assert [(c.start_line, c.end_line) for c in chunks] == [(1, len(file_lines(text)))], "H4 stays inside the section"

    split = chunk_markdown("docs/t.md", text, "T", heading_level=4)
    assert_true_to_file(text, split)
    assert [c.heading_path for c in split] == [("T",), ("T", "Deep A"), ("T", "Deep B")]


def test_deep_heading_is_in_the_path_of_a_chunk_that_starts_under_it() -> None:
    paragraphs: list[str] = []
    for i in range(6):
        paragraphs += [*block(f"x{i}", 3), ""]
    text = "\n".join(["## S", *paragraphs, "#### Edge", *block("edge", 3), "", *block("y", 3), ""]) + "\n"

    chunks = chunk_markdown("docs/s.md", text, "S", target=700)

    assert_true_to_file(text, chunks)
    assert chunks[0].heading_path == ("S",) and chunks[-1].heading_path == ("S", "Edge")


def test_title_roots_the_path_unless_an_h1_does() -> None:
    chunks = chunk_markdown("docs/x.md", "Preamble text.\n\n## Only\nbody\n", "My Title")
    assert [c.heading_path for c in chunks] == [("My Title",), ("My Title", "Only")]

    chunks = chunk_markdown("docs/x.md", "# Own Title\n\nbody\n", "Own Title")
    assert [c.heading_path for c in chunks] == [("Own Title",)]

    chunks = chunk_markdown("docs/some-file.md", "plain text\n", "")
    assert [c.heading_path for c in chunks] == [("some-file",)], "no title: the file's stem"


def test_a_line_over_the_target_is_cut_into_pieces_on_its_own_line() -> None:
    long_line = " ".join(f"word{i:04d}" for i in range(500))
    assert len(long_line) > 4000
    text = f"# T\n{long_line}\ntail\n"

    chunks = chunk_markdown("docs/t.md", text, "T")

    pieces = [c for c in chunks if c.start_line == 2]
    assert len(pieces) >= 3 and all(c.end_line == 2 and len(c.text) <= 1600 for c in pieces)
    assert "".join(c.text for c in pieces) == long_line, "the pieces are the line, cut and nothing else"
    assert [c.ordinal for c in chunks] == list(range(len(chunks)))
    assert chunks[0].text == "# T" and chunks[-1].text == "tail", "neighbours are not glued to a cut line"


def test_a_huge_heading_does_not_ride_on_every_chunk() -> None:
    huge = "x" * 5000
    text = f"# {huge}\n\n" + "\n\n".join(block(f"p{i}", 3, 80)[0] for i in range(30)) + "\n"

    chunks = chunk_markdown("docs/t.md", text, huge, target=500)

    assert len(chunks) > 3
    assert all(len(part) <= 200 for c in chunks for part in c.heading_path), "headings and title are cut"
    assert chunks[0].heading_path == chunks[-1].heading_path


def test_degenerate_input() -> None:
    assert chunk_markdown("a.md", "", "A") == []
    assert chunk_markdown("a.md", "\n\n  \n", "A") == []
    assert chunk_markdown("a.md", "---\ntitle: x\n---\n", "A") == []
    assert chunk_lines("a.txt", "", "A") == []

    (only,) = chunk_markdown("a.md", "one line", "A")
    assert (only.start_line, only.end_line, only.text) == (1, 1, "one line")

    # an unterminated front matter is not front matter
    (kept,) = chunk_markdown("a.md", "---\nnot closed\n", "A")
    assert kept.start_line == 1


def test_crlf_and_bom_do_not_leak_into_chunks() -> None:
    chunks = chunk_markdown("a.md", "﻿# T\r\n\r\nbody\r\n", "T")

    (chunk,) = chunks
    assert chunk.text == "# T\n\nbody" and (chunk.start_line, chunk.end_line) == (1, 3)


def test_an_unterminated_fence_swallows_what_follows() -> None:
    text = "# T\n\n```\n# not a heading\nstill code\n"

    chunks = chunk_markdown("a.md", text, "T")

    assert_true_to_file(text, chunks)
    assert {c.heading_path for c in chunks} == {("T",)}


def test_chunk_lines_windows() -> None:
    lines = ["---", "kind: not front matter", "---", *[f"{i:03d} ".ljust(40, "q") for i in range(117)]]
    text = "\n".join(lines) + "\n"
    assert len(lines) == 120

    chunks = chunk_lines("scripts/run.sh", text, "run.sh", target=400)

    assert_true_to_file(text, chunks)
    assert chunks[0].start_line == 1 and "kind: not front matter" in chunks[0].text, "nothing is stripped"
    assert chunks[-1].end_line == 120
    assert all(len(c.text) <= 400 for c in chunks)
    assert (chunks[0].start_line, chunks[0].end_line) == (1, 12), (
        "three short lines and nine of 40 characters fit in 400"
    )
    assert (chunks[1].start_line, chunks[1].end_line) == (12, 20), (
        "one line of overlap: 15% of 400 is 60, two lines are 81"
    )
    for before, after in zip(chunks, chunks[1:], strict=False):
        assert after.start_line == before.end_line
    assert {c.heading_path for c in chunks} == {("run.sh",)}
