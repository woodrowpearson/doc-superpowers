"""Range mode of the writing lint, run on invented history.

``range`` lints what a branch wrote and nothing it inherited. It compares the merge base with
the committed ``HEAD`` and never reads the working tree, so old text, text moved between files
and edits that touch only a number, a link target or a line wrap are not the branch's. Every
repository below is built in a throwaway directory that no global git setting can reach, and every
path, code and sentence is made up.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from tests import support
from tests.support import code_of, default_config, put, run, where

lint = support.load("lint")
config = support.load("config")

# The shipped defaults, with no project file and no work ledger.
CONFIG = default_config()

# Two vocabularies, so a rewrite can keep under 60% of its source's words.
LOAVES = "the cooling racks hold sixty small loaves beside two warm ovens".split()
HARBOR = "sailors mend torn canvas before the harbor wind rises again tonight".split()


def sentence(words: int, vocabulary: list[str] = LOAVES) -> str:
    """A sentence of ``words`` words and no code. A longer sentence begins with the words of a
    shorter one, so the pair reads as one sentence rewritten."""
    chosen = [vocabulary[number % len(vocabulary)] for number in range(words)]
    return " ".join(chosen).capitalize() + "."


# Short sentences about unrelated things; a file made of them shares almost nothing with another.
SHORTS = (
    "Trays are counted at dawn.", "Flour arrives on Tuesday.", "The scale needs a new battery.",
    "Sourdough rests overnight.", "Ask the porter for the cellar key.", "Yeast is kept cold.",
    "Aprons hang beside the sink.", "The van leaves at six.", "Rye costs more than wheat.",
    "Close the shutters after rain.", "Salt is stored in tins.", "Rolls sell out by noon.",
    "The ledger lives in the drawer.", "Each baker signs the rota.", "Cracked eggs are binned.",
    "The window faces the canal.", "Crumbs go to the ducks.", "Lids are washed on Fridays.",
)


@contextmanager
def forked() -> Iterator[Path]:
    """A repository with one commit on ``main`` and the work branch ``feat`` checked out of it."""
    with support.git_repo() as repo:
        support.commit(repo, {"README.md": "The base commit.\n"}, "base")
        support.run_git(repo, "checkout", "-q", "-b", "feat")
        yield repo


def on_main(repo: Path, files: dict[str, str]) -> None:
    """Commit ``files`` on ``main`` and move the branch back to that tip."""
    support.run_git(repo, "checkout", "-q", "main")
    support.commit(repo, files, "text on main")
    support.run_git(repo, "checkout", "-q", "-B", "feat", "main")


def new_lint(repo: Path, path: str) -> dict:
    return lint.new_sentences(repo, "main", path, CONFIG)


class Additions(unittest.TestCase):
    """Which sentences of a changed file are the branch's own."""

    def test_range_lints_a_new_long_sentence(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/guides/bakery.md":
                                  f"# Bakery\n\n{sentence(6)}\n\n{sentence(47)}\n"}, "add")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [("docs/guides/bakery.md", 5, "long-sentence")])

    def test_range_leaves_an_old_sentence_whose_number_changed(self) -> None:
        old = sentence(37)[:-1] + " beside tray 31 today."
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{old}\n"})
            self.assertEqual(len(lint.lint_text(old, path, "full", CONFIG)), 1)
            support.commit(repo, {path: f"# Bakery\n\n{old.replace('tray 31', 'tray 47')}\n"},
                           "update the tray number")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            # Going from one digit to three changes only a number as well.
            single = old.replace("tray 31", "tray 7")
            on_main(repo, {path: f"# Bakery\n\n{single}\n"})
            support.commit(repo, {path: f"# Bakery\n\n{single.replace('tray 7', 'tray 118')}\n"},
                           "give the number more digits")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_reports_only_the_new_sentence_of_a_paragraph(self) -> None:
        # The paragraph keeps its old long sentence and gains a short one; that one alone is new.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{sentence(43)}\n"})
            support.commit(repo, {path: f"# Bakery\n\n{sentence(43)}\nProofing starts at five.\n"},
                           "add a short sentence")
            self.assertEqual(set(new_lint(repo, path)), {"Proofing starts at five."})
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_lints_the_committed_head_not_the_working_tree(self) -> None:
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{sentence(4)}\n"})
            put(repo, {path: f"# Bakery\n\n{sentence(4)}\n\n{sentence(48)}\n"})
            self.assertEqual(new_lint(repo, path), {})
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            support.commit(repo, {path: f"# Bakery\n\n{sentence(4)}\n\n{sentence(48)}\n"},
                           "add a long one")
            self.assertEqual(where(lint.lint_range(repo, "main", CONFIG)), [(5, "long-sentence")])
            # What HEAD holds is what counts, whatever the file on disk says by then.
            put(repo, {path: f"# Bakery\n\n{sentence(4)}\n"})
            self.assertEqual(where(lint.lint_range(repo, "main", CONFIG)), [(5, "long-sentence")])

    def test_range_lints_every_sentence_of_a_new_file(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/issues/oven-log.md":
                                  f"# Oven log\n\n{sentence(37)}\n\n"
                                  "- Wipe the door seal; ROW-3 waits.\n"}, "add")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual(where(found), [(3, "long-sentence"), (5, "bare-code")])

    # The shape of a ledger item: a YAML block of keys, then the text.
    LEDGER_ITEM = ("---\nkey: kiln-~7e3b\nowner: tessa\nstatus: open\n"
                   f"relates: [sibling:kiln-~9a0c]\nsummary: {sentence(43)}\n---\n"
                   "# Kiln repair\n\nThe glaze shelf needs a new bracket.\n")

    def test_range_passes_a_ledger_item_with_front_matter(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/issues/2026-11-02-kiln-repair.md": self.LEDGER_ITEM},
                           "add a ledger item")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            done = run("range", "main...HEAD", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)

    def test_range_picks_the_profile_by_path(self) -> None:
        self.assertEqual([f.rule for f in lint.lint_text(sentence(37), "a.md", "terse", CONFIG)],
                         ["long-sentence"])
        with forked() as repo:
            support.commit(repo, {"docs/guides/bakery.md": f"# Bakery\n\n{sentence(37)}\n",
                                  "README.md": f"{sentence(52)}\n"}, "full register, unread file")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            support.commit(repo, {"ops/AGENTS.md": f"# Agents\n\n{sentence(37)}\n"}, "terse")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [("ops/AGENTS.md", 3, "long-sentence")])

    def test_range_keeps_old_codes_and_reports_a_lengthened_item(self) -> None:
        guide = "docs/guides/bakery.md"
        issue = "docs/issues/bakery.md"
        with forked() as repo:
            on_main(repo, {guide: "# Bakery\n\nRack ROW-3 is still empty.\n"})
            support.commit(repo, {guide: "# Bakery\n\nRack ROW-3 is still empty.\n"
                                         "Ovens heat by six.\n"}, "append a line to the paragraph")
            text = "Rack ROW-3 is still empty.\nOvens heat by six.\n"
            self.assertEqual([f.rule for f in lint.lint_text(text, "a.md", "full", CONFIG)],
                             ["bare-code"])
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

            on_main(repo, {issue: f"# Bakery\n\n- {sentence(21)}\n  {sentence(26)}\n"})
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            support.commit(repo, {issue: f"# Bakery\n\n- {sentence(21)}\n  {sentence(31)}\n"},
                           "stretch the item")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual([(f.path, f.line, f.rule) for f in found], [(issue, 3, "long-item")])

    def test_range_leaves_an_old_sentence_with_a_new_link_target_or_wrap(self) -> None:
        old = sentence(38)[:-1] + " per [the shift chart](charts/shifts.md)."
        self.assertEqual([f.rule for f in lint.lint_text(old, "a.md", "full", CONFIG)],
                         ["long-sentence"])
        halves = sentence(46).split(" ")
        with forked() as repo:
            on_main(repo, {"docs/guides/chart.md": f"# Chart\n\n{old}\n",
                           "docs/guides/rota.md": f"# Rota\n\n{sentence(46)}\n"})
            retargeted = old.replace("(charts/shifts.md)", "(charts/archive/shifts-2026.md)")
            put(repo, {"docs/guides/chart.md": f"# Chart\n\n{retargeted}\n",
                       "docs/guides/rota.md":
                           f"# Rota\n\n{' '.join(halves[:31])}\n{' '.join(halves[31:])}\n"})
            support.commit(repo, {}, "new link target, new line breaks")
            changed = support.run_git(repo, "diff", "--name-only", "main", "HEAD").split()
            self.assertEqual(changed, ["docs/guides/chart.md", "docs/guides/rota.md"])
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_leaves_an_old_long_sentence_with_one_word_changed(self) -> None:
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{sentence(44)}\n"})
            edited = sentence(44).replace("loaves", "rolls", 1)
            support.commit(repo, {path: f"# Bakery\n\n{edited}\n"}, "swap one word")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_leaves_a_line_the_branch_did_not_touch(self) -> None:
        # Dropping the fence around a long sentence turns it into prose, but the branch did not
        # write that line, so it is not the branch's to answer for.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n```\n{sentence(46)}\n```\n"})
            unfenced = f"# Bakery\n\n{sentence(46)}\n\nProofing starts at five.\n"
            support.commit(repo, {path: unfenced}, "unfence and extend")
            self.assertEqual(set(new_lint(repo, path)), {"Proofing starts at five."})
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_reports_a_rewritten_long_sentence(self) -> None:
        # Under 60% of the words survive, in order, so this is a new sentence and no edit. It is
        # shorter than its source, so were it taken for an edit it would pass unreported.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{sentence(48)}\n"})
            support.commit(repo, {path: f"# Bakery\n\n{sentence(43, HARBOR)}\n"},
                           "recast the sentence")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual(where(found), [(3, "long-sentence")])

    def test_range_reports_only_the_code_an_edit_adds(self) -> None:
        # The old sentence already carried SHELF-6 bare. The edit brings in NAV-52 beside it: both
        # are bare in the new sentence, but only the second is the branch's.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: "# Bakery\n\nLoaves leave the cooling rack SHELF-6 by nine.\n"})
            support.commit(repo, {path: "# Bakery\n\nLoaves leave the cooling rack SHELF-6 and "
                                        "NAV-52 by nine.\n"}, "bring in a bare code")
            whole = lint.lint_text("Loaves leave the cooling rack SHELF-6 and NAV-52 by nine.\n",
                                   "a.md", "full", CONFIG)
            self.assertEqual([code_of(f) for f in whole], ["SHELF-6", "NAV-52"])
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual([(f.line, f.rule, code_of(f)) for f in found],
                         [(3, "bare-code", "NAV-52")])

    def test_range_reports_a_new_code_of_the_series_already_bare(self) -> None:
        # The second code of the series is the branch's though the first was bare before it,
        # since digits are not blanked when codes are compared.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {path: "# Bakery\n\nThe night crew follows BAY-31 before opening.\n"})
            support.commit(repo, {path: "# Bakery\n\nThe night crew follows BAY-31 and BAY-32 "
                                        "before opening.\n"}, "add the next code of the series")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual([(f.line, f.rule, code_of(f)) for f in found],
                         [(3, "bare-code", "BAY-32")])

    def test_range_passes_a_plan_line_that_names_a_spec_file(self) -> None:
        path = "docs/plans/2026-10-28-oven-plan.md"
        with forked() as repo:
            on_main(repo, {path: "# Oven\n\n- Read the proofing notes.\n"})
            support.commit(repo, {path: "# Oven\n\n- Read the proofing notes.\n"
                                        "- Edit: `ops/runbooks/ROW-8-kiln.md`\n"}, "list a file")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_reports_a_sentence_an_edit_lengthens_past_the_limit(self) -> None:
        path = "docs/issues/bakery.md"
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{sentence(26)}\n\n{sentence(42)}\n"})
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            support.commit(repo, {path: f"# Bakery\n\n{sentence(36)}\n\n{sentence(42)}\n"},
                           "grow the sentence past the limit")
            self.assertEqual(where(lint.lint_range(repo, "main", CONFIG)), [(3, "long-sentence")])
            # Trimming a long sentence without getting it under the limit adds nothing to blame.
            support.commit(repo, {path: f"# Bakery\n\n{sentence(26)}\n\n{sentence(39)}\n"},
                           "trim it but stay over")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_reports_only_new_sentences_on_a_changed_line(self) -> None:
        # A line of old sentences takes one more; the branch wrote only that last one.
        path = "docs/guides/bakery.md"
        old = f"Bake TIDE-58 first. {sentence(43)}"
        self.assertEqual([f.rule for f in lint.lint_text(old, "a.md", "full", CONFIG)],
                         ["bare-code", "long-sentence"])
        with forked() as repo:
            on_main(repo, {path: f"# Bakery\n\n{old}\n"})
            support.commit(repo, {path: f"# Bakery\n\n{old} Glaze dries overnight.\n"}, "add one")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

            late = f"# Bakery\n\n{old} Next comes NAV-77 stacking.\n"
            support.commit(repo, {path: late}, "add a code")
            found = lint.lint_range(repo, "main", CONFIG)
            self.assertEqual([(f.line, f.rule, code_of(f)) for f in found],
                             [(3, "bare-code", "NAV-77")])
            # In normal form every run of digits is a single 0, the code's included.
            self.assertEqual(set(new_lint(repo, path)), {"Next comes NAV-0 stacking."})

    def test_range_skips_an_injected_plan_task(self) -> None:
        body = f"- {sentence(58)} Check NAV-41 later.\n"
        with forked() as repo:
            support.commit(repo, {"docs/plans/2026-10-28-oven-plan.md":
                                  f"# Plan\n\n### Task 9: Final claims gate\n\n{body}"},
                           "claims task")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            support.commit(repo, {"docs/plans/2026-10-29-oven-plan.md":
                                  f"# Plan\n\n### Task 9: Bake the loaves\n\n{body}"}, "own task")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual({f.rule for f in found}, {"long-item", "long-sentence", "bare-code"})


