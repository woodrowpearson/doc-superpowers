"""`doc-search check`: the gating readiness probe, one test per row of its order (check.py's `assess`).

The CLI is driven in-process through `main(argv)`, as in test_cli.py, whose fixtures and helpers these
tests reuse. Every test has its own HOME and CODEX_HOME, so a developer's own Codex config never counts as
an MCP registration, and DOC_SEARCH_MCP is unset.
"""

from __future__ import annotations

import json
import shutil
import threading
from dataclasses import fields
from pathlib import Path
from typing import Any

import pytest
from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder

from doc_search.check import LAUNCHER_REL, Verdict, config_says_required
from doc_search.config import CONFIG_REL
from doc_search.engines import IndexPool
from doc_search.transformer import TransformerSpec
from doc_search.version import plugin_root, plugin_version
from conftest import CODE_PATH, SHIPPING_PATH
from test_cli import BuildSpy, build_held_elsewhere, build_threads, touch
from fakes_transformer import fake_encoder

INDEX_FIX = "sh .claude/doc-superpowers/search-mcp.sh index"
PLUGIN = ".".join(str(part) for part in plugin_version(plugin_root()) or (0, 0, 0))


@pytest.fixture(autouse=True)
def own_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A HOME and a CODEX_HOME of the test's own, and no per-developer MCP switch (a repository fixture then sets
    HOME again, to its own throwaway directory; CODEX_HOME stays this one)."""
    home = tmp_path / "check-home"
    (home / ".codex").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("CODEX_HOME", str(home / ".codex"))
    monkeypatch.delenv("DOC_SEARCH_MCP", raising=False)
    return home


def configure(made, **keys) -> None:
    """Set top-level keys of the repository's config (the docs and code models stay)."""
    path = made.root / CONFIG_REL
    path.write_text(json.dumps({**json.loads(path.read_text()), **keys}))


def install_launcher(made, text: str | None = None) -> Path:
    """The committed launcher copy: the plugin's own, or `text`."""
    target = made.root / LAUNCHER_REL
    target.parent.mkdir(parents=True, exist_ok=True)
    if text is None:
        shutil.copyfile(plugin_root() / "scripts" / "search" / "launch.sh", target)
    else:
        target.write_text(text)
    return target


@pytest.fixture
def gated(repo):
    """The static repository, required, with the plugin's own launcher copy (made before any index)."""
    configure(repo, required=True)
    install_launcher(repo)
    return repo


def install_fix(fix: str) -> bool:
    """The plugin's `install.sh install --search`, by its path (quoted when the path needs it)."""
    return fix.startswith("bash ") and "scripts/hooks/install.sh" in fix and fix.endswith(" install --search")


def check(run, *argv: str) -> tuple[int, dict]:
    done = run("check", "--format", "json", *argv)
    return done.code, json.loads(done.out)


# --- the cache rows ---------------------------------------------------------------------------------------


def test_check_ready_after_index(gated, run) -> None:
    assert run("index").code == 0

    text = run("check")
    code, payload = check(run)

    assert text.code == 0 and text.lines == ["doc-search: ready", "mcp: not-registered", "launcher: current"]
    assert code == 0 and payload["state"] == "ready" and payload["reason"] is None and payload["fix"] is None
    assert payload["cache"] == {"docs": "valid", "code": "valid", "docs_fallback": None}
    assert payload["refreshed"] is False and payload["required"] is True


def test_check_refreshes_a_stale_docs_index_within_budget(gated, run) -> None:
    assert run("index").code == 0
    touch(gated.root / SHIPPING_PATH)
    assert json.loads(run("status", "--format", "json").out)["cache"]["docs"] == "stale"

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready"
    assert payload["refreshed"] is True and payload["cache"]["docs"] == "valid"
    assert json.loads(run("status", "--format", "json").out)["cache"]["docs"] == "valid", "the refresh was saved"


