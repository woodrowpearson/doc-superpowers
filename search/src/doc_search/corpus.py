"""The docs corpus: which files are docs, and what each doc is (type, status, title, headings).

Discovery is the include/exclude globs intersected with git's view of the working tree.
Enrichment is stdlib only: front matter, the first H1, a `**Status:**` line and the doc-index
entry, resolved in the order of the design (section 5) and cached per file by
(size, mtime_ns). The file-derived parse is cached; the doc-index entry is read on every
call, so an index update is seen without the doc changing.

A file that cannot be read as text is skipped, never raised on: `skipped()` says why.
"""

from __future__ import annotations

import codecs
import os
import re
import stat
import threading
import time
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pathspec import PathSpec

from .config import Config, ConfigError
from .docindex import DocIndex
from .repo import confine, ls_files, norm_rel
from .types import DocMeta

HEAD_BYTES = 64 * 1024
MAX_BYTES = 1024 * 1024
STATUS_SCAN_LINES = 20

# Skip reasons: the three the design names, plus `unreadable` for an OS error that is not
# "the file is gone" (permissions, I/O).
NOT_UTF8 = "not-utf8"
TOO_LARGE = "too-large"
VANISHED = "vanished"
UNREADABLE = "unreadable"

# Design section 5, tier 4, in order.
_BUILTIN_TYPES = (
    ("docs/superpowers/specs/", "design-spec"),
    ("docs/adr/", "adr"),
    ("docs/specs/", "spec"),
    ("docs/plans/", "plan"),
    ("docs/issues/", "issue"),
    ("docs/architecture/", "architecture"),
    ("docs/workflows/", "workflows"),
    ("docs/guides/", "guide"),
)

ARCHIVE_PREFIX = "docs/archive/"

_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")
_CLOSING_HASHES = re.compile(r"(?:^|[ \t]+)#+$")
_BOLD_STATUS = re.compile(r"^\s*(?:[-*+>]\s+)*\*\*status(?::\*\*|\*\*\s*:)\s*[*_`\[(]*([a-z][\w-]*)", re.IGNORECASE)
_FM_KEY = re.compile(r"^([A-Za-z_][\w-]*)[ \t]*:(.*)$")
_FM_COMMENT = re.compile(r"[ \t]+#")


def _spec(patterns: tuple[str, ...]) -> PathSpec:
    """A gitignore-style matcher. pathspec 1.x names the factory `gitignore`; 0.x `gitwildmatch`."""
    try:
        return PathSpec.from_lines("gitignore", patterns)
    except KeyError:
        return PathSpec.from_lines("gitwildmatch", patterns)


def _compile(patterns: tuple[str, ...], where: str) -> PathSpec:
    try:
        return _spec(patterns)
    except (ValueError, re.error) as err:  # pathspec: a malformed pattern, or one that makes a bad regex (`[z-a]`)
        raise ConfigError(f"{where} has an invalid pattern: {err}") from err


def _text(value: Any) -> str | None:
    """A non-empty string, stripped, else None (index fields are JSON: anything can be in them)."""
    return (value.strip() or None) if isinstance(value, str) else None


# --- text parsing ---------------------------------------------------------------------


def _decode(data: bytes, *, complete: bool) -> str | None:
    """UTF-8 text (a BOM is dropped), or None for binary or non-UTF-8 bytes.

    `complete=False` says `data` is a prefix of a longer file, so a multibyte character cut
    at the end is not an error.
    """
    if b"\0" in data:
        return None
    try:
        return codecs.getincrementaldecoder("utf-8-sig")().decode(data, final=complete)
    except UnicodeDecodeError:
        return None


def _split_lines(text: str) -> list[str]:
    """Lines as an editor numbers them: split on LF only, CR dropped."""
    return [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]


def _unquote(value: str) -> str:
    value = value.strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        return value[1:end] if end > 0 else value[1:]
    return _FM_COMMENT.split(value, maxsplit=1)[0].strip()


def _front_matter(lines: list[str]) -> tuple[dict[str, str], int]:
    """The simple `key: value` fields of a leading `---` block, and the index of the first body line.

    Nested values, lists and block scalars are not read; the keys we use are plain scalars.
    """
    if not lines or lines[0].rstrip() != "---":
        return {}, 0
    for end in range(1, len(lines)):
        if lines[end].rstrip() in ("---", "..."):
            fields: dict[str, str] = {}
            for line in lines[1:end]:
                found = _FM_KEY.match(line)  # indented lines and comments do not match
                if not found:
                    continue
                value = _unquote(found.group(2))
                if value and value[0] not in "[{|>&*!":
                    fields.setdefault(found.group(1).lower(), value)
            return fields, end + 1
    return {}, 0


