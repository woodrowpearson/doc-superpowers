"""The shared Markdown reader, run against invented text.

A code (a record such as ORB-12, a short name such as KX7, an issue such as #318) is shorthand:
acceptable in brackets after words that name the thing, not acceptable alone. These tests pin
which lines count as prose, where a paragraph ends and which codes are left unexplained.
"""

from __future__ import annotations

import unittest

from tests import support

md = support.load("markdown")
CODES = support.DEFAULT_CODES

BASE = """\
# Pager rota notes

## Who owns the night shift

The rota gives the night shift to the platform team, per the handover note (ORB-12).

- Platform keeps the pager on weekdays.
- Support covers the weekends.
"""
BASE_LINES = len(BASE.splitlines())


def bare(text: str) -> list[str]:
    return md.bare_codes(text, CODES)


def codes_by_line(text: str) -> list[tuple[int, str]]:
    """Report what a lint would: every unexplained code in ``text``, paired with its line number.
    It chains the reader's pieces, and ignores codes inside file paths."""
    found = []
    for paragraph in md.paragraphs(list(md.prose_lines(text))):
        joined = " ".join(line for _, line in paragraph)
        starts, offset = [], 0
        for number, line in paragraph:
            starts.append((offset, number))
            offset += len(line) + 1
        paths = md.path_spans(joined)
        for start, end in md.bare_spans(joined, CODES):
            if any(open_ <= start and end <= close for open_, close in paths):
                continue
            number = next(number for begin, number in reversed(starts) if begin <= start)
            found.append((number, joined[start:end]))
    return found


