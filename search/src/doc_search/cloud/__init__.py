"""The optional cloud docs leg: Vertex embeddings over a Firestore chunk collection (design section 8).

The google libraries belong to the `cloud` extra. Nothing in this package imports them when the
package is imported: `import_module` loads one on first use and turns a missing extra into
`CloudUnavailable`, so the base install never touches them and a server without the extra still
starts, answering from its local legs with a note.

`import_module` also turns gRPC's fork support off (unless the environment already says) before the
first google module loads, since gRPC reads the setting once. grpcio's POSIX wheels have it on by
default: its `pthread_atfork` handlers then restart gRPC's threads in every forked child, and the local
legs fork git (CPython's subprocess forks on macOS) while the cloud leg's client is live. Those threads
ran between fork and exec and sometimes killed the git child (SIGTRAP, SIGPIPE). Nothing here forks
a process that goes on to use gRPC, which is all fork support is for.
"""

from __future__ import annotations

import importlib
import os
import threading
import time
from collections.abc import Callable
from types import ModuleType
from typing import Any

EXTRA_HINT = "cloud extra not installed (uv sync --extra cloud)"
CLIENT_RETRY_S = 300.0  # a failed client construction is not retried sooner: credential discovery can take ~10 s
REASON_CHARS = 200


class CloudUnavailable(Exception):
    """The cloud leg cannot serve: the extra is missing, there is no project or no credentials."""


def import_module(name: str) -> ModuleType:
    """A google module of the `cloud` extra, or CloudUnavailable when it is not installed."""
    os.environ.setdefault("GRPC_ENABLE_FORK_SUPPORT", "false")  # before grpc loads: see the module docstring
    try:
        return importlib.import_module(name)
    except ImportError as err:
        raise CloudUnavailable(EXTRA_HINT) from err
    except Exception as err:  # noqa: BLE001 - a broken install raises anything (protobuf: TypeError) while importing
        raise CloudUnavailable(f"google libraries failed to load: {describe(err)}") from err


def has_class_named(err: BaseException, name: str) -> bool:
    """True when `err` is an instance of a class called `name` (checked by name: no google import needed)."""
    return any(cls.__name__ == name for cls in type(err).__mro__)


def describe(err: BaseException) -> str:
    """One line for a header note or a status line: what went wrong, without line breaks."""
    if isinstance(err, CloudUnavailable):
        text = str(err)
    elif has_class_named(err, "DefaultCredentialsError"):
        text = "no credentials (run gcloud auth application-default login)"
    else:
        message = " ".join(str(err).split())
        text = f"{type(err).__name__}: {message}" if message else type(err).__name__
    text = " ".join(text.split())
    return text if len(text) <= REASON_CHARS else text[: REASON_CHARS - 1] + "…"


class LazyClient:
    """A client built on first use, once, by `make`.

    Building a Firestore client without credentials takes about ten seconds (the metadata server
    probe), so nothing is built at startup, and a failure is remembered for `retry_s`: every search
    in that time gets the same `CloudUnavailable` at once instead of another wait.
    """

    def __init__(
        self,
        make: Callable[[], Any],
        *,
        clock: Callable[[], float] = time.monotonic,
        retry_s: float = CLIENT_RETRY_S,
    ) -> None:
        self._make = make
        self._clock = clock
        self._retry_s = retry_s
        self._lock = threading.Lock()
        self._client: Any = None
        self._failure: str | None = None
        self._failed_at = 0.0

    def get(self) -> Any:
        with self._lock:
            if self._client is not None:
                return self._client
            if self._failure is not None and self._clock() - self._failed_at < self._retry_s:
                raise CloudUnavailable(self._failure)
            try:
                client = self._make()
            except Exception as err:  # noqa: BLE001 - any construction failure means no cloud leg for now
                self._failure = describe(err)
                self._failed_at = self._clock()
                if isinstance(err, CloudUnavailable):
                    raise
                raise CloudUnavailable(self._failure) from err
            self._client, self._failure = client, None
            return client
