"""The cloud leg when it cannot work (no cloud extra, no project): degraded, never a crash.

Imports nothing from google, so these run on the base install too: a missing extra is simulated by
making the import fail, which is also what the base install does.
"""

from __future__ import annotations

import importlib
import json
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import anyio
import pytest
from mcp.client.client import Client

import doc_search.cloud as cloud_pkg
import doc_search.cloud.read as cloud_read
from doc_search.cloud import CloudUnavailable
from doc_search.cloud.read import DegradedLeg, build_cloud_leg
from doc_search.cloud.vertex import VertexEmbedder
from doc_search.config import CloudCfg, FirestoreCfg, VertexCfg, load_config
from doc_search.engines import IndexPool, WorktreeIndexes
from doc_search.server import build_server

NO_PROJECT = "no project (set cloud.vertex.project or GOOGLE_CLOUD_PROJECT)"
NO_EXTRA = "cloud extra not installed (uv sync --extra cloud)"
BROKEN = "google libraries failed to load: TypeError: Descriptors cannot be created directly."

SPEC = """# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

Refunds round half up to the nearest cent.
"""


def cloud_cfg(**vertex) -> CloudCfg:
    base = VertexCfg(project="p", location="us-central1", model="gemini-embedding-001", dimensions=768)
    firestore = FirestoreCfg("p", "(default)", "doc_chunks", "corpus_meta", None)
    return CloudCfg(vertex=replace(base, **vertex), firestore=firestore)


GOOGLE_MODULES = ("google.genai", "google.genai.types", "google.genai.errors", "google.cloud.firestore")


def hide_google(monkeypatch: pytest.MonkeyPatch) -> None:
    """The google modules of the cloud extra cannot be imported."""
    for name in GOOGLE_MODULES:
        monkeypatch.setitem(sys.modules, name, None)


def break_google(monkeypatch: pytest.MonkeyPatch) -> None:
    """Importing a google module raises what a broken install raises (a protobuf mismatch), not ImportError."""
    real = importlib.import_module

    def broken(name: str, package: str | None = None):
        if name == "google" or name.startswith("google."):
            raise TypeError(
                "Descriptors cannot be created directly.\nIf this call came from a _pb2.py file, "
                "your generated code is out of date and must be regenerated with protoc >= 3.19.0."
            )
        return real(name, package)

    monkeypatch.setattr(cloud_pkg, "importlib", SimpleNamespace(import_module=broken))


@pytest.fixture
def no_extra(monkeypatch: pytest.MonkeyPatch) -> None:
    hide_google(monkeypatch)


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


def test_a_broken_install_is_a_degraded_leg(monkeypatch: pytest.MonkeyPatch) -> None:
    break_google(monkeypatch)

    with pytest.raises(CloudUnavailable, match="google libraries failed to load: TypeError"):
        VertexEmbedder(cloud_cfg())
    leg = build_cloud_leg(cloud_cfg())

    assert isinstance(leg, DegradedLeg)
    note = leg.hits("q", {"a.md"}, Path("."), 30)[1]
    assert note is not None and note.startswith(f"cloud failed: {BROKEN}") and "\n" not in note


def test_any_failure_to_build_the_leg_is_a_degraded_leg(monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(*args, **kwargs):
        raise RuntimeError("cannot build\nanything")

    monkeypatch.setattr(cloud_read, "VertexEmbedder", boom)

    leg = build_cloud_leg(cloud_cfg())

    assert isinstance(leg, DegradedLeg) and leg.reason == "RuntimeError: cannot build anything"


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
    ("cloud", "mode", "reason"),
    [
        ({}, "no-project", NO_PROJECT),
        ({"vertex": {"project": "p"}, "firestore": {"project": "p"}}, "no-extra", NO_EXTRA),
        ({"vertex": {"project": "p"}, "firestore": {"project": "p"}}, "broken-install", BROKEN),
    ],
    ids=["no-project", "no-extra", "broken-install"],
)
def test_server_still_answers(
    git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, cloud: dict, mode: str, reason: str
) -> None:
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    if mode == "no-extra":
        hide_google(monkeypatch)
    elif mode == "broken-install":
        break_google(monkeypatch)
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
