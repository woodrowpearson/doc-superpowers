"""Shared fixtures: offline semble, a tiny Model2Vec model, a fake transformer model, isolated git repositories, and
the command line's seeded repository (`repo`, `tx_repo`, `run`: test_cli.py and test_check.py).

Tests never touch the network, the user's semble cache, or the user's git config.
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from doc_search.transformer import TransformerSpec

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


@pytest.fixture(autouse=True)
def doc_search_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """Point doc-search's own cache (the encode cache, the host lock, the build progress) at a per-test directory.

    Checked again when the test ends, like `semble_cache`: a test that needs another value scopes
    the patch with `monkeypatch.context()`.
    """
    cache = tmp_path / "doc-search-cache"
    monkeypatch.setenv("DOC_SEARCH_CACHE_LOCATION", str(cache))
    yield cache
    assert os.environ.get("DOC_SEARCH_CACHE_LOCATION") == str(cache), (
        "DOC_SEARCH_CACHE_LOCATION changed during the test (monkeypatch.undo()?): "
        "its encode cache may have reached the real doc-search cache"
    )


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


@pytest.fixture
def fake_transformer(monkeypatch: pytest.MonkeyPatch, tiny_model: str) -> Iterator[TransformerSpec]:
    """A transformer docs model that loads nothing: yields its spec, `test-tiny` (16-d).

    The spec is in the registry for the test's lifetime, and the encoder loader makes a
    `FakeEncoder` for it over a real encode cache (`fakes_transformer.fake_encoder()` returns the
    one a build uses). semble's default model is the tiny static one, so a static build works
    offline. The process's encoders are dropped before and after (each test starts as a new
    process would), any build still held at a gate is let go to fail, and semble's own loader is
    put back.
    """
    import semble.index.dense as dense

    from doc_search import transformer
    from fakes_transformer import TEST_SPEC, FakeEncoder, fake_cache

    made: list[FakeEncoder] = []

    def make(spec: TransformerSpec, threads: int) -> FakeEncoder:
        encoder = FakeEncoder(spec, fake_cache(spec), threads=threads)
        made.append(encoder)
        return encoder

    monkeypatch.setattr(transformer, "REGISTRY", {**transformer.REGISTRY, TEST_SPEC.name: TEST_SPEC})
    monkeypatch.setattr(transformer, "_make_encoder", make)
    monkeypatch.setattr(transformer, "_threads", None)
    monkeypatch.setattr(dense, "_load_cached", dense._load_cached)  # undone at the end: semble's loader is back
    monkeypatch.setenv("SEMBLE_MODEL_NAME", tiny_model)
    transformer._reset_encoders()
    yield TEST_SPEC
    for encoder in made:
        encoder.retire()
    transformer._reset_encoders()


@pytest.fixture
def spec(fake_transformer: TransformerSpec) -> Iterator[TransformerSpec]:
    """The fake transformer's spec, for the tests of what a pool does with it; at the end every held encode is let
    go and every build thread joined (`fakes_transformer.release_builds`). test_transformer.py, which runs the
    real encoder, has a `spec` of its own (the tiny ONNX model's)."""
    from fakes_transformer import release_builds

    yield fake_transformer
    release_builds()


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


# --- the command line's repository (test_cli.py, test_check.py) ---------------------------------------------

SPEC_PATH = "docs/specs/SPEC-PAY-004.md"
SHIPPING_PATH = "docs/shipping.md"
CODE_PATH = "src/refund.py"

SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

## Rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

SHIPPING = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''


def seed(repo, tiny_model: str, **config) -> None:
    """The CLI tests' repository: two docs, one code file and a config on the tiny models (`config` adds keys)."""
    import json

    from doc_search.config import CONFIG_REL

    repo.write(SPEC_PATH, SPEC)
    repo.write(SHIPPING_PATH, SHIPPING)
    repo.write(CODE_PATH, REFUND_PY)
    repo.write(CONFIG_REL, json.dumps({"docs": {"model": tiny_model}, "code": {"model": tiny_model}, **config}))
    repo.commit("seed")


@pytest.fixture
def repo(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch):
    """An enabled repository (tiny models) that is the process's working directory."""
    made = git_repo()
    seed(made, tiny_model)
    monkeypatch.chdir(made.root)
    return made


@dataclass
class Ran:
    code: int
    out: str
    err: str

    @property
    def lines(self) -> list[str]:
        return self.out.splitlines()


@pytest.fixture
def run(capsys):
    """`run(*argv)`: the CLI's `main` in-process, with its exit code and captured output."""
    from doc_search.cli import main

    def go(*argv: str) -> Ran:
        code = main(list(argv))
        out, err = capsys.readouterr()
        return Ran(code, out, err)

    return go


@pytest.fixture
def tx_repo(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch):
    """An enabled repository whose docs model is the fake transformer, as the process's working directory."""
    made = git_repo()
    seed(made, tiny_model, docs={"model": "transformer:test-tiny"})
    monkeypatch.chdir(made.root)
    return made
