"""The anchor check, tried on made-up rewrites.

Rewording and reordering are fine, but the identifiers, codes, numbers and link targets of the old
text have to turn up in the new one at least as often. A test commits one text, puts another in
the working copy, then starts the command line as a batch of rewrites does. All files, codes and
sentences are invented, and every repository is a scratch one that no global git setting can
reach.
"""

from __future__ import annotations

import io
import json
import os
import re
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tests import support
from tests.support import ANCHORS, DEFAULT_CODES, put, run

anchors = support.load("anchors")

# A page with one anchor of each kind and a few that sit in odd places: a number in a heading and
# in a table row, a number in a fenced block, a reference definition ahead of the prose.
PUMP_ROOM = """# Pump room, stage 2

[catalogue]: https://catalogue.example.test/valves

Valve V-12 opens only once the gauge shows 3.5 bar. The cycle runs from `pump_cycle.sh`,
which is explained in [the pump manual](manuals/pump-manual.pdf).

| Step  | Wait |
|-------|------|
| prime | 90 s |
| purge | 15 s |

```sh
pump_cycle.sh --stage 2 --retry 2
```
"""

GONE = "is not in the file"


@contextmanager
def based(text: str = PUMP_ROOM, path: str = "docs/a.md") -> Iterator[Path]:
    """A repository whose only commit, on ``main``, holds ``text`` at ``path``."""
    with support.git_repo() as repo:
        support.commit(repo, {path: text}, "seed")
        yield repo


def check(repo: Path, text: str, *files: str) -> support.Result:
    """Replace the working copy of ``docs/a.md`` with ``text``, then compare ``files`` (just that
    file, if none are named) with ``main``."""
    put(repo, {"docs/a.md": text})
    return run("--base", "main", *(files or ("docs/a.md",)), cwd=repo, script=ANCHORS)


def rewrite(repo: Path, path: str, before: str, after: str) -> support.Result:
    """Make ``before`` the committed text of ``path``, leave ``after`` on disk uncommitted, and
    run the check against that commit."""
    support.commit(repo, {path: before}, f"seed {path}")
    put(repo, {path: after})
    return run("--base", "HEAD", path, cwd=repo, script=ANCHORS)


def codes_of(*patterns: str) -> support.Codes:
    """A ``Codes`` that knows ``patterns`` and nothing else."""
    return support.Codes(tuple(re.compile(pattern) for pattern in patterns), frozenset(),
                         frozenset())


def found(text: str) -> list[tuple[int, str, str]]:
    return [(anchor.line, anchor.kind, anchor.text)
            for anchor in anchors.anchors(text, DEFAULT_CODES)]


@contextmanager
def in_directory(path: Path) -> Iterator[None]:
    before = os.getcwd()
    os.chdir(str(path))
    try:
        yield
    finally:
        os.chdir(before)


