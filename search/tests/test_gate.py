"""`doc-search gate <event>`: the client hooks' entry (gate.py), driven in-process through `main(argv)`.

The repository fixtures are test_check.py's (`gated`: required, the plugin's launcher copy, no index yet;
`own_home`: a HOME and CODEX_HOME of the test's own).
"""

from __future__ import annotations

import io
import json
import sys
import threading
from pathlib import Path
from typing import Any

import pytest

from doc_search import gate as gate_mod
from doc_search.check import CONFIG_FIX, Verdict
from doc_search.config import CONFIG_REL
from doc_search.gate import agent_can_run, hook_output, verdict_path, write_verdict
import test_check
from test_check import INDEX_FIX, configure, install_launcher

own_home = test_check.own_home  # autouse: a HOME and CODEX_HOME of the test's own
gated = test_check.gated

CHECK_FIX = "sh .claude/doc-superpowers/search-mcp.sh check"
USER_ONLY = (
    " Only the user can run this fix; you may run only sh .claude/doc-superpowers/search-mcp.sh index, status"
    " or check."
)


def verdict(state: str, reason: str | None = None, fix: str | None = None, mcp: str = "not-registered") -> Verdict:
    state_: Any = state  # a State literal
    mcp_: Any = mcp
    return Verdict(state_, reason, fix, True, None, "1.2.3", "current", mcp_, {}, False)


def gate(run, event: str, *argv: str) -> tuple[int, Any]:
    """`gate <event>`: its exit code and its JSON (None for no output)."""
    done = run("gate", event, *argv)
    assert done.err == ""
    return done.code, json.loads(done.out) if done.out.strip() else None


def verdict_file(made) -> Path:
    return made.root / ".git" / "doc-search-gate"


def block(reason: str, fix: str) -> dict[str, str]:
    return {
        "decision": "block",
        "reason": (
            f"doc-search is required here and not ready: {reason}. Fix: {fix} — then send your message again."
            " (Set DOC_SEARCH_GATE=0 to turn the gate off for yourself.)"
        ),
    }


def context(text: str) -> dict[str, Any]:
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}


# --- prompt ----------------------------------------------------------------------------------------------


def test_gate_prompt_blocks_when_not_ready(gated, run) -> None:
    code, out = gate(run, "prompt")

    assert code == 0
    assert out == block("docs index absent", INDEX_FIX)
    assert verdict_file(gated).read_bytes() == f"not-ready\ndocs index absent; fix: {INDEX_FIX}\n".encode()


def test_gate_prompt_silent_and_clears_when_ready(gated, run) -> None:
    assert gate(run, "prompt")[1] is not None
    assert verdict_file(gated).exists()
    assert run("index").code == 0

    assert gate(run, "prompt") == (0, None)
    assert not verdict_file(gated).exists(), "a verdict that is not not-ready removes the file"
    assert gate(run, "prompt") == (0, None), "…and a missing file is fine"


def test_gate_prompt_silent_when_not_required(gated, run) -> None:
    configure(gated, required=False)
    verdict_file(gated).write_text("not-ready\nold\n")

    assert gate(run, "prompt") == (0, None)
    assert not verdict_file(gated).exists()


def test_gate_prompt_says_fix_for_a_fix_that_is_not_one_command(gated, run) -> None:
    (gated.root / CONFIG_REL).write_text('{"required": true, "bogus": 1}')

    code, out = gate(run, "prompt")

    assert code == 0 and out == block("invalid config: unknown key bogus", CONFIG_FIX)
    assert USER_ONLY.strip() not in out["reason"], "the prompt block is shown to the user"


# --- session-start ---------------------------------------------------------------------------------------


