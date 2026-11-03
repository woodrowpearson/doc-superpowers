"""The whole-file writing lint, run on invented text.

A reader who takes a document in one pass needs every code explained (words around it, a link,
or an entry in a key), short sentences, and one idea per list item. These tests check the lint's
limits and what it must ignore in a Markdown file. Every code, folder and sentence here is made up.
The tests that run the command line start it in a throwaway repository, so no project file in
this checkout can change what they see.
"""

from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from typing import NamedTuple
from unittest import mock

from tests import support

lint = support.load("lint")
config = support.load("config")

LINT = support.WRITING / "lint.py"
REPO_ROOT = support.WRITING.parents[1]


def default_config() -> config.Config:
    with tempfile.TemporaryDirectory(prefix="writing defaults ") as empty:
        return config.load(Path(empty))


# The shipped defaults, with no project file and no work ledger.
CONFIG = default_config()


def sentence(words: int) -> str:
    """A sentence made of ``words`` words and nothing code-like."""
    return " ".join(["Quiet"] + ["rooms"] * (words - 1)) + "."


def check(text: str, register: str = "terse", **options: object) -> list:
    return lint.lint_text(text, "a.md", register, CONFIG, **options)


def rules(findings: list) -> list[str]:
    return [finding.rule for finding in findings]


def where(findings: list) -> list[tuple[int, str]]:
    return [(finding.line, finding.rule) for finding in findings]


def code_of(finding: object) -> str:
    return finding.message.split('"')[1]


class Result(NamedTuple):
    code: int
    out: str
    err: str


def run(*args: str, cwd: Path, stdin: str | bytes | None = None) -> Result:
    """Run the lint script as the wrapper will: an isolated interpreter, UTF-8 output."""
    data = stdin.encode("utf-8") if isinstance(stdin, str) else stdin
    done = subprocess.run([sys.executable, "-I", "-B", "-X", "utf8", str(LINT), *args],
                          capture_output=True, cwd=str(cwd), input=data)
    return Result(done.returncode, done.stdout.decode("utf-8"), done.stderr.decode("utf-8"))


def put(root: Path, files: dict[str, str | bytes]) -> None:
    """Write ``files`` under ``root`` without committing them."""
    for name, content in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)


@contextmanager
def in_directory(path: Path) -> Iterator[None]:
    before = os.getcwd()
    os.chdir(str(path))
    try:
        yield
    finally:
        os.chdir(before)


class Limits(unittest.TestCase):
    def test_a_list_item_over_50_words_is_long(self) -> None:
        over = f"- {sentence(25)} {sentence(26)}\n"
        self.assertEqual(rules(check(over)), ["long-item"])
        at = f"- {sentence(25)} {sentence(25)}\n"
        self.assertEqual(check(at), [])

    def test_a_list_item_of_three_sentences_is_long(self) -> None:
        three = f"- {sentence(5)} {sentence(5)} {sentence(5)}\n"
        self.assertEqual(rules(check(three)), ["long-item"])
        self.assertEqual(check(f"- {sentence(5)} {sentence(5)}\n"), [])
        self.assertEqual(check(three, "full"), [])
        # A task box adds no words to the item.
        self.assertEqual(check(f"- [ ] {sentence(25)} {sentence(25)}\n"), [])

    def test_a_sentence_over_the_profile_limit_is_long(self) -> None:
        self.assertEqual(rules(check(sentence(36) + "\n")), ["long-sentence"])
        self.assertEqual(check(sentence(35) + "\n"), [])
        self.assertEqual(check(sentence(36) + "\n", "full"), [])
        self.assertEqual(check(sentence(40) + "\n", "full"), [])
        self.assertEqual(rules(check(sentence(41) + "\n", "full")), ["long-sentence"])

    def test_link_targets_are_not_words(self) -> None:
        linked = " ".join(["Calm"] + ["tides"] * 33) + " [timetable](docs/guides/tides.md)."
        self.assertEqual(check(linked + "\n"), [])
        self.assertEqual(rules(check(f"Extra {linked}\n")), ["long-sentence"])

    def test_limits_come_from_the_configuration(self) -> None:
        tight = CONFIG._replace(limits={"terse": config.Limits(10, 12, None),
                                        "full": config.Limits(40, None, 1)})
        flagged = lint.lint_text(sentence(11) + "\n", "a.md", "terse", tight)
        self.assertEqual(rules(flagged), ["long-sentence"])
        self.assertIn("limit of 10", flagged[0].message)
        words = lint.lint_text(f"- {sentence(8)} {sentence(8)}\n", "a.md", "terse", tight)
        self.assertEqual(rules(words), ["long-item"])  # 16 words, and no sentence limit
        two = f"- {sentence(5)} {sentence(5)}\n"
        found = lint.lint_text(two, "a.md", "full", tight)  # no word limit, one sentence
        self.assertEqual(rules(found), ["long-item"])
        self.assertIn("1 sentence", found[0].message)

    def test_an_unknown_register_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            lint.lint_text("A line.\n", "a.md", "brief", CONFIG)

    def test_a_bold_lead_in_counts_as_a_sentence(self) -> None:
        item = f"- **Rule.** {sentence(5)} {sentence(5)}\n"
        self.assertEqual(rules(check(item)), ["long-item"])
        self.assertEqual(check(f"- **Rule.** {sentence(5)}\n"), [])

    def test_sentences_split_once_after_a_file_name_and_not_after_e_g(self) -> None:
        self.assertEqual(lint.sentences("Open `rota_sync.py`. Then rerun the sync."),
                         ["Open `rota_sync.py`.", "Then rerun the sync."])
        self.assertEqual(lint.sentences("Pick e.g. a seat."), ["Pick e.g. a seat."])
        self.assertEqual(lint.sentences("Run it at 5 p.m. tomorrow. Then stop."),
                         ["Run it at 5 p.m. tomorrow.", "Then stop."])

    def test_an_abbreviation_ends_no_sentence_even_before_a_capital(self) -> None:
        for abbreviation in ("e.g.", "i.e.", "cf.", "vs."):
            with self.subTest(abbreviation=abbreviation):
                text = f"Compare the ferries, {abbreviation} Ferry A and Ferry B."
                self.assertEqual(lint.sentences(text), [text])
        self.assertEqual(lint.sentences("Compare the ferries. Ferry A is faster."),
                         ["Compare the ferries.", "Ferry A is faster."])