class Verdicts(unittest.TestCase):
    def assertClean(self, done: support.Result) -> None:
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(done.out, "")

    def test_a_rewrite_that_keeps_every_anchor_passes(self) -> None:
        # The prose is rearranged but nothing is dropped: the valve code sits in brackets, the
        # table rows trade places, and stage 2 is mentioned one more time than before.
        rewritten = """# Pump room, stage 2

The cycle for stage 2 comes from `pump_cycle.sh` and is explained in
[the pump manual](manuals/pump-manual.pdf). Open the valve (V-12) only once the gauge shows
3.5 bar.

| Step  | Wait |
|-------|------|
| purge | 15 s |
| prime | 90 s |

[catalogue]: https://catalogue.example.test/valves

```sh
pump_cycle.sh --stage 2 --retry 2
```
"""
        with based() as repo:
            self.assertClean(check(repo, rewritten))

    def test_a_removed_anchor_fails_and_is_named(self) -> None:
        cases = (
            ("Valve V-12 opens", "The main valve opens", [f'5: code: "V-12" {GONE}']),
            ("shows 3.5 bar", "shows three and a half bar", [f'5: number: "3.5" {GONE}']),
            ("| prime | 90 s |", "| prime | 1.5 min |", [f'10: number: "90" {GONE}']),
            ("(manuals/pump-manual.pdf)", "(archive/pump-manual.pdf)",
             [f'6: link-target: "manuals/pump-manual.pdf" {GONE}',
              '6: link-target: "archive/pump-manual.pdf" names no file']),
            ("https://catalogue.example.test/valves", "https://parts.example.test/pumps",
             [f'3: link-target: "https://catalogue.example.test/valves" {GONE}']),
            # Only an unbroken backtick span is an identifier: bold type, or the name cut into
            # two spans, leaves the use uncounted.
            ("`pump_cycle.sh`,", "**pump_cycle.sh**,", [f'5: identifier: "pump_cycle.sh" {GONE}']),
            ("`pump_cycle.sh`,", "`pump_cycle`.`sh`,", [f'5: identifier: "pump_cycle.sh" {GONE}']),
        )
        for old, new, lines in cases:
            with self.subTest(old=old), based() as repo:
                self.assertEqual(PUMP_ROOM.count(old), 1)
                done = check(repo, PUMP_ROOM.replace(old, new))
                self.assertEqual(done.code, 1, done.out + done.err)
                self.assertEqual(done.out.splitlines(), [f"docs/a.md:{line}" for line in lines])

    def test_a_use_dropped_where_another_remains_fails(self) -> None:
        # A count, not a presence test: two mentions remain, and three were there to begin with.
        before = ("# Tide notes\n\nSpring tides reach marker V-4 first.\n\n"
                  "The V-4 post sits on the east wall.\n\n"
                  "Its chart hangs by the door, next to V-4 itself.\n\n"
                  "Report a loose V-4 plate to the harbour office.\n")
        with support.git_repo() as repo:
            done = rewrite(repo, "docs/b.md", before,
                           before.replace("The V-4 post", "The east post"))
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [
            'docs/b.md:3: code: "V-4" is used 3 times, 4 at the base (lines 3, 5, 7, 9)'])

    def test_a_number_dropped_from_a_heading_leaves_its_other_uses_counted(self) -> None:
        # The stage number is in the heading and, twice on one line, in the fenced command.
        with based() as repo:
            done = check(repo, PUMP_ROOM.replace("Pump room, stage 2", "Pump room, second stage"))
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [
            'docs/a.md:1: number: "2" is used 2 times, 3 at the base (lines 1, 14)'])

    def test_the_line_reported_is_the_first_use_in_the_file(self) -> None:
        # The fenced copy sits between two prose copies. Fences are read apart from prose, and
        # one use is left, but the line reported is still where the base first used the word.
        before = ("# Dials\n\nTurn the `knob` slowly.\n\n```md\n`knob`\n```\n\n"
                  "Then release the `knob` again.\n")
        after = before.replace("the `knob` slowly", "it slowly").replace("the `knob` again",
                                                                          "it again")
        with support.git_repo() as repo:
            done = rewrite(repo, "docs/c.md", before, after)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [
            'docs/c.md:3: identifier: "knob" is used 1 time, 3 at the base (lines 3, 6, 9)'])

    def test_a_code_moved_into_a_link_passes(self) -> None:
        with based() as repo:
            put(repo, {"docs/manuals/valve.md": "# Valve\n",
                       "docs/manuals/V-12-valve.md": "# Valve V-12\n"})
            into_text = PUMP_ROOM.replace("Valve V-12 opens",
                                          "[Valve V-12](manuals/valve.md) opens")
            self.assertClean(check(repo, into_text))
            into_target = PUMP_ROOM.replace(
                "Valve V-12 opens", "The [valve](manuals/V-12-valve.md#opening) opens")
            self.assertClean(check(repo, into_target))

    def test_a_link_the_rewrite_adds_must_name_a_file(self) -> None:
        # Two files are missing, and the first is linked again further down. Each is reported
        # once, where it first appears. The URL is never looked up, and neither is the pump
        # manual, which the base text linked already though nothing by that name exists.
        linked = PUMP_ROOM + (
            "\nFaults are logged in [the fault history](records/faults.md).\n\n"
            "Shifts follow [the rota](rota/shifts.md), and the calendar is at "
            "[the harbour site](https://harbour.example.test/calendar).\n\n"
            "Faults are listed once more in [the history](records/faults.md).\n")
        with based() as repo:
            done = check(repo, linked)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertEqual(done.out.splitlines(), [
                'docs/a.md:17: link-target: "records/faults.md" names no file',
                'docs/a.md:19: link-target: "rota/shifts.md" names no file'])
            # Syntax quoted in a table cell's backticks, or in a tilde fence, only illustrates.
            examples = PUMP_ROOM.replace(
                "| purge | 15 s |\n", "| purge | 15 s |\n| link  | `[label](page.md)` |\n")
            examples += "\n~~~text\n[see](nowhere.md)\n~~~\n"
            self.assertClean(check(repo, examples))

    def test_a_root_relative_or_fragment_target_is_not_checked(self) -> None:
        # None of these can be found by looking beside the file: the slash forms depend on where
        # a site is served from, a fragment is a spot within a page, and a mail address is no path.
        for target in ("/ops/valves.md", "#valve-notes", "mailto:duty@example.test",
                       "//cdn.example.test/valves.css"):
            with self.subTest(target=target), based() as repo:
                done = check(repo, PUMP_ROOM.replace("Valve V-12 opens",
                                                     f"Valve V-12 ([notes]({target})) opens"))
                self.assertClean(done)

    def test_a_target_is_looked_up_without_its_fragment_query_or_escapes(self) -> None:
        with based() as repo:
            put(repo, {"docs/manuals/pump notes.md": "# Notes\n"})
            present = PUMP_ROOM.replace(
                "Valve V-12 opens", "Valve V-12 ([notes](manuals/pump%20notes.md?raw=1#top)) opens")
            self.assertClean(check(repo, present))
            absent = PUMP_ROOM.replace(
                "Valve V-12 opens", "Valve V-12 ([notes](manuals/pump%20gone.md#top)) opens")
            done = check(repo, absent)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertEqual(done.out.splitlines(), [
                'docs/a.md:5: link-target: "manuals/pump%20gone.md#top" names no file'])

    def test_a_file_the_base_does_not_hold_has_no_anchors(self) -> None:
        with based() as repo:
            put(repo, {"docs/new.md": "The sluice log lists V-77 first.\n"})
            self.assertClean(check(repo, PUMP_ROOM, "docs/new.md"))

    def test_a_new_file_must_still_link_to_files_that_exist(self) -> None:
        with based() as repo:
            put(repo, {"docs/new.md": "See [the log](logs/day.md).\n"})
            done = check(repo, PUMP_ROOM, "docs/new.md")
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [
            'docs/new.md:1: link-target: "logs/day.md" names no file'])

    def test_it_reads_the_working_tree_not_head(self) -> None:
        # Only the working tree is read, so an uncommitted rewrite can be vetted.
        lossy = PUMP_ROOM.replace("V-12", "V-13")
        with based() as repo:
            self.assertEqual(check(repo, lossy).code, 1)
            support.commit(repo, {"docs/a.md": lossy}, "record the lossy text")
            # The loss is now committed, but the file on disk has the old words back, and a pass
            # shows that the check never consulted HEAD's copy.
            put(repo, {"docs/a.md": PUMP_ROOM})
            done = run("--base", "HEAD~1", "docs/a.md", cwd=repo, script=ANCHORS)
            self.assertClean(done)

    def test_line_endings_are_not_anchors(self) -> None:
        with based() as repo:
            self.assertClean(check(repo, PUMP_ROOM.replace("\n", "\r\n")))

    def test_a_byte_order_mark_is_not_part_of_the_first_line(self) -> None:
        # A reference definition is read only at the start of its line, mark or no mark.
        text = "[catalogue]: https://catalogue.example.test/valves\n\nValve V-12 opens.\n"
        mark = b"\xef\xbb\xbf"
        with based(text) as repo:
            put(repo, {"docs/a.md": mark + text.encode("utf-8")})
            self.assertClean(run("--base", "main", "docs/a.md", cwd=repo, script=ANCHORS))
            support.commit(repo, {"docs/a.md": mark.decode("utf-8") + text}, "mark the base")
            put(repo, {"docs/a.md": text})
            self.assertClean(run("--base", "HEAD", "docs/a.md", cwd=repo, script=ANCHORS))

    def test_the_file_may_be_named_from_a_subdirectory(self) -> None:
        with based() as repo:
            put(repo, {"docs/a.md": PUMP_ROOM.replace("V-12", "V-13")})
            done = run("--base", "main", "a.md", cwd=repo / "docs", script=ANCHORS)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [f'a.md:5: code: "V-12" {GONE}'])


