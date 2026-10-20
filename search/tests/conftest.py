"""Shared fixtures: offline semble, a tiny Model2Vec model, and isolated git repositories.

Tests never touch the network, the user's semble cache, or the user's git config.
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest

# huggingface_hub reads HF_HUB_OFFLINE once, at import. conftest loads before any test
# module (and so before semble and model2vec), so setting it here makes it stick.
os.environ["HF_HUB_OFFLINE"] = "1"

# A fixed vocabulary for the tiny model: the words the tests' docs and code are written
# in. A word outside it tokenizes to [UNK], so a task that adds test texts with new
# vocabulary extends this list (append only: the vectors are seeded by position).
VOCAB = """
refund refunds rounding round rounded half up down nearest cent cents total totals sum amount
amounts line lines never always price tax rate discount fee payment payments invoice invoices
order orders customer customers account balance credit debit charge charges currency decimal
float int integer string bool true false none null if else elif while for in not and or is
are was be by on at an a the of to from with as it this that we use used uses when then must
should can will all any each new old first last next more less see also related note example
rule rules policy limit default max min count size time date day month year version release
build run start stop open close read write get set add remove update delete create check
verify validate parse load save store fetch send receive handle process compute calculate
format render print log debug info warn fail pass ok error errors exception value values
result results query request response server client database data model user name id key list
dict def class return import self test tests spec design plan adr decision context
consequences status draft accepted proposed deprecated superseded archived title heading
section overview summary doc docs code file files path module function worktree branch
commit index search config auth login session token cache queue event handler service api
cloud local remote repo repository tree guide readme usage install setup
""".split()

TINY_MODEL_DIM = 16


@pytest.fixture(autouse=True)
def semble_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """Point semble's cache at a per-test directory and forbid hub traffic.

    The isolation is checked again when the test ends. A test that calls `monkeypatch.undo()`
    reverts these variables too, and every index it builds from then on is written to the
    developer's real semble cache. Scope such patches with `monkeypatch.context()` instead.
    """
    cache = tmp_path / "semble-cache"
    cache.mkdir()
    monkeypatch.setenv("SEMBLE_CACHE_LOCATION", str(cache))
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    yield cache
    assert os.environ.get("SEMBLE_CACHE_LOCATION") == str(cache), (
        "SEMBLE_CACHE_LOCATION changed during the test (monkeypatch.undo()?): "
        "its indexes may have reached the real semble cache"
    )
    assert os.environ.get("HF_HUB_OFFLINE") == "1", "HF_HUB_OFFLINE changed during the test (monkeypatch.undo()?)"


@pytest.fixture(scope="session")
def tiny_model(tmp_path_factory: pytest.TempPathFactory) -> str:
    """A Model2Vec StaticModel built in-process: seeded random 16-d vectors over VOCAB."""
    import numpy as np
    from model2vec import StaticModel
    from tokenizers import Tokenizer, models, normalizers, pre_tokenizers

    words = ["[UNK]", "[PAD]"]
    words += [w for w in dict.fromkeys(VOCAB) if w not in words]
    tokenizer = Tokenizer(models.WordLevel({w: i for i, w in enumerate(words)}, unk_token="[UNK]"))
    tokenizer.normalizer = normalizers.Lowercase()
    tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
    rng = np.random.default_rng(0)
    vectors = rng.standard_normal((len(words), TINY_MODEL_DIM)).astype(np.float32)
    model = StaticModel(vectors=vectors, tokenizer=tokenizer, normalize=True)
    path = tmp_path_factory.mktemp("tiny-model")
    model.save_pretrained(path)
    return str(path)


@dataclass
class GitRepo:
    """A throwaway git repository with its own HOME and no inherited git config."""

    root: Path
    env: dict[str, str]

    def git(self, *args: str, cwd: Path | None = None) -> str:
        done = subprocess.run(
            ["git", *args],
            cwd=cwd or self.root,
            env=self.env,
            capture_output=True,
            text=True,
        )
        if done.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} failed ({done.returncode}): {done.stderr.strip()}")
        return done.stdout

    def write(self, rel: str, text: str) -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def commit(self, msg: str) -> str:
        """Stage everything, commit, and return the new commit's full sha."""
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD").strip()

    def add_worktree(self, name: str, branch: str) -> Path:
        """Add a linked worktree (a sibling directory of the repository) on `branch`."""
        path = self.root.parent / f"{self.root.name}-wt-{name}"
        exists = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
            cwd=self.root,
            env=self.env,
            capture_output=True,
        ).returncode == 0
        if exists:
            self.git("worktree", "add", "-q", str(path), branch)
        else:
            self.git("worktree", "add", "-q", "-b", branch, str(path))
        return path.resolve()


@pytest.fixture
def git_repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Callable[..., GitRepo]:
    """Factory: `git_repo()` makes an initialised repository on branch `main`.

    The process environment is isolated too (not just the fixture's own git calls), so the
    git helpers under test see no user config either.
    """
    home = tmp_path / "git-home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    # a pytest run started from inside a git hook inherits these; none may reach the fixtures
    for leaked in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
    ):
        env.pop(leaked, None)
        monkeypatch.delenv(leaked, raising=False)
    for key in ("HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT"):
        monkeypatch.setenv(key, env[key])
    made = 0

    def make(name: str | None = None) -> GitRepo:
        nonlocal made
        made += 1
        root = tmp_path / (name or f"repo{made}")
        root.mkdir()
        repo = GitRepo(root=root.resolve(), env=env)
        repo.git("init", "-q", "-b", "main")
        return repo

    return make