class Codes(unittest.TestCase):
    def test_a_bare_code_is_found(self) -> None:
        found = check("KX7 is open.\n")
        self.assertEqual(rules(found), ["bare-code"])
        self.assertIn('"KX7"', found[0].message)
        self.assertEqual(check("moving the late sailing (KX7) is open.\n"), [])
        self.assertEqual(check("[KX7](x.md) is open.\n"), [])
        keyed = "KX7 is open.\n\n## Key\n\n- **KX7**: moving the late sailing.\n"
        self.assertEqual(check(keyed), [])

    def test_a_glossed_code_passes_later_only_in_full(self) -> None:
        text = "Moving the late sailing (KX7) is open. Then KX7 is next.\n"
        self.assertEqual(check(text, "full"), [])
        self.assertEqual(rules(check(text)), ["bare-code"])
        linked = "See [the late sailing rule (KX7)](x.md).\n\nThen KX7 is next.\n"
        self.assertEqual(check(linked, "full"), [])
        early = "KX7 is next.\n\nMoving the late sailing (KX7) is open.\n"
        self.assertEqual(where(check(early, "full")), [(1, "bare-code")])

    def test_a_linked_first_use_lets_later_uses_pass_in_full(self) -> None:
        text = "See [KX7](x.md).\n\nThen KX7 is next.\n"
        self.assertEqual(check(text, "full"), [])
        self.assertEqual(where(check(text)), [(3, "bare-code")])

    def test_a_bold_label_on_a_plain_line_defines_its_code(self) -> None:
        text = "**KX7** moves the late sailing.\n\nKX7 is open.\n"
        self.assertEqual(lint.defined_codes(text, CONFIG.codes), frozenset({"KX7"}))
        self.assertEqual(check(text), [])
        self.assertEqual(check(text, "full"), [])

    def test_a_heading_or_bold_label_of_codes_alone_defines_nothing(self) -> None:
        heading = "## ORB-12\n\nORB-12 is open.\n"
        self.assertEqual(lint.defined_codes(heading, CONFIG.codes), frozenset())
        self.assertEqual(where(check(heading)), [(3, "bare-code")])
        bold = "**ORB-12 is blocked.**\n\nORB-12 is open.\n"
        self.assertEqual(lint.defined_codes(bold, CONFIG.codes), frozenset())
        self.assertEqual(where(check(bold)), [(1, "bare-code"), (3, "bare-code")])

    def test_a_heading_or_bold_label_with_words_defines_its_codes(self) -> None:
        for text in ("## ORB-12: delayed sailings\n\nORB-12 is open.\n",
                     "- **ORB-12**: delayed sailings.\n\nORB-12 is open.\n",
                     "**ORB-12** Delayed sailings.\n\nORB-12 is open.\n"):
            with self.subTest(text=text):
                self.assertEqual(lint.defined_codes(text, CONFIG.codes), frozenset({"ORB-12"}))
                self.assertEqual(check(text), [])

    def test_a_code_in_backticks_is_still_a_code(self) -> None:
        self.assertEqual(rules(check("`ORB-12` is done.\n")), ["bare-code"])

    def test_a_code_inside_a_file_path_is_not_bare(self) -> None:
        # Inside a path a code is only part of a file name: the token has a slash, then a final
        # slash or an extension, which a line range may follow.
        for text in ("- Modify: `docs/guides/NAV-210-layout.md`\n",
                     "The decision docs/adr/ADR-077-moorings.md is recorded.\n",
                     "See docs/adr/ADR-077-moorings.md.\n",
                     "Its samples are in `tests/samples/ORB-12/` now.\n",
                     "- Modify: `docs/guides/NAV-210-layout.md:12-40`\n"):
            with self.subTest(text=text):
                self.assertEqual(check(text), [])

    def test_codes_joined_by_a_slash_or_beside_a_path_are_still_read(self) -> None:
        found = check("KX1/KX2 are open.\n")
        self.assertEqual([(f.rule, code_of(f)) for f in found],
                         [("bare-code", "KX1"), ("bare-code", "KX2")])
        beside = check("`ORB-19` is filed in `docs/guides/NAV-210-layout.md`.\n")
        self.assertEqual([(f.rule, code_of(f)) for f in beside], [("bare-code", "ORB-19")])
        # Naming a path explains nothing: in full, a later bare use of the code is flagged.
        later = "`docs/guides/NAV-210-layout.md` holds it. Then NAV-210 is next.\n"
        self.assertEqual([(f.rule, code_of(f)) for f in check(later, "full")],
                         [("bare-code", "NAV-210")])

    def test_issue_numbers_pass_only_on_github(self) -> None:
        self.assertEqual(rules(check("#318 is open.\n")), ["bare-code"])
        self.assertEqual(check("#318 is open.\n", github=True), [])

    def test_a_code_the_document_defines_passes(self) -> None:
        later = "This follows W5.1 closely.\n"
        self.assertEqual(rules(check(later, "full")), ["bare-code"])
        text = "### W5. Handover\n\n- **W5.1** The note names the owner first.\n\n" + later
        self.assertEqual(lint.defined_codes(text, CONFIG.codes), frozenset({"W5"}))
        self.assertEqual(check(text, "full"), [])

    def test_the_project_decides_what_a_code_looks_like(self) -> None:
        self.assertEqual(check("The pier is called HARBOR9 now.\n"), [])
        pattern = re.compile(r"(?<![A-Za-z0-9_])HARBOR[0-9]+(?![A-Za-z0-9_])")
        mine = CONFIG._replace(codes=CONFIG.codes._replace(
            patterns=(*CONFIG.codes.patterns, pattern)))
        found = lint.lint_text("The pier is called HARBOR9 now.\n", "a.md", "terse", mine)
        self.assertEqual([code_of(f) for f in found], ["HARBOR9"])
        allowed = mine._replace(codes=mine.codes._replace(allowed=frozenset({"HARBOR9"})))
        self.assertEqual(lint.lint_text("HARBOR9 is open.\n", "a.md", "terse", allowed), [])

    def test_a_bare_span_is_always_among_the_code_spans(self) -> None:
        # ``lint._code_spans`` repeats the overlap rule of the parser's ``bare_spans``.
        markdown = support.markdown
        for line in ("Touches ORB-LAUNCH-14, KX7-2 and then KX7 and KX7",
                     "Both P1 and P10 appear, with UTF-8 and beacon-~a1c9 (ORB-12) and #318",
                     "the rota change (#318) and [ORB-12](x) and ORB-12/ORB-13"):
            with self.subTest(line=line):
                spans = lint._code_spans(line, CONFIG.codes)
                self.assertTrue(set(markdown.bare_spans(line, CONFIG.codes)) <= set(spans))
                self.assertTrue(all(line[start:end] not in CONFIG.codes.allowed
                                    for start, end in spans))


