"""A read-only view of `docs/.doc-index.json`: per-doc entries and the code-to-docs cross-links.

doc-search never writes the index. It reads the file again whenever its mtime (or size)
changes, so edits made by `doc-tools.sh` while the server runs are picked up.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any

from .repo import norm_rel

INDEX_REL = "docs/.doc-index.json"

_UNLOADED = object()


def _norm_ref(ref: Any) -> str | None:
    """A code_ref as a repo-relative path without `./` or a trailing slash; `.` is the root."""
    if not isinstance(ref, str):
        return None
    ref = ref.strip()
    if ref in (".", "./"):
        return "."
    ref = norm_rel(ref).rstrip("/")
    return ref if ref and not ref.startswith("/") else None


def _specificity(ref: str) -> int:
    """How narrow a ref is: its path components, so a file beats its directory beats `.`."""
    return 0 if ref == "." else ref.count("/") + 1


class DocIndex:
    """The doc-index as the corpus and the cross-links need it. Entries are read-only."""

    def __init__(self, top: Path) -> None:
        self._path = Path(top) / INDEX_REL
        self._lock = threading.RLock()
        self._sig: object = _UNLOADED
        self._docs: dict[str, dict[str, Any]] = {}
        self._by_ref: dict[str, list[str]] = {}
        self._present = False
        # why a file that exists could not be used; None when it is usable or absent
        self.error: str | None = None

    @property
    def present(self) -> bool:
        """True when the index file exists and is usable."""
        with self._lock:
            self._refresh()
            return self._present

    def entry(self, path: str) -> dict[str, Any] | None:
        """The index entry for a repo-relative doc path, or None."""
        with self._lock:
            self._refresh()
            return self._docs.get(norm_rel(path))

    def docs_covering(self, code_path: str) -> list[str]:
        """Docs whose code_refs name `code_path`, an ancestor directory of it, or `.`.

        Most specific first (the file itself, then deeper directories, then `.`), ties by path.
        """
        with self._lock:
            self._refresh()
            path = norm_rel(code_path).rstrip("/")
            candidates = ["."]
            if path and path != ".":
                parts = path.split("/")
                candidates += ["/".join(parts[: i + 1]) for i in range(len(parts))]
            best: dict[str, int] = {}
            for ref in candidates:
                for doc in self._by_ref.get(ref, ()):
                    best[doc] = max(best.get(doc, -1), _specificity(ref))
            return [doc for doc, _ in sorted(best.items(), key=lambda item: (-item[1], item[0]))]

    def _refresh(self) -> None:
        try:
            st = self._path.stat()
        except OSError:
            sig: object = None
        else:
            sig = (st.st_mtime_ns, st.st_size)
        if sig == self._sig:
            return
        self._sig = sig
        self._docs, self._by_ref, self._present, self.error = {}, {}, False, None
        if sig is None:
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            docs = raw["docs"] if isinstance(raw, dict) else None
            if not isinstance(docs, dict):
                raise ValueError('no "docs" object')
        except (OSError, ValueError, KeyError) as err:  # JSONDecodeError and UnicodeDecodeError are ValueErrors
            self.error = f"{INDEX_REL} is not usable: {err}"
            return
        self._docs = {key: value for key, value in docs.items() if isinstance(value, dict)}
        for doc, value in self._docs.items():
            refs = value.get("code_refs")
            for ref in {_norm_ref(r) for r in refs} if isinstance(refs, list) else ():
                if ref is not None:
                    self._by_ref.setdefault(ref, []).append(doc)
        self._present = True
