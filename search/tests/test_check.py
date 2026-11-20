"""`doc-search check`: the gating readiness probe, one test per row of its order (check.py's `assess`).

The CLI is driven in-process through `main(argv)`, as in test_cli.py, whose fixtures and helpers these
tests reuse. Every test has its own HOME and CODEX_HOME, so a developer's own Codex config never counts as
an MCP registration, and DOC_SEARCH_MCP is unset. Its own XDG_CACHE_HOME and no DOC_SEARCH_RELEASE_NOTES or
CLAUDE_PLUGIN_CACHE keep the developer's release-notes cache and plugin installs out of the security floor.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import threading
from dataclasses import fields
from pathlib import Path
from typing import Any

import pytest
from semble import ContentType, SembleIndex
from semble.cache import find_index_from_cache_folder

from doc_search import release_cache
from doc_search.check import LAUNCHER_REL, PLUGIN_FIX, Verdict, config_says_required, mcp_state
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
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg-cache"))
    monkeypatch.delenv("DOC_SEARCH_RELEASE_NOTES", raising=False)
    monkeypatch.delenv("CLAUDE_PLUGIN_CACHE", raising=False)
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

    assert text.code == 0 and text.lines == [
        "doc-search: ready",
        "mcp: claude=not-registered codex=not-registered",
        "launcher: current",
    ]
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


def fake_root(where: Path, monkeypatch: pytest.MonkeyPatch, version: str = "3.18.0", notes: str | None = None) -> Path:
    """A doc-superpowers root of the test's own at `version`, never the real one: the plugin's own launcher (so
    the committed copy stays current) and release notes whose first release is `version`."""
    (where / "scripts" / "search").mkdir(parents=True)
    shutil.copyfile(plugin_root() / "scripts" / "search" / "launch.sh", where / "scripts" / "search" / "launch.sh")
    (where / "package.json").write_text(json.dumps({"version": version}))
    (where / "RELEASE-NOTES.md").write_text(notes if notes is not None else own_notes(version))
    monkeypatch.setattr("doc_search.check.plugin_root", lambda: where.resolve())
    return where.resolve()


def own_notes(version: str) -> str:
    """A root's own release notes: `version` first, and an older security release under it."""
    return (
        f"# Release Notes\n\n## v{version} (2026-11-18)\n### Changed\n- x\n\n"
        "## v0.1.0 (2026-01-01)\n### Security\n- old\n"
    )


def upgrade_fix(root: Path) -> str:
    return f"bash {root}/scripts/hooks/install.sh upgrade"


def test_check_plugin_below_floor_in_a_plugin_install(gated, run, tmp_path: Path, monkeypatch) -> None:
    cache = tmp_path / "plugin-cache"
    monkeypatch.setenv("CLAUDE_PLUGIN_CACHE", str(cache))
    fake_root(cache / "doc-superpowers" / "doc-superpowers" / "3.18.0", monkeypatch)
    configure(gated, requires=">=99.0.0")

    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready"
    assert payload["reason"] == "doc-superpowers 3.18.0 is below requires >=99.0.0"
    assert payload["fix"] == PLUGIN_FIX == "claude plugin update doc-superpowers"
    assert payload["requires"] == ">=99.0.0" and payload["version"] == "3.18.0"


def test_check_plugin_below_floor_in_a_checkout_is_upgraded(gated, run, tmp_path: Path, monkeypatch) -> None:
    root = fake_root(tmp_path / "ds-checkout", monkeypatch)
    configure(gated, requires=">=99.0.0")

    code, payload = check(run)

    assert code == 1 and payload["reason"] == "doc-superpowers 3.18.0 is below requires >=99.0.0"
    assert payload["fix"] == upgrade_fix(root)