class BareCodes(unittest.TestCase):
    def test_bare_codes_are_found(self) -> None:
        self.assertEqual(bare("Closes ORB-12 and KX7, and compare beacon-~a1c9 with #318"),
                         ["ORB-12", "KX7", "beacon-~a1c9", "#318"])

    def test_glossed_codes_pass(self) -> None:
        self.assertEqual(
            bare("the pager handover note (ORB-12) and the rota change (#318)"), [])

    def test_bracket_without_words_before_is_bare(self) -> None:
        self.assertEqual(bare("Owner: (KX7)"), ["KX7"])

    def test_allowed_words_are_not_codes(self) -> None:
        self.assertEqual(
            bare("Severity P1 or P2, quarter Q3, encoding UTF-8, digest SHA-1, date ISO-8601"), [])
        self.assertEqual(bare("Both P1 and P10 appear"), ["P10"])

    def test_overlapping_matches_count_once_as_the_longest(self) -> None:
        self.assertEqual(bare("Touches ORB-LAUNCH-14, KX7-2 and then KX7 and KX7"),
                         ["ORB-LAUNCH-14", "KX7-2", "KX7", "KX7"])

    def test_headings_and_html_entities_are_not_issue_numbers(self) -> None:
        self.assertEqual(bare("### 7 pending reviews\nThe &#8217;quoted&#8217; entry"), [])

    def test_a_code_that_is_the_whole_link_text_is_bare(self) -> None:
        self.assertEqual(bare("details in [ORB-12](https://example.com/a)"), ["ORB-12"])
        self.assertEqual(
            bare("details in [the pager handover (ORB-12)](https://example.com/a)"), [])

    def test_link_text_with_digits_besides_the_code_glosses_it(self) -> None:
        self.assertEqual(bare("read [ORB-12 2027](x)"), [])
        self.assertEqual(bare("read [ORB-12 *](x)"), ["ORB-12"])

    def test_a_blank_line_ends_a_paragraph_in_bare_codes(self) -> None:
        self.assertEqual(bare("Some words here.\n\n(ORB-12) begins a new paragraph"), ["ORB-12"])
        self.assertEqual(bare("> a quoted line\n>\n> (ORB-12) begins again"), ["ORB-12"])

    def test_a_fence_line_in_plain_text_hides_nothing(self) -> None:
        self.assertEqual(bare("first\n```\nORB-12 after a fence line"), ["ORB-12"])

    def test_the_caller_says_what_a_code_is(self) -> None:
        # The codes are an argument, not a global: a different set reads the same text another way.
        only_orbit = md.Codes(patterns=(CODES.patterns[0],), allowed=frozenset({"ORB-12"}),
                              gloss_chars=frozenset({"~"}))

        self.assertEqual(md.bare_codes("ORB-12 and ORB-13 and KX7", only_orbit), ["ORB-13"])
        self.assertEqual(md.bare_codes("a ~ (ORB-13) and `x` (ORB-14)", only_orbit), ["ORB-14"])

    def test_code_cases(self) -> None:
        cases = [
            ("Deferred ORB-12 until June.", ["ORB-12"]),
            ("Deferred the pager change (ORB-12) until June.", []),
            ("Both KX7a and KX7 stay open.", ["KX7a", "KX7"]),
            ("The rota owner (KX7) agreed.", []),
            ("Logs in beacon-~a1c9 show it.", ["beacon-~a1c9"]),
            ("The failing run (beacon-~a1c9) shows it.", []),
            ("Fixed by #318 last week.", ["#318"]),
            ("Fixed by the rota PR (#318) last week.", []),
            ("the ‘rota’ (ORB-12), `rota` (KX7) and **rota** (ORB-14)", []),
            ("the r\u00e9sum\u00e9 (ORB-12)", []),
            ("a \u00bd (KX7)", []),
            ("a pause — (ORB-12)", ["ORB-12"]),
            ("ñKX7 and KX7ñ", ["KX7", "KX7"]),
            ("KX7xy and xKX7 and KX7_1", []),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(bare(text), expected)


class FilePaths(unittest.TestCase):
    def test_a_code_inside_a_file_path_is_not_bare(self) -> None:
        # A path has a "/" and ends in "/" or an extension (once with a line range), which makes it
        # a file name, whatever codes it holds.
        for text in ("See `docs/guides/NAV-210-layout.md` for the layout.",
                     "The file docs/notes/NAV-211-effort.md holds the estimate.",
                     "Sample data sits under `tests/samples/ORB-12/`.",
                     "Read `docs/guides/NAV-210-layout.md:12-40` before editing."):
            with self.subTest(text=text):
                self.assertEqual(bare(text), [])
        named = BASE.replace("(ORB-12).", "(ORB-12) in `docs/guides/NAV-210-layout.md`.")
        self.assertNotEqual(named, BASE)
        self.assertEqual(codes_by_line(named), [])

    def test_a_bare_code_beside_a_path_or_joined_by_a_slash_is_still_bare(self) -> None:
        self.assertEqual(bare("Compare ORB-13 with `docs/guides/NAV-210-layout.md`."), ["ORB-13"])
        self.assertEqual(bare("Pick K1/K2 or K3/K4."), ["K1", "K2", "K3", "K4"])

    def test_path_spans_cover_the_whole_token(self) -> None:
        text = "See (`docs/guides/NAV-210-layout.md:12-40`) and src/ and a/b."
        spans = md.path_spans(text)

        self.assertEqual([text[start:end] for start, end in spans],
                         ["(`docs/guides/NAV-210-layout.md:12-40`)", "src/"])

    def test_a_token_needs_a_slash_and_a_trailing_slash_or_an_extension(self) -> None:
        for text in ("and/or", "v1.2", "notes.md", "see the file", "a/b."):
            with self.subTest(text=text):
                self.assertEqual(md.path_spans(text), [])
        for text in ("docs/", "docs/notes.md", "a/b.c", "a/b.c:3"):
            with self.subTest(text=text):
                self.assertEqual(len(md.path_spans(text)), 1)


class ProseLines(unittest.TestCase):
    def test_lines_are_numbered_from_one(self) -> None:
        self.assertEqual(list(md.prose_lines("one\n\nthree\n")),
                         [(1, "one"), (2, ""), (3, "three")])

    def test_fenced_blocks_and_link_targets_are_ignored(self) -> None:
        text = BASE + """
The background is in [the handover note](docs/notes/NAV-210.md).

```
ORB-12 appears only inside this fence
```
"""
        self.assertEqual(codes_by_line(text), [])
        blanked = dict(md.prose_lines("See [the note](docs/NAV-210.md) too"))[1]
        self.assertEqual(blanked, "See [the note](" + " " * len("docs/NAV-210.md") + ") too")

    def test_every_link_form_is_blanked_to_the_same_length(self) -> None:
        cases = [
            "See [the note](docs/NAV-210.md) and more",
            "See <https://example.com/browse/ORB-12> and more",
            "See https://example.com/browse/ORB-12 and more",
            "See https://example.com/browse/ORB-12. And more",
            "[ref]: https://example.com/browse/KX9",
            "  [KX7]: <notes.md> \"title\"",
            "> [KX7]: notes.md",
        ]
        for line in cases:
            with self.subTest(line=line):
                blanked = md.blank_link_targets(line)
                self.assertEqual(len(blanked), len(line))
                self.assertNotRegex(blanked, r"ORB|KX|NAV|example|notes")

    def test_trailing_punctuation_and_words_round_a_url_are_kept(self) -> None:
        self.assertEqual(md.blank_link_targets("Read https://example.com/a. Then go."),
                         "Read " + " " * len("https://example.com/a") + ". Then go.")
        self.assertEqual(md.blank_link_targets("(see https://example.com/a)"),
                         "(see " + " " * len("https://example.com/a") + ")")

    def test_text_that_only_looks_like_a_destination_is_kept(self) -> None:
        for line in ("Note: use KX7 here", "a [KX7] label", "[^1]: a footnote on KX7",
                     "use a < b and c > d", "mail me@example.com", "the 12:30 ferry"):
            with self.subTest(line=line):
                self.assertEqual(md.blank_link_targets(line), line)

    def test_a_url_inside_a_code_span_leaves_the_span_whole(self) -> None:
        cases = {
            "Use `https://example.com/a` for it.":
                "Use `" + " " * len("https://example.com/a") + "` for it.",
            "A `https://example.com/a`, then `https://example.com/b` too.":
                "A `" + " " * len("https://example.com/a") + "`, then `"
                + " " * len("https://example.com/b") + "` too.",
            "See https://example.com/a`x`.":
                "See " + " " * len("https://example.com/a") + "`x`.",
        }
        for line, want in cases.items():
            with self.subTest(line=line):
                self.assertEqual(dict(md.prose_lines(line))[1], want)
                self.assertEqual(md.blank_link_targets(line), want)

    def test_only_a_definition_is_blanked_whole(self) -> None:
        kept = ("[x]: the ferry rota is late", "[KX7]: see notes.md for the ferry rota",
                "  [ref]: notes.md and KX9", "[ref]: notes.md \"A title\" and more")
        for line in kept:
            with self.subTest(line=line):
                self.assertEqual(dict(md.prose_lines(line))[1], line)
        blanked = ("[KX7]: notes.md", "[ref]: https://example.com/browse/KX9",
                   "[ref]: notes.md \"A title\"", "[ref]: notes.md 'A title'",
                   "[ref]: <notes.md> (A title)", "> [KX7]: notes.md", "   [KX7]:  notes.md  ")
        for line in blanked:
            with self.subTest(line=line):
                self.assertEqual(dict(md.prose_lines(line))[1].strip("> "), "")
        self.assertEqual(codes_by_line("[x]: the ferry rota is late KX7\n"), [(1, "KX7")])

    def test_a_reference_definition_keeps_its_line_but_not_its_text(self) -> None:
        # The line stays in the numbering, so a caller that wants the definitions still finds it,
        # and what it holds is blank, so it is no prose.
        text = "one\n[KX7]: notes.md\ntwo\n"
        self.assertEqual(list(md.prose_lines(text)),
                         [(1, "one"), (2, " " * len("[KX7]: notes.md")), (3, "two")])
        self.assertEqual(codes_by_line(text), [])

    def test_a_definition_ends_the_paragraph_it_stands_in(self) -> None:
        paragraphs = list(md.paragraphs(list(md.prose_lines("one\n[KX7]: notes.md\ntwo\n"))))
        self.assertEqual([[number for number, _ in paragraph] for paragraph in paragraphs],
                         [[1], [3]])

    def test_bare_codes_skips_the_forms_too(self) -> None:
        self.assertEqual(bare("[ref]: https://example.com/browse/KX9\n"
                              "A <https://example.com/ORB-12> and https://example.com/KX7 here"),
                         [])

    def test_a_fence_of_any_kind_or_indent_is_skipped(self) -> None:
        text = "a\n~~~\nORB-12\n~~~\nb\n    ```\n    KX7\n    ```\nc\n"

        self.assertEqual([line for _, line in md.prose_lines(text)], ["a", "b", "c"])
        self.assertEqual([number for number, _ in md.prose_lines(text)], [1, 5, 9])

    def test_an_unclosed_fence_runs_to_the_end(self) -> None:
        self.assertEqual(list(md.prose_lines("a\n```\nORB-12\nKX7\n")), [(1, "a")])

    def test_only_a_marker_as_long_and_of_the_same_kind_closes_a_fence(self) -> None:
        text = "a\n````\n```\nORB-12\n~~~~\n````\nb\n"

        self.assertEqual([line for _, line in md.prose_lines(text)], ["a", "b"])

    def test_an_indented_fence_in_a_list_item_is_ignored(self) -> None:
        text = BASE + """
- An example follows:
    - A nested bullet with a sample:

        ```
        ORB-12 appears only in this sample
        ```
"""
        self.assertEqual(codes_by_line(text), [])

    def test_headings_and_table_rows_are_prose_lines(self) -> None:
        text = "## Night shift\n| a | b |\nwords\n"

        self.assertEqual([line for _, line in md.prose_lines(text)],
                         ["## Night shift", "| a | b |", "words"])

    def test_a_fence_inside_a_blockquote_is_a_fence(self) -> None:
        self.assertEqual(codes_by_line(BASE + "\n> ```\n> KX7 inside a quoted fence\n> ```\n"), [])

        # Leaving the quote also leaves the fence it opened.
        found = codes_by_line(
            BASE + "\n> ```\n> KX7 inside a quoted fence\n\nThen ORB-14 stands alone.\n")

        self.assertEqual(found, [(BASE_LINES + 5, "ORB-14")])

    def test_a_quoted_fence_marker_does_not_close_an_unquoted_fence(self) -> None:
        text = BASE + "\n```\n> ```\n> KX7 hidden here\n> ```\n```\n\nThen ORB-14 stands alone.\n"

        self.assertEqual(codes_by_line(text), [(BASE_LINES + 8, "ORB-14")])

    def test_a_deeper_fence_marker_does_not_close_a_quoted_fence(self) -> None:
        text = BASE + "\n> ```\n> > ```\n> KX7 hidden here\n> ```\n\nThen ORB-14 stands alone.\n"

        self.assertEqual(codes_by_line(text), [(BASE_LINES + 7, "ORB-14")])


class Unquote(unittest.TestCase):
    def test_the_depth_and_the_line_without_its_markers(self) -> None:
        self.assertEqual(md.unquote("plain"), (0, "plain"))
        self.assertEqual(md.unquote("> one"), (1, "one"))
        self.assertEqual(md.unquote(">> two"), (2, "two"))
        self.assertEqual(md.unquote("> > two"), (2, "two"))
        self.assertEqual(md.unquote("  >"), (1, ""))
        self.assertEqual(md.unquote("a > b"), (0, "a > b"))


class Paragraphs(unittest.TestCase):
    def test_a_hard_wrapped_bracket_is_still_a_gloss(self) -> None:
        text = BASE + """
- Hand the pager over, per the
  (ORB-12) note.

The rota follows the handover
(ORB-12) note, and the handover notes (ORB-12,
KX7) apply.
"""
        self.assertEqual(codes_by_line(text), [])

    def test_a_code_on_a_wrapped_line_without_a_bracket_is_bare_at_its_line(self) -> None:
        text = BASE + """
The handover notes (ORB-12,
KX7) apply, and the
rota lists ORB-14 too.
"""
        self.assertEqual(codes_by_line(text), [(BASE_LINES + 4, "ORB-14")])

    def test_a_heading_or_list_item_never_glosses_the_next_line(self) -> None:
        for block in ("## Night shift\n(ORB-12) covers it.\n",
                      "- The night shift\n(ORB-12) covers it.\n",
                      "| The night shift |\n(ORB-12) covers it.\n"):
            with self.subTest(block=block):
                self.assertEqual(codes_by_line(BASE + "\n" + block),
                                 [(BASE_LINES + 3, "ORB-12")])

    def test_a_wrapped_blockquote_is_one_paragraph(self) -> None:
        self.assertEqual(codes_by_line(BASE + "\n> the rota follows\n> (ORB-12) as written\n"), [])

    def test_a_bare_quote_line_or_a_new_depth_starts_a_paragraph(self) -> None:
        for block in ("> the rota follows\n>> (ORB-12) as written\n",
                      "> the rota follows\n(ORB-12) as written\n"):
            with self.subTest(block=block):
                self.assertEqual(codes_by_line(BASE + "\n" + block),
                                 [(BASE_LINES + 3, "ORB-12")])

        found = codes_by_line(BASE + "\n> the rota follows\n>\n> (ORB-12) as written\n")

        self.assertEqual(found, [(BASE_LINES + 4, "ORB-12")])

    def test_blocks_split_and_join_as_a_reader_sees_them(self) -> None:
        text = ("# Title\n"
                "First line\n"
                "wrapped on.\n"
                "## Section\n"
                "\n"
                "intro line\n"
                "- an item\n"
                "  its wrapped line\n"
                "  - a nested item\n"
                "  and its wrap\n"
                "- a second item\n"
                "| a | b |\n"
                "| c | d |\n"
                "> quoted\n"
                "> on\n"
                "plain again\n"
                "| e | f |\n"
                "tail\n")
        blocks = [[line for _, line in block]
                  for block in md.paragraphs(list(md.prose_lines(text)))]

        self.assertEqual(blocks, [
            ["# Title"],
            ["First line", "wrapped on."],
            ["## Section"],
            ["intro line"],
            ["- an item", "  its wrapped line"],
            ["  - a nested item", "  and its wrap"],
            ["- a second item"],
            ["| a | b |"],
            ["| c | d |"],
            ["quoted", "on"],
            ["plain again"],
            ["| e | f |"],
            ["tail"]])

    def test_a_removed_fence_ends_a_paragraph(self) -> None:
        text = "Night shift notes\n```\ncode\n```\n(ORB-12) apply.\n"

        self.assertEqual(codes_by_line(text), [(5, "ORB-12")])

    def test_paragraph_lines_keep_their_numbers(self) -> None:
        blocks = list(md.paragraphs(list(md.prose_lines("a\n\n> b\n> c\n"))))

        self.assertEqual(blocks, [[(1, "a")], [(3, "b"), (4, "c")]])


if __name__ == "__main__":
    unittest.main()