def test_check_budget_overrun_is_not_ready(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    assert run("index").code == 0
    touch(gated.root / SHIPPING_PATH)
    gate = threading.Event()
    real = SembleIndex.from_path

    def slow(cls, *args, **kwargs):  # a build that holds until the test lets it go
        gate.wait(30)
        return real(*args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(slow))
    try:
        code, payload = check(run, "--budget", "1")
    finally:
        gate.set()
        for thread in threading.enumerate():
            if thread.name.startswith("doc-search-"):
                thread.join(30)

    assert code == 1 and payload["state"] == "not-ready"
    assert payload["reason"].startswith("refresh did not finish within 1s")
    assert payload["fix"] == INDEX_FIX and payload["refreshed"] is True


def test_check_refresh_that_fails_is_not_ready(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    assert run("index").code == 0
    touch(gated.root / SHIPPING_PATH)

    def broken(cls, *args, **kwargs):
        raise RuntimeError("disk full")

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(broken))
    code, payload = check(run)

    assert code == 1 and payload["reason"] == "docs index failed: RuntimeError: disk full"
    assert payload["fix"] == INDEX_FIX and payload["refreshed"] is True


def test_check_with_code_off_is_ready(gated, run) -> None:
    configure(gated, code={"enabled": False})
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready"
    assert payload["cache"] == {"docs": "valid", "code": "off", "docs_fallback": None}


def test_check_absent_index_is_not_ready_with_fix(gated, run) -> None:
    text = run("check")
    code, payload = check(run)

    assert text.code == 1
    assert text.lines[0] == f"doc-search: not ready: docs index absent; run {INDEX_FIX}"
    assert code == 1 and payload["reason"] == "docs index absent" and payload["fix"] == INDEX_FIX
    assert payload["refreshed"] is False


def test_check_absent_code_index_is_not_ready(gated, run) -> None:
    assert run("index").code == 0
    shutil.rmtree(find_index_from_cache_folder(str(gated.root), (ContentType.CODE,)))  # the docs index stays

    code, payload = check(run)

    assert code == 1 and payload["reason"] == "code index absent" and payload["fix"] == INDEX_FIX
    assert payload["cache"] == {"docs": "valid", "code": "absent", "docs_fallback": None}


@pytest.fixture
def tx_gated(tx_repo, spec: TransformerSpec):
    configure(tx_repo, required=True)
    install_launcher(tx_repo)
    return tx_repo


def test_check_degraded_on_static_fallback(tx_gated, spec: TransformerSpec, run) -> None:
    pool, served = build_held_elsewhere(tx_gated, spec)

    text = run("check")
    code, payload = check(run)

    progress = f"docs: transformer index building, 0 / {len(served.docs.chunks)} chunks encoded"
    reason = f"static index while the transformer index builds ({progress})"
    assert text.code == 0 and text.lines[0] == f"doc-search: degraded: {reason}"
    assert code == 0 and payload["state"] == "degraded" and payload["reason"] == reason
    assert payload["cache"] == {"docs": "absent", "code": "valid", "docs_fallback": "valid"}
    assert payload["refreshed"] is False


def test_check_refreshes_a_stale_static_fallback(tx_gated, spec: TransformerSpec, run) -> None:
    """No transformer index and a stale static one: the static index is refreshed, and serves (degraded)."""
    build_held_elsewhere(tx_gated, spec)
    touch(tx_gated.root / SHIPPING_PATH)
    assert json.loads(run("status", "--format", "json").out)["cache"]["docs_fallback"] == "stale"

    code, payload = check(run)

    assert code == 0 and payload["state"] == "degraded" and payload["refreshed"] is True
    assert payload["reason"].startswith("static index while the transformer index builds")
    assert payload["cache"] == {"docs": "absent", "code": "valid", "docs_fallback": "valid"}


def test_check_refreshes_a_stale_transformer_index(tx_gated, spec: TransformerSpec, run) -> None:
    assert run("index").code == 0  # the transformer index, built in the foreground
    touch(tx_gated.root / SHIPPING_PATH)
    assert json.loads(run("status", "--format", "json").out)["cache"]["docs"] == "stale"

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready" and payload["refreshed"] is True
    assert payload["cache"] == {"docs": "valid", "code": "valid", "docs_fallback": "absent"}


def test_check_stale_code_beside_the_static_fallback_starts_no_transformer_build(
    tx_gated, spec: TransformerSpec, run, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No transformer index, the static one valid and code stale: the refresh runs on the static config."""
    build_held_elsewhere(tx_gated, spec)  # the other process's transformer build is held mid-encode
    touch(tx_gated.root / CODE_PATH)
    started: list[object] = []
    real = IndexPool._run_transformer

    def spy(self, *args, **kwargs):
        started.append(self)
        return real(self, *args, **kwargs)

    monkeypatch.setattr(IndexPool, "_run_transformer", spy)
    code, payload = check(run, "--budget", "5")

    assert code == 0 and payload["state"] == "degraded" and payload["refreshed"] is True
    assert payload["cache"] == {"docs": "absent", "code": "valid", "docs_fallback": "valid"}
    assert started == [], "check started a transformer docs build"


def test_check_stale_transformer_refresh_over_budget_is_not_ready(tx_gated, spec: TransformerSpec, run) -> None:
    """A saved transformer index serves, so no static fallback does: a refresh that overruns stays not-ready."""
    assert run("index").code == 0
    touch(tx_gated.root / SHIPPING_PATH)
    fake_encoder(spec).gate.clear()  # the incremental encode holds (the spec fixture lets it go)

    code, payload = check(run, "--budget", "1")

    assert code == 1 and payload["state"] == "not-ready"
    assert payload["reason"] == "refresh did not finish within 1s" and payload["refreshed"] is True


def test_check_transformer_nothing_built_is_not_ready(tx_gated, run) -> None:
    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready"
    assert payload["reason"] == "transformer index not built" and payload["fix"] == INDEX_FIX
    assert payload["cache"] == {"docs": "absent", "code": "absent", "docs_fallback": "absent"}


# --- the versions and the launcher ------------------------------------------------------------------------


def test_check_plugin_below_floor(gated, run) -> None:
    configure(gated, requires=">=99.0.0")

    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready"
    assert payload["reason"] == f"doc-superpowers {PLUGIN} is below requires >=99.0.0"
    assert payload["fix"] == "claude plugin update doc-superpowers"
    assert payload["requires"] == ">=99.0.0" and payload["version"] == PLUGIN


def test_check_plugin_below_floor_in_the_codex_root_is_pulled(
    gated, run, own_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = own_home / ".codex" / "doc-superpowers"
    root.mkdir()
    (root / "package.json").write_text('{"version": "1.0.0"}')
    monkeypatch.setattr("doc_search.check.plugin_root", lambda: root.resolve())
    monkeypatch.setenv("HOME", str(own_home))  # git_repo's HOME came after this file's
    configure(gated, requires=">=2.0.0")

    code, payload = check(run)

    assert code == 1 and payload["reason"] == "doc-superpowers 1.0.0 is below requires >=2.0.0"
    assert payload["fix"] == "git -C ~/.codex/doc-superpowers pull"


def test_check_launcher_absent_or_below_floor_is_not_ready(gated, run) -> None:
    assert run("index").code == 0
    configure(gated, requires=f">={PLUGIN}")
    launcher = gated.root / LAUNCHER_REL

    launcher.unlink()
    code, payload = check(run)
    assert code == 1 and payload["launcher"] == "absent"
    assert payload["reason"] == f"launcher copy absent ({LAUNCHER_REL})"
    assert install_fix(payload["fix"])

    install_launcher(gated, "#!/bin/sh\n# doc-search launcher v0.0.1\n")
    code, payload = check(run)
    assert code == 1 and payload["launcher"] == "below-floor"
    assert payload["reason"] == f"launcher copy v0.0.1 is below requires >={PLUGIN}"
    assert install_fix(payload["fix"])

    install_launcher(gated, "#!/bin/sh\necho no stamp\n")
    code, payload = check(run)
    assert code == 1 and payload["launcher"] == "below-floor"
    assert payload["reason"] == f"launcher copy has no version stamp (requires >={PLUGIN})"


def test_check_launcher_differs_but_meets_floor_is_degraded(gated, run) -> None:
    assert run("index").code == 0
    configure(gated, requires=f">={PLUGIN}")
    launcher = gated.root / LAUNCHER_REL
    launcher.write_text(launcher.read_text() + "# a local edit\n")

    text = run("check")
    code, payload = check(run)

    assert code == 0 and payload["state"] == "degraded" and payload["launcher"] == "differs"
    assert payload["reason"] == "launcher copy differs from the plugin's"
    assert install_fix(payload["fix"])
    assert text.lines[-1] == "launcher: differs"


# --- not in force -----------------------------------------------------------------------------------------


def test_check_not_required_is_not_in_force(repo, run) -> None:
    install_launcher(repo)
    code, payload = check(run)
    assert code == 4 and payload["state"] == "not-in-force" and payload["required"] is False
    assert payload["reason"] == "not required here (not-ready: docs index absent)"

    assert run("index").code == 0
    text = run("check")
    assert text.code == 4 and text.lines[0] == "doc-search: not in force: not required here (ready)"


def test_check_not_required_and_stale_builds_nothing(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    """Not required: a stale index is reported from the cache states alone, with no refresh and no wait."""
    install_launcher(repo)
    assert run("index").code == 0
    touch(repo.root / SHIPPING_PATH)
    spy = BuildSpy(monkeypatch)

    code, payload = check(run)

    assert code == 4 and payload["state"] == "not-in-force" and payload["refreshed"] is False
    assert payload["reason"] == "not required here (stale: docs index stale)"
    assert payload["cache"]["docs"] == "stale"
    assert spy.calls == [] and build_threads() == [], "check built or loaded an index"
    assert json.loads(run("status", "--format", "json").out)["cache"]["docs"] == "stale", "nothing was written"


def test_check_no_config_is_not_in_force(repo, run) -> None:
    (repo.root / CONFIG_REL).unlink()

    code, payload = check(run)

    assert code == 4 and payload["state"] == "not-in-force"
    assert payload["reason"] == "no docs/search/config.json" and payload["cache"] == {}


def test_check_outside_a_repository_is_not_in_force(tmp_path: Path, run, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(tmp_path)

    code, payload = check(run)

    assert code == 4 and payload["reason"] == "not in a git work tree"


def test_check_invalid_required_config_is_not_ready(repo, run) -> None:
    (repo.root / CONFIG_REL).write_text('{"required" : true, "bogus": 1}')
    assert config_says_required(repo.root)

    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready" and payload["required"] is True
    assert payload["reason"] == "invalid config: unknown key bogus"
    assert payload["fix"] == "edit docs/search/config.json, then run sh .claude/doc-superpowers/search-mcp.sh check"


def test_check_invalid_config_without_required_is_not_in_force(repo, run) -> None:
    (repo.root / CONFIG_REL).write_text('{"bogus": 1, "required": false}')
    assert not config_says_required(repo.root)

    code, payload = check(run)

    assert code == 4 and payload["state"] == "not-in-force" and payload["required"] is False
    assert payload["reason"] == "invalid config: unknown key bogus"


# --- mcp, shape and usage ---------------------------------------------------------------------------------


def test_check_mcp_states(repo, run, own_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def mcp() -> str:
        return check(run)[1]["mcp"]

    assert mcp() == "not-registered"

    (own_home / ".codex" / "config.toml").write_text('[mcp_servers.doc-search]\ncommand = "sh"\n')
    assert mcp() == "expected", "the user's Codex config"
    (own_home / ".codex" / "config.toml").unlink()

    project = repo.root / ".codex" / "config.toml"
    project.parent.mkdir()
    project.write_text('[mcp_servers."doc-search"]\ncommand = "sh"\n')
    assert mcp() == "expected", "the project's Codex config"
    project.unlink()

    (repo.root / ".mcp.json").write_text(json.dumps({"mcpServers": {"other": {}}}))
    assert mcp() == "not-registered"
    (repo.root / ".mcp.json").write_text(json.dumps({"mcpServers": {"doc-search": {"command": "sh"}}}))
    assert mcp() == "expected", ".mcp.json"

    monkeypatch.setenv("DOC_SEARCH_MCP", "0")
    assert mcp() == "off", "the developer's switch wins"


def test_check_json_shape(gated, run) -> None:
    code, payload = check(run)

    assert set(payload) == {f.name for f in fields(Verdict)} | {"exit"}
    assert payload["exit"] == code == 1
    assert payload["version"] == PLUGIN and payload["requires"] is None
    assert payload["launcher"] == "current" and payload["mcp"] == "not-registered"


@pytest.mark.parametrize("budget", ["0", "601", "x"])
def test_check_budget_usage(repo, run, budget: str) -> None:
    done = run("check", "--budget", budget)

    assert done.code == 3 and "--budget" in done.err


def test_verdict_line_and_exit_codes() -> None:
    def verdict(state: str, reason: str | None = None, fix: str | None = None) -> Verdict:
        state_: Any = state  # a State literal
        return Verdict(state_, reason, fix, True, None, "1.2.3", "current", "expected", {}, False)

    assert [verdict(s).exit_code() for s in ("ready", "degraded", "not-ready", "not-in-force")] == [0, 0, 1, 4]
    assert verdict("ready").line() == "doc-search: ready"
    assert verdict("not-ready", "docs index absent", INDEX_FIX).line() == (
        f"doc-search: not ready: docs index absent; run {INDEX_FIX}"
    )
    assert verdict("not-in-force", "no docs/search/config.json").line() == (
        "doc-search: not in force: no docs/search/config.json"
    )
