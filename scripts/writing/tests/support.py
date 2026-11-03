"""Helpers the writing tests share: loading a module that sits beside ``tests/``, and a throwaway
git repository that no global git setting can reach."""

from __future__ import annotations

import importlib
import os
import subprocess
import sys
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType
from unittest import mock

WRITING = Path(__file__).resolve().parents[1]


def load(name: str) -> ModuleType:
    """Import ``name``, a module beside ``tests/``, with ``scripts/writing/`` first on
    ``sys.path``. An isolated interpreter (``-I``) leaves the script directory off the path, and
    the modules import each other by name."""
    where = str(WRITING)
    if sys.path[:1] != [where]:
        if where in sys.path:
            sys.path.remove(where)
        sys.path.insert(0, where)
    return importlib.import_module(name)


markdown = load("markdown")
config = load("config")
Codes = markdown.Codes


def _default_codes() -> Codes:
    with tempfile.TemporaryDirectory(prefix="writing defaults ") as empty:
        return config.load(Path(empty)).codes


# What a code looks like and which words are never codes, as ``defaults.json`` has them: four
# shapes (a hyphenated record such as ORB-12, a short one such as KX7, a short name and hash such
# as beacon-~a1c9, an issue number such as #318), the words that are never codes, and the
# characters that make a bracket after them a gloss. No project file and no work ledger.
DEFAULT_CODES: Codes = _default_codes()


def run_git(repo: Path, *args: str) -> str:
    """Run ``git`` in ``repo`` and return its standard output as UTF-8 text, line endings as
    git wrote them; a failure raises."""
    result = subprocess.run(["git", *args], cwd=str(repo), check=True, capture_output=True)
    return result.stdout.decode("utf-8")


@contextmanager
def git_repo() -> Iterator[Path]:
    """A temporary repository on ``main``, with a user name and email, and an environment git
    cannot reach out of: no system or global config, a private ``HOME``, no ``GIT_*`` variable
    from the caller. The environment holds while the block runs, so code under test that calls
    ``git`` sees the same repository settings. The directory name holds a space."""
    with tempfile.TemporaryDirectory(prefix="writing test ") as base:
        home = Path(base) / "home"
        repo = Path(base) / "repo"
        home.mkdir()
        repo.mkdir()
        isolated = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        isolated.update(HOME=str(home), XDG_CONFIG_HOME=str(home / "config"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        with mock.patch.dict(os.environ, isolated, clear=True):
            try:
                run_git(repo, "init", "-q", "-b", "main")
            except subprocess.CalledProcessError:  # git older than 2.28 has no -b
                run_git(repo, "init", "-q")
                run_git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
            run_git(repo, "config", "user.name", "Test Author")
            run_git(repo, "config", "user.email", "author@example.com")
            yield repo


def commit(repo: Path, files: dict[str, str], message: str) -> str:
    """Write ``files`` (path to text, written as UTF-8 byte for byte) into ``repo``, commit all
    changes with ``message`` and return the commit id."""
    for name, text in files.items():
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))
    run_git(repo, "add", "-A")
    run_git(repo, "commit", "-q", "-m", message)
    return run_git(repo, "rev-parse", "HEAD").strip()