def _unfenced(lines: list[str], start: int) -> Iterator[tuple[int, str]]:
    """(1-based line number, line) for lines outside fenced code blocks; fence lines are skipped."""
    fence: tuple[str, int] | None = None
    for index in range(start, len(lines)):
        line = lines[index]
        found = _FENCE.match(line)
        if fence is None:
            if found and not (found.group(1)[0] == "`" and "`" in found.group(2)):
                fence = (found.group(1)[0], len(found.group(1)))
                continue
            yield index + 1, line
        elif found and found.group(1)[0] == fence[0] and len(found.group(1)) >= fence[1] and not found.group(2).strip():
            fence = None


def _heading(line: str) -> tuple[int, str] | None:
    """(level, text) of an ATX heading line, else None."""
    found = _ATX.match(line)
    if not found:
        return None
    text = _CLOSING_HASHES.sub("", found.group(2) or "").strip()
    return (len(found.group(1)), text) if text else None


@dataclass(frozen=True)
class _Head:
    """What the first 64 KiB of a doc says."""

    title: str
    title_line: int | None  # 1-based line of the H1 the title came from
    fields: Mapping[str, str]  # front matter, keys lowercased
    bold_status: str | None


def _parse_head(path: str, text: str) -> _Head:
    lines = _split_lines(text)
    fields, body = _front_matter(lines)
    h1: tuple[int, str] | None = None
    bold: str | None = None
    for number, line in _unfenced(lines, body):
        in_status_window = number - 1 - body < STATUS_SCAN_LINES
        if h1 is None:
            heading = _heading(line)
            if heading and heading[0] == 1:
                h1 = (number, heading[1])
        if bold is None and in_status_window:
            found = _BOLD_STATUS.match(line)
            if found:
                bold = found.group(1).lower()
        if h1 is not None and (bold is not None or not in_status_window):
            break
    title = h1[1] if h1 else fields.get("title") or Path(path).stem
    return _Head(title=title, title_line=h1[0] if h1 else None, fields=fields, bold_status=bold)


def _parse_outline(text: str) -> tuple[tuple[int, int, str], ...]:
    """(line, level, text) of every heading outside fenced blocks and front matter."""
    lines = _split_lines(text)
    _, body = _front_matter(lines)
    outline = []
    for number, line in _unfenced(lines, body):
        heading = _heading(line)
        if heading:
            outline.append((number, heading[0], heading[1]))
    return tuple(outline)


# --- the corpus -----------------------------------------------------------------------


def is_terminal(meta: DocMeta, cfg: Config) -> bool:
    """A doc whose status is terminal (`search.terminal_statuses`) or that lives under docs/archive/."""
    terminal = {status.lower() for status in cfg.search.terminal_statuses}
    return (meta.status or "").lower() in terminal or meta.path.startswith(ARCHIVE_PREFIX)


Sig = tuple[int, int]  # (size, mtime_ns)


