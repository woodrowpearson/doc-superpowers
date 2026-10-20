"""The cloud leg when it cannot work (no cloud extra, no project): degraded, never a crash.

Imports nothing from google, so these run on the base install too: a missing extra is simulated by
making the import fail, which is also what the base install does.
"""

from __future__ import annotations

import json
import sys
from dataclasses import replace
from pathlib import Path

import anyio
import pytest
from mcp.client.client import Client

from doc_search.cloud import CloudUnavailable
from doc_search.cloud.read import DegradedLeg, build_cloud_leg
from doc_search.cloud.vertex import VertexEmbedder
from doc_search.config import CloudCfg, FirestoreCfg, VertexCfg, load_config
from doc_search.engines import IndexPool, WorktreeIndexes
from doc_search.server import build_server

NO_PROJECT = "no project (set cloud.vertex.project or GOOGLE_CLOUD_PROJECT)"
NO_EXTRA = "cloud extra not installed (uv sync --extra cloud)"

SPEC = """# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

Refunds round half up to the nearest cent.
"""


def cloud_cfg(**vertex) -> CloudCfg:
    base = VertexCfg(project="p", location="us-central1", model="gemini-embedding-001", dimensions=768)
    firestore = FirestoreCfg("p", "(default)", "doc_chunks", "corpus_meta", None)
    return CloudCfg(vertex=replace(base, **vertex), firestore=firestore)


@pytest.fixture
def no_extra(monkeypatch: pytest.MonkeyPatch) -> None:
    """The google modules of the cloud extra cannot be imported."""
    for name in ("google.genai", "google.genai.types", "google.genai.errors", "google.cloud.firestore"):
        monkeypatch.setitem(sys.modules, name, None)


def test_no_project_is_a_degraded_leg() -> None:
    with pytest.raises(CloudUnavailable, match="no project"):
        VertexEmbedder(cloud_cfg(project=None))

    leg = build_cloud_leg(cloud_cfg(project=None))

    assert isinstance(leg, DegradedLeg)
    assert leg.hits("q", {"a.md"}, Path("."), 30) == ([], f"cloud failed: {NO_PROJECT}")
    assert leg.status_lines(Path(".")) == [f"cloud: unavailable: {NO_PROJECT}"]


def test_missing_extra_is_a_degraded_leg(no_extra: None) -> None:
    with pytest.raises(CloudUnavailable, match="cloud extra not installed"):
        VertexEmbedder(cloud_cfg())

    leg = build_cloud_leg(cloud_cfg())

    assert isinstance(leg, DegradedLeg)
    assert leg.hits("q", {"a.md"}, Path("."), 30) == ([], f"cloud failed: {NO_EXTRA}")


def serve(git_repo, tiny_model: str, cloud: dict):
    repo = git_repo()
    repo.write("docs/specs/SPEC-PAY-004.md", SPEC)
    config = {"docs": {"model": tiny_model}, "code": {"model": tiny_model}, "cloud": cloud}
    repo.write("docs/search/config.json", json.dumps(config))
    repo.commit("seed")
    cfg = load_config(repo.root, {"GOOGLE_CLOUD_PROJECT": ""})
    assert cfg is not None and cfg.cloud is not None
    pool = IndexPool(cfg)
    return repo, pool, build_server(repo.root, pool=pool)


def ask(server, tool: str, args: dict) -> str:
    async def go() -> str:
        async with Client(server) as client:
            result = await client.call_tool(tool, args)
        return result.content[0].text

    return anyio.run(go)


@pytest.mark.parametrize(
    ("cloud", "reason", "extra_missing"),
    [({}, NO_PROJECT, False), ({"vertex": {"project": "p"}, "firestore": {"project": "p"}}, NO_EXTRA, True)],
    ids=["no-project", "no-extra"],
)
def test_server_still_answers(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, cloud: dict, reason: str, extra_missing: bool
) -> None:
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    if extra_missing:
        for name in ("google.genai", "google.genai.types", "google.genai.errors", "google.cloud.firestore"):
            monkeypatch.setitem(sys.modules, name, None)
    repo, pool, server = serve(git_repo, tiny_model, cloud)

    try:
        found = ask(server, "search", {"query": "refund rounding half up", "scope": "docs"})
        status = ask(server, "status", {})
    finally:
        assert isinstance(pool.get(repo.root, wait_s=60), WorktreeIndexes)  # no build thread outlives the test

    assert "docs/specs/SPEC-PAY-004.md" in found
    assert f"note: cloud failed: {reason}" in found
    assert "(+cloud: gemini-embedding-001)" in found.splitlines()[0]
    assert f"cloud: unavailable: {reason}" in status
