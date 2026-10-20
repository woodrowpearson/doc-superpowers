"""Live: real semble indexes on semble's default model, through the CLI a user runs.

Skipped unless DOC_SEARCH_LIVE=1. It is the one test that touches the network: semble's default model
(`minishlab/potion-code-16M-v2`, about 33 MB) comes from Hugging Face on first use and is kept in the
Hugging Face cache (`HF_HOME`), as a user's first build does. The indexes go to the test's own semble cache.
"""

from __future__ import annotations

import json
import os

import huggingface_hub.constants
import pytest

from doc_search.cli import main

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(
        os.environ.get("DOC_SEARCH_LIVE") != "1",
        reason="live: set DOC_SEARCH_LIVE=1 (downloads semble's default model from Hugging Face)",
    ),
]

SPEC = """---
status: accepted
---
# SPEC-PAY-004: Refund rounding

Refunds are rounded half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum of the raw amounts.
"""

ADR = """# ADR-0002: PostgreSQL as the primary database

## Decision

We store orders, invoices and customers in PostgreSQL. It gives us transactions,
foreign keys and mature tooling; a document store was rejected.
"""

GUIDE = """# Deploying the service

Deploy to production with a blue-green switch: start the new release beside the old one,
run the smoke checks, then move the traffic and keep the old release for a quick rollback.
"""

REFUND_PY = '''def refund_total(lines):
    """Sum the refund line amounts, each rounded half up to the cent."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''

DEPLOY_PY = '''def switch_traffic(router, new_release):
    """Point the router at the new release once its smoke checks pass."""
    if not new_release.healthy():
        raise RuntimeError("smoke checks failed")
    router.target = new_release
'''


def query(run, text: str, scope: str) -> list[str]:
    done = run("query", text, "--scope", scope, "--format", "json")
    assert done[0] == 0, done
    return [hit["path"] for hit in json.loads(done[1])["hits"]]


def test_default_model_end_to_end(git_repo, monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    repo = git_repo()
    repo.write("docs/specs/SPEC-PAY-004.md", SPEC)
    repo.write("docs/adr/0002-postgres.md", ADR)
    repo.write("docs/guides/deploy.md", GUIDE)
    repo.write("src/refund.py", REFUND_PY)
    repo.write("src/deploy.py", DEPLOY_PY)
    repo.write("docs/search/config.json", "{}\n")  # the defaults: semble's default model for both indexes
    repo.commit("seed")
    monkeypatch.chdir(repo.root)
    monkeypatch.delenv("SEMBLE_MODEL_NAME", raising=False)
    # conftest makes the hub offline for every test; this one may download (huggingface_hub reads it per call)
    monkeypatch.setattr(huggingface_hub.constants, "HF_HUB_OFFLINE", False)

    def run(*argv: str) -> tuple[int, str, str]:
        code = main(list(argv))
        out, err = capsys.readouterr()
        return code, out, err

    built = run("index")
    assert built[0] == 0, built

    assert query(run, "how are refund amounts rounded", "docs")[0] == "docs/specs/SPEC-PAY-004.md"
    assert query(run, "which database did we choose and why", "docs")[0] == "docs/adr/0002-postgres.md"
    assert query(run, "how do we deploy a release to production", "docs")[0] == "docs/guides/deploy.md"
    assert query(run, "sum the rounded refund line amounts", "code")[0] == "src/refund.py"
    assert query(run, "move traffic to the new release", "code")[0] == "src/deploy.py"