def test_check_plugin_below_floor_in_the_codex_root_is_upgraded(
    gated, run, own_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The Codex root is a git checkout that `install.sh upgrade` moves in place, as any other checkout."""
    root = fake_root(own_home / ".codex" / "doc-superpowers", monkeypatch, version="1.0.0")
    monkeypatch.setenv("HOME", str(own_home))  # git_repo's HOME came after this file's
    configure(gated, requires=">=2.0.0")

    code, payload = check(run)

    assert code == 1 and payload["reason"] == "doc-superpowers 1.0.0 is below requires >=2.0.0"
    assert payload["fix"] == upgrade_fix(root)


def test_plugin_fix_by_install_kind(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from doc_search.check import _plugin_fix

    home = tmp_path / "fix-home"
    env = {"HOME": str(home)}
    marketplace = home / ".claude" / "plugins" / "marketplaces" / "doc-superpowers"
    cached = home / ".claude" / "plugins" / "cache" / "doc-superpowers" / "doc-superpowers" / "3.18.0"
    elsewhere = tmp_path / "elsewhere" / "doc-superpowers" / "3.18.0"
    spaced = tmp_path / "a dir" / "doc-superpowers"
    for root in (marketplace, cached, elsewhere, spaced):
        root.mkdir(parents=True)

    def fix(root: Path, env: dict[str, str]) -> str:
        monkeypatch.setattr("doc_search.check.plugin_root", lambda: root.resolve())
        return _plugin_fix(env)

    assert fix(marketplace, env) == PLUGIN_FIX, "under ~/.claude/plugins/"
    assert fix(cached, env) == PLUGIN_FIX, "under the default plugin cache"
    assert fix(elsewhere, env) == upgrade_fix(elsewhere.resolve()), "a plain checkout"
    in_cache = {**env, "CLAUDE_PLUGIN_CACHE": str(tmp_path / "elsewhere")}
    assert fix(elsewhere, in_cache) == PLUGIN_FIX, "under CLAUDE_PLUGIN_CACHE"
    quoted = "'" + str(spaced.resolve() / "scripts" / "hooks" / "install.sh") + "'"
    assert fix(spaced, env) == f"bash {quoted} upgrade", "a path that needs quoting is quoted whole"


# --- the security floor -----------------------------------------------------------------------------------

SECURITY_NOTES = (
    "# Release Notes\n\n## v3.19.0 (2026-11-19)\n\n### Security\n- A fix users must upgrade for.\n\n"
    "## v3.18.0 (2026-11-18)\n\n### Changed\n- Something.\n"
)
SOURCE = "https://example.test/a-fork/doc-superpowers.git"
FETCHED = "2026-11-19T08:30:00Z"


def release_notes(
    where: Path, monkeypatch: pytest.MonkeyPatch | None = None, text: str = SECURITY_NOTES, **sidecar: Any
) -> Path:
    """`<where>/release-notes.md` and its sidecar, as `install.sh upgrade` writes them; named by
    DOC_SEARCH_RELEASE_NOTES when `monkeypatch` is given."""
    where.mkdir(parents=True, exist_ok=True)
    notes = where / "release-notes.md"
    notes.write_text(text)
    meta = {"tag": "v3.19.0", "fetched": FETCHED, "source": SOURCE, **sidecar}
    (where / "release-notes.json").write_text(json.dumps(meta) + "\n")
    if monkeypatch is not None:
        monkeypatch.setenv("DOC_SEARCH_RELEASE_NOTES", str(notes))
    return notes


BELOW = "doc-superpowers 3.18.0 is below security release 3.19.0"


def test_below_security_release_halts_when_opted_in(gated, run, tmp_path: Path, monkeypatch) -> None:
    root = fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_notes(tmp_path / "notes", monkeypatch)
    configure(gated, security_floor=True)

    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready"
    assert BELOW in payload["reason"]
    assert payload["fix"] == upgrade_fix(root) and payload["fix"].endswith("install.sh upgrade")
    assert payload["cache"] == {}, "the order stopped before the indexes"


def test_below_security_release_degrades_when_not_opted_in(gated, run, tmp_path: Path, monkeypatch) -> None:
    root = fake_root(tmp_path / "ds-checkout", monkeypatch)
    assert run("index").code == 0
    release_notes(tmp_path / "notes", monkeypatch)

    code, payload = check(run)

    assert code == 0 and payload["state"] == "degraded" and payload["launcher"] == "current"
    assert payload["reason"].startswith(BELOW)
    assert payload["fix"] == upgrade_fix(root), "the upgrade, not install --search"


def test_below_security_release_not_required_is_not_in_force(repo, run, tmp_path: Path, monkeypatch) -> None:
    """The halt applies only with `required: true`: elsewhere `security_floor` is reported, never a halt."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    install_launcher(repo)
    release_notes(tmp_path / "notes", monkeypatch)
    configure(repo, security_floor=True)

    code, payload = check(run)

    assert code == 4 and payload["state"] == "not-in-force"
    assert payload["reason"].startswith(f"not required here (not-ready: {BELOW}")


def test_no_cache_never_behind(gated, run, tmp_path: Path, monkeypatch) -> None:
    """No variable and an empty cache: only the root's own notes, which never show a release past its own."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_cache.cache_dir(os.environ).mkdir(parents=True)
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready" and payload["reason"] is None


def test_reason_names_source(gated, run, tmp_path: Path, monkeypatch) -> None:
    """A cache from another install's remote (a fork's notes) is named in the reason, with when it was fetched."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_notes(tmp_path / "notes", monkeypatch)
    configure(gated, security_floor=True)

    reason = check(run)[1]["reason"]

    assert SOURCE in reason and FETCHED in reason and "release notes v3.19.0" in reason


