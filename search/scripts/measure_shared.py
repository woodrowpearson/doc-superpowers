"""Sum the memory of N doc-search sessions, shared or in-process (by hand, not CI).

usage: uv run --project search --frozen --all-extras python search/scripts/measure_shared.py \
           <repo> <mode 0|1> <N> [<worktree>...] [--again S]

Each client is an MCP stdio session started as a client starts it, through `doc-search serve` in <repo>,
with DOC_SEARCH_CLIENT_CWD set to the worktrees in turn (default: <repo>). Once every client has run one
search, the footprints (macOS `footprint`, Linux PSS) of every process under this one are summed by role:
uv, proxy, daemon, in-process server. `--again S` keeps the sessions open and idle for S seconds and
measures again (with DOC_SEARCH_IDLE_UNLOAD_S set low, that shows idle unload).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

import anyio
from mcp.client.client import Client
from mcp.client.stdio import StdioServerParameters

SEARCH_DIR = Path(__file__).resolve().parents[1]


def processes(root: int) -> list[tuple[int, str]]:
    """Every descendant of `root`, with its command line (a detached daemon keeps its spawner as parent)."""
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines()
    kids: dict[int, list[tuple[int, str]]] = defaultdict(list)
    for row in rows:
        parts = row.split(None, 2)
        if len(parts) == 3:
            kids[int(parts[1])].append((int(parts[0]), parts[2]))
    out, todo = [], [root]
    while todo:
        for pid, command in kids.get(todo.pop(), []):
            out.append((pid, command))
            todo.append(pid)
    return out


def role(command: str, shared: bool) -> str:
    if command.startswith("uv ") or "/uv " in command:
        return "uv"
    if "resource_tracker" in command:
        return "resource tracker"
    if "doc_search.entry daemon" in command:
        return "daemon"
    return "proxy" if shared else "server"


def footprint_mb(pid: int) -> float:
    if sys.platform == "darwin":
        text = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
        m = re.search(r"phys_footprint:\s+([\d.]+) (KB|MB|GB)", text)
        return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)] if m else 0.0
    try:
        text = Path(f"/proc/{pid}/smaps_rollup").read_text()
    except OSError:
        return 0.0
    m = re.search(r"^Pss:\s+(\d+) kB", text, re.M)
    return int(m.group(1)) / 1024 if m else 0.0


def report(label: str, shared: bool) -> None:
    by_role: dict[str, list[float]] = defaultdict(list)
    for pid, command in processes(os.getpid()):
        if command.startswith(("ps ", "footprint ")):
            continue  # this script's own probes
        by_role[role(command, shared)].append(footprint_mb(pid))
    total = sum(sum(v) for v in by_role.values())
    parts = ", ".join(f"{name} {len(v)}x {sum(v):.0f} MB" for name, v in sorted(by_role.items()))
    print(f"{label}: total {total:.0f} MB ({parts})", flush=True)


async def main() -> None:
    args = sys.argv[1:]
    again = 0.0
    if "--again" in args:
        i = args.index("--again")
        again = float(args[i + 1])
        del args[i : i + 2]
    repo, mode, n, trees = Path(args[0]), args[1], int(args[2]), args[3:] or [args[0]]
    shared = mode == "1"
    env = {**os.environ, "DOC_SEARCH_SHARED": mode, "DOC_SEARCH_RUNTIME_DIR": tempfile.mkdtemp(prefix="dsm-", dir="/tmp")}
    label = f"mode={'shared' if shared else 'in-process'} N={n} worktrees={len(set(trees[:n]))}"
    done = anyio.Event()
    count = [0]
    measured = anyio.Event()

    async def client(i: int) -> None:
        p = StdioServerParameters(
            command="uv",
            args=["run", "--project", str(SEARCH_DIR), "--frozen", "--all-extras", "doc-search", "serve"],
            cwd=repo,
            env={**env, "DOC_SEARCH_CLIENT_CWD": trees[i % len(trees)]},
        )
        async with Client(p) as c:
            with anyio.fail_after(1800):
                await c.call_tool("search", {"query": "configuration and setup"})
            count[0] += 1
            if count[0] == n:
                done.set()
            await measured.wait()

    async with anyio.create_task_group() as tg:
        for i in range(n):
            tg.start_soon(client, i)
        await done.wait()
        await anyio.sleep(5)
        report(label, shared)
        if again:
            await anyio.sleep(again)
            report(f"{label} after {again:g} s idle", shared)
        measured.set()


anyio.run(main)