class Counting(unittest.TestCase):
    def test_digits_of_a_code_or_a_list_marker_are_not_numbers(self) -> None:
        text = ("# Start-up\n\n1. Check the gauge.\n2) Read the dial: 7.25 bar at most.\n"
                "10. Close the valve V-3.\n")
        numbers = [text for _, kind, text in found(text) if kind == "number"]
        self.assertEqual(numbers, ["7.25"])
        self.assertIn((5, "code", "V-3"), found(text))

    def test_every_anchor_of_the_pump_room_is_counted_once_at_its_first_line(self) -> None:
        self.assertEqual(found(PUMP_ROOM), [
            (1, "number", "2"),
            (3, "link-target", "https://catalogue.example.test/valves"),
            (5, "identifier", "pump_cycle.sh"),
            (5, "code", "V-12"),
            (5, "number", "3.5"),
            (6, "link-target", "manuals/pump-manual.pdf"),
            (10, "number", "90"),
            (11, "number", "15"),
        ])

    def test_digits_inside_a_link_target_are_not_numbers(self) -> None:
        # The numerals in the file name are part of the destination and add nothing to the
        # numbers; the destination is counted once, as a link target.
        text = "Read [the tide table](tables/harbour-v2-17.csv) for the day.\n"
        self.assertEqual(found(text), [(1, "link-target", "tables/harbour-v2-17.csv")])

    def test_digits_in_a_reference_definition_destination_are_numbers(self) -> None:
        # The module docstring says so: only an inline link's target is set aside.
        self.assertEqual(found("[page]: docs/page-17.md\n"), [
            (1, "number", "17"), (1, "link-target", "docs/page-17.md")])

    def test_a_reference_definition_is_still_read_by_the_anchors(self) -> None:
        # The lint blanks a definition; the anchor check reads it as it was written.
        text = "[KX7]: docs/notes-9.md\n"
        self.assertEqual(found(text), [(1, "code", "KX7"), (1, "number", "9"),
                                       (1, "link-target", "docs/notes-9.md")])
        self.assertEqual([(loss.anchor.kind, loss.anchor.text)
                          for loss in anchors.missing(text, "Gone.\n", DEFAULT_CODES)],
                         [("code", "KX7"), ("number", "9"), ("link-target", "docs/notes-9.md")])

    def test_an_added_reference_definition_that_leads_nowhere_is_unresolved(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing anchors ") as base:
            self.assertEqual(anchors.unresolved("", "Text.\n\n[KX7]: gone.md\n", Path(base)),
                             [anchors.Anchor(3, "link-target", "gone.md")])

    def test_digits_of_an_identifier_are_not_numbers(self) -> None:
        text = "Set the `retry_limit=4` option.\n"
        self.assertEqual(found(text), [(1, "identifier", "retry_limit=4")])

    # A paragraph whose first identifier, a small JSON object, runs over three lines.
    WRAPPED = """# Sensors

The node posts `{"unit": "mm",
"scale": 2,
"offset": 0}` to the hub, which
replies with `ack`.
"""

    def test_a_span_wrapped_over_two_lines_is_one_anchor(self) -> None:
        # The span here covers three lines; the digits inside it belong to it.
        self.assertEqual(found(self.WRAPPED), [
            (3, "identifier", '{"unit": "mm", "scale": 2, "offset": 0}'),
            (6, "identifier", "ack"),
        ])

    def test_a_wrapped_span_survives_a_rewrite_that_joins_its_lines(self) -> None:
        joined = self.WRAPPED.replace('"mm",\n"scale": 2,\n"offset"',
                                      '"mm", "scale": 2, "offset"')
        self.assertEqual(joined.count("\n"), self.WRAPPED.count("\n") - 2)
        with support.git_repo() as repo:
            done = rewrite(repo, "docs/sensors.md", self.WRAPPED, joined)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(done.out, "")

    def test_a_span_wrapped_inside_a_quote_is_one_anchor(self) -> None:
        text = "> Run the `pump_cycle\n> --stage` script.\n"
        self.assertEqual(found(text), [(1, "identifier", "pump_cycle --stage")])

    def test_an_unclosed_backtick_yields_no_identifier(self) -> None:
        # Each list item is a paragraph of its own, so the lone backtick of the second item cannot
        # reach across to the closed span of the third.
        text = ("- Reset with the `knob` first.\n- Never turn the `dial past the mark.\n"
                "- Then log the `reading` field.\n")
        self.assertEqual([(line, value) for line, kind, value in found(text)
                          if kind == "identifier"], [(1, "knob"), (3, "reading")])

    # Footnote definitions, one of whose first words looks like the path of a file.
    FOOTED = """# Rainfall log

Totals come from the gauge.[^gauge] Spill days are tallied apart.[^spill]

[^gauge]: logs/gauge.csv lists each reading.
[^spill]: Overflow is counted from the weir.
"""

    def test_a_footnote_is_not_a_link(self) -> None:
        # A line such as "[^gauge]: words" defines a footnote and has no destination, whatever
        # its first word looks like.
        self.assertEqual(found(self.FOOTED), [])
        with tempfile.TemporaryDirectory(prefix="writing anchors ") as folder:
            self.assertEqual(anchors.unresolved("", self.FOOTED, Path(folder)), [])
        # Definitions moved above the prose and reworded lose nothing.
        moved = """# Rainfall log

[^spill]: The weir overflow is counted separately.
[^gauge]: Each reading is listed in logs/gauge.csv.

Totals come from the gauge.[^gauge] Spill days are tallied apart.[^spill]
"""
        with support.git_repo() as repo:
            done = rewrite(repo, "docs/rain.md", self.FOOTED, moved)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(done.out, "")


class Api(unittest.TestCase):
    def test_missing_names_each_loss_with_its_uses(self) -> None:
        before = "Open V-1 and V-2.\n\nThen shut V-2 at 17 psi.\n"
        after = "Open V-1.\n\nThen shut V-2.\n"
        lost = anchors.missing(before, after, DEFAULT_CODES)
        self.assertEqual(lost, [
            anchors.Loss(anchors.Anchor(1, "code", "V-2"), 1, (1, 3)),
            anchors.Loss(anchors.Anchor(3, "number", "17"), 0, (3,)),
        ])
        self.assertEqual(anchors.missing(before, before, DEFAULT_CODES), [])

    def test_a_pattern_of_the_codes_it_is_given_makes_a_code(self) -> None:
        lane = codes_of(r"(?<![A-Za-z0-9_])LANE[0-9]+(?![A-Za-z0-9_])")
        before, after = "Row in LANE9 now.\n", "Row in a lane now.\n"
        lost = anchors.missing(before, after, lane)
        self.assertEqual([(loss.anchor.kind, loss.anchor.text) for loss in lost],
                         [("code", "LANE9")])
        self.assertEqual(anchors.missing(before, after, DEFAULT_CODES), [])

    def test_unresolved_looks_in_the_given_folder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing anchors ") as base:
            folder = Path(base)
            put(folder, {"here.md": "x\n"})
            after = "See [a](here.md), [b](gone.md) and [c](gone.md#part).\n"
            self.assertEqual(anchors.unresolved("", after, folder), [
                anchors.Anchor(1, "link-target", "gone.md"),
                anchors.Anchor(1, "link-target", "gone.md#part")])
            self.assertEqual(anchors.unresolved("[b](gone.md)\n", after, folder), [
                anchors.Anchor(1, "link-target", "gone.md#part")])

    def test_unresolved_survives_a_target_the_file_system_refuses(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing anchors ") as base:
            long_name = "x" * 300 + ".md"
            self.assertEqual(anchors.unresolved("", f"[a]({long_name})\n", Path(base)),
                             [anchors.Anchor(1, "link-target", long_name)])


class Configuration(unittest.TestCase):
    LANES = "# Lanes\n\nBoats use LANE9 on race days.\n"
    PATTERN = r"(?<![A-Za-z0-9_])LANE[0-9]+(?![A-Za-z0-9_])"

    def test_the_codes_come_from_the_working_trees_configuration(self) -> None:
        dropped = self.LANES.replace("LANE9", "the far lane")
        with based(self.LANES) as repo:
            # Without the project's pattern LANE9 is not a code, so losing it is not a loss.
            self.assertEqual(check(repo, dropped).code, 0)
            settings = {"codes": {"patterns": [self.PATTERN]}}
            put(repo, {"docs/writing/config.json": json.dumps(settings)})
            done = check(repo, dropped)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [f'docs/a.md:3: code: "LANE9" {GONE}'])

    def test_a_malformed_configuration_exits_2_and_names_the_key(self) -> None:
        with based() as repo:
            put(repo, {"docs/writing/config.json": '{"codes": {"patterns": ["("]}}'})
            done = check(repo, PUMP_ROOM)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("docs/writing/config.json", done.err)
        self.assertIn("codes.patterns[0]", done.err)
        self.assertNotIn("Traceback", done.err)
        self.assertNotIn("internal error", done.err)
        self.assertEqual(done.out, "")


class Format(unittest.TestCase):
    def test_json_prints_one_list_of_objects_and_nothing_else(self) -> None:
        changed = PUMP_ROOM.replace("Valve V-12 opens",
                                    "Valve V-13 ([notes](notes/valve.md)) opens")
        with based() as repo:
            put(repo, {"docs/a.md": changed})
            done = run("--base", "main", "--format", "json", "docs/a.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 1, done.err)
        self.assertEqual(done.err, "")
        self.assertEqual(json.loads(done.out), [
            {"path": "docs/a.md", "line": 5, "kind": "code", "anchor": "V-12",
             "rule": "lost-anchor", "message": f'code: "V-12" {GONE}',
             "before": 1, "after": 0, "base_lines": [5]},
            {"path": "docs/a.md", "line": 5, "kind": "link-target", "anchor": "notes/valve.md",
             "rule": "unresolved-target",
             "message": 'link-target: "notes/valve.md" names no file'},
        ])

    def test_json_counts_the_uses_before_and_after(self) -> None:
        with based() as repo:
            put(repo, {"docs/a.md": PUMP_ROOM.replace("stage 2\n\n[", "second stage\n\n[")})
            done = run("--base", "main", "--format", "json", "docs/a.md", cwd=repo, script=ANCHORS)
        [item] = json.loads(done.out)
        self.assertEqual((item["anchor"], item["before"], item["after"], item["base_lines"]),
                         ("2", 3, 2, [1, 14]))

    def test_json_of_a_clean_run_is_an_empty_list(self) -> None:
        with based() as repo:
            done = run("--base", "main", "--format", "json", "docs/a.md", cwd=repo, script=ANCHORS)
        self.assertEqual((done.code, json.loads(done.out), done.err), (0, [], ""))


class Failures(unittest.TestCase):
    def test_usage_errors_and_unreadable_input_exit_2(self) -> None:
        cases = (
            ([], "--base"),
            (["docs/a.md"], "--base"),
            (["--base", "main"], "FILE"),
            (["--base", "main", "--format", "xml", "docs/a.md"], "--format"),
            (["--base", "unknown-ref", "docs/a.md"], "base 'unknown-ref'"),
            (["--base", "main", "docs/absent.md"], "cannot read docs/absent.md"),
            (["--base", "main", "docs"], "cannot read docs"),
        )
        with based() as repo:
            for args, said in cases:
                with self.subTest(args=args):
                    done = run(*args, cwd=repo, script=ANCHORS)
                    self.assertEqual(done.code, 2, done.out + done.err)
                    self.assertIn(said, done.err)
                    self.assertNotIn("Traceback", done.err)
                    self.assertEqual(done.out, "")

    def test_a_base_that_starts_with_a_dash_is_refused(self) -> None:
        with based() as repo:
            done = run("--base=--all", "docs/a.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("a base cannot start with -", done.err)
        self.assertNotIn("Traceback", done.err)

    def test_a_file_outside_the_repository_exits_2(self) -> None:
        with based() as repo, tempfile.TemporaryDirectory(prefix="writing outside ") as other:
            stray = Path(other) / "stray.md"
            stray.write_text("V-12 is open.\n", encoding="utf-8")
            done = run("--base", "main", str(stray), cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("not inside the repository", done.err)

    def test_outside_any_repository_exits_2(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing none ") as empty:
            with mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(Path(empty).parent)}):
                put(Path(empty), {"a.md": "Fine.\n"})
                done = run("--base", "main", "a.md", cwd=Path(empty), script=ANCHORS)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertNotIn("Traceback", done.err)

    def test_a_file_that_is_not_utf8_exits_2_and_the_next_one_is_still_checked(self) -> None:
        with based() as repo:
            support.commit(repo, {"docs/b.md": "Shut V-9 first.\n"}, "second file")
            put(repo, {"docs/a.md": b"caf\xe9 \xff\n", "docs/b.md": "Shut it first.\n"})
            done = run("--base", "main", "docs/a.md", "docs/b.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("cannot read docs/a.md: not UTF-8", done.err)
        self.assertEqual(done.out.splitlines(), [f'docs/b.md:1: code: "V-9" {GONE}'])

    def test_a_base_copy_that_is_not_utf8_is_still_compared(self) -> None:
        # Only the working-tree copy has to decode. The base copy is read with its undecodable
        # bytes replaced, so a loss is found and reported with status 1, not 2.
        with support.git_repo() as repo:
            put(repo, {"docs/old.md": "Sluice V-5 faces the caf\xe9.\n".encode("latin-1")})
            support.run_git(repo, "add", "-A")
            support.run_git(repo, "commit", "-q", "-m", "seed a Latin-1 text")
            put(repo, {"docs/old.md": "The sluice faces the caf\u00e9.\n"})
            done = run("--base", "HEAD", "docs/old.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [f'docs/old.md:1: code: "V-5" {GONE}'])
        self.assertEqual(done.err, "")

    def test_a_loss_and_an_unreadable_file_together_exit_2(self) -> None:
        with based() as repo:
            put(repo, {"docs/a.md": PUMP_ROOM.replace("V-12", "V-13")})
            done = run("--base", "main", "docs/a.md", "docs/absent.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertEqual(done.out.splitlines(), [f'docs/a.md:5: code: "V-12" {GONE}'])

    def test_a_module_that_cannot_be_imported_exits_2_with_one_line(self) -> None:
        for missing in ("config.py", "lint.py", "markdown.py"):
            with self.subTest(missing=missing), support.engine_without(missing) as folder, \
                    based("Valve V-12 opens.\n", "a.md") as repo:
                done = run("--base", "HEAD", "a.md", cwd=repo, script=folder / "anchors.py")
                self.assertEqual(done.code, 2, done.out + done.err)
                self.assertEqual(done.out, "")
                self.assertEqual(len(done.err.splitlines()), 1, done.err)
                self.assertTrue(done.err.startswith("writing: "), done.err)
                self.assertIn(missing.removesuffix(".py"), done.err)

    def test_a_pipe_closed_early_is_quiet_and_keeps_the_exit_code(self) -> None:
        many = "".join(f"Valve V-{number} opens.\n\n" for number in range(3000))
        with based(many, "a.md") as repo:
            put(repo, {"a.md": "Gone.\n"})
            done = support.run_cut_short("--base", "HEAD", "a.md", cwd=repo, script=ANCHORS)
        self.assertEqual(done.code, 1, done.out + done.err)  # anchors were lost, as ever
        self.assertEqual(done.err, "")
        self.assertTrue(done.out.startswith("a.md:1: code: "), done.out)

    def test_a_closed_stdout_keeps_the_exit_code_and_is_quiet(self) -> None:
        with based("Valve V-12 opens.\n", "a.md") as repo:
            same = support.run_stdout_closed("--base", "HEAD", "a.md", cwd=repo, script=ANCHORS)
            put(repo, {"a.md": "Gone.\n"})
            lost = support.run_stdout_closed("--base", "HEAD", "a.md", cwd=repo, script=ANCHORS)
        self.assertEqual((same.code, same.err), (0, ""))
        self.assertEqual((lost.code, lost.err), (1, ""))

    def test_a_crash_exits_2_not_1(self) -> None:
        # An uncaught exception would exit 1, which a caller reads as a lost anchor.
        with based("Valve V-12 opens.\n", "a.md") as repo:
            out, err = io.StringIO(), io.StringIO()
            with in_directory(repo), \
                    mock.patch.object(anchors, "missing", side_effect=RuntimeError("boom")), \
                    redirect_stdout(out), redirect_stderr(err):
                status = anchors.entry(["--base", "HEAD", "a.md"])
        self.assertEqual(status, 2)
        self.assertIn("writing: internal error: RuntimeError: boom", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())
        self.assertEqual(out.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