def test_the_cache_is_read(gated, run, tmp_path: Path, monkeypatch) -> None:
    """`install.sh upgrade`'s cache, `${XDG_CACHE_HOME:-~/.cache}/doc-superpowers`, with no variable set."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_notes(release_cache.cache_dir(os.environ))
    configure(gated, security_floor=True)

    code, payload = check(run)

    assert code == 1 and BELOW in payload["reason"] and SOURCE in payload["reason"]


def test_store_then_load_round_trips(tmp_path: Path) -> None:
    env = {"XDG_CACHE_HOME": str(tmp_path / "xdg"), "HOME": str(tmp_path / "h")}

    release_cache.store(env, SECURITY_NOTES, "v3.19.0", SOURCE)

    where = release_cache.cache_dir(env)
    assert where == tmp_path / "xdg" / "doc-superpowers"
    meta = json.loads((where / "release-notes.json").read_text())
    assert set(meta) == {"tag", "fetched", "source"} and meta["tag"] == "v3.19.0" and meta["source"] == SOURCE
    assert (where / "release-notes.md").read_text() == SECURITY_NOTES
    assert [p.name for p in where.iterdir() if p.name.startswith(".")] == [], "no temp file left behind"
    [loaded] = release_cache.load(env, plugin=tmp_path / "no-root")
    assert loaded.text == SECURITY_NOTES and loaded.ceiling == (3, 19, 0)
    assert loaded.meta["source"] == SOURCE and loaded.meta["tag"] == "v3.19.0"
    assert release_cache.cache_dir({"HOME": str(tmp_path / "h")}) == tmp_path / "h" / ".cache" / "doc-superpowers"
    assert release_cache.cache_dir({"HOME": str(tmp_path / "h"), "XDG_CACHE_HOME": ""}) == (
        tmp_path / "h" / ".cache" / "doc-superpowers"
    ), "an empty XDG_CACHE_HOME is unset, as for install.sh"


@pytest.mark.parametrize(
    "sidecar",
    [
        {"source": "https://evil.test/x\nsecond line"},
        {"source": "https://evil.test/\x1b[31mred\x1b[0m"},
        {"source": "has a space", "fetched": "yesterday\r\n"},
        {"source": 5, "fetched": None, "tag": "v3.19.0;touch pwned"},
    ],
    ids=["newline", "ansi", "space", "wrong-types"],
)
def test_hostile_sidecar_shows_unknown(gated, run, tmp_path: Path, monkeypatch, sidecar: dict) -> None:
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_notes(tmp_path / "notes", monkeypatch, **sidecar)
    configure(gated, security_floor=True)

    reason = check(run)[1]["reason"]

    assert BELOW in reason and "unknown" in reason
    assert not any(ch in reason for ch in "\n\r\x1b"), reason
    assert "evil" not in reason and "pwned" not in reason and "yesterday" not in reason
    verdict = (gated.root / ".git" / "doc-search-gate").read_text().splitlines()
    assert len(verdict) == 2 and verdict[0] == "not-ready", "the verdict file keeps its two lines"


def test_a_hostile_path_reaches_the_reason_stripped(gated, run, tmp_path: Path, monkeypatch) -> None:
    """With no sidecar the source is the file's path, which may hold anything a file name can: its ANSI sequences
    and control characters are dropped."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    where = tmp_path / "a\x1b[31mred\nline two"
    where.mkdir()
    (where / "notes.md").write_text(SECURITY_NOTES)
    monkeypatch.setenv("DOC_SEARCH_RELEASE_NOTES", str(where / "notes.md"))
    configure(gated, security_floor=True)

    reason = check(run)[1]["reason"]

    assert BELOW in reason and "aredlinetwo" in reason
    assert not any(ch in reason for ch in "\n\x1b "), reason


@pytest.mark.parametrize("content", ["not json", "[1, 2]", "{" + '"source": "x", ' * 2000 + '"tag": "v3.19.0"}'])
def test_unreadable_sidecar_shows_unknown(tmp_path: Path, content: str) -> None:
    notes = release_notes(tmp_path / "notes")
    (tmp_path / "notes" / "release-notes.json").write_text(content)

    [found] = release_cache.load({"DOC_SEARCH_RELEASE_NOTES": str(notes), "HOME": str(tmp_path)}, plugin=tmp_path)
    meta = found.meta

    assert meta["source"] == "unknown" and meta["fetched"] == "unknown"
    assert meta["tag"] == "v3.19.0", "no valid tag: the notes' own first release"


def test_symlinked_cache_dir_is_refused(gated, run, tmp_path: Path, monkeypatch) -> None:
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    real = tmp_path / "elsewhere"
    release_notes(real)
    where = release_cache.cache_dir(os.environ)
    where.parent.mkdir(parents=True)
    where.symlink_to(real, target_is_directory=True)
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready", "a symlinked cache dir is never read"
    where.unlink()
    shutil.copytree(real, where)
    assert check(run)[0] == 1, "the same files in a real directory are read"


def test_cache_dir_not_owned_is_refused(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    env = {"XDG_CACHE_HOME": str(tmp_path / "xdg"), "HOME": str(tmp_path)}
    release_notes(release_cache.cache_dir(env))
    assert len(release_cache.load(env, plugin=tmp_path)) == 1
    real_uid = os.getuid()
    monkeypatch.setattr(release_cache.os, "getuid", lambda: real_uid + 1)

    assert release_cache.load(env, plugin=tmp_path) == []


HOSTILE = "\n## v99999.0.0 (2026-11-19)\n\n### Security\n- A release far in the future.\n"


def test_hostile_newer_heading_is_clamped_to_the_sidecar_tag(gated, run, tmp_path: Path, monkeypatch) -> None:
    """A security section above the notes' own release is dropped: a release is never newer than its notes."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    release_notes(release_cache.cache_dir(os.environ), text="# Release Notes\n" + HOSTILE + SECURITY_NOTES[17:])
    configure(gated, security_floor=True)

    reason = check(run)[1]["reason"]

    assert BELOW in reason and "99999" not in reason


def test_hostile_newer_heading_is_clamped_to_the_first_release(gated, run, tmp_path: Path, monkeypatch) -> None:
    """With no sidecar, a source's ceiling is its first release heading (check-version's rule)."""
    fake_root(tmp_path / "ds-checkout", monkeypatch, notes=own_notes("3.18.0") + HOSTILE)
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready", "the root's own notes never put it below a security release"
    notes = tmp_path / "plain" / "RELEASE-NOTES.md"
    notes.parent.mkdir()
    notes.write_text(SECURITY_NOTES + HOSTILE)
    monkeypatch.setenv("DOC_SEARCH_RELEASE_NOTES", str(notes))
    code, payload = check(run)
    assert code == 1 and BELOW in payload["reason"] and "99999" not in payload["reason"]


def marketplace(home: Path, name: str, plugin: str, notes: str, version: str = "0.0.0") -> Path:
    clone = home / ".claude" / "plugins" / "marketplaces" / name
    (clone / ".claude-plugin").mkdir(parents=True)
    (clone / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": plugin, "version": version}))
    (clone / "RELEASE-NOTES.md").write_text(notes)
    return clone


def plugin_install(home: Path, monkeypatch: pytest.MonkeyPatch, market: str = "dsp-market") -> Path:
    """A Claude Code plugin install of the test's own at 3.18.0, from the marketplace `market`, in the default
    plugin cache (`~/.claude/plugins/cache/<market>/doc-superpowers/<version>`)."""
    cached = home / ".claude" / "plugins" / "cache" / market / "doc-superpowers" / "3.18.0"
    return fake_root(cached, monkeypatch)


def test_plugin_install_names_its_marketplace(tmp_path: Path) -> None:
    """`upg_kind`'s UPG_KIND=plugin and UPG_MKT, from the root's path."""
    home = tmp_path / "h"
    env = {"HOME": str(home)}
    plugins = home / ".claude" / "plugins"
    other = tmp_path / "other-cache"
    cached = plugins / "cache" / "mk" / "doc-superpowers" / "1.0.0"
    for where in (cached, plugins / "marketplaces" / "mk", other / "mk2" / "x"):
        where.mkdir(parents=True)

    assert release_cache.plugin_install(env, cached) == (True, "mk")
    assert release_cache.plugin_install(env, plugins / "marketplaces" / "mk") == (True, "mk")
    assert release_cache.plugin_install(env, plugins) == (True, None)
    in_other = {**env, "CLAUDE_PLUGIN_CACHE": str(other)}
    assert release_cache.plugin_install(in_other, other / "mk2" / "x") == (True, "mk2")
    assert release_cache.plugin_install(env, other / "mk2" / "x") == (False, None)


def test_the_installs_own_marketplace_clone_is_read(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    """Claude Code keeps the install's marketplace clone fresh: it counts, named in the reason."""
    home = Path(os.environ["HOME"])
    plugin_install(home, monkeypatch)
    clone = marketplace(home, "dsp-market", "doc-superpowers", SECURITY_NOTES, version="3.19.0")
    configure(gated, security_floor=True)

    code, payload = check(run)

    assert code == 1 and BELOW in payload["reason"] and "dsp-market" in payload["reason"]
    assert payload["fix"] == PLUGIN_FIX
    assert clone.is_dir()


def test_the_marketplace_clone_is_clamped_to_its_plugin_json_version(
    gated, run, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The clone's notes may run ahead of the release it holds; its `.claude-plugin/plugin.json` `version` is
    its ceiling, so a security section above that version does not count."""
    home = Path(os.environ["HOME"])
    plugin_install(home, monkeypatch)
    marketplace(home, "dsp-market", "doc-superpowers", SECURITY_NOTES, version="3.18.5")
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready", payload["reason"]


def test_another_doc_superpowers_marketplace_is_ignored(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    """Only the marketplace this install came from counts: a fork's marketplace that also calls its plugin
    doc-superpowers could halt the gate with a release `claude plugin update` can never install."""
    home = Path(os.environ["HOME"])
    plugin_install(home, monkeypatch)
    marketplace(home, "dsp-market", "doc-superpowers", own_notes("3.18.0"), version="3.18.0")
    marketplace(home, "a-fork", "doc-superpowers", SECURITY_NOTES.replace("3.19.0", "9.0.0"), version="9.0.0")
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready", payload["reason"]


def test_a_checkout_reads_no_marketplace_clone(gated, run, tmp_path: Path, monkeypatch) -> None:
    """A checkout or the Codex root is not updated from any marketplace, so no clone counts for it."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    marketplace(Path(os.environ["HOME"]), "doc-superpowers", "doc-superpowers", SECURITY_NOTES, version="3.19.0")
    configure(gated, security_floor=True)
    assert run("index").code == 0

    code, payload = check(run)

    assert code == 0 and payload["state"] == "ready", payload["reason"]


def test_a_newer_source_does_not_hide_an_older_sources_security_release(
    gated, run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Each source's own newest security release counts, and the highest wins: the cache's v3.19.0 security
    release stands though the install's marketplace clone is at v4.0.0 with no `### Security` section."""
    home = Path(os.environ["HOME"])
    fake_root(home / ".claude" / "plugins" / "cache" / "dsp-market" / "doc-superpowers" / "3.18.0", monkeypatch)
    release_notes(release_cache.cache_dir(os.environ))
    marketplace(home, "dsp-market", "doc-superpowers", own_notes("4.0.0"), version="4.0.0")
    configure(gated, security_floor=True)

    code, payload = check(run)

    assert code == 1 and payload["state"] == "not-ready"
    assert BELOW in payload["reason"] and SOURCE in payload["reason"], "named by the source that produced it"
    assert payload["fix"] == PLUGIN_FIX


NETWORK_GIT = {"fetch", "ls-remote", "pull", "clone"}


def test_check_never_fetches(gated, run, tmp_path: Path, monkeypatch) -> None:
    """`check` reads only what is on disk: no socket reaches the network, and no git verb that would."""
    fake_root(tmp_path / "ds-checkout", monkeypatch)
    assert run("index").code == 0
    release_notes(tmp_path / "notes", monkeypatch)
    blocked: list[str] = []
    real_init = subprocess.Popen.__init__
    real_connect = socket.socket.connect

    def popen(self, args, *rest, **kwargs):
        argv = [str(a) for a in args] if isinstance(args, (list, tuple)) else str(args).split()
        if argv and Path(argv[0]).name == "git" and NETWORK_GIT & set(argv[1:]):
            blocked.append(" ".join(argv))
            raise AssertionError(f"check ran a network git verb: {argv}")
        real_init(self, args, *rest, **kwargs)

    def connect(self, address):
        if self.family in (socket.AF_INET, socket.AF_INET6):
            blocked.append(f"connect {address}")
            raise AssertionError(f"check opened a network connection: {address}")
        return real_connect(self, address)

    def create_connection(address, *args, **kwargs):
        blocked.append(f"create_connection {address}")
        raise AssertionError(f"check opened a network connection: {address}")

    monkeypatch.setattr(subprocess.Popen, "__init__", popen)
    monkeypatch.setattr(socket.socket, "connect", connect)
    monkeypatch.setattr(socket, "create_connection", create_connection)

    code, payload = check(run)

    assert blocked == []
    assert code == 0 and payload["state"] == "degraded" and BELOW in payload["reason"]


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
    """With no client named (an agent ran `check` itself), `mcp` is each client's state: Claude Code's from
    `.mcp.json`, Codex's from the project's or the user's Codex config."""

    def mcp() -> dict[str, str]:
        return check(run)[1]["mcp"]

    assert mcp() == {"claude": "not-registered", "codex": "not-registered"}

    (own_home / ".codex" / "config.toml").write_text('[mcp_servers.doc-search]\ncommand = "sh"\n')
    assert mcp() == {"claude": "not-registered", "codex": "expected"}, "the user's Codex config: Codex only"
    (own_home / ".codex" / "config.toml").unlink()

    project = repo.root / ".codex" / "config.toml"
    project.parent.mkdir()
    project.write_text('[mcp_servers."doc-search"]\ncommand = "sh"\n')
    assert mcp() == {"claude": "not-registered", "codex": "expected"}, "the project's Codex config: Codex only"
    project.unlink()

    (repo.root / ".mcp.json").write_text(json.dumps({"mcpServers": {"other": {}}}))
    assert mcp() == {"claude": "not-registered", "codex": "not-registered"}
    (repo.root / ".mcp.json").write_text(json.dumps({"mcpServers": {"doc-search": {"command": "sh"}}}))
    assert mcp() == {"claude": "expected", "codex": "not-registered"}, ".mcp.json: Claude Code only"
    assert run("check").lines[1] == "mcp: claude=expected codex=not-registered", "the text names each client"

    monkeypatch.setenv("DOC_SEARCH_MCP", "0")
    assert mcp() == {"claude": "off", "codex": "off"}, "the developer's switch wins, for every client"


def test_mcp_state_per_client(repo, own_home: Path) -> None:
    env = {"HOME": str(own_home), "CODEX_HOME": str(own_home / ".codex")}
    (repo.root / ".mcp.json").write_text(json.dumps({"mcpServers": {"doc-search": {"command": "sh"}}}))

    assert mcp_state(repo.root, env, "claude") == {"claude": "expected"}
    assert mcp_state(repo.root, env, "codex") == {"codex": "not-registered"}, ".mcp.json is not Codex's"
    (own_home / ".codex" / "config.toml").write_text('[mcp_servers.doc-search]\ncommand = "sh"\n')
    (repo.root / ".mcp.json").unlink()
    assert mcp_state(repo.root, env, "codex") == {"codex": "expected"}
    assert mcp_state(repo.root, env, "claude") == {"claude": "not-registered"}, "Codex's config is not Claude Code's"
    assert mcp_state(repo.root, {**env, "DOC_SEARCH_MCP": " 0 "}, "codex") == {"codex": "off"}


def test_check_json_shape(gated, run) -> None:
    code, payload = check(run)

    assert set(payload) == {f.name for f in fields(Verdict)} | {"exit"}
    assert payload["exit"] == code == 1
    assert payload["version"] == PLUGIN and payload["requires"] is None
    assert payload["launcher"] == "current" and payload["mcp"] == {"claude": "not-registered", "codex": "not-registered"}


@pytest.mark.parametrize("budget", ["0", "601", "x"])
def test_check_budget_usage(repo, run, budget: str) -> None:
    done = run("check", "--budget", budget)

    assert done.code == 3 and "--budget" in done.err


def test_verdict_line_and_exit_codes() -> None:
    def verdict(state: str, reason: str | None = None, fix: str | None = None) -> Verdict:
        state_: Any = state  # a State literal
        return Verdict(state_, reason, fix, True, None, "1.2.3", "current", {"claude": "expected"}, {}, False)

    assert [verdict(s).exit_code() for s in ("ready", "degraded", "not-ready", "not-in-force")] == [0, 0, 1, 4]
    assert verdict("ready").line() == "doc-search: ready"
    assert verdict("not-ready", "docs index absent", INDEX_FIX).line() == (
        f"doc-search: not ready: docs index absent; run {INDEX_FIX}"
    )
    assert verdict("not-in-force", "no docs/search/config.json").line() == (
        "doc-search: not in force: no docs/search/config.json"
    )