class Skipped(unittest.TestCase):
    def test_headings_tables_fences_quotes_and_trailers_are_skipped(self) -> None:
        long = " ".join(["KX7"] + ["tides"] * 59)
        self.assertEqual(set(rules(check(f"{long}.\n"))), {"bare-code", "long-sentence"})
        skipped = (f"## {long}\n\n"
                   f"| {long} |\n|---|\n| {long} |\n\n"
                   f"```\n{long}.\n```\n\n"
                   f"> {long}.\n> {long}.\n\n"
                   f"Ledger-Claims: {long}\n\n"
                   f"Co-Authored-By: {long}\n")
        self.assertEqual(check(skipped), [])

    def test_tool_written_lines_are_skipped(self) -> None:
        for header in ("Implementation:", "Realized-by:"):
            text = (f"{header}\n  - PR: #42 — complete\n"
                    "  - commit: abc1234 — partial — the dock work ORB-12\n")
            with self.subTest(header=header):
                self.assertEqual(check(text), [])
                bare = lint.lint_text(text, "a.md", "terse", CONFIG._replace(skip_blocks=()))
                self.assertEqual([code_of(f) for f in bare], ["#42", "ORB-12"])

    def test_skip_prefixes_skip_a_paragraph(self) -> None:
        text = f"Handover note: {sentence(60)}\n"
        self.assertEqual(rules(check(text)), ["long-sentence"])
        mine = CONFIG._replace(skip_prefixes=(*CONFIG.skip_prefixes, "Handover note:"))
        self.assertEqual(lint.lint_text(text, "a.md", "terse", mine), [])
        listed = lint.lint_text(f"- Handover note: {sentence(60)}\n", "a.md", "terse", mine)
        self.assertEqual(listed, [])

    # The shape of a ledger item: a YAML block of keys, then the text.
    LEDGER_ITEM = ("---\nstatus: open\nkey: beacon-~a1c9\nrelates: [sibling:beacon-~b2d4]\n"
                   f"summary: {sentence(40)}\n---\n# A ledger item\n\nThe timetable page keeps "
                   "its filter.\n")

    def test_front_matter_on_line_one_is_skipped(self) -> None:
        self.assertEqual(check(self.LEDGER_ITEM), [])
        # A # line inside the YAML block resembles a heading and defines nothing.
        comment = "---\n# KX7 moves the late sailing\n---\nKX7 is open.\n"
        self.assertEqual(lint.defined_codes(comment, CONFIG.codes), frozenset())
        self.assertEqual(where(check(comment)), [(4, "bare-code")])

    def test_a_dashed_block_below_line_one_or_unclosed_is_linted(self) -> None:
        below = "# A\n\n---\nkey: beacon-~a1c9\n---\n"
        self.assertEqual(where(check(below)), [(4, "bare-code")])
        unclosed = "---\nkey: beacon-~a1c9\n"
        self.assertEqual(where(check(unclosed)), [(2, "bare-code")])

    def test_crlf_keeps_line_numbers(self) -> None:
        three = f"- {sentence(5)} {sentence(5)} {sentence(5)}"
        text = f"# Title\n\nKX7 is open.\n\n{sentence(36)}\n\n{three}\n"
        expected = [(3, "bare-code"), (5, "long-sentence"), (7, "long-item")]
        self.assertEqual(where(check(text)), expected)
        self.assertEqual(where(check(text.replace("\n", "\r\n"))), expected)

    def test_crlf_and_a_byte_order_mark_lint_as_lf(self) -> None:
        # Each text has something a leading mark would hide: front matter on line one, a heading
        # that defines its code.
        texts = ("---\nkey: beacon-~a1c9\n---\n# Pager rota notes\n\nKX7 is open.\n",
                 "# Pager rota ORB-12 notes\n\nORB-12 is open.\n\nKX7 is open.\n")
        for text in texts:
            marked = "\ufeff" + text.replace("\n", "\r\n")
            with self.subTest(text=text):
                expected = check(text)
                self.assertEqual([code_of(f) for f in expected], ["KX7"])
                self.assertEqual(check(marked), expected)
                self.assertEqual(lint.identifier_density(marked), lint.identifier_density(text))
                with support.git_repo() as repo:
                    put(repo, {"a.md": marked.encode("utf-8")})
                    done = run("check", "--profile", "terse", "a.md", cwd=repo)
                self.assertEqual(done.code, 1, done.out + done.err)
                self.assertIn(f"a.md:{expected[0].line}: bare-code: ", done.out)

    @staticmethod
    def injected_titles() -> list[str]:
        """The task headings ``spec-inject`` writes, as its procedure shows them, numbered."""
        actions = (REPO_ROOT / "references" / "spec-lifecycle-actions.md").read_text("utf-8")
        titles = re.findall(r"^\s*(### Task N\+\d[a-z]?: .+)$", actions, re.MULTILINE)
        return [re.sub(r"\{[^}]*\}", "7", re.sub(r"N\+(\d)", r"\1", title))
                for title in titles]

    def test_the_plan_tasks_doc_superpowers_injects_are_skipped(self) -> None:
        body = f"- {sentence(60)} See KX7 now.\n"
        titles = self.injected_titles()
        self.assertGreaterEqual(len(titles), 6)
        for title in titles:
            with self.subTest(title=title):
                self.assertEqual(check(f"# Plan\n\n{title}\n\n{body}"), [])
        other = f"### Task 3: other\n\n{body}"
        self.assertEqual(set(rules(check(other))), {"long-item", "long-sentence", "bare-code"})
        # A later heading at the task's level or above ends the skip.
        both = f"{titles[0]}\n\n{body}\n{other}"
        self.assertEqual({f.line for f in check(both)}, {7})
        self.assertNotEqual(check(both, "full"), [])

    def test_a_task_heading_deeper_or_shallower_than_the_skipped_one_ends_it(self) -> None:
        body = f"- {sentence(60)}\n"
        title = self.injected_titles()[0].replace("### ", "## ", 1)  # a level-2 heading
        deeper = f"{title}\n\n{body}\n### Task 3: other\n\n{body}"
        self.assertEqual(check(deeper), [])  # a sub-heading stays inside the skipped task
        shallower = f"{title}\n\n{body}\n# Appendix\n\n{body}"
        self.assertNotEqual(check(shallower), [])

    def test_a_task_that_is_not_injected_is_linted(self) -> None:
        self.assertNotEqual(check(f"### Task 4: Write the tests\n\n- {sentence(60)}\n"), [])