def test_gate_session_start_context_per_state(gated, run) -> None:
    code, out = gate(run, "session-start")
    assert code == 0 and out == context(
        f"doc-search is required here and not ready: docs index absent. Fix: {INDEX_FIX}. Do no work until it is"
        " ready: tell the user this line and stop."
    )
    assert verdict_file(gated).read_text().splitlines()[0] == "not-ready"

    assert run("index").code == 0
    code, out = gate(run, "session-start")
    assert code == 0 and out == context("doc-search: ready\nmcp: not-registered")
    assert not verdict_file(gated).exists()

    install_launcher(gated, "#!/bin/sh\n# doc-search launcher v0.0.1\n")
    code, out = gate(run, "session-start")
    assert code == 0 and out == context(
        "doc-search: ready (degraded: launcher copy differs from the plugin's)\nmcp: not-registered"
    )
    assert not verdict_file(gated).exists()

    configure(gated, required=False)
    assert gate(run, "session-start") == (0, None)


def test_gate_session_start_tells_the_agent_when_only_the_user_can_fix(gated, run) -> None:
    (gated.root / CONFIG_REL).write_text('{"required": true, "bogus": 1}')

    code, out = gate(run, "session-start")

    assert code == 0 and out == context(
        f"doc-search is required here and not ready: invalid config: unknown key bogus. Fix: {CONFIG_FIX}.{USER_ONLY}"
        " Do no work until it is ready: tell the user this line and stop."
    )


def test_hook_output_texts() -> None:
    ready = verdict("ready", mcp="expected")
    degraded = verdict("degraded", "static index while the transformer index builds")
    not_ready = verdict("not-ready", "code index absent", INDEX_FIX)
    plugin = verdict("not-ready", "doc-superpowers 1.2.3 is below requires >=9.0.0", "claude plugin update x")
    off = verdict("not-in-force", "not required here (ready)")

    assert hook_output("session-start", ready) == context("doc-search: ready\nmcp: expected")
    assert hook_output("session-start", degraded) == context(
        "doc-search: ready (degraded: static index while the transformer index builds)\nmcp: not-registered"
    )
    assert hook_output("session-start", plugin) == context(
        "doc-search is required here and not ready: doc-superpowers 1.2.3 is below requires >=9.0.0."
        f" Fix: claude plugin update x.{USER_ONLY} Do no work until it is ready: tell the user this line and stop."
    )
    assert hook_output("session-start", off) is None
    assert hook_output("prompt", not_ready) == block("code index absent", INDEX_FIX)
    for quiet in (ready, degraded, off):
        assert hook_output("prompt", quiet) is None


def test_agent_can_run_is_the_launchers_allowlist() -> None:
    for fix in (
        INDEX_FIX,
        "sh .claude/doc-superpowers/search-mcp.sh status --format json",
        "sh .claude/doc-superpowers/search-mcp.sh check",
        'sh "/a dir/.claude/doc-superpowers/search-mcp.sh" check --format text',
        "sh /abs/path/.claude/doc-superpowers/search-mcp.sh index",
    ):
        assert agent_can_run(fix), fix
    for fix in (
        CONFIG_FIX,
        "install uv",
        "claude plugin update doc-superpowers",
        f"{INDEX_FIX}\n",
        f"{INDEX_FIX}; ls",
        "sh .claude/doc-superpowers/search-mcp.sh serve",
        'sh "x/.claude/doc-superpowers/search-mcp.sh index',
        None,
    ):
        assert not agent_can_run(fix), fix


# --- an exception in assess ------------------------------------------------------------------------------


def _raise(*_args: object, **_kwargs: object) -> Verdict:
    raise RuntimeError("boom\nsecond line")


