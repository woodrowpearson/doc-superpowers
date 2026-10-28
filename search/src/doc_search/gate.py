"""`doc-search gate session-start|prompt`: the readiness gate's hook entry (design:
2026-10-27-doc-search-readiness-gate-design.md, "`gate`: the hooks").

The client hooks run `sh <top>/.claude/doc-superpowers/search-mcp.sh gate <event>`; the launcher answers
`gate tool` itself, from the verdict file this module keeps, and forwards the other two events here. Each runs
`check`'s `assess`, writes the verdict file, and prints the client's JSON (the same for Claude Code and Codex)
or nothing. It always exits 0: the decision is the JSON.

- `session-start`: the verdict as context; not-ready says to do no work until it is ready, and that only the user
  can run a fix the tool gate does not allow, or a first transformer build. Not in force: nothing.
- `prompt`: not-ready blocks the prompt with the reason and the fix; anything else: nothing.
- An exception in `assess` is not-ready (`check failed: <type>: <message>`) when the raw config says
  `"required": true`, and not in force otherwise.
- `DOC_SEARCH_GATE=0` (blanks ignored): nothing, and the verdict file is not touched.

The verdict file, `$(git rev-parse --git-path doc-search-gate)`, is two LF lines while the verdict is not-ready
(`not-ready`, then `<reason>; fix: <fix>`) and absent otherwise. It is replaced atomically. `check` keeps it
too (cli.py), so the halt's own fix, run by the agent, lifts the tool gate.
"""

from __future__ import annotations

import contextlib
import os
import re
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .check import LAUNCHER_REL, TRANSFORMER_NOT_BUILT, Verdict, assess, config_says_required
from .repo import git

EVENTS = ("session-start", "prompt")
VERDICT_NAME = "doc-search-gate"
CHECK_FIX = f"sh {LAUNCHER_REL} check"
"""The fix of a `check` that raised: run it again, and read what it says."""

NOT_READY = "doc-search is required here and not ready"
TRANSFORMER_USER_ONLY = "Only the user can run this fix: the first transformer build takes hours."
USER_ONLY = f"Only the user can run this fix; you may run only sh {LAUNCHER_REL} index, status or check."

# The commands the launcher's `gate tool` allows while not ready (launch.sh, GATE_ALLOWED_PLAIN and
# GATE_ALLOWED_QUOTED): the launcher path holds only [A-Za-z0-9_./-], and spaces too when double-quoted.
_VERB = r" (index|status|check)( --format (text|json))?"
_ALLOWED = (
    re.compile(r"sh ([A-Za-z0-9_./-]*/)?\.claude/doc-superpowers/search-mcp\.sh" + _VERB),
    re.compile(r'sh "([A-Za-z0-9_. /-]*/)?\.claude/doc-superpowers/search-mcp\.sh"' + _VERB),
)
_BREAKS = re.compile(r"[\r\n]+")


def gate_off(env: Mapping[str, str]) -> bool:
    """The developer's switch: `DOC_SEARCH_GATE=0` (blanks ignored, as the launcher reads it). The hooks are silent,
    and neither `gate` nor `check` touches the verdict file."""
    return "".join(env.get("DOC_SEARCH_GATE", "").split()) == "0"


def agent_can_run(fix: str | None) -> bool:
    """Whether the tool gate lets the agent run `fix` while not ready: the whole of it is one allowed command."""
    return fix is not None and any(pattern.fullmatch(fix) for pattern in _ALLOWED)


def verdict_path(top: Path) -> Path:
    """`git rev-parse --git-path doc-search-gate` in `top`: one file per worktree."""
    out = git(Path(top), "rev-parse", "--git-path", VERDICT_NAME).rstrip("\n")
    return Path(top) / out  # an absolute output stays absolute


def _one_line(text: str) -> str:
    return _BREAKS.sub(" ", text)


def write_verdict(path: Path, verdict: Verdict) -> None:
    """Two LF lines while `verdict` is not-ready, written to a temp file beside `path` and renamed over it; else
    `path` is removed (a missing file is fine)."""
    if verdict.state != "not-ready":
        path.unlink(missing_ok=True)
        return
    second = _one_line(verdict.reason or "")
    if verdict.fix:
        second += f"; fix: {_one_line(verdict.fix)}"
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(f"not-ready\n{second}\n".encode())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def hook_output(event: str, verdict: Verdict) -> dict[str, Any] | None:
    """The client's JSON for `event` and `verdict`, or None for no output."""
    reason = _one_line(verdict.reason or "")
    fix = _one_line(verdict.fix or "")
    if event == "prompt":
        if verdict.state != "not-ready":
            return None
        text = (
            f"{NOT_READY}: {reason}. Fix: {fix} — then send your message again."
            " (Set DOC_SEARCH_GATE=0 to turn the gate off for yourself.)"
        )
        return {"decision": "block", "reason": text}
    if verdict.state == "not-in-force":
        return None
    if verdict.state == "not-ready":
        text = f"{NOT_READY}: {reason}. Fix: {fix}."
        if verdict.reason == TRANSFORMER_NOT_BUILT:
            text += f" {TRANSFORMER_USER_ONLY}"
        elif not agent_can_run(verdict.fix):
            text += f" {USER_ONLY}"
        text += " Do no work until it is ready: tell the user this line and stop."
    else:
        head = "doc-search: ready"
        if verdict.state == "degraded":
            head += f" (degraded: {reason})" if reason else " (degraded)"
        text = f"{head}\nmcp: {verdict.mcp}"
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}


def judge(top: Path, *, budget_s: float, env: Mapping[str, str]) -> Verdict:
    """`assess`, with an exception turned into a verdict: not-ready when the raw config says required."""
    try:
        return assess(top, budget_s=budget_s, env=env)
    except Exception as err:  # noqa: BLE001 - any failure of the probe is a verdict, never a crash
        required = config_says_required(top)
        return Verdict(
            state="not-ready" if required else "not-in-force",
            reason=f"check failed: {type(err).__name__}: {err}",
            fix=CHECK_FIX if required else None,
            required=required,
            requires=None,
            version=None,
            launcher="absent",  # not looked at: the hooks do not show it
            mcp="not-registered",
            cache={},
            refreshed=False,
        )