class Blocks(unittest.TestCase):
    """The block a tool writes after a header such as ``Implementation:``: the header line,
    each ``- `` item at any indent, and the item's indented lines. It ends at a blank line, at a
    fence, or at an unindented line that is not an item; only the first header of a file opens
    one."""

    ADR = ("# Adopt the harbor schedule\n\n**Status**: Accepted\n\n"
           "Implementation:\n"
           "- PR #42 — complete\n"
           "  - commit: abc1234 — partial — the second phase waits for the dock work, which\n"
           "    ORB-12 tracks\n"
           "\n"
           "The schedule follows KX7 for now.\n")

    def test_an_implementation_block_is_skipped_whole(self) -> None:
        for register in ("terse", "full"):
            with self.subTest(register=register):
                found = check(self.ADR, register)
                self.assertEqual([(f.line, code_of(f)) for f in found], [(10, "KX7")])
        # Each of the block's items holds a code that would be a finding on its own.
        bare = lint.lint_text(self.ADR, "a.md", "terse", CONFIG._replace(skip_blocks=()))
        self.assertEqual([code_of(f) for f in bare], ["#42", "ORB-12", "KX7"])

    def test_a_second_implementation_header_is_prose(self) -> None:
        later = "Implementation:\n- PR #42 — complete\n\nRealized-by:\n- PR #57 — partial\n"
        self.assertEqual([(f.line, code_of(f)) for f in check(later)], [(5, "#57")])
        # Directly after the block, with no blank line, it still ends the block as prose.
        close = "Implementation:\n- PR #42 — complete\nImplementation:\n- PR #57 — partial\n"
        self.assertEqual([(f.line, code_of(f)) for f in check(close)], [(4, "#57")])

    def test_a_blank_line_ends_the_skipped_block(self) -> None:
        text = "Implementation:\n- PR #42 — complete\n\n- PR #57 — partial\n"
        self.assertEqual([(f.line, code_of(f)) for f in check(text)], [(4, "#57")])

    def test_an_unindented_line_that_is_not_an_item_ends_the_skipped_block(self) -> None:
        text = "Implementation:\n- PR #42 — complete\nThen KX7 is next.\n  - PR #57 — partial\n"
        self.assertEqual([(f.line, code_of(f)) for f in check(text)],
                         [(3, "KX7"), (4, "#57")])

    def test_a_fence_ends_the_skipped_block(self) -> None:
        text = ("Implementation:\n- PR #42 — complete\n~~~\nsome sample output\n~~~\n"
                "- PR #57 — partial\n")
        self.assertEqual([(f.line, code_of(f)) for f in check(text)], [(6, "#57")])

    def test_a_header_in_a_fence_does_not_open_the_block(self) -> None:
        text = ("~~~\nImplementation:\n~~~\n\n"
                "Implementation:\n- PR #42 — complete\n")
        self.assertEqual(check(text), [])

    def test_an_empty_block_is_one_line(self) -> None:
        for header in ("Implementation: []", "Realized-by: [ ]"):
            with self.subTest(header=header):
                text = f"{header}\n- PR #42 — complete\n"
                self.assertEqual([(f.line, code_of(f)) for f in check(text)], [(2, "#42")])
        self.assertEqual(check("Implementation: []\n"), [])

    def test_a_header_with_words_after_it_is_prose(self) -> None:
        # Only a bare header (or "[]") is a block, so a sentence that happens to start with the
        # word is read like any other.
        text = "Implementation: ORB-14 — partial\n"
        self.assertEqual([code_of(f) for f in check(text)], ["ORB-14"])
        # It does not use up the file's one block either.
        both = f"{text}\nRealized-by:\n- PR #42 — complete\n"
        self.assertEqual([code_of(f) for f in check(both)], ["ORB-14"])

    def test_a_header_that_is_inside_a_list_item_or_a_quote_is_prose(self) -> None:
        text = "- Implementation:\n- PR #42 — complete\n\n> Realized-by:\n"
        self.assertEqual([code_of(f) for f in check(text)], ["#42"])

    def test_the_project_can_name_more_blocks(self) -> None:
        text = "Steps:\n- ORB-12 first\n  - then KX7\n"
        self.assertEqual([code_of(f) for f in check(text)], ["ORB-12", "KX7"])
        mine = CONFIG._replace(skip_blocks=(*CONFIG.skip_blocks, "Steps:"))
        self.assertEqual(lint.lint_text(text, "a.md", "terse", mine), [])

    def test_a_skipped_block_is_left_out_of_the_density(self) -> None:
        text = ("Implementation:\n- `a` `b` `c` `d` `e` `f` `g` `h` `i` `j`\n\n"
                "Eight plain words stand in this short line here.\n")
        self.assertEqual(lint.identifier_density(text, (), CONFIG.skip_blocks), 0.0)
        self.assertGreater(lint.identifier_density(text), 0.0)


