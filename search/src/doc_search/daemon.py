"""The shared server: one `Runtime` for every session of a repository, configuration and environment on a host.

A proxy (shared.py) starts it detached in the launch worktree with `--key` and `--dir`. entry.py takes the
life lock before this module is imported (another daemon holds it: exit). `run` checks the key against its
own launch worktree, config and environment, removes a stale socket, listens, then builds the `Runtime`;
connections queue meanwhile. Each connection sends a hello line, gets one back, and is then served one MCP
session over newline-delimited JSON, through a view with its own default worktree. With no session for
DOC_SEARCH_DAEMON_IDLE_S, and nothing building, it removes its socket and exits. A connection that fails
is logged and closed; it never stops the others. Its output is the log file the proxy opened.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import IO

import anyio
import anyio.to_thread
from anyio.streams.buffered import BufferedByteReceiveStream
import mcp_types as types
from mcp.shared._context_streams import create_context_streams  # what mcp.server.stdio frames with
from mcp.shared.message import SessionMessage

from .server import Runtime, build_server_for, limits
from . import __version__
from .shared import CONFIG_REL, MAX_LINE, PROTOCOL, Place, daemon_key

logger = logging.getLogger(__name__)

DAEMON_IDLE_S = 600.0
HELLO_WAIT_S = 30.0
WAIT_S = 20.0  # a call's wait for a first build, as the in-process server's


def idle_seconds() -> float:
    raw = os.environ.get("DOC_SEARCH_DAEMON_IDLE_S", "").strip()
    try:
        value = float(raw) if raw else DAEMON_IDLE_S
    except ValueError:
        value = DAEMON_IDLE_S
    return value if value > 0 else DAEMON_IDLE_S


class Daemon:
    def __init__(self, place: Place, top: Path) -> None:
        self.place, self.top = place, top
        self.sessions = 0
        self.last_left = time.monotonic()
        self.ready = anyio.Event()
        self.rt: Runtime | None = None
        self.idle_s = idle_seconds()

    async def serve(self) -> None:
        listener = await anyio.create_unix_listener(self.place.sock, mode=0o600)
        async with anyio.create_task_group() as tg:
            tg.start_soon(self._build)
            tg.start_soon(self._watch_idle, tg.cancel_scope)
            tg.start_soon(listener.serve, self._connection)

    async def _build(self) -> None:
        rt = await anyio.to_thread.run_sync(lambda: Runtime(self.top, None, WAIT_S, warm=False, shared=True))
        rt.mode = lambda: f"shared (pid {os.getpid()}, {self.sessions} session{'s' if self.sessions != 1 else ''})"
        if rt.pool is not None:
            rt.pool.start_reaper(limits(True)[1])
        self.rt = rt
        self.ready.set()
        logger.info("doc-search: shared server ready for %s (pid %d)", self.top, os.getpid())

    async def _watch_idle(self, scope: anyio.CancelScope) -> None:
        while True:
            await anyio.sleep(min(5.0, self.idle_s))
            building = self.rt is not None and self.rt.pool is not None and self.rt.pool.building()
            if self.sessions == 0 and not building and time.monotonic() - self.last_left >= self.idle_s:
                logger.info("doc-search: no session for %g s; exiting", self.idle_s)
                self.place.sock.unlink(missing_ok=True)
                scope.cancel()
                return

    async def _connection(self, stream) -> None:
        self.sessions += 1
        try:
            buffered = BufferedByteReceiveStream(stream)
            with anyio.fail_after(HELLO_WAIT_S):
                first = await buffered.receive_until(b"\n", MAX_LINE)
            try:
                hello = json.loads(first)
            except ValueError:
                hello = None
            ok = isinstance(hello, dict) and hello.get("doc_search_proxy") == PROTOCOL and hello.get("key") == self.place.key
            reply = {"doc_search_daemon": PROTOCOL, "key": self.place.key, "version": __version__}
            if not ok:
                reply["error"] = "not this server"
            await stream.send((json.dumps(reply) + "\n").encode())
            if not ok:
                return
            await self.ready.wait()
            client_cwd = hello.get("client_cwd") if isinstance(hello.get("client_cwd"), str) else None
            view = await anyio.to_thread.run_sync(self.rt.view, client_cwd)
            await serve_stream(build_server_for(view), buffered, stream)
        except (anyio.EndOfStream, anyio.IncompleteRead, anyio.BrokenResourceError, anyio.ClosedResourceError,
                anyio.DelimiterNotFound, TimeoutError):
            pass  # the session left, or never said hello
        except Exception:  # noqa: BLE001 - one session's failure must not stop the server for the others
            logger.exception("doc-search: a session failed")
        finally:
            self.sessions -= 1
            self.last_left = time.monotonic()
            with anyio.CancelScope(shield=True):
                await stream.aclose()


async def serve_stream(server, receive: BufferedByteReceiveStream, stream) -> None:
    """One MCP session over a connection's newline-delimited JSON (the framing of mcp.server.stdio)."""
    read_writer, read_stream = create_context_streams[SessionMessage | Exception](0)
    write_stream, write_reader = create_context_streams[SessionMessage](0)

    async def reader() -> None:
        async with read_writer:
            while True:
                try:
                    line = await receive.receive_until(b"\n", MAX_LINE)
                except (anyio.EndOfStream, anyio.IncompleteRead, anyio.BrokenResourceError,
                        anyio.ClosedResourceError, anyio.DelimiterNotFound):
                    return
                try:
                    message = types.jsonrpc_message_adapter.validate_json(line, by_name=False)
                except Exception as exc:  # noqa: BLE001 - the session answers a parse error itself
                    await read_writer.send(exc)
                    continue
                await read_writer.send(SessionMessage(message))

    async def writer() -> None:
        async with write_reader:
            async for message in write_reader:
                data = message.message.model_dump_json(by_alias=True, exclude_unset=True)
                try:
                    await stream.send((data + "\n").encode())
                except (anyio.BrokenResourceError, anyio.ClosedResourceError):
                    return  # the session left mid-answer

    lowlevel = server._lowlevel_server  # noqa: SLF001 - what MCPServer.run_stdio_async runs; mcp is pinned < 3
    async with anyio.create_task_group() as tg:
        tg.start_soon(reader)
        tg.start_soon(writer)
        await lowlevel.run(read_stream, write_stream, lowlevel.create_initialization_options())
        tg.cancel_scope.cancel()


def run(place: Place, life: IO[str]) -> int:
    """Serve until idle; `life` is the life lock entry.py took, released when this returns."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    top = Path.cwd()
    try:
        config = (top / CONFIG_REL).read_bytes()
    except OSError:
        config = b""
    if daemon_key(top, config, os.environ) != place.key:
        # the config changed between the proxy's read and ours: a server for it gets its own key
        logger.warning("doc-search: this launch worktree's config or environment no longer matches %s", place.key)
        life.close()
        return 0
    place.sock.unlink(missing_ok=True)  # ours to replace: we hold the life lock
    try:
        anyio.run(Daemon(place, top).serve)
    finally:
        place.sock.unlink(missing_ok=True)
        life.close()
    return 0
