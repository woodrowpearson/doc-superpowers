"""The test helpers themselves: the module loader and the isolated git repository."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from tests import support


class Load(unittest.TestCase):
    def test_load_imports_a_sibling_of_tests_with_its_directory_first_on_the_path(self) -> None:
        module = support.load("markdown")

        self.assertEqual(Path(module.__file__).resolve().parent, support.WRITING)
        self.assertEqual(sys.path[0], str(support.WRITING))

    def test_the_default_codes_hold_the_four_patterns(self) -> None:
        codes = support.DEFAULT_CODES

        self.assertEqual(len(codes.patterns), 4)
        self.assertIn("UTF-8", codes.allowed)
        self.assertIn("`", codes.gloss_chars)


class GitRepo(unittest.TestCase):
    def test_the_repository_is_isolated_and_the_environment_comes_back(self) -> None:
        before = dict(os.environ)
        with mock.patch.dict(os.environ, {"GIT_AUTHOR_NAME": "Outsider", "GIT_DIR": "/nowhere"}):
            outside = dict(os.environ)
            with support.git_repo() as repo:
                self.assertTrue((repo / ".git").is_dir())
                self.assertIn(" ", str(repo))
                self.assertEqual(os.environ["GIT_CONFIG_GLOBAL"], "/dev/null")
                self.assertEqual(os.environ["GIT_CONFIG_NOSYSTEM"], "1")
                self.assertNotEqual(os.environ["HOME"], before.get("HOME"))
                self.assertNotIn("GIT_DIR", os.environ)
                self.assertEqual(support.run_git(repo, "branch", "--show-current").strip(), "main")
                self.assertEqual(support.run_git(repo, "config", "user.name").strip(),
                                 "Test Author")
                self.assertEqual(support.run_git(repo, "config", "user.email").strip(),
                                 "author@example.com")

                support.commit(repo, {"a.md": "one\n"}, "first")

                self.assertEqual(support.run_git(repo, "log", "-1", "--format=%an").strip(),
                                 "Test Author")
                kept = repo
            self.assertEqual(dict(os.environ), outside)
        self.assertFalse(kept.exists())
        self.assertEqual(dict(os.environ), before)

    def test_commit_returns_the_commit_id_and_stores_the_bytes(self) -> None:
        with support.git_repo() as repo:
            first = support.commit(repo, {"docs/a.md": "one\r\ntwo\r\n", "b.md": "b\n"}, "first")
            second = support.commit(repo, {"docs/a.md": "café\n"}, "second")

            self.assertRegex(first, r"^[0-9a-f]{40}$")
            self.assertNotEqual(first, second)
            self.assertEqual(support.run_git(repo, "rev-parse", "HEAD").strip(), second)
            self.assertEqual(support.run_git(repo, "rev-parse", "HEAD~1").strip(), first)
            self.assertEqual(support.run_git(repo, "show", f"{first}:docs/a.md"), "one\r\ntwo\r\n")
            self.assertEqual(support.run_git(repo, "show", f"{second}:docs/a.md"), "café\n")
            self.assertEqual(support.run_git(repo, "show", f"{second}:b.md"), "b\n")
            self.assertEqual(support.run_git(repo, "log", "-1", "--format=%s", second).strip(),
                             "second")

    def test_a_failing_git_command_raises(self) -> None:
        with support.git_repo() as repo:
            with self.assertRaises(subprocess.CalledProcessError):
                support.run_git(repo, "show", "no-such-rev")


if __name__ == "__main__":
    unittest.main()
