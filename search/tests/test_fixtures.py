"""The offline fixtures: a tiny Model2Vec model, a fake transformer and git repositories drive real semble."""

from __future__ import annotations

import os
import subprocess
import threading
from pathlib import Path

from semble import ContentType, SembleIndex

REFUNDS_MD = """# Refund rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

SHIPPING_MD = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

CACHE_PY = '''def load_session(token):
    """Read a session from the cache by token."""
    return cache.get(token)
'''

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''


def test_tiny_model_drives_semble(tiny_model: str, git_repo) -> None:
    repo = git_repo()
    repo.write("docs/refunds.md", REFUNDS_MD)
    repo.write("docs/shipping.md", SHIPPING_MD)
    repo.write("src/refund.py", REFUND_PY)
    repo.write("src/cache.py", CACHE_PY)
    repo.commit("seed")

    docs = SembleIndex.from_path(repo.root, content=[ContentType.DOCS], model_path=tiny_model)
    docs_hits = docs.search("refund rounding", top_k=3)
    assert docs_hits, "the docs index returned nothing"
    assert docs_hits[0].chunk.file_path == "docs/refunds.md"
    assert {h.chunk.file_path for h in docs.search("refund rounding", top_k=10)} <= {
        "docs/refunds.md",
        "docs/shipping.md",
    }

    code = SembleIndex.from_path(repo.root, content=[ContentType.CODE], model_path=tiny_model)
    code_hits = code.search("refund rounding", top_k=3)
    assert code_hits, "the code index returned nothing"
    assert code_hits[0].chunk.file_path == "src/refund.py"
    assert {h.chunk.file_path for h in code.search("refund rounding", top_k=10)} <= {
        "src/refund.py",
        "src/cache.py",
    }


def test_semble_runs_offline_with_an_isolated_cache(semble_cache: Path) -> None:
    assert os.environ["HF_HUB_OFFLINE"] == "1"
    assert Path(os.environ["SEMBLE_CACHE_LOCATION"]) == semble_cache
    assert semble_cache.is_absolute()



def test_fake_transformer_gate_holds_indexing_only(fake_transformer) -> None:
    """A cleared gate holds a build mid-encode while a search, on the same encoder, still answers."""
    from fakes_transformer import fake_encoder

    encoder = fake_encoder(fake_transformer)
    encoder.gate.clear()
    build = threading.Thread(target=encoder.encode, args=(["refund total"],), kwargs={"use_multiprocessing": False})
    build.start()
    build.join(0.2)
    assert build.is_alive() and encoder.forwarded == []  # held at the gate
    assert encoder.encode(["refund"]).shape == (1, fake_transformer.dim)  # a query does not wait
    assert encoder.forwarded == [["refund"]]
    encoder.gate.set()
    build.join(10)
    assert not build.is_alive()
    assert encoder.forwarded == [["refund"], ["refund total"]]


def test_git_repo_is_isolated_from_user_config(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "one\n")
    first = repo.commit("first")
    assert len(first) == 40
    author = repo.git("log", "-1", "--format=%an <%ae>").strip()
    assert author == "t <t@example.com>"
    assert repo.git("rev-parse", "--abbrev-ref", "HEAD").strip() == "main"


def test_git_repo_adds_worktrees(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "one\n")
    repo.commit("first")
    wt = repo.add_worktree("feature", "feat/x")
    assert wt.is_dir()
    assert (wt / "a.txt").read_text() == "one\n"
    assert repo.git("-C", str(wt), "rev-parse", "--abbrev-ref", "HEAD").strip() == "feat/x"
    listing = repo.git("worktree", "list", "--porcelain")
    assert str(wt.resolve()) in listing


def test_git_repo_calls_do_not_see_the_users_home(git_repo) -> None:
    repo = git_repo()
    out = subprocess.run(
        ["git", "config", "--global", "--list"],
        cwd=repo.root,
        env=repo.env,
        capture_output=True,
        text=True,
    )
    assert out.stdout.strip() == ""
