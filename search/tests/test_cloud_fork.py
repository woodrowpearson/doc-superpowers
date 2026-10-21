"""gRPC fork support is off before the cloud extra loads, so a forked git child never runs gRPC code.

grpcio's POSIX wheels build fork support in and turn it on by default: once a channel exists, its
`pthread_atfork` handlers restart gRPC's threads in every forked child. CPython's subprocess forks on
macOS (posix_spawn needs no `cwd` and `close_fds=False`), so each git child the local legs start while
the cloud leg is live ran those threads between fork and exec. They log `FD from fork parent still in
poll list` on the parent's stderr, and now and then kill the child before exec (SIGTRAP on an M1 Pro:
`git ls-files ... failed (-5)`, an `all` eval leg skipped; SIGPIPE, -13, in a fork loop).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

import doc_search.cloud as cloud_pkg

FORK_VAR = "GRPC_ENABLE_FORK_SUPPORT"


def seen_at_import(monkeypatch: pytest.MonkeyPatch) -> list[str | None]:
    """Record the variable's value at the moment `import_module` imports a google module."""
    seen: list[str | None] = []

    def record(name: str, package: str | None = None) -> ModuleType:
        seen.append(os.environ.get(FORK_VAR))
        return ModuleType(name)

    monkeypatch.setattr(cloud_pkg, "importlib", SimpleNamespace(import_module=record))
    return seen


def test_fork_support_is_off_before_a_google_module_loads(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(FORK_VAR, raising=False)
    seen = seen_at_import(monkeypatch)
    cloud_pkg.import_module("google.cloud.firestore")
    assert seen == ["false"]


def test_an_explicit_setting_is_kept(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(FORK_VAR, "1")
    seen = seen_at_import(monkeypatch)
    cloud_pkg.import_module("google.genai")
    assert seen == ["1"]


# A process with a live gRPC client (a local server and a connected channel, no network) runs the
# local legs' git listing; gRPC writes its fork handlers' lines straight to this process's stderr.
LIVE_CLIENT = """
import sys
from concurrent import futures
from pathlib import Path

from doc_search.cloud import import_module
from doc_search.repo import ls_files

import_module("google.cloud.firestore")  # loads grpc, as the cloud leg does
import grpc

server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
port = server.add_insecure_port("127.0.0.1:0")
server.start()
channel = grpc.insecure_channel(f"127.0.0.1:{port}")
grpc.channel_ready_future(channel).result(timeout=20)
for _ in range(int(sys.argv[2])):
    ls_files(Path(sys.argv[1]))
channel.close()
server.stop(None)
"""


@pytest.mark.slow
def test_a_git_child_runs_no_grpc_fork_handler(git_repo, tmp_path: Path) -> None:
    pytest.importorskip("grpc", reason="the cloud extra is not installed")
    pytest.importorskip("google.cloud.firestore", reason="the cloud extra is not installed")
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.commit("a")
    script = tmp_path / "live_client.py"
    script.write_text(LIVE_CLIENT, encoding="utf-8")
    env = {key: value for key, value in os.environ.items() if key != FORK_VAR}
    done = subprocess.run(
        [sys.executable, str(script), str(repo.root), "40"],
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    assert done.returncode == 0, done.stderr
    fork_lines = [line for line in done.stderr.splitlines() if "fork" in line.lower()]
    assert fork_lines == []
