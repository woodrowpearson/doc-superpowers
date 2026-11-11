"""The shared server as processes: one daemon for many sessions, its loss, its idle exit, and when it is off."""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from pathlib import Path

import anyio
import pytest
from mcp.client.client import Client
from mcp.client.stdio import StdioServerParameters

from test_server import seed

pytestmark = pytest.mark.slow


def params(cwd: Path, **env: str) -> StdioServerParameters:
    return StdioServerParameters(
        command=sys.executable, args=["-m", "doc_search.entry", "serve"], cwd=cwd, env={**os.environ, **env}
    )


async def ask(p: StdioServerParameters, *calls: tuple[str, dict]) -> list[str]:
    with anyio.fail_after(120):
        async with Client(p) as client:
            out = []
            for name, args in calls:
                result = await client.call_tool(name, args)
                out.append(result.content[0].text)
            return out


def daemons(where: Path) -> list[int]:
    """The pids of the daemons alive under `where`: a life lock that is held (a pid alone can be reused)."""
    from doc_search.shared import _lock_free

    pids = []
    for alive in where.glob("*.alive"):
        if _lock_free(alive):
            continue
        try:
            pids.append(int(alive.read_text().split()[0]))
        except (ValueError, IndexError):
            continue
    return pids


def test_two_sessions_share_one_daemon_with_their_own_defaults(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    branch = repo.add_worktree("b", "b")

    async def both():
        async with anyio.create_task_group() as tg:
            got = {}

            async def one(name, p):
                got[name] = await ask(p, ("status", {}), ("search", {"query": "refund rounding"}))

            tg.start_soon(one, "main", params(repo.root, DOC_SEARCH_SHARED="1"))
            tg.start_soon(one, "b", params(repo.root, DOC_SEARCH_SHARED="1", DOC_SEARCH_CLIENT_CWD=str(branch)))
        return got

    got = anyio.run(both)
    assert len(daemons(shared_runtime)) == 1
    assert f"default worktree: {branch}" in got["b"][0]
    assert "default worktree:" not in got["main"][0]
    assert "server: shared (pid" in got["main"][0]
    assert "docs/specs/SPEC-PAY-004.md" in got["main"][1] and "docs/specs/SPEC-PAY-004.md" in got["b"][1]


def test_a_killed_daemon_is_replaced_within_the_session(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    p = params(repo.root, DOC_SEARCH_SHARED="1")

    async def go():
        with anyio.fail_after(120):
            async with Client(p) as client:
                await client.call_tool("search", {"query": "refund rounding"})
                (first,) = daemons(shared_runtime)
                os.kill(first, signal.SIGKILL)
                await anyio.sleep(0.5)
                result = await client.call_tool("search", {"query": "refund rounding"})
                return first, result

    first, result = anyio.run(go)
    assert not result.is_error and "docs/specs/SPEC-PAY-004.md" in result.content[0].text
    assert daemons(shared_runtime) and first not in daemons(shared_runtime)


def test_an_idle_daemon_exits(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    anyio.run(ask, params(repo.root, DOC_SEARCH_SHARED="1"), ("search", {"query": "refund"}))
    assert daemons(shared_runtime)
    deadline = time.monotonic() + 30
    while daemons(shared_runtime) and time.monotonic() < deadline:
        time.sleep(0.2)
    assert daemons(shared_runtime) == [] and list(shared_runtime.glob("*.sock")) == []


@pytest.mark.parametrize("env", [{"DOC_SEARCH_SHARED": "0"}, {"DOC_SEARCH_SHARED": "", "CLAUDE_CODE_REMOTE": "true"}])
def test_in_process_when_off(git_repo, tiny_model, shared_runtime, env) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    (status,) = anyio.run(ask, params(repo.root, **env), ("status", {}))
    assert "server: in-process" in status
    assert daemons(shared_runtime) == []


def test_a_config_edit_gets_its_own_daemon(git_repo, tiny_model, shared_runtime) -> None:
    repo = git_repo()
    seed(repo, tiny_model)
    p = params(repo.root, DOC_SEARCH_SHARED="1", DOC_SEARCH_DAEMON_IDLE_S="120")  # the first must outlive the edit
    anyio.run(ask, p, ("status", {}))
    config = repo.root / "docs/search/config.json"
    data = json.loads(config.read_text())
    data["search"] = {"default_limit": 5}
    config.write_text(json.dumps(data))
    anyio.run(ask, p, ("status", {}))
    assert len(daemons(shared_runtime)) == 2