class Files(unittest.TestCase):
    """Which files and which base each changed file is compared with."""

    def test_range_ignores_a_deleted_file(self) -> None:
        with forked() as repo:
            on_main(repo, {"docs/guides/bakery.md": f"# Bakery\n\n{sentence(47)}\n"})
            support.run_git(repo, "rm", "-q", "docs/guides/bakery.md")
            support.commit(repo, {}, "delete the page")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_leaves_a_renamed_doc_with_old_findings(self) -> None:
        with forked() as repo:
            on_main(repo, {"docs/guides/a.md": f"# A\n\nBAY-9 stays reserved.\n\n{sentence(44)}\n"})
            support.run_git(repo, "mv", "docs/guides/a.md", "docs/guides/b.md")
            support.commit(repo, {}, "move the file")
            status = support.run_git(repo, "diff", "--name-status", "-M", "main", "HEAD").split()
            self.assertEqual(status, ["R100", "docs/guides/a.md", "docs/guides/b.md"])
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_leaves_text_moved_out_of_a_deleted_file(self) -> None:
        with forked() as repo:
            on_main(repo, {"docs/guides/a.md": f"# A\n\n{sentence(41)}\n"})
            support.run_git(repo, "rm", "-q", "docs/guides/a.md")
            others = "".join(f"\n{line}\n" for line in SHORTS[:16])
            support.commit(repo, {"docs/guides/c.md": f"# C\n{others}\n{sentence(41)}\n"},
                           "carry a sentence over to a new file")
            # Too little is shared for git to pair them as a rename, so the deleted file serves
            # as the old copy.
            status = support.run_git(repo, "diff", "--name-status", "-M", "main", "HEAD").split()
            self.assertEqual(status, ["D", "docs/guides/a.md", "A", "docs/guides/c.md"])
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_text_moved_out_of_a_deleted_upper_case_file_is_not_new(self) -> None:
        # A file named NOTES.MD is Markdown too, so what it held is what the branch carried over.
        with forked() as repo:
            on_main(repo, {"docs/guides/OLD-NOTES.MD": f"# Old\n\n{sentence(42)}\n"})
            support.run_git(repo, "rm", "-q", "docs/guides/OLD-NOTES.MD")
            others = "".join(f"\n{line}\n" for line in SHORTS[2:17])
            support.commit(repo, {"docs/guides/notes.md": f"# Notes\n{others}\n{sentence(42)}\n"},
                           "carry the sentence over")
            status = support.run_git(repo, "diff", "--name-status", "-M", "main", "HEAD").split()
            self.assertEqual(status, ["D", "docs/guides/OLD-NOTES.MD", "A", "docs/guides/notes.md"])
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_a_file_that_git_treats_as_binary_is_still_compared(self) -> None:
        # With "-diff" git prints "Binary files differ" and no hunk, unless it is told to treat the
        # blobs as text; the sentence added to the file must still be found.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            on_main(repo, {".gitattributes": "*.md -diff\n", path: f"# Bakery\n\n{sentence(4)}\n"})
            support.commit(repo, {path: f"# Bakery\n\n{sentence(4)}\n\n{sentence(44)}\n"}, "long")
            self.assertIn("Binary files", support.run_git(repo, "diff", "main", "HEAD", "--", path))
            self.assertEqual(where(lint.lint_range(repo, "main", CONFIG)), [(5, "long-sentence")])

    def test_range_compares_with_the_merge_base_not_the_tip_of_the_base(self) -> None:
        path = "docs/guides/bakery.md"
        with forked() as repo:
            support.run_git(repo, "checkout", "-q", "main")
            support.commit(repo, {path: f"# Bakery\n\n{sentence(45)}\n"}, "main text")
            support.run_git(repo, "checkout", "-q", "-B", "feat", "main")
            support.commit(repo, {"docs/guides/other.md": f"# Other\n\n{sentence(5)}\n"}, "work")
            # After the fork, main drops the long sentence. The branch never touched that file.
            support.run_git(repo, "checkout", "-q", "main")
            support.commit(repo, {path: "# Bakery\n\nShort now.\n"}, "main shortens it")
            support.run_git(repo, "checkout", "-q", "feat")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_a_path_with_a_space_or_accent_is_linted_under_its_name(self) -> None:
        # Without -z, git quotes such a name and the lint would open a file that is not there.
        name = "docs/a b/café.md"
        renamed = "docs/a b/thé \"menu\".md"
        with forked() as repo:
            on_main(repo, {name: f"# Café\n\n{sentence(45)}\n"})
            support.commit(repo, {name: f"# Café\n\n{sentence(45)}\n\n{sentence(46)}\n"}, "add")
            found = lint.lint_range(repo, "main", CONFIG)
            self.assertEqual([(f.path, f.line, f.rule) for f in found],
                             [(name, 5, "long-sentence")])
            done = run("range", "main...HEAD", cwd=repo)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertIn(f"{name}:5: long-sentence: ", done.out)
            self.assertIn(f"{name}: ", done.out.splitlines()[-1])  # its density line

            # A renamed file is compared with its old name, which is quoted the same way.
            support.run_git(repo, "checkout", "-q", "-B", "feat", "main")
            support.run_git(repo, "mv", name, renamed)
            support.commit(repo, {renamed: f"# Café\n\n{sentence(45)}\n\nHot rolls at noon.\n"},
                           "rename and extend")
            status = support.run_git(repo, "diff", "--name-status", "-z", "-M", "main", "HEAD")
            self.assertTrue(status.startswith("R"), status)
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])
            self.assertEqual(set(new_lint(repo, renamed)), {"Hot rolls at noon."})

    def test_a_base_that_is_not_utf8_is_read_leniently(self) -> None:
        # Only the head must decode: a base copy is just what the branch is compared with.
        path = "docs/guides/bakery.md"
        with forked() as repo:
            support.run_git(repo, "checkout", "-q", "main")
            put(repo, {path: b"# Bakery\n\nCaf\xe9 stays open.\n"})
            support.commit(repo, {}, "a latin-1 base")
            support.run_git(repo, "checkout", "-q", "-B", "feat", "main")
            support.commit(repo, {path: f"# Bakery\n\n{sentence(45)}\n"}, "rewrite in UTF-8")
            found = lint.lint_range(repo, "main", CONFIG)
        self.assertEqual(where(found), [(3, "long-sentence")])

    def test_a_head_file_that_is_not_utf8_exits_2(self) -> None:
        with forked() as repo:
            put(repo, {"docs/guides/cafe.md": b"# Bakery\n\nCaf\xe9 stays open.\n"})
            support.commit(repo, {}, "a latin-1 file")
            done = run("range", "main...HEAD", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("cannot read docs/guides/cafe.md: not UTF-8", done.err)
        self.assertNotIn("Traceback", done.err)
        self.assertNotIn("internal error", done.err)

    def test_crlf_and_a_byte_order_mark_lint_as_lf(self) -> None:
        plain = f"{self.LEDGER}# Notes\n\n{sentence(45)}\n"
        marked = "\ufeff" + plain.replace("\n", "\r\n")
        with forked() as repo:
            support.commit(repo, {"docs/guides/lf.md": plain}, "an LF file")
            support.commit(repo, {"docs/guides/crlf.md": marked}, "a CRLF file with a mark")
            found = lint.lint_range(repo, "main", CONFIG)
        by_path = {name: where([f for f in found if f.path == name])
                   for name in ("docs/guides/lf.md", "docs/guides/crlf.md")}
        self.assertEqual(by_path["docs/guides/lf.md"], [(9, "long-sentence")])
        self.assertEqual(by_path["docs/guides/crlf.md"], by_path["docs/guides/lf.md"])

    # Five lines of front matter and a blank one: the long summary is data, not a sentence.
    LEDGER = f"---\nkey: kiln-~7e3b\nstate: open\nsummary: {sentence(42)}\n---\n\n"


class Registers(unittest.TestCase):
    """The register of each file, and the configuration, are the committed HEAD's."""

    @staticmethod
    def index(entries: dict[str, str]) -> str:
        return json.dumps({"docs": {path: {"doc_type": kind} for path, kind in entries.items()}})

    def test_a_record_is_linted_in_range_mode(self) -> None:
        # A plan, an issue, an audit and a design spec are records of a moment; the freshness
        # check never reports them stale, but a sentence the branch adds to one is still checked.
        cases = (("plan", 38, True), ("issue", 38, True), ("audit", 38, True),
                 ("design-spec", 38, False), ("design-spec", 41, True))
        for kind, words, flagged in cases:
            with self.subTest(kind=kind, words=words), forked() as repo:
                path = "docs/notes/kiln-firing.md"
                support.commit(repo, {path: f"# Firing\n\n{sentence(words)}\n",
                                      "docs/.doc-index.json": self.index({path: kind})}, "add")
                found = lint.lint_range(repo, "main", CONFIG)
                self.assertEqual(where(found), [(3, "long-sentence")] if flagged else [])

    def test_the_archive_is_never_linted(self) -> None:
        path = "docs/archive/plans/old-kiln-plan.md"
        with forked() as repo:
            support.commit(repo, {path: f"# Old\n\n{sentence(47)}\n",
                                  "docs/.doc-index.json": self.index({path: "plan"})}, "archive")
            self.assertEqual(lint.lint_range(repo, "main", CONFIG), [])

    def test_range_reads_the_index_and_configuration_at_head(self) -> None:
        path = "docs/guides/kiln.md"
        with forked() as repo:
            settings = {"limits": {"full": {"sentence": 20}}}
            support.commit(repo, {path: f"# Kiln\n\n{sentence(25)}\n",
                                  "docs/writing/config.json": json.dumps(settings)}, "add")
            # Edits that were never committed change nothing.
            lenient = {"limits": {"full": {"sentence": 90}}}
            put(repo, {"docs/writing/config.json": json.dumps(lenient),
                       "docs/.doc-index.json": self.index({path: "plan"})})
            found = lint.lint_range(repo, "main", config.load(repo, "HEAD"))
            done = run("range", "main...HEAD", cwd=repo)
        self.assertEqual(where(found), [(3, "long-sentence")])
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn("kiln.md:3: long-sentence: ", done.out)
        self.assertIn("the full limit of 20", done.out)

    def test_range_applies_the_configured_skips(self) -> None:
        text = (f"# Notes\n\nHandover note: {sentence(45)}\n\nImplementation:\n"
                f"  - PR #42 complete\n  - {sentence(45)}\n")
        with forked() as repo:
            support.commit(repo, {"docs/guides/notes.md": text}, "add")
            before = run("range", "main...HEAD", cwd=repo)
            support.commit(repo, {"docs/writing/config.json":
                                  json.dumps({"skip_prefixes": ["Handover note:"]})}, "configure")
            after = run("range", "main...HEAD", cwd=repo)
        self.assertEqual(before.code, 1, before.out + before.err)
        self.assertIn("docs/guides/notes.md:3: long-sentence", before.out)
        self.assertNotIn("notes.md:7", before.out)  # the tool-written block is skipped already
        self.assertEqual(after.code, 0, after.out + after.err)
        self.assertEqual(after.out, "")  # skipped text is no new sentence, so no density line

    def test_a_malformed_configuration_at_head_exits_2(self) -> None:
        cases = (("docs/writing/config.json", '{"stale": 1}', "stale"),
                 ("docs/writing/config.json", "{", "not valid JSON"),
                 ("docs/.doc-index.json", "[]", "the top level must be an object"))
        for name, text, key in cases:
            with self.subTest(name=name, text=text), forked() as repo:
                support.commit(repo, {name: text, "docs/guides/kiln.md": "Fine.\n"}, "add")
                done = run("range", "main...HEAD", cwd=repo)
                self.assertEqual(done.code, 2, done.out + done.err)
                self.assertIn(f"{name} at HEAD", done.err)
                self.assertIn(key, done.err)
                self.assertNotIn("Traceback", done.err)
                self.assertNotIn("internal error", done.err)
                self.assertEqual(done.out, "")


class CommandLine(unittest.TestCase):
    def test_main_range_exit_codes(self) -> None:
        # The density line counts the whole file: every span of rolls.md sits in a sentence the
        # branch never touched, so a density over new text only would read 0.0.
        kept = "Dial `oven` before `proof`."
        with forked() as repo:
            on_main(repo, {"docs/guides/rolls.md": f"# Rolls\n\n{kept}\n"})
            support.commit(repo, {"docs/guides/a.md": f"# A\n\n{sentence(7)}\n"}, "a short page")
            clean = run("range", "main...HEAD", cwd=repo)
            self.assertEqual(clean.code, 0, clean.out + clean.err)
            self.assertEqual(clean.out.splitlines(),
                             ["docs/guides/a.md: 0.0 backtick spans per 100 words (whole file)"])

            wordy = f"# Rolls\n\n{kept}\n\n{sentence(43)}\n"
            support.commit(repo, {"docs/guides/rolls.md": wordy}, "a wordy page")
            found = run("range", "main...HEAD", cwd=repo)
            self.assertEqual(found.code, 1)
            self.assertIn("docs/guides/rolls.md:5: long-sentence: ", found.out)
            # 2 spans over 47 words: four words from the old sentence, 43 from the new one.
            self.assertIn("docs/guides/rolls.md: 4.3 backtick spans per 100 words (whole file)",
                          found.out.splitlines())

            bare = run("range", "main", cwd=repo)  # a base alone means BASE...HEAD
            self.assertEqual((bare.code, bare.out), (found.code, found.out))

    def test_an_unknown_base_exits_2_naming_it(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/guides/a.md": "Fine.\n"}, "add")
            done = run("range", "no-such-base...HEAD", cwd=repo)
            with self.assertRaises(lint.Unreadable) as raised:
                lint.lint_range(repo, "no-such-base", CONFIG)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("no-such-base", done.err)
        self.assertNotIn("Traceback", done.err)
        self.assertNotIn("internal error", done.err)
        self.assertEqual(done.out, "")
        self.assertIn("no-such-base", str(raised.exception))

    def test_a_base_that_starts_with_a_dash_is_refused(self) -> None:
        # After "--" the command line takes it as a base. Git would read it as a switch: with
        # --fork-point it even answers, and the run would compare HEAD with itself and pass.
        with forked() as repo:
            support.commit(repo, {"docs/guides/a.md": f"# A\n\n{sentence(47)}\n"}, "long")
            done = run("range", "--", "--fork-point...HEAD", cwd=repo)
            with self.assertRaises(lint.Unreadable) as raised:
                lint.lint_range(repo, "--fork-point", CONFIG)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("'--fork-point': a base cannot start with -", done.err)
        self.assertEqual(done.out, "")
        self.assertIn("a base cannot start with -", str(raised.exception))

    def test_a_base_with_no_merge_base_exits_2_naming_it(self) -> None:
        # A shallow clone cuts the history short, so two tips can share no commit it holds.
        with forked() as repo:
            support.commit(repo, {"docs/guides/a.md": "Work on the branch.\n"}, "work")
            support.run_git(repo, "checkout", "-q", "main")
            support.commit(repo, {"docs/guides/b.md": "Work on main.\n"}, "more work on main")
            support.run_git(repo, "checkout", "-q", "feat")
            shallow = repo.parent / "shallow clone"
            support.run_git(repo.parent, "clone", "-q", "--depth", "1", "--branch", "feat",
                            repo.as_uri(), str(shallow))
            support.run_git(shallow, "fetch", "-q", "--depth", "1", "origin",
                            "main:refs/remotes/origin/main")
            done = run("range", "origin/main...HEAD", cwd=shallow)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("origin/main", done.err)
        self.assertIn("merge base", done.err)
        self.assertNotIn("Traceback", done.err)

    def test_a_repository_without_commits_exits_2(self) -> None:
        with support.git_repo() as repo:
            done = run("range", "main...HEAD", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("HEAD", done.err)
        self.assertNotIn("Traceback", done.err)

    def test_range_outside_a_repository_exits_2(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing plain ") as base:
            home = Path(base) / "home"
            home.mkdir()
            env = {**os.environ, "HOME": str(home), "GIT_CEILING_DIRECTORIES": str(base)}
            with mock.patch.dict(os.environ, env, clear=True):
                done = run("range", "main...HEAD", cwd=Path(base))
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertNotIn("Traceback", done.err)
        self.assertNotIn("internal error", done.err)

    def test_range_paths_are_from_the_top_of_the_repository(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/guides/a.md": f"# A\n\n{sentence(47)}\n"}, "add")
            done = run("range", "main...HEAD", cwd=repo / "docs")
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn("docs/guides/a.md:3: long-sentence: ", done.out)

    def test_json_in_range_mode(self) -> None:
        with forked() as repo:
            support.commit(repo, {"docs/guides/b.md": f"# B\n\n{sentence(47)}\n"}, "a wordy page")
            done = run("range", "--format", "json", "main...HEAD", cwd=repo)
            clean = run("range", "--format", "json", "feat...HEAD", cwd=repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        found = json.loads(done.out)  # only the list: no density lines in JSON
        self.assertEqual([(item["path"], item["line"], item["rule"], item["paragraph_first_line"],
                           item["paragraph_last_line"]) for item in found],
                         [("docs/guides/b.md", 3, "long-sentence", 3, 3)])
        self.assertEqual(set(found[0]), {"path", "line", "rule", "message",
                                         "paragraph_first_line", "paragraph_last_line"})
        self.assertEqual((clean.code, json.loads(clean.out)), (0, []))

    def test_main_range_usage_errors_exit_2(self) -> None:
        cases = (["range"],
                 ["range", "main...HEAD", "--profile", "terse"],
                 ["range", "main...HEAD", "--github"],
                 ["range", "main...HEAD", "docs/guides/a.md"],
                 ["range", "main...HEAD", "--format", "xml"],
                 ["range", "main...feat"],       # the head is always HEAD
                 ["range", "main..."],
                 ["range", "...HEAD"],
                 ["range", "main..HEAD"],        # two dots compare no merge base
                 ["range", "-x...HEAD"])         # a base that git would read as an option
        with forked() as repo:
            for args in cases:
                with self.subTest(args=args):
                    done = run(*args, cwd=repo)
                    self.assertEqual(done.code, 2, done.out + done.err)
                    self.assertEqual(done.out, "")
                    self.assertNotIn("Traceback", done.err)
                    self.assertNotIn("internal error", done.err)
            head = run("range", "main...feat", cwd=repo)
            two = run("range", "main..HEAD", cwd=repo)
        self.assertIn("HEAD", head.err)
        self.assertRegex(head.err, re.compile(r"range|BASE\.\.\.HEAD"))
        self.assertIn("usage:", two.err)  # a usage error, not a base that git cannot find


if __name__ == "__main__":
    unittest.main()