class Density(unittest.TestCase):
    def test_density_counts_backtick_spans(self) -> None:
        text = "`one` `two` `three` " + " ".join(["words"] * 97) + ".\n"
        self.assertEqual(lint.identifier_density(text), 3.0)
        self.assertEqual(lint.identifier_density(""), 0.0)

    def test_density_leaves_skipped_lines_out(self) -> None:
        text = "`a` b c d e f g h i j.\n\nCo-Authored-By: `x` `y` `z` more words.\n"
        self.assertEqual(lint.identifier_density(text, CONFIG.skip_prefixes), 10.0)
        self.assertGreater(lint.identifier_density(text), 10.0)


class CommandLine(unittest.TestCase):
    def test_main_exit_codes(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"clean.md": "# Notes\n\nThe timetable page keeps its filter.\n",
                       "flagged.md": "# Notes\n\nKX7 is open.\n"})

            done = run("check", "--profile", "terse", "clean.md", cwd=repo)
            self.assertEqual(done.code, 0, done.out + done.err)
            self.assertIn("per 100 words", done.out)

            found = run("check", "--profile", "terse", "flagged.md", cwd=repo)
            self.assertEqual(found.code, 1)
            self.assertIn("flagged.md:3: bare-code: ", found.out)

            missing = run("check", "--profile", "full", "missing.md", "flagged.md", cwd=repo)
            self.assertEqual(missing.code, 2)
            self.assertIn("cannot read missing.md", missing.err)
            self.assertIn("bare-code", missing.out)

    # Three paragraphs with one finding each: a code on line 4 (paragraph 3-4), a long sentence
    # wrapped over lines 6-7, and a long item over lines 9-10.
    _LONG = sentence(36).split()
    EACH_RULE = ("# Notes\n\nThe timetable page keeps its filter.\nThen KX7 is open.\n\n"
                 f"{' '.join(_LONG[:18])}\n{' '.join(_LONG[18:])}\n\n"
                 f"- {sentence(25)}\n  {sentence(26)}\n")
    JSON_KEYS = {"path", "line", "rule", "message", "paragraph_first_line",
                 "paragraph_last_line"}

    def test_json_lists_each_finding_with_its_paragraph(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"notes.md": self.EACH_RULE})
            done = run("check", "--format", "json", "--profile", "terse", "notes.md", cwd=repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        found = json.loads(done.out)  # only the list; the density line is text output
        self.assertTrue(all(set(item) == self.JSON_KEYS for item in found))
        self.assertEqual(
            [(item["path"], item["line"], item["rule"], item["paragraph_first_line"],
              item["paragraph_last_line"]) for item in found],
            [("notes.md", 4, "bare-code", 3, 4), ("notes.md", 6, "long-sentence", 6, 7),
             ("notes.md", 9, "long-item", 9, 10)])
        text = lint.lint_text(self.EACH_RULE, "notes.md", "terse", CONFIG)
        self.assertEqual([item["message"] for item in found], [f.message for f in text])

    def test_json_of_a_clean_file_is_an_empty_list(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"clean.md": "# Notes\n\nThe timetable page keeps its filter.\n"})
            done = run("check", "--format", "json", "--profile", "full", "clean.md", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(json.loads(done.out), [])

    def test_json_keeps_exit_2_for_an_unreadable_file(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"flagged.md": "# Notes\n\nKX7 is open.\n"})
            done = run("check", "--format", "json", "--profile", "terse", "missing.md",
                       "flagged.md", cwd=repo)
        self.assertEqual(done.code, 2)
        self.assertIn("missing.md", done.err)
        self.assertEqual([(item["line"], item["rule"]) for item in json.loads(done.out)],
                         [(3, "bare-code")])

    def test_stdin_is_read_with_its_label(self) -> None:
        text = "# Notes\n\nKX7 is open.\n"
        with support.git_repo() as repo:
            done = run("check", "--profile", "terse", "--name", "body.md", "-", cwd=repo,
                       stdin=text)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertIn("body.md:3: bare-code: ", done.out)
            self.assertIn("body.md: ", done.out.splitlines()[-1])  # its density line

            as_json = run("check", "--format", "json", "--profile", "terse", "--name",
                          "body.md", "-", cwd=repo, stdin=text)
            self.assertEqual([item["path"] for item in json.loads(as_json.out)], ["body.md"])

            unnamed = run("check", "--profile", "terse", "-", cwd=repo, stdin=text)
            self.assertIn("<stdin>:3: bare-code: ", unnamed.out)

            # The name is only a label: it does not give standard input a register.
            no_profile = run("check", "--name", "docs/plans/x.md", "-", cwd=repo, stdin=text)
            self.assertEqual(no_profile.code, 2, no_profile.out + no_profile.err)
            self.assertEqual(no_profile.out, "")
            self.assertIn("--profile", no_profile.err)

    def test_stdin_with_a_byte_order_mark_and_crlf(self) -> None:
        with support.git_repo() as repo:
            done = run("check", "--profile", "terse", "-", cwd=repo,
                       stdin="\ufeff# Notes\r\n\r\nKX7 is open.\r\n")
        self.assertIn("<stdin>:3: bare-code: ", done.out)

    def test_the_github_flag_reaches_the_lint(self) -> None:
        with support.git_repo() as repo:
            plain = run("check", "--profile", "terse", "-", cwd=repo, stdin="#318 is open.\n")
            linked = run("check", "--github", "--profile", "terse", "-", cwd=repo,
                         stdin="#318 is open.\n")
        self.assertEqual(plain.code, 1)
        self.assertEqual(linked.code, 0, linked.out + linked.err)

    def test_a_file_that_is_not_utf8_exits_2(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"latin.md": b"# Notes\n\nCaf\xe9 stays open.\n",
                       "flagged.md": "# Notes\n\nKX7 is open.\n"})
            done = run("check", "--profile", "terse", "latin.md", "flagged.md", cwd=repo)
            piped = run("check", "--profile", "terse", "-", cwd=repo, stdin=b"Caf\xe9\n")
        self.assertEqual(done.code, 2)
        self.assertIn("cannot read latin.md: not UTF-8", done.err)
        self.assertNotIn("Traceback", done.err)
        self.assertIn("flagged.md:3: bare-code", done.out)  # the other file is still linted
        self.assertEqual(piped.code, 2)
        self.assertIn("cannot read <stdin>: not UTF-8", piped.err)

    def test_a_directory_is_not_a_file_to_lint(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"docs/a.md": "Fine.\n"})
            done = run("check", "--profile", "terse", "docs", cwd=repo)
        self.assertEqual(done.code, 2)
        self.assertIn("cannot read docs: ", done.err)
        self.assertNotIn("Traceback", done.err)

    def test_a_crash_exits_2_not_1(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing crash ") as base:
            target = Path(base) / "a.md"
            target.write_text("KX7 is open.\n", encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with in_directory(Path(base)), \
                    mock.patch.object(lint, "lint_text", side_effect=RuntimeError("boom")), \
                    redirect_stdout(out), redirect_stderr(err):
                status = lint.entry(["check", "--profile", "terse", str(target)])
        self.assertEqual(status, 2)
        self.assertIn("writing: internal error: RuntimeError: boom", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())

    def test_malformed_config_exits_2(self) -> None:
        cases = (('{"limits": {"terse": {"sentence": 0}}}', "limits.terse.sentence"),
                 ('{"codes": {"patterns": ["("]}}', "codes.patterns[0]"),
                 ('{"stale": 1}', "stale"),
                 ("{", "not valid JSON"))
        for text, key in cases:
            with self.subTest(text=text), support.git_repo() as repo:
                put(repo, {"docs/writing/config.json": text, "a.md": "Fine.\n"})
                done = run("check", "--profile", "terse", "a.md", cwd=repo)
                self.assertEqual(done.code, 2, done.out + done.err)
                self.assertIn("docs/writing/config.json", done.err)
                self.assertIn(key, done.err)
                self.assertNotIn("Traceback", done.err)
                self.assertNotIn("internal error", done.err)  # reported, not a crash
                self.assertEqual(done.out, "")

    def test_usage_errors_exit_2(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"a.md": "Fine.\n"})
            for args in (["check"],                                     # no file
                         ["check", "--profile", "brief", "a.md"],       # a register that is not
                         ["check", "--format", "xml", "a.md"],
                         ["check", "-"],                                # no register
                         ["check", "--name", "body.md", "-"],           # a label is no register
                         ["check", "--name", "body.md", "a.md"],        # a label for no stdin
                         ["check", "--profile", "terse", "-", "-"],
                         []):                                           # no subcommand
                with self.subTest(args=args):
                    done = run(*args, cwd=repo, stdin="")
                    self.assertEqual(done.code, 2, done.out + done.err)
                    self.assertNotIn("Traceback", done.err)


class Registers(unittest.TestCase):
    LONG_ITEM = f"- {sentence(5)} {sentence(5)} {sentence(5)}\n"

    def test_without_a_profile_each_file_gets_its_register(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"docs/plans/2026-plan.md": self.LONG_ITEM,
                       "docs/guides/ferries.md": self.LONG_ITEM,
                       "docs/notes.md": self.LONG_ITEM,
                       "docs/plans/typed.md": self.LONG_ITEM,
                       "README.md": "KX7 is open.\n",
                       "src/notes.txt": "KX7 is open.\n"})
            # The doc-index type is read before the path: a plan type makes a file under docs/
            # terse, and a guide type makes a file under docs/plans/ full.
            index = {"docs/notes.md": {"doc_type": "plan"},
                     "docs/plans/typed.md": {"doc_type": "guide"}}
            put(repo, {"docs/.doc-index.json": json.dumps({"docs": index})})
            terse = run("check", "docs/plans/2026-plan.md", cwd=repo)
            full = run("check", "docs/guides/ferries.md", cwd=repo)
            typed_terse = run("check", "docs/notes.md", cwd=repo)
            typed_full = run("check", "docs/plans/typed.md", cwd=repo)
            none = run("check", "README.md", "src/notes.txt", cwd=repo)
            none_json = run("check", "--format", "json", "README.md", cwd=repo)
        self.assertEqual(terse.code, 1)
        self.assertIn("docs/plans/2026-plan.md:1: long-item: ", terse.out)
        self.assertEqual(full.code, 0, full.out + full.err)
        self.assertEqual(typed_terse.code, 1, typed_terse.out + typed_terse.err)
        self.assertEqual(typed_full.code, 0, typed_full.out + typed_full.err)
        self.assertEqual(none.code, 0, none.out + none.err)
        self.assertEqual(none.out, "")
        self.assertEqual((none_json.code, json.loads(none_json.out)), (0, []))
        self.assertEqual(none.err.splitlines(), ["README.md: not linted (no register)",
                                                 "src/notes.txt: not linted (no register)"])

    def test_the_register_is_looked_up_from_the_top_of_the_repository(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"docs/plans/2026-plan.md": self.LONG_ITEM})
            nested = run("check", "plans/2026-plan.md", cwd=repo / "docs")
            absolute = run("check", str(repo / "docs/plans/2026-plan.md"), cwd=repo / "docs")
            outside = run("check", str(Path(sys.executable).resolve()), cwd=repo)
        self.assertEqual(nested.code, 1, nested.out + nested.err)
        self.assertIn("plans/2026-plan.md:1: long-item: ", nested.out)
        self.assertEqual(absolute.code, 1, absolute.out + absolute.err)
        self.assertEqual(outside.code, 0, outside.out + outside.err)
        self.assertIn("not linted (no register)", outside.err)

    def test_a_file_outside_any_repository_is_looked_up_from_where_it_is_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing plain ") as base:
            put(Path(base), {"docs/guides/ferries.md": f"{sentence(41)}\n"})
            home = Path(base) / "home"
            home.mkdir()
            env = {**os.environ, "HOME": str(home), "GIT_CEILING_DIRECTORIES": str(base)}
            with mock.patch.dict(os.environ, env, clear=True):
                done = run("check", "docs/guides/ferries.md", cwd=Path(base))
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn("docs/guides/ferries.md:1: long-sentence: ", done.out)
        self.assertIn("the full limit of 40", done.out)

    def test_a_tool_written_block_does_not_fail_the_check(self) -> None:
        adr = ("# Adopt the harbor schedule\n\n**Status**: Accepted\n\n"
               "Implementation:\n  - PR #42 — complete (`a` `b` `c`)\n")
        with support.git_repo() as repo:
            put(repo, {"docs/adr/0007-harbor.md": adr})
            done = run("check", "docs/adr/0007-harbor.md", cwd=repo)
            settings = {"skip_blocks": []}
            put(repo, {"docs/writing/config.json": json.dumps(settings)})
            unchanged = run("check", "docs/adr/0007-harbor.md", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertIn("0.0 backtick spans per 100 words", done.out)  # the block's spans are out
        self.assertEqual(unchanged.code, 0, unchanged.out + unchanged.err)  # lists only add

    def test_a_profile_overrides_the_lookup(self) -> None:
        with support.git_repo() as repo:
            put(repo, {"docs/guides/ferries.md": self.LONG_ITEM, "README.md": self.LONG_ITEM})
            full = run("check", "--profile", "terse", "docs/guides/ferries.md", "README.md",
                       cwd=repo)
        self.assertEqual(full.code, 1)
        self.assertEqual(sorted(re.findall(r"^(\S+):1: long-item", full.out, re.MULTILINE)),
                         ["README.md", "docs/guides/ferries.md"])

    def test_the_projects_configuration_reaches_the_check(self) -> None:
        settings = {"limits": {"full": {"sentence": 20}},
                    "codes": {"allowed": ["KX7"]},
                    "skip_prefixes": ["Handover note:"],
                    "registers": {"paths": [{"prefix": "ops/", "register": "terse"}]}}
        with support.git_repo() as repo:
            put(repo, {"docs/writing/config.json": json.dumps(settings),
                       "docs/guides/ferries.md":
                           f"{sentence(21)}\n\nKX7 is open.\n\nHandover note: {sentence(45)}\n",
                       "ops/runbook.md": f"{sentence(36)}\n"})
            guide = run("check", "docs/guides/ferries.md", cwd=repo)
            ops = run("check", "ops/runbook.md", cwd=repo)
        self.assertEqual(guide.code, 1)
        self.assertEqual(re.findall(r"^\S+:(\d+): (\S+):", guide.out, re.MULTILINE),
                         [("1", "long-sentence")])
        self.assertEqual(ops.code, 1, ops.out + ops.err)  # the rule made it terse: 35 words
        self.assertIn("ops/runbook.md:1: long-sentence: ", ops.out)
        self.assertIn("the terse limit of 35", ops.out)


class PullRequestBodies(unittest.TestCase):
    # Two invented bodies, about a library's return desk and a weather station's sensors: one
    # whose paragraph and list item run on and carry many identifiers, one whose codes stand
    # without words.
    RUN_ON_BODY = """# Route returned books to the right branch

## Why

Until now a book dropped at the wrong branch sat in a bin until a volunteer spotted the stamp \
on its spine, so a reader waiting elsewhere saw `HoldState.pending` for `12` days, long after \
the copy had come back through `ReturnDesk.scan` and been checked in by whoever was on shift.

## What changed

- `ReturnDesk.route` compares `copy.home_branch` with `DeskConfig.branch_id`.
- A copy for another branch goes to `transfer_bin` and prints a `TransferSlip`. A copy for \
this branch goes to `ShelfQueue.push`. A damaged copy goes to `repair_hold` instead.
- The label printer stops jamming when `TransferSlip.render` gets a long title.

## Not changed

The hold rules stay as they are.
"""

    RUN_ON_FIXED = """# Route returned books to the right branch

## Why

A book dropped at the wrong branch used to wait in a bin for days. A reader waiting elsewhere
saw the hold as pending long after the copy came back.

## What changed

- `ReturnDesk.route` compares the copy's home branch with the desk's branch.
- A copy for another branch goes to the transfer bin and prints a slip.
- A copy for this branch goes to the shelving queue.
- A damaged copy goes to the repair hold instead.
- The label printer no longer jams on a long title.

## Not changed

The hold rules stay as they are.
"""

    def test_a_run_on_pr_body_fails_long_item_and_long_sentence(self) -> None:
        found = lint.lint_text(self.RUN_ON_BODY, "body.md", "terse", CONFIG)
        self.assertEqual(where(found), [(5, "long-sentence"), (10, "long-item")])
        self.assertIn("a sentence of 50 words", found[0].message)
        self.assertIn("27 words and 3 sentences", found[1].message)
        self.assertGreater(lint.identifier_density(self.RUN_ON_BODY), 8)
        self.assertEqual(lint.lint_text(self.RUN_ON_FIXED, "body.md", "terse", CONFIG), [])

    CODED_BODY = """# Roll out the rooftop sensors

The first batch goes live next week, following {A}. Two sites still wait on {B}, and the \
wind gauges stay off until {C} arrives.

## Steps

1. Install the mounts at the north site, as {D} describes.
2. Calibrate each gauge against the reference unit before {E} is filed.
3. Log every reading in the shared sheet during {F}.
"""
    # For each slot: its code, and the words that explain it.
    CODED = {"A": ("WX-31", "the rollout plan"), "B": ("RM4", "the roof-access review"),
             "C": ("gauge-~b7e2", "the wind-gauge order"), "D": ("SPC-118", "the mounting spec"),
             "E": ("#318", "the permit request"), "F": ("TRL-0317", "the field trial")}

    def coded_body(self, form: str) -> str:
        """Render the body with every code left alone, explained in words, linked, or defined
        in a key."""
        if form == "glossed":
            return self.CODED_BODY.format(**{slot: f"{words} ({code})"
                                             for slot, (code, words) in self.CODED.items()})
        if form == "linked":
            return self.CODED_BODY.format(**{
                slot: f"[{code}](https://example.test/{code.lower()})"
                for slot, (code, _) in self.CODED.items()})
        text = self.CODED_BODY.format(**{slot: code for slot, (code, _) in self.CODED.items()})
        if form == "keyed":
            text += "\n## Key\n\n" + "".join(
                f"- **{code}** is {words} ([record](https://example.test/{code.lower()})).\n"
                for code, words in self.CODED.values())
        return text

    def test_a_coded_pr_body_fails_bare_code_until_glossed_linked_or_keyed(self) -> None:
        found = lint.lint_text(self.coded_body("bare"), "body.md", "terse", CONFIG)
        self.assertEqual([(f.line, f.rule, code_of(f)) for f in found],
                         [(3, "bare-code", "WX-31"), (3, "bare-code", "RM4"),
                          (3, "bare-code", "gauge-~b7e2"), (7, "bare-code", "SPC-118"),
                          (8, "bare-code", "#318"), (9, "bare-code", "TRL-0317")])
        for form in ("glossed", "linked", "keyed"):
            with self.subTest(form=form):
                self.assertEqual(
                    lint.lint_text(self.coded_body(form), "body.md", "terse", CONFIG), [])


if __name__ == "__main__":
    unittest.main()
