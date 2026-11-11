"""Hand freed heap back to the OS after the pool drops a worktree's indexes.

A worktree's indexes are about 1.4 GB of numpy arrays and small Python objects on a large repository.
Once they are freed, the allocator keeps the pages, so the process footprint does not fall. macOS has
`malloc_zone_pressure_relief`, glibc `malloc_trim`; elsewhere this only collects garbage. Never raises.
"""

from __future__ import annotations

import ctypes
import functools
import gc
import sys
from collections.abc import Callable


@functools.cache
def _relief() -> Callable[[], object] | None:
    try:
        if sys.platform == "darwin":
            fn = ctypes.CDLL(None).malloc_zone_pressure_relief
            fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
            fn.restype = ctypes.c_size_t
            return lambda: fn(None, 0)
        if sys.platform.startswith("linux"):
            fn = ctypes.CDLL("libc.so.6").malloc_trim
            fn.argtypes = [ctypes.c_size_t]
            fn.restype = ctypes.c_int
            return lambda: fn(0)
    except (OSError, AttributeError):  # no such library or symbol (musl, say)
        return None
    return None


def release() -> bool:
    """Collect garbage and return freed heap pages to the OS; True when an allocator call ran."""
    gc.collect()
    fn = _relief()
    if fn is None:
        return False
    try:
        fn()
    except Exception:  # noqa: BLE001 - relief is best effort
        return False
    return True
