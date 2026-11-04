"""Ceilings and counts of the writing lint, run on invented history.

A ceilings file names paths, files or folders, with the number of findings each holds in the
committed ``HEAD``, counted over whole files. A count over its ceiling fails, and so does a count
under it. A ceiling never rises and a path never leaves the file, unless the branch edits the
project's writing configuration or sets ``counting_version`` to the running engine's own.
``counts`` reports the same numbers per folder from the working tree, for the audit. Every
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
from tests.support import put, run

lint = support.load("lint")
config = support.load("config")

CEILINGS = "docs/writing/ceilings.json"
CONFIG = "docs/writing/config.json"
INDEX = "docs/.doc-index.json"
SPEC = "docs/specs/mill.md"
CORPUS = support.WRITING / "tests" / "corpus"

VERSION = lint.COUNTING_VERSION
EARLIER = VERSION - 1  # the number an engine before this one counted with

REEDS = "reeds bend low where the slow brown river widens past the old stone mill".split()


def sentence(words: int) -> str:
    """A sentence of ``words`` words and no code."""
    chosen = [REEDS[number % len(REEDS)] for number in range(words)]
    return " ".join(chosen).capitalize() + "."


def page(*, codes: int = 0, long: int = 0) -> str:
    """A page with ``codes`` bare codes (TW1, TW2, ...), one to a paragraph, then ``long``
    sentences of 43 words, over the limit of either register. Each code and each long sentence
    is a finding."""
    parts = ["# Mill gauge"]
    parts += [f"TW{number} reads high." for number in range(1, codes + 1)]
    parts += [sentence(43) for _ in range(long)]
    return "\n\n".join(parts) + "\n"


def ceilings(paths: dict[str, object], version: object = VERSION) -> str:
    return json.dumps({"counting_version": version, "paths": paths}, indent=2) + "\n"


def versionless(paths: dict[str, object]) -> str:
    """A ceilings file from before versions: no ``counting_version``."""
    return json.dumps({"paths": paths}, indent=2) + "\n"


def stale_line(recorded: int, file: str = CEILINGS) -> str:
    update = "writing ceilings --update" + ("" if file == CEILINGS else f" --file {file}")
    return f"writing ceilings: counted with version {recorded}; this engine counts with " \
           f"{VERSION}: run {update}"


@contextmanager
def forked(files: dict[str, str] | None = None) -> Iterator[Path]:
    """A repository whose ``main`` holds ``files`` beside a README, with the work branch ``feat``
    checked out of it."""
    with support.git_repo() as repo:
        support.commit(repo, {"README.md": "The base commit.\n", **(files or {})}, "base")
        support.run_git(repo, "checkout", "-q", "-b", "feat")
        yield repo


def main_moves_on(repo: Path, files: dict[str, str]) -> None:
    """Commit ``files`` on ``main``, which moves on after the branch left it, and come back."""
    support.run_git(repo, "checkout", "-q", "main")
    support.commit(repo, files, "later work on main")
    support.run_git(repo, "checkout", "-q", "feat")


def check(repo: Path, *extra: str) -> support.Result:
    return run("ceilings", "--base", "main", *extra, cwd=repo)


def lines(done: support.Result) -> list[str]:
    return done.out.splitlines()


class Counts(unittest.TestCase):
    """Each listed path holds exactly the findings its ceiling states, in the committed HEAD."""

    def test_ceilings_pass_at_the_count(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done), [f"{SPEC}: 3 findings, at its ceiling of 3",
                                       f"{CEILINGS}: 1 path checked at HEAD"])

    def test_ceilings_fail_above_and_list_the_findings(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            support.commit(repo, {SPEC: page(codes=4)}, "one more code")
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn(f"{SPEC}: 4 findings, above its ceiling of 3", lines(done))
        # A path over its ceiling lists its findings, which shows where the new one is.
        listed = [line for line in lines(done) if re.match(r"\S+:[0-9]+: bare-code: ", line)]
        self.assertEqual([line.split(": ")[0] for line in listed],
                         [f"{SPEC}:{number}" for number in (3, 5, 7, 9)])

    def test_ceilings_fail_below_until_the_ceiling_falls(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            support.commit(repo, {SPEC: page(codes=2)}, "drop a stale reading")
            done = check(repo)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertIn(f"{SPEC}: 2 findings, below its ceiling of 3; set the ceiling to 2",
                          lines(done))
            support.commit(repo, {CEILINGS: ceilings({SPEC: 2})}, "bring the ceiling down")
            lowered = check(repo)
        self.assertEqual(lowered.code, 0, lowered.out + lowered.err)

    def test_one_finding_is_singular(self) -> None:
        with forked({SPEC: page(codes=1), CEILINGS: ceilings({SPEC: 1})}) as repo:
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done)[0], f"{SPEC}: 1 finding, at its ceiling of 1")

    def test_ceilings_read_the_committed_head_and_nothing_else(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            # A fix in the working tree would put the count under its ceiling, if it were read.
            put(repo, {SPEC: page(codes=2)})
            self.assertEqual(check(repo).code, 0)
            # So would a ceiling that sits in the index and is not yet committed.
            put(repo, {CEILINGS: ceilings({SPEC: 4})})
            support.run_git(repo, "add", CEILINGS)
            self.assertEqual(check(repo).code, 0)
            support.run_git(repo, "commit", "-qm", "commit the ceiling alone")
            self.assertEqual(check(repo).code, 1)

    def test_a_deleted_definition_fails_its_ceiling_though_range_mode_passes(self) -> None:
        # A heading is no sentence, so rewriting one adds nothing for range mode to read. The code
        # it defined, used further down, now stands without words.
        defined = "# Mill gauge\n\n### TW5. Float chamber\n\nTW5 needs rinsing each month.\n"
        with forked({SPEC: defined, CEILINGS: ceilings({SPEC: 0})}) as repo:
            self.assertEqual(check(repo).code, 0)
            support.commit(repo, {SPEC: defined.replace("TW5. Float chamber", "Float chamber")},
                           "rename the heading")
            ranged = run("range", "main...HEAD", cwd=repo)
            done = check(repo)
        self.assertEqual(ranged.code, 0, ranged.out + ranged.err)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn(f"{SPEC}: 1 finding, above its ceiling of 0", lines(done))

    def test_the_file_is_found_from_the_top_and_a_given_one_from_where_you_stand(self) -> None:
        other = "docs/gauges/ceilings.json"
        with forked({SPEC: page(codes=1), CEILINGS: ceilings({SPEC: 1}),
                     other: ceilings({SPEC: 1})}) as repo:
            by_default = run("ceilings", "--base", "main", cwd=repo / "docs")
            given = run("ceilings", "--base", "main", "--file", "gauges/ceilings.json",
                        cwd=repo / "docs")
        self.assertEqual(by_default.code, 0, by_default.out + by_default.err)
        self.assertEqual(lines(by_default)[-1], f"{CEILINGS}: 1 path checked at HEAD")
        self.assertEqual(given.code, 0, given.out + given.err)
        self.assertEqual(lines(given)[-1], f"{other}: 1 path checked at HEAD")


class Exemptions(unittest.TestCase):
    """What lets a range lift a ceiling or remove a path."""

    def test_a_raised_ceiling_fails_when_nothing_in_the_range_explains_it(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}),
                     "docs/guides/tide.md": "A page.\n"}) as repo:
            support.commit(repo, {SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5}),
                                  "docs/guides/tide.md": "Another page.\n"}, "raise it")
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn(f"{SPEC}: the ceiling rose from 3 to 5 against the base", lines(done))
        self.assertNotIn("allowed", done.out)

    def test_a_config_change_in_the_range_allows_a_raise(self) -> None:
        loose = json.dumps({"limits": {"full": {"sentence": 55}}}) + "\n"
        tight = json.dumps({"limits": {"full": {"sentence": 40}}}) + "\n"
        long = f"# Mill gauge\n\n{sentence(50)}\n"
        with forked({SPEC: long, CONFIG: loose, CEILINGS: ceilings({SPEC: 0})}) as repo:
            support.commit(repo, {CONFIG: tight, CEILINGS: ceilings({SPEC: 1})},
                           "tighten the limit")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done), [
            f"{SPEC}: the ceiling rose from 0 to 1 against the base; allowed: the range "
            f"changes {CONFIG}",
            f"{SPEC}: 1 finding, at its ceiling of 1",
            f"{CEILINGS}: 1 path checked at HEAD"])

    def test_a_version_bump_in_the_range_allows_a_raise(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}, EARLIER)}) as repo:
            support.commit(repo, {SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5})},
                           "record the counts of this engine")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done)[0], (
            f"{SPEC}: the ceiling rose from 3 to 5 against the base; allowed: the range "
            f"changes counting_version from {EARLIER} to {VERSION}"))

    def test_both_reasons_are_named_when_both_hold(self) -> None:
        with forked({SPEC: page(codes=3), CONFIG: "{}\n",
                     CEILINGS: ceilings({SPEC: 3}, EARLIER)}) as repo:
            support.commit(repo, {SPEC: page(codes=4), CONFIG: '{"enabled": true}\n',
                                  CEILINGS: ceilings({SPEC: 4})}, "both")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertIn(f"allowed: the range changes {CONFIG} and counting_version from "
                      f"{EARLIER} to {VERSION}", lines(done)[0])

    def test_a_hand_edited_version_that_is_not_the_engines_does_not_allow_a_raise(self) -> None:
        for edited in (VERSION + 4, EARLIER):
            with self.subTest(version=edited), forked(
                    {SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
                support.commit(repo, {SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5}, edited)},
                               "raise it and edit the version")
                done = check(repo)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertEqual(lines(done), [stale_line(edited)])
            self.assertNotIn("allowed", done.out)

    def test_a_stale_counting_version_exits_1_with_the_update_line(self) -> None:
        for file in (CEILINGS, "docs/gauges/ceilings.json"):
            with self.subTest(file=file), forked(
                    {SPEC: page(codes=3), file: ceilings({SPEC: 3}, EARLIER)}) as repo:
                done = check(repo, "--file", file)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertEqual(lines(done), [stale_line(EARLIER, file)])
            self.assertEqual(done.err, "")

    def test_a_version_move_backwards_allows_nothing(self) -> None:
        # The base was counted by a newer engine than this one. Only a move up to this engine's
        # number excuses a raise or a drop.
        newer = VERSION + 1
        with self.subTest("raise"), forked(
                {SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}, newer)}) as repo:
            support.commit(repo, {SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5})}, "raise")
            done = check(repo)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertIn(f"{SPEC}: the ceiling rose from 3 to 5 against the base", lines(done))
            self.assertNotIn("allowed", done.out)
        with self.subTest("drop"), forked(
                {SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}, newer)}) as repo:
            support.commit(repo, {CEILINGS: ceilings({})}, "drop")
            done = check(repo)
            self.assertEqual(done.code, 1, done.out + done.err)
            self.assertEqual(lines(done), [
                f"{SPEC}: dropped from {CEILINGS}; the base holds it at 3",
                f"{CEILINGS}: 0 paths checked at HEAD"])

    def test_a_versionless_file_is_stale_at_head(self) -> None:
        self.assertEqual(lint.parse_ceilings('{"paths": {}}'), lint.Ceilings(0, {}))
        with forked({SPEC: page(codes=3), CEILINGS: versionless({SPEC: 3})}) as repo:
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(lines(done), [stale_line(0)])
        self.assertEqual(done.err, "")

    def test_moving_from_a_versionless_base_allows_a_raise(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: versionless({SPEC: 3})}) as repo:
            support.commit(repo, {SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5})},
                           "record the counts with a version")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done)[0], (
            f"{SPEC}: the ceiling rose from 3 to 5 against the base; allowed: the range "
            f"changes counting_version from 0 to {VERSION}"))

    def test_a_version_that_did_not_change_allows_nothing(self) -> None:
        # The base and the head record the engine's own number, so a bump is not in the range.
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            support.commit(repo, {SPEC: page(codes=4), CEILINGS: ceilings({SPEC: 4})}, "raise")
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertNotIn("allowed", done.out)

    def test_a_dropped_path_fails_unless_the_config_or_the_version_changes(self) -> None:
        dropped = f"{SPEC}: dropped from {CEILINGS}; the base holds it at 3"
        cases = {
            "nothing": ({}, {}, dropped, 1),
            "config": ({CONFIG: "{}\n"}, {CONFIG: '{"enabled": true}\n'},
                       f"{dropped}; allowed: the range changes {CONFIG}", 0),
        }
        for name, (base, change, first, code) in cases.items():
            with self.subTest(name), forked(
                    {SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}), **base}) as repo:
                support.commit(repo, {CEILINGS: ceilings({}), **change}, "stop holding the page")
                done = check(repo)
            self.assertEqual(done.code, code, done.out + done.err)
            self.assertEqual(lines(done), [first, f"{CEILINGS}: 0 paths checked at HEAD"])
        with self.subTest("version"), forked(
                {SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3}, EARLIER)}) as repo:
            support.commit(repo, {CEILINGS: ceilings({})}, "re-record with this engine")
            done = check(repo)
            self.assertEqual(done.code, 0, done.out + done.err)
            self.assertEqual(lines(done)[0], f"{dropped}; allowed: the range changes "
                             f"counting_version from {EARLIER} to {VERSION}")

    def test_deleting_the_file_drops_every_path_it_held(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            support.run_git(repo, "rm", "-q", CEILINGS)
            support.run_git(repo, "commit", "-qm", "remove the ceilings file")
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertEqual(lines(done), [f"{SPEC}: dropped from {CEILINGS}; the base holds it at 3",
                                       f"{CEILINGS}: 0 paths checked at HEAD"])

    def test_the_base_copy_is_the_merge_bases_not_the_tip_of_base(self) -> None:
        # Main lists one more path once the branch has left it. The branch never had that path.
        tide = "docs/specs/tide.md"
        with forked({SPEC: page(codes=5), CEILINGS: ceilings({SPEC: 5})}) as repo:
            main_moves_on(repo, {tide: page(), CEILINGS: ceilings({SPEC: 5, tide: 0})})
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertNotIn("dropped", done.out)

    def test_a_config_change_on_main_after_the_fork_does_not_excuse_a_raise(self) -> None:
        with forked({SPEC: page(codes=3), CONFIG: "{}\n", CEILINGS: ceilings({SPEC: 3})}) as repo:
            support.commit(repo, {SPEC: page(codes=4), CEILINGS: ceilings({SPEC: 4})}, "raise it")
            main_moves_on(repo, {CONFIG: '{"enabled": true}\n'})
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn(f"{SPEC}: the ceiling rose from 3 to 4 against the base", lines(done))
        self.assertNotIn("allowed", done.out)


class Files(unittest.TestCase):
    """What a ceilings file may be."""

    def test_no_ceilings_file_checks_nothing(self) -> None:
        with forked({SPEC: page(codes=3)}) as repo:
            done = check(repo)
            self.assertEqual(done.code, 0, done.out + done.err)
            support.commit(repo, {CEILINGS: ceilings({})}, "start with no paths")
            empty = check(repo)
        self.assertEqual(lines(done), [f"{CEILINGS}: 0 paths checked at HEAD"])
        self.assertEqual(empty.code, 0, empty.out + empty.err)

    def test_a_malformed_ceilings_file_exits_2(self) -> None:
        texts = [
            "{ not closed\n", '"paths"\n', '{"paths": null}\n',
            f'{{"counting_version": {VERSION}}}\n',
            '{"paths": {}, "owners": {}}\n',  # no version is fine; an unknown key is not
            f'{{"counting_version": {VERSION}, "paths": []}}\n',
            f'{{"counting_version": {VERSION}, "paths": {{}}, "owners": {{}}}}\n',
            f'{{"counting_version": {VERSION}, "counting_version": {VERSION}, "paths": {{}}}}\n',
            f'{{"counting_version": {VERSION}, "paths": {{"{SPEC}": 4, "{SPEC}": 4}}}}\n',
            ceilings({SPEC: 4.5}), ceilings({SPEC: -6}), ceilings({SPEC: "5"}),
            ceilings({SPEC: False}), ceilings({SPEC: None}), ceilings({SPEC: [5]}),
            ceilings({}, "1"), ceilings({}, 1.5), ceilings({}, True), ceilings({}, None),
            ceilings({}, -1), ceilings({}, [1]),
            ceilings({"./" + SPEC: 4}), ceilings({"docs/guides/": 4}), ceilings({"/" + SPEC: 4}),
            ceilings({"docs/../tide.md": 4}), ceilings({"": 4}), ceilings({".": 4}),
            ceilings({"docs//specs": 4}),
        ]
        with forked({SPEC: page(codes=3)}) as repo:
            for text in texts:
                with self.subTest(text=text):
                    support.commit(repo, {CEILINGS: text}, "write a bad file")
                    done = check(repo)
                    self.assertEqual(done.code, 2, done.out + done.err)
                    self.assertIn(f"{CEILINGS} at HEAD: ", done.err)
                    self.assertNotIn("Traceback", done.err)
                    self.assertNotIn("internal error", done.err)

    def test_a_malformed_base_copy_exits_2(self) -> None:
        for broken in ("{ not closed\n", '{"paths": {}, "owners": {}}\n'):
            files = {SPEC: page(codes=3), CEILINGS: broken}
            with self.subTest(broken=broken), forked(files) as repo:
                support.commit(repo, {CEILINGS: ceilings({SPEC: 3})}, "write a valid file")
                done = check(repo)
            self.assertEqual(done.code, 2, done.out + done.err)
            # The error says which copy it could not read.
            self.assertIn(f"{CEILINGS} at the base: ", done.err)

    def test_a_ceilings_file_that_is_not_utf8_exits_2(self) -> None:
        with forked() as repo:
            put(repo, {CEILINGS: b'{"paths": "\xff\xfe"}'})
            support.run_git(repo, "add", "-A")
            support.run_git(repo, "commit", "-qm", "bytes")
            done = check(repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn(f"cannot read {CEILINGS}: not UTF-8", done.err)

    def test_a_ceilings_file_outside_the_repository_exits_2(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing outside ") as other, forked() as repo:
            outside = Path(other) / "ceilings.json"
            outside.write_text(ceilings({}), encoding="utf-8")
            done = check(repo, "--file", str(outside))
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("is not inside the repository", done.err)

    def test_ceiling_values_parse_as_whole_numbers(self) -> None:
        words = [("0", 0), ("8", 8), ("-4", None), ('"6"', None), ("7.5", None), ("false", None),
                 ("null", None), ("8.0", None), ("2e1", None), ("[5]", None)]
        for word, number in words:
            with self.subTest(word=word):
                text = f'{{"counting_version": {VERSION}, "paths": {{"docs/a.md": {word}}}}}'
                if number is None:
                    with self.assertRaises(config.Malformed):
                        lint.parse_ceilings(text)
                else:
                    self.assertEqual(lint.parse_ceilings(text),
                                     lint.Ceilings(VERSION, {"docs/a.md": number}))
        # Through the command: a page with no findings is held by a ceiling of 0 and no other.
        with forked({SPEC: page()}) as repo:
            for word, want in (("0", 0), ("8", 1), ("7.5", 2)):
                with self.subTest(word=word):
                    support.commit(repo, {CEILINGS: f'{{"counting_version": {VERSION}, '
                                          f'"paths": {{"{SPEC}": {word}}}}}\n'}, word)
                    done = check(repo)
                    self.assertEqual(done.code, want, done.out + done.err)


class Paths(unittest.TestCase):
    """What a ceiling's path may name."""

    def test_a_folder_ceiling_counts_what_it_holds_in_each_register(self) -> None:
        # Plans allow 35 words to a sentence and everything else 40, so 36 words fail in the plan
        # and 39 pass on the reference page.
        files = {
            "docs/tally.csv": f"TW7,{sentence(44)}\n",
            "docs/plans/2026-09-14-lock-plan.md": f"# Lock\n\n{sentence(36)}\n",
            "docs/archive/dredge.md": f"# Dredge\n\n{sentence(52)}\n",
            "docs/reference/tolls.md": f"# Tolls\n\n{sentence(39)}\n",
            "docs/guides/nested/weir.md": "# Weir\n\nTW6 needs a new float.\n",
            "docs/guides-old/rafts.md": "# Rafts\n\nTW8 is retired.\n",
            "docs/guides/dock.md": f"# Dock\n\n{sentence(44)}\n",
            CEILINGS: ceilings({"docs": 4, "docs/guides": 2, "docs/guides/nested": 1,
                                "docs/plans": 1, "docs/reference": 0}),
        }
        with forked(files) as repo:
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        # Each file is judged in its own register; the archive and the CSV are not read; a sibling
        # that only shares the start of the folder's name is not inside it.
        self.assertEqual(lines(done), [
            "docs: 4 findings, at its ceiling of 4",
            "docs/guides: 2 findings, at its ceiling of 2",
            "docs/guides/nested: 1 finding, at its ceiling of 1",
            "docs/plans: 1 finding, at its ceiling of 1",
            "docs/reference: 0 findings, at its ceiling of 0",
            f"{CEILINGS}: 5 paths checked at HEAD"])

    def test_a_key_that_is_only_a_prefix_of_a_name_names_nothing(self) -> None:
        # "docs/spec" names no file, and the folder is docs/specs.
        with forked({SPEC: page(codes=3)}) as repo:
            support.commit(repo, {CEILINGS: ceilings({"docs/spec": 0})}, "name half a path")
            done = check(repo)
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn("docs/spec: names no Markdown file the lint reads at HEAD", lines(done))

    def test_a_new_path_must_name_a_file_the_lint_reads(self) -> None:
        files = {SPEC: page(), "docs/tally.csv": "dock,3\n", "docs/archive/dredge.md": "Silt.\n"}
        with forked(files) as repo:
            for path in ("README.md", "docs/tally.csv", "docs/archive", "docs/specs/ghost.md"):
                with self.subTest(path=path):
                    support.commit(repo, {CEILINGS: ceilings({path: 0})}, f"list {path}")
                    done = check(repo)
                    self.assertEqual(done.code, 1, done.out + done.err)
                    self.assertIn(f"{path}: names no Markdown file the lint reads at HEAD",
                                  lines(done))

    def test_a_listed_folder_whose_files_are_all_deleted_counts_none_and_keeps_its_entry(
            self) -> None:
        files = {SPEC: page(), "docs/specs/tide.md": page(), CEILINGS: ceilings({"docs/specs": 0})}
        with forked(files) as repo:
            support.run_git(repo, "rm", "-q", "-r", "docs/specs")
            support.run_git(repo, "commit", "-qm", "delete the folder")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertIn("docs/specs: 0 findings, at its ceiling of 0", lines(done))

    def test_a_record_file_takes_no_ceiling(self) -> None:
        record = "docs/plans/silt-plan.md"
        index = json.dumps({"docs": {record: {"doc_type": "plan"}}})
        files = {INDEX: index, record: f"# Silt\n\n{sentence(37)}\n",
                 "docs/plans/sluice-plan.md": f"# Sluice\n\n{sentence(36)}\n",
                 "docs/archive/dredge.md": f"# Dredge\n\n{sentence(44)}\n",
                 CEILINGS: ceilings({"docs/plans": 1})}
        with forked(files) as repo:
            # A folder skips its records: only the sluice plan counts.
            folder = check(repo)
            self.assertEqual(folder.code, 0, folder.out + folder.err)
            self.assertIn("docs/plans: 1 finding, at its ceiling of 1", lines(folder))
            for path in (record, "docs/archive/dredge.md"):
                with self.subTest(path=path):
                    support.commit(repo, {CEILINGS: ceilings({"docs/plans": 1, path: 1})},
                                   f"list {path}")
                    done = check(repo)
                    self.assertEqual(done.code, 1, done.out + done.err)
                    self.assertIn(f"{path} is a record; records take no ceiling", lines(done))

    def test_a_link_in_the_tree_is_not_read_as_a_file(self) -> None:
        # Git stores a link as the name of its target. A name that looks like a code would be a
        # finding if the link were read.
        with forked({SPEC: page(codes=1), CEILINGS: ceilings({"docs/specs": 1})}) as repo:
            os.symlink("TW9", repo / "docs/specs/odd.md")
            support.run_git(repo, "add", "-A")
            support.run_git(repo, "commit", "-qm", "add a link")
            done = check(repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertIn("docs/specs: 1 finding, at its ceiling of 1", lines(done))

    def test_a_head_file_that_is_not_utf8_exits_2(self) -> None:
        with forked({CEILINGS: ceilings({"docs": 0})}) as repo:
            put(repo, {"docs/guides/bytes.md": b"# Bytes\n\n\xff\xfe\n"})
            support.run_git(repo, "add", "-A")
            support.run_git(repo, "commit", "-qm", "bytes")
            done = check(repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("cannot read docs/guides/bytes.md: not UTF-8", done.err)


class Update(unittest.TestCase):
    """``--update`` re-records the working tree's counts and this engine's version."""

    def test_update_records_the_working_tree_counts_and_the_version(self) -> None:
        plan = f"# Sluice\n\n{sentence(37)}\n"
        listed = {SPEC: 0, "docs/gone.md": 8, "docs/plans": 0, "docs/specs": 0}
        with forked({SPEC: page(codes=2), "docs/plans/2026-09-14-lock-plan.md": plan,
                     CEILINGS: ceilings(listed, EARLIER)}) as repo:
            self.assertEqual(lines(check(repo)), [stale_line(EARLIER)])
            # Neither the page's new codes nor the new plan is committed: the working tree counts.
            put(repo, {SPEC: page(codes=4), "docs/plans/2026-09-15-weir-plan.md": plan})
            done = run("ceilings", "--update", cwd=repo)
            self.assertEqual(done.code, 0, done.out + done.err)
            written = (repo / CEILINGS).read_text(encoding="utf-8")
            support.commit(repo, {}, "record the counts")
            after = check(repo)
        self.assertEqual(written, "\n".join([
            "{", f'  "counting_version": {VERSION},', '  "paths": {', '    "docs/gone.md": 0,',
            '    "docs/plans": 2,', '    "docs/specs": 4,', f'    "{SPEC}": 4', "  }", "}", ""]))
        self.assertIn(f"{SPEC}: 4 findings", lines(done))
        self.assertEqual(lines(done)[-1], f"{CEILINGS}: recorded 4 paths at counting version "
                                          f"{VERSION}")
        # The base was counted with the earlier version, so the rises are allowed.
        self.assertEqual(after.code, 0, after.out + after.err)
        self.assertIn(f"{SPEC}: the ceiling rose from 0 to 4 against the base; allowed: the "
                      f"range changes counting_version from {EARLIER} to {VERSION}", lines(after))

    def test_update_adds_the_version_to_a_versionless_file(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: versionless({SPEC: 8})}) as repo:
            done = run("ceilings", "--update", cwd=repo)
            written = json.loads((repo / CEILINGS).read_text(encoding="utf-8"))
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(written, {"counting_version": VERSION, "paths": {SPEC: 3}})

    def test_update_adds_and_removes_no_path(self) -> None:
        with forked({SPEC: page(codes=3), "docs/specs/tide.md": page(codes=1),
                     CEILINGS: ceilings({SPEC: 8})}) as repo:
            done = run("ceilings", "--update", cwd=repo)
            written = json.loads((repo / CEILINGS).read_text(encoding="utf-8"))
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(written, {"counting_version": VERSION, "paths": {SPEC: 3}})

    def test_update_refuses_a_record_and_writes_nothing(self) -> None:
        record = "docs/plans/silt-plan.md"
        files = {INDEX: json.dumps({"docs": {record: {"doc_type": "plan"}}}),
                 record: f"# Silt\n\n{sentence(37)}\n", CEILINGS: ceilings({record: 1}, EARLIER)}
        with forked(files) as repo:
            before = (repo / CEILINGS).read_text(encoding="utf-8")
            done = run("ceilings", "--update", cwd=repo)
            after = (repo / CEILINGS).read_text(encoding="utf-8")
        self.assertEqual(done.code, 1, done.out + done.err)
        self.assertIn(f"{record} is a record; records take no ceiling", lines(done))
        self.assertEqual(after, before)

    def test_update_without_a_file_exits_2(self) -> None:
        with forked() as repo:
            done = run("ceilings", "--update", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn(CEILINGS, done.err)
        self.assertFalse((repo / CEILINGS).exists())

    def test_update_takes_no_base(self) -> None:
        with forked({CEILINGS: ceilings({})}) as repo:
            done = run("ceilings", "--update", "--base", "main", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("--update", done.err)
        self.assertEqual(done.out, "")


class Base(unittest.TestCase):
    """The base a ceilings check compares with."""

    def test_the_default_base_is_origin_head_and_then_origin_main(self) -> None:
        with forked({SPEC: page(codes=3), CEILINGS: ceilings({SPEC: 3})}) as repo:
            first = support.run_git(repo, "rev-parse", "main").strip()
            support.run_git(repo, "checkout", "-q", "main")
            second = support.commit(repo, {SPEC: page(codes=4), CEILINGS: ceilings({SPEC: 4})},
                                    "raise it on main")
            support.run_git(repo, "checkout", "-q", "feat")
            support.run_git(repo, "reset", "-q", "--hard", second)
            support.run_git(repo, "update-ref", "refs/remotes/origin/main", first)
            support.run_git(repo, "update-ref", "refs/remotes/origin/trunk", second)
            support.run_git(repo, "symbolic-ref", "refs/remotes/origin/HEAD",
                            "refs/remotes/origin/trunk")
            # origin/HEAD names origin/trunk, which already holds the raise.
            by_head = run("ceilings", cwd=repo)
            self.assertEqual(by_head.code, 0, by_head.out + by_head.err)
            # Without it the base is origin/main, which does not.
            support.run_git(repo, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
            by_main = run("ceilings", cwd=repo)
            self.assertEqual(by_main.code, 1, by_main.out + by_main.err)
            self.assertIn(f"{SPEC}: the ceiling rose from 3 to 4 against the base", lines(by_main))
            support.run_git(repo, "update-ref", "-d", "refs/remotes/origin/main")
            neither = run("ceilings", cwd=repo)
        self.assertEqual(neither.code, 2, neither.out + neither.err)
        self.assertIn("origin/main", neither.err)

    def test_a_base_git_cannot_resolve_exits_2_naming_it(self) -> None:
        with forked({CEILINGS: ceilings({})}) as repo:
            done = run("ceilings", "--base", "unknown-ref", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("unknown-ref", done.err)
        self.assertNotIn("Traceback", done.err)

    def test_outside_a_repository_exits_2(self) -> None:
        with tempfile.TemporaryDirectory(prefix="writing plain ") as base:
            home = Path(base) / "home"
            home.mkdir()
            env = {**os.environ, "HOME": str(home), "GIT_CEILING_DIRECTORIES": str(base)}
            with mock.patch.dict(os.environ, env, clear=True):
                done = run("ceilings", cwd=Path(base))
                counted = run("counts", cwd=Path(base))
        for answer in (done, counted):
            self.assertEqual(answer.code, 2, answer.out + answer.err)
            self.assertNotIn("Traceback", answer.err)
            self.assertNotIn("internal error", answer.err)


class Folders(unittest.TestCase):
    """``counts``: findings per folder and register, from the working tree."""

    FILES = {
        "AGENTS.md": f"# Agents\n\n{sentence(36)}\n",
        "README.md": f"# Read me\n\n{sentence(48)}\n",
        "docs/plans/silt-plan.md": f"# Silt\n\n{sentence(37)}\n",
        "docs/plans/sluice-plan.md": f"# Sluice\n\n{sentence(41)}\n\nTW1 reads high.\n",
        "docs/plans/sluice-design.md": f"# Sluice\n\n{sentence(40)}\n",
        SPEC: page(codes=2),
        "docs/archive/dredge.md": f"# Dredge\n\n{sentence(44)}\n",
        "docs/tally.csv": f"TW7,{sentence(44)}\n",
    }

    def test_counts_groups_by_folder_and_register_and_skips_records(self) -> None:
        record = "docs/plans/silt-plan.md"
        with forked({INDEX: json.dumps({"docs": {record: {"doc_type": "plan"}}}),
                     **self.FILES}) as repo:
            done = run("counts", "--format", "json", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(json.loads(done.out), {
            "counting_version": VERSION,
            "folders": [
                {"folder": ".", "register": "terse", "files": 1, "findings": 1},
                {"folder": "docs/plans", "register": "full", "files": 1, "findings": 0},
                {"folder": "docs/plans", "register": "terse", "files": 1, "findings": 2},
                {"folder": "docs/specs", "register": "full", "files": 1, "findings": 2}],
            # The plan the index types, and the archived page: records are left out.
            "records_skipped": 2})

    def test_counts_prints_text_by_default(self) -> None:
        with forked(self.FILES) as repo:
            done = run("counts", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(lines(done), [
            ".: terse, 1 file, 1 finding",
            "docs/plans: full, 1 file, 0 findings",
            "docs/plans: terse, 2 files, 3 findings",
            "docs/specs: full, 1 file, 2 findings",
            f"counting version {VERSION}; 1 record skipped"])

    def test_counts_reads_the_working_tree(self) -> None:
        files = {SPEC: page(codes=1), "docs/specs/tide.md": page(codes=1),
                 ".gitignore": "docs/specs/ice.md\n"}
        with forked(files) as repo:
            put(repo, {SPEC: page(codes=3), "docs/specs/new.md": page(codes=1),
                       "docs/specs/ice.md": page(codes=1)})
            os.remove(repo / "docs/specs/tide.md")
            os.symlink("mill.md", repo / "docs/specs/link.md")
            done = run("counts", "--format", "json", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        # The edited page and the untracked one count; the deleted page, the ignored page and the
        # link do not.
        self.assertEqual(json.loads(done.out)["folders"], [
            {"folder": "docs/specs", "register": "full", "files": 2, "findings": 4}])

    def test_counts_under_given_paths_from_anywhere_in_the_repository(self) -> None:
        with forked(self.FILES) as repo:
            by_path = run("counts", "--format", "json", "docs/specs", cwd=repo)
            from_below = run("counts", "--format", "json", "plans", cwd=repo / "docs")
            whole = run("counts", "--format", "json", cwd=repo / "docs")
        self.assertEqual([item["folder"] for item in json.loads(by_path.out)["folders"]],
                         ["docs/specs"])
        self.assertEqual([item["folder"] for item in json.loads(from_below.out)["folders"]],
                         ["docs/plans", "docs/plans"])
        self.assertEqual(json.loads(whole.out)["folders"][0]["folder"], ".")

    def test_counts_of_an_empty_repository(self) -> None:
        with forked() as repo:
            done = run("counts", "--format", "json", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(json.loads(done.out), {"counting_version": VERSION, "folders": [],
                                                "records_skipped": 0})

    def test_counts_names_a_file_it_cannot_read(self) -> None:
        with forked() as repo:
            put(repo, {"docs/guides/bytes.md": b"# Bytes\n\n\xff\xfe\n"})
            done = run("counts", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertIn("cannot read docs/guides/bytes.md: not UTF-8", done.err)

    def test_counts_with_a_path_outside_the_repository_exits_2(self) -> None:
        with forked() as repo:
            done = run("counts", "/", cwd=repo)
        self.assertEqual(done.code, 2, done.out + done.err)
        self.assertNotIn("Traceback", done.err)


# What ``counts`` reports for the corpus, by counting version. A change that moves these counts
# adds an entry for a new version and raises ``COUNTING_VERSION``; an existing entry never changes.
EXPECTED = {
    1: {
        "files": {"terse-hive-log.md": 8, "terse-kiln-checklist.md": 4,
                  "full-orchard-guide.md": 2, "full-gauge-notes.md": 4},
        "counts": {
            "counting_version": 1,
            "folders": [
                {"folder": "docs/guides", "register": "full", "files": 2, "findings": 6},
                {"folder": "docs/plans", "register": "terse", "files": 2, "findings": 12}],
            "records_skipped": 0},
    },
}


class Corpus(unittest.TestCase):
    """Four invented pages with a known number of findings each. Each is copied into a folder
    whose register the shipped path rules give it: the terse pages into ``docs/plans``, the full
    ones into ``docs/guides``. A change to those rules then moves the counts, as a change to a
    limit or a code pattern does."""

    @contextmanager
    def placed(self) -> Iterator[Path]:
        with support.git_repo() as repo:
            for source in sorted(CORPUS.glob("*.md")):
                folder = "docs/plans" if source.name.startswith("terse-") else "docs/guides"
                put(repo, {f"{folder}/{source.name}": source.read_bytes()})
            yield repo

    def test_the_corpus_has_two_terse_pages_and_two_full_ones(self) -> None:
        names = sorted(path.name for path in CORPUS.glob("*.md"))
        self.assertEqual(sorted(EXPECTED[VERSION]["files"]), names)
        self.assertEqual([name.split("-")[0] for name in names], ["full", "full", "terse", "terse"])

    def test_the_corpus_counts_match_the_counting_version(self) -> None:
        self.assertIn(VERSION, EXPECTED, "a new counting version needs an EXPECTED entry")
        with self.placed() as repo:
            done = run("counts", "--format", "json", cwd=repo)
        self.assertEqual(done.code, 0, done.out + done.err)
        self.assertEqual(json.loads(done.out), EXPECTED[VERSION]["counts"])

    def test_each_corpus_page_has_its_known_findings(self) -> None:
        with self.placed() as repo:
            for name, want in EXPECTED[VERSION]["files"].items():
                folder = "docs/plans" if name.startswith("terse-") else "docs/guides"
                with self.subTest(name=name):
                    done = run("check", "--format", "json", f"{folder}/{name}", cwd=repo)
                    self.assertEqual(len(json.loads(done.out)), want, done.out)

    def test_the_expected_files_add_up_to_the_expected_counts(self) -> None:
        for version, entry in EXPECTED.items():
            with self.subTest(version=version):
                registers: dict[str, int] = {}
                for name, found in entry["files"].items():
                    register = name.split("-")[0]
                    registers[register] = registers.get(register, 0) + found
                self.assertEqual(
                    {item["register"]: item["findings"] for item in entry["counts"]["folders"]},
                    {"full": registers["full"], "terse": registers["terse"]})


class Usage(unittest.TestCase):
    def test_usage_errors_exit_2(self) -> None:
        cases = (["ceilings", "--bogus"], ["ceilings", "docs/specs"], ["ceilings", "--base"],
                 ["ceilings", "--format", "json"], ["counts", "--format", "xml"],
                 ["counts", "--bogus"])
        with forked({CEILINGS: ceilings({})}) as repo:
            for args in cases:
                with self.subTest(args=args):
                    done = run(*args, cwd=repo)
                    self.assertEqual(done.code, 2, done.out + done.err)
                    self.assertEqual(done.out, "")
                    self.assertIn("usage:", done.err)
                    self.assertNotIn("Traceback", done.err)
                    self.assertNotIn("internal error", done.err)


if __name__ == "__main__":
    unittest.main()