class Corpus:
    """The doc files of one worktree and what is known about each.

    `meta()`, `heading_path_at()` and `skipped()` work for any repo-relative path, in the
    corpus or not; `files()`, `contains()` and `allowed()` are about corpus membership.
    """

    def __init__(self, top: Path, cfg: Config, docindex: DocIndex) -> None:
        self._top = Path(top)
        self._cfg = cfg
        self._docindex = docindex
        self._include = _compile(cfg.docs.include, "docs.include")
        self._exclude = _compile(cfg.docs.exclude, "docs.exclude")
        self._rules = [
            (_compile((glob,), f"docs.types[{i}]"), doc_type) for i, (glob, doc_type) in enumerate(cfg.docs.types)
        ]
        self._lock = threading.RLock()
        self._listing: tuple[list[str], frozenset[str]] | None = None
        self._listed_at = 0.0
        self._heads: dict[str, tuple[Sig, _Head | None, str | None]] = {}
        self._outlines: dict[str, tuple[Sig, tuple[tuple[int, int, str], ...]]] = {}
        self._skipped: dict[str, str] = {}

    @property
    def docindex(self) -> DocIndex:
        """The doc-index this corpus reads, shared so a caller's cross-links agree with its metadata."""
        return self._docindex

    # discovery

    def files(self) -> list[str]:
        """The corpus: include minus exclude, among the files git lists, sorted.

        Only regular files count (or symlinks that resolve to one inside the worktree), so a
        tracked file deleted from the working tree is not in it. The listing is reused for
        `search.rescan_seconds`.
        """
        with self._lock:
            return list(self._current()[0])

    def contains(self, path: str) -> bool:
        with self._lock:
            return norm_rel(path) in self._current()[1]

    def _current(self) -> tuple[list[str], frozenset[str]]:
        if self._listing is None or time.monotonic() - self._listed_at >= self._cfg.search.rescan_seconds:
            self._listing = self._scan()
            self._listed_at = time.monotonic()
        return self._listing

    def _scan(self) -> tuple[list[str], frozenset[str]]:
        found = sorted(
            path
            for path in ls_files(self._top)
            if self._include.match_file(path) and not self._exclude.match_file(path) and self._usable(path)
        )
        keep = frozenset(found)
        for cache in (self._heads, self._outlines, self._skipped):
            for path in [p for p in cache if p not in keep]:
                del cache[path]
        return found, keep

    def _usable(self, rel: str) -> bool:
        """A listed path counts only if it is a regular file (or resolves to one) inside the worktree.

        git lists the index (`--cached`) whatever the working tree looks like, so a directory
        swapped for a symlink out of the worktree still has its files listed: check the path itself.
        """
        plain = self._plain(rel)
        try:
            if plain is not None:
                return stat.S_ISREG(os.lstat(plain).st_mode)
            return confine(self._top, rel).is_file()
        except (ValueError, OSError):
            return False

    def _plain(self, rel: str) -> Path | None:
        """`top/rel` when no component is a symlink, `..` or `.git`; otherwise None.

        Such a path is physically inside `top`, so it needs no resolution. This costs one
        `lstat` per component, against the dozen or so that `confine` spends resolving the
        whole path; anything it does not clear goes through `confine`.
        """
        full = self._top
        for part in rel.split("/"):
            if part in ("", ".", "..") or part.lower() == ".git":
                return None
            full = full / part
            try:
                if stat.S_ISLNK(os.lstat(full).st_mode):
                    return None
            except OSError:
                return None
        return full

    # enrichment

    def meta(self, path: str) -> DocMeta | None:
        """What is known about a doc, or None when it cannot be read as text (see `skipped()`)."""
        path = norm_rel(path)
        with self._lock:
            head = self._head(path)
            if head is None:
                return None
            entry = self._docindex.entry(path) or {}
            refs = entry.get("code_refs")
            fields = head.fields
            superseded_by = _text(entry.get("superseded_by"))
            if entry.get("status") == "deprecated":
                status: str | None = "deprecated"
            elif superseded_by:
                status = "superseded"
            elif fields.get("status"):
                status = fields["status"].lower()
            else:
                status = head.bold_status
            return DocMeta(
                path=path,
                title=head.title,
                doc_type=_text(entry.get("doc_type"))
                or fields.get("doc_type")
                or fields.get("type")
                or self._type_from_path(path),
                status=status,
                code_refs=tuple(r for r in refs if isinstance(r, str)) if isinstance(refs, list) else (),
                replaces=_text(entry.get("replaces")),
                superseded_by=superseded_by,
            )

    def title_and_front_matter(self, path: str) -> tuple[str, dict[str, str]] | None:
        """A doc's title (as `meta()` has it) and the simple `key: value` fields of its front matter.

        One read of the cached parse of the first 64 KiB: one `stat` and the symlink checks, where
        `meta()` and `front_matter()` together would pay them twice. Field keys are lowercased;
        lists, nested values and block scalars are not among the fields, and the dict is a copy.
        None when the file cannot be read as text (see `skipped()`).
        """
        path = norm_rel(path)
        with self._lock:
            head = self._head(path)
            return (head.title, dict(head.fields)) if head is not None else None

    def front_matter(self, path: str) -> dict[str, str]:
        """The front-matter fields of `title_and_front_matter`; {} when there are none or the file is unreadable."""
        found = self.title_and_front_matter(path)
        return found[1] if found else {}

    def heading_path_at(self, path: str, line: int) -> tuple[str, ...]:
        """The title, then the headings that enclose `line` (1-based), outermost first.

        A heading line belongs to its own section. Headings inside fenced blocks and front
        matter do not count. An unreadable path gives `()`.
        """
        path = norm_rel(path)
        with self._lock:
            head = self._head(path)
            if head is None:
                return ()
            stack: list[tuple[int, str]] = []
            for number, level, text in self._outline(path):
                if number > line:
                    break
                if number == head.title_line:
                    continue  # the title heading is the root, already first
                while stack and stack[-1][0] >= level:
                    stack.pop()
                stack.append((level, text))
            return (head.title, *(text for _, text in stack))

    def allowed(self, doc_types: tuple[str, ...], path_prefix: str | None, include_terminal: bool) -> list[str]:
        """Corpus files passing the doc_type, path prefix and terminal filters, sorted.

        `doc_types` match case-insensitively, `path_prefix` is a plain string prefix. A file
        that cannot be read is never allowed.
        """
        wanted = {doc_type.lower() for doc_type in doc_types}
        prefix = norm_rel(path_prefix) if path_prefix else ""
        allowed = []
        with self._lock:
            for path in self._current()[0]:
                if prefix and not path.startswith(prefix):
                    continue
                meta = self.meta(path)
                if meta is None:
                    continue
                if wanted and (meta.doc_type or "other").lower() not in wanted:
                    continue
                if not include_terminal and is_terminal(meta, self._cfg):
                    continue
                allowed.append(path)
        return allowed

    def skipped(self) -> dict[str, str]:
        """Corpus files that could not be read as text, path to reason.

        Reasons: `not-utf8` (also binary), `too-large` (over 1 MiB), `vanished` (gone, not a
        regular file, or no longer safely inside the worktree, since discovery) and `unreadable`
        (an OS error). The corpus as last listed is checked first, so the answer does not
        depend on who asked about which file.
        """
        with self._lock:
            for path in self._current()[0]:
                self._head(path)
            return dict(sorted(self._skipped.items()))

    # internals

    def _type_from_path(self, path: str) -> str:
        for spec, doc_type in self._rules:
            if spec.match_file(path):
                return doc_type
        for prefix, doc_type in _BUILTIN_TYPES:
            if path.startswith(prefix):
                return doc_type
        return "other"

    def _note(self, path: str, reason: str) -> None:
        """Record why a path was skipped, but only for paths in the corpus as last listed:
        a caller asking about a path that is not a corpus file is not a corpus problem."""
        if self._listing is not None and path in self._listing[1]:
            self._skipped[path] = reason

    def _skip(self, path: str, reason: str) -> None:
        self._note(path, reason)
        self._heads.pop(path, None)
        self._outlines.pop(path, None)

    def _openable(self, path: str) -> Path:
        """Where to open `path`. ValueError when it is not safely inside the worktree.

        Checked on every call, not once per listing: the working tree can change under a listing.
        """
        plain = self._plain(path)
        return plain if plain is not None else confine(self._top, path)

    def _target(self, path: str) -> tuple[Path, Sig] | None:
        """The real file behind `path` and its (size, mtime_ns), or None (recording why)."""
        try:
            real = self._openable(path)
        except ValueError:  # outside the worktree: for a listed file it has gone bad since the listing
            self._skip(path, VANISHED)
            return None
        try:
            st = real.stat()
        except (FileNotFoundError, NotADirectoryError):
            self._skip(path, VANISHED)
            return None
        except OSError:
            self._skip(path, UNREADABLE)
            return None
        if not stat.S_ISREG(st.st_mode):
            self._skip(path, VANISHED)
            return None
        if st.st_size > MAX_BYTES:
            self._skip(path, TOO_LARGE)
            return None
        return real, (st.st_size, st.st_mtime_ns)

    def _head(self, path: str) -> _Head | None:
        target = self._target(path)
        if target is None:
            return None
        real, sig = target
        cached = self._heads.get(path)
        if cached is not None and cached[0] == sig:
            _, head, reason = cached
        else:
            head, reason = self._read_head(path, real, sig)
            if reason in (None, NOT_UTF8):  # a content verdict; a vanished or unreadable file is retried
                self._heads[path] = (sig, head, reason)
        if head is None:
            self._note(path, reason or UNREADABLE)
            return None
        self._skipped.pop(path, None)
        return head

    def _read_head(self, path: str, real: Path, sig: Sig) -> tuple[_Head | None, str | None]:
        try:
            with real.open("rb") as handle:
                data = handle.read(HEAD_BYTES)
        except (FileNotFoundError, NotADirectoryError):
            return None, VANISHED
        except OSError:
            return None, UNREADABLE
        text = _decode(data, complete=sig[0] <= HEAD_BYTES)
        if text is None:
            return None, NOT_UTF8
        return _parse_head(path, text), None

    def _outline(self, path: str) -> tuple[tuple[int, int, str], ...]:
        target = self._target(path)
        if target is None:
            return ()
        real, sig = target
        cached = self._outlines.get(path)
        if cached is not None and cached[0] == sig:
            return cached[1]
        try:
            text = _decode(real.read_bytes(), complete=True)
        except OSError:
            return ()
        outline = _parse_outline(text) if text is not None else ()
        self._outlines[path] = (sig, outline)
        return outline