def test_gate_assess_exception_blocks_when_required(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(gate_mod, "assess", _raise)

    code, out = gate(run, "prompt")

    assert code == 0
    assert out == block("check failed: RuntimeError: boom second line", CHECK_FIX)
    assert verdict_file(gated).read_bytes() == (
        f"not-ready\ncheck failed: RuntimeError: boom second line; fix: {CHECK_FIX}\n".encode()
    )
    code, out = gate(run, "session-start")
    assert code == 0 and out["hookSpecificOutput"]["additionalContext"].startswith(
        "doc-search is required here and not ready: check failed: RuntimeError: boom second line. Fix:"
    )


def test_gate_assess_exception_silent_when_not_required(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(gate_mod, "assess", _raise)
    verdict_file(repo).write_text("not-ready\nold\n")

    assert gate(run, "prompt") == (0, None)
    assert gate(run, "session-start") == (0, None)
    assert not verdict_file(repo).exists()


# --- the verdict file ------------------------------------------------------------------------------------


def test_write_verdict_two_lf_lines(tmp_path: Path) -> None:
    gitdir = tmp_path / "gitdir"
    gitdir.mkdir()
    path = gitdir / "doc-search-gate"

    write_verdict(path, verdict("not-ready", "index\r\nabsent\rnow\nhere", "sh x\nindex"))
    assert path.read_bytes() == b"not-ready\nindex absent now here; fix: sh x index\n"

    write_verdict(path, verdict("not-ready", "no fix here"))
    assert path.read_bytes() == b"not-ready\nno fix here\n"

    write_verdict(path, verdict("degraded", "x"))
    assert not path.exists()
    write_verdict(path, verdict("ready"))
    assert not path.exists(), "a missing file is fine"
    assert list(gitdir.iterdir()) == [], "no temp file is left behind"


def test_write_verdict_is_atomic(tmp_path: Path) -> None:
    gitdir = tmp_path / "gitdir"
    gitdir.mkdir()
    path = gitdir / "doc-search-gate"
    texts = {f"not-ready\nreason {i} {'x' * 4000}; fix: {INDEX_FIX}\n" for i in range(4)}
    verdicts = [verdict("not-ready", f"reason {i} {'x' * 4000}", INDEX_FIX) for i in range(4)] + [verdict("ready")]
    stop = threading.Event()
    seen: list[str] = []
    errors: list[BaseException] = []

    def writer(offset: int) -> None:
        try:
            for n in range(200):
                write_verdict(path, verdicts[(n + offset) % len(verdicts)])
        except BaseException as err:  # pragma: no cover - surfaced below
            errors.append(err)

    def reader() -> None:
        while not stop.is_set():
            try:
                seen.append(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                seen.append("")

    threads = [threading.Thread(target=writer, args=(i,)) for i in range(8)]
    watch = threading.Thread(target=reader)
    watch.start()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    stop.set()
    watch.join()

    assert errors == []
    assert seen and all(text == "" or text in texts for text in seen), "every read is a whole verdict or no file"
    assert [p.name for p in gitdir.iterdir()] in ([], ["doc-search-gate"]), "no temp file is left behind"


def test_verdict_path_is_per_worktree(gated) -> None:
    linked = gated.add_worktree("other", "other")

    assert verdict_path(gated.root) == verdict_file(gated)
    assert verdict_path(linked) == gated.root / ".git" / "worktrees" / linked.name / "doc-search-gate"


# --- the event and usage ---------------------------------------------------------------------------------


def test_gate_reads_and_ignores_the_event_on_stdin(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    event = json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": "MARKER-7f3a " + "x" * 300000})
    stdin = io.StringIO(event)
    monkeypatch.setattr(sys, "stdin", stdin)

    done = run("gate", "prompt")

    assert done.code == 0 and stdin.read() == "", "the event was read whole"
    assert "MARKER-7f3a" not in done.out + done.err, "…and never echoed"
    assert json.loads(done.out) == block("docs index absent", INDEX_FIX), "…nor used"


def test_gate_outside_a_repository_is_silent(tmp_path: Path, run, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(tmp_path)

    assert gate(run, "prompt") == (0, None)
    assert gate(run, "session-start") == (0, None)


@pytest.mark.parametrize("argv", [("stop",), ("tool",), ("prompt", "--budget", "0"), ("prompt", "--budget", "601")])
def test_gate_usage(repo, run, argv: tuple[str, ...]) -> None:
    done = run("gate", *argv)

    assert done.code == 3 and done.out == ""


def test_gate_budget_reaches_assess(gated, run, monkeypatch: pytest.MonkeyPatch) -> None:
    budgets: list[float] = []

    def spy(top: Path, *, budget_s: float, env: Any) -> Verdict:
        budgets.append(budget_s)
        return verdict("ready")

    monkeypatch.setattr(gate_mod, "assess", spy)
    run("gate", "prompt")
    run("gate", "prompt", "--budget", "7")

    assert budgets == [20, 7]
