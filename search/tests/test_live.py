"""Live: real semble indexes, through the CLI a user runs.

Skipped unless DOC_SEARCH_LIVE=1. These are the tests that touch the network. The first runs on semble's
default model (`minishlab/potion-code-16M-v2`, about 33 MB); the second runs the local transformer docs model
(`transformer:gte-modernbert-base`: the int8 ONNX file and the tokenizer, about 150 MB; it needs the
local-transformer extra, so `uv run --all-extras`). Both come from Hugging Face on first use and are kept in the
Hugging Face cache (`HF_HOME`), as a user's first build does. The indexes go to the test's own semble cache and
the encode cache to the test's own `DOC_SEARCH_CACHE_LOCATION`.
"""

from __future__ import annotations

import json
import os

import huggingface_hub.constants
import pytest
from semble import ContentType, SembleIndex
from semble.cache import get_validated_cache
from semble.index.types import PersistencePath

from doc_search import transformer
from doc_search.cli import main

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(
        os.environ.get("DOC_SEARCH_LIVE") != "1",
        reason="live: set DOC_SEARCH_LIVE=1 (downloads models from Hugging Face)",
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


def seed(repo, config: str) -> None:
    repo.write("docs/specs/SPEC-PAY-004.md", SPEC)
    repo.write("docs/adr/0002-postgres.md", ADR)
    repo.write("docs/guides/deploy.md", GUIDE)
    repo.write("src/refund.py", REFUND_PY)
    repo.write("src/deploy.py", DEPLOY_PY)
    repo.write("docs/search/config.json", config)
    repo.commit("seed")


def allow_downloads(monkeypatch: pytest.MonkeyPatch) -> None:
    # conftest makes the hub offline for every test; these may download (huggingface_hub reads it per call)
    monkeypatch.setattr(huggingface_hub.constants, "HF_HUB_OFFLINE", False)


def test_default_model_end_to_end(git_repo, monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    repo = git_repo()
    seed(repo, "{}\n")  # the defaults: semble's default model for both indexes
    monkeypatch.chdir(repo.root)
    monkeypatch.delenv("SEMBLE_MODEL_NAME", raising=False)
    allow_downloads(monkeypatch)

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


def test_transformer_docs_model_end_to_end(git_repo, monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    """The docs index on gte-modernbert: the CLI builds it in the foreground (there is no static fallback)."""
    spec = transformer.REGISTRY["gte-modernbert-base"]
    repo = git_repo()
    # the code index is off: this test is the docs model's (code.model refuses a transformer: it is always static)
    config = {"docs": {"model": f"transformer:{spec.name}"}, "code": {"enabled": False}}
    seed(repo, json.dumps(config))
    monkeypatch.chdir(repo.root)
    monkeypatch.delenv("SEMBLE_MODEL_NAME", raising=False)
    allow_downloads(monkeypatch)

    def run(*argv: str) -> tuple[int, str, str]:
        code = main(list(argv))
        out, err = capsys.readouterr()
        return code, out, err

    built = run("index")
    assert built[0] == 0, built

    # what semble saved: the docs index records the model path with the registry revision, at 768 dimensions
    saved = get_validated_cache(str(repo.root.resolve()), spec.model_path, (ContentType.DOCS,))
    assert saved is not None, "no valid saved docs index for the transformer model path"
    metadata = json.loads(PersistencePath.from_path(saved).metadata.read_text(encoding="utf-8"))
    assert metadata["model_path"] == spec.model_path == "transformer:gte-modernbert-base@e7f32e3c00f9"
    transformer.install()  # the CLI installed it already; loading a saved index asks the model loader for the encoder
    index = SembleIndex.load_from_disk(saved)
    assert index.model.dim == spec.dim == 768
    assert index._semantic_index.vectors.shape == (len(index.chunks), 768)  # private, as the seam test reads it

    status = run("status", "--format", "json")
    assert status[0] == 0, status
    payload = json.loads(status[1])
    assert payload["cache"]["docs"] == "valid" and payload["ready"] is True
    assert payload["docs"]["transformer"]["model"] == spec.model_path
    assert payload["encode_cache"]["bytes"] > 0  # the build stored its vectors

    assert query(run, "how are refund amounts rounded", "docs")[0] == "docs/specs/SPEC-PAY-004.md"
    assert query(run, "which database did we choose and why", "docs")[0] == "docs/adr/0002-postgres.md"
    assert query(run, "how do we deploy a release to production", "docs")[0] == "docs/guides/deploy.md"
