"""The cloud corpora (design section 5): what each cloud collection holds, and how its files are read and cut.

A `CloudCorpus` is everything the writer and the reader need to know about one collection that is not the
collection's plumbing: its names (collection, stamp and lease documents), its query task, the files it holds,
how a file's bytes become text and the text chunks, the fields a chunk carries beyond the common ones, and
how its stamp names the chunker.

- `DocsCloudCorpus` is the docs leg as it has always been: the docs corpus's files (`Corpus.in_scope`), the
  1 MiB limit, `chunk_markdown` / `chunk_lines`, `docType` and `headingPath`, `chunker_version`.
- `CodeCloudCorpus` is what semble's own walker would hold over HEAD, minus the docs corpus, a deny list of
  secret-bearing file names and `cloud.code.exclude`. Scope is a path test only, so it answers for a deleted
  path: HEAD's `.gitignore` / `.sembleignore` blobs are read once per corpus, from git, never the working
  tree, and matched with semble's own matcher (`semble.index.file_walker`), so a file the local code index
  leaves out (archived code, `dist/`, a nested ignore) never reaches the cloud. Chunks are semble's
  (`chunk_source`), the text embedded at most 6,000 characters, and the stamp names the chunker
  `semble-<major>.<minor>`.
"""

from __future__ import annotations

import fnmatch
import threading
from collections.abc import Mapping
from pathlib import Path, PurePosixPath
from typing import Any, Literal, Protocol

import semble
from pathspec import GitIgnoreSpec
from semble.chunking.chunking import chunk_source
from semble.index.file_walker import _DEFAULT_IGNORED_DIRS, IgnoreSpec, _is_ignored
from semble.index.files import detect_language, get_extensions

from ..chunker import CHUNKER_VERSION, CloudChunk, chunk_lines, chunk_markdown
from ..config import CODE_LEASE_DOC, CODE_STAMP_DOC, Config
from ..corpus import Corpus, _compile
from ..docindex import DocIndex
from ..engines import content_types
from ..repo import git, git_bytes, norm_rel, rev_parse
from . import CloudUnavailable
from .read import STAMP_DOC, CorpusStamp
from .vertex import CODE_QUERY_TASK, QUERY_TASK, embedder_id

LEASE_DOC = "catch_up_lease"  # the docs corpus's lease, in `cloud.firestore.meta_collection`
MAX_FILE_BYTES = 1 << 20  # the docs corpus's own limit; a larger file is not indexed
MARKDOWN_SUFFIXES = (".md", ".markdown", ".mdx")
REGULAR_MODES = ("100644", "100755")  # symlinks (120000) and submodules (160000) are not files to index

# A fixed constant, semble's default: never semble's `SEMBLE_MAX_FILE_BYTES` override, so every host writes the
# same set.
CODE_MAX_FILE_BYTES = 1_000_000
CODE_TEXT_CAP = 6000  # the characters of a code chunk stored and embedded

# File names never sent, whatever the config (matched on the name alone, case-insensitive). Design section 10:
# these keep the obvious secret-bearing files out; they do not replace a secret scanner.
CODE_DENY: tuple[str, ...] = (
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.keystore",
    "*.tfvars",
    "*.tfvars.json",
    ".env",
    ".env.*",
    "*.env",
    "id_rsa*",
    "id_ed25519*",
    "id_ecdsa*",
    "*secret*",
    "*secrets*",
    "*credential*",
    "*credentials*",
    ".npmrc",
    ".pypirc",
    ".netrc",
)

# The ignore files semble's walker reads in each directory, in its order (`_load_ignore_for_dir`). Matched on
# the lowercased name: on a case-insensitive file system semble reads a committed `.GitIgnore` too.
IGNORE_FILES = (".gitignore", ".sembleignore")
SYMLINK_MODE = "120000"
MAX_LINK_HOPS = 32  # past this many links a path resolves to nothing, as ELOOP does (macOS's MAXSYMLINKS)

# semble's major.minor: pinned `>=0.7,<0.8`, so a patch never changes it. Raised by hand (`semble-0.7.r2`) only
# when the boundary pins in the tests show a lock bump moved the cuts.
CODE_CHUNKER_ID = "semble-" + ".".join(semble.__version__.split(".")[:2])

_ROOT = Path(".")  # semble's matcher sees paths relative to this root: no "./" prefix


class CloudCorpus(Protocol):
    """One cloud collection's description. The writer and the reader take everything corpus-specific from it."""

    name: Literal["docs", "code"]
    collection: str
    stamp_doc: str
    lease_doc: str
    query_task: str
    hit_kind: Literal["doc", "code"]
    note_prefix: str  # "cloud" / "cloud code": the first words of the leg's notes and status lines
    # True: the collection holds only what is in scope at HEAD, so a file that leaves scope while HEAD still holds
    # it (newly ignored, excluded, sealed) loses its chunks. False: only a file git no longer knows is an orphan
    # (an archived doc keeps its chunks).
    purges_out_of_scope: bool

    def in_scope(self, path: str) -> bool:
        """Whether the corpus holds `path`: a test of the path alone, so it answers for a deleted one too."""
        ...

    def readable(self, path: str, data: bytes) -> str | None:
        """The file's text, or None when it cannot be held (too large, binary, not UTF-8): its chunks are purged."""
        ...

    def chunks(self, path: str, text: str) -> list[CloudChunk]:
        """The file's chunks, ordinals from 0."""
        ...

    def fields(self, path: str, chunk: CloudChunk) -> dict[str, Any]:
        """The fields a chunk document carries beyond the common ones."""
        ...

    def chunk_identity(self) -> dict[str, Any]:
        """The fields every chunk document carries that name the chunker and embedder that made it; empty when
        the corpus's chunks name neither (then a rewrite cannot resume, and `resumable_current` is never asked)."""
        ...

    def chunker_stamp(self) -> dict[str, Any]:
        """The stamp fields that name this corpus's chunker."""
        ...

    def chunker_matches(self, stamp: CorpusStamp) -> bool:
        """Whether `stamp`'s chunks were cut as this corpus cuts them; if not, a catch-up is a full rewrite."""
        ...

    def resumable_current(self, chunk0: Mapping[str, Any] | None, sha: str) -> bool:
        """During a rewrite: whether the stored chunk 0 shows this file already rewritten by this run's rules."""
        ...


def decode_text(data: bytes, limit: int) -> str | None:
    """UTF-8 text (a BOM dropped), or None for bytes over `limit`, binary or not UTF-8."""
    if len(data) > limit or b"\0" in data:
        return None
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None


def _cloud(cfg: Config) -> Any:
    if cfg.cloud is None:
        raise CloudUnavailable("cloud is not configured (set the cloud object in docs/search/config.json)")
    return cfg.cloud


class DocsCloudCorpus:
    """The docs corpus: the docs leg's files, cuts and fields, unchanged."""

    name: Literal["docs", "code"] = "docs"
    hit_kind: Literal["doc", "code"] = "doc"
    note_prefix = "cloud"
    stamp_doc = STAMP_DOC
    lease_doc = LEASE_DOC
    query_task = QUERY_TASK
    purges_out_of_scope = False

    def __init__(self, cfg: Config, top: Path) -> None:
        self.collection = _cloud(cfg).firestore.collection
        # the working tree is read for each doc's type and title only, as before
        self._corpus = Corpus(Path(top), cfg, DocIndex(Path(top)))

    def in_scope(self, path: str) -> bool:
        return self._corpus.in_scope(path)

    def readable(self, path: str, data: bytes) -> str | None:
        return decode_text(data, MAX_FILE_BYTES)

    def chunks(self, path: str, text: str) -> list[CloudChunk]:
        meta = self._corpus.meta(path)
        title = meta.title if meta else ""
        if PurePosixPath(path).suffix.lower() in MARKDOWN_SUFFIXES:
            return chunk_markdown(path, text, title)
        return chunk_lines(path, text, title)

    def fields(self, path: str, chunk: CloudChunk) -> dict[str, Any]:
        meta = self._corpus.meta(path)
        return {
            "docType": ((meta.doc_type if meta else None) or "other").lower(),
            "headingPath": list(chunk.heading_path),
        }

    def chunk_identity(self) -> dict[str, Any]:
        return {}  # the docs documents are unchanged: no chunker or embedder named

    def chunker_stamp(self) -> dict[str, Any]:
        return {"chunker_version": CHUNKER_VERSION}

    def chunker_matches(self, stamp: CorpusStamp) -> bool:
        # a stamp this indexer wrote (it names an embedder) names the chunker too; the first writer's names neither
        if stamp.chunker_version is not None:
            return stamp.chunker_version == CHUNKER_VERSION
        return not stamp.embedder_id

    def resumable_current(self, chunk0: Mapping[str, Any] | None, sha: str) -> bool:
        return False  # a docs chunk 0 names no chunker or embedder: a rewrite trusts no sha


def _denied(path: str) -> bool:
    """Whether the file name matches the deny list (case-insensitive)."""
    name = PurePosixPath(path).name.lower()
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in CODE_DENY)


class _Escapes(Exception):
    """A symlinked ignore file points outside the repository (or at an absolute path): HEAD cannot say what it
    holds."""


_Entry = tuple[str, str, str]  # (mode, type, oid) of one path in HEAD's tree


def _follow(top: Path, entries: dict[str, _Entry], link: str) -> str | None:
    """The oid of the regular blob that the symlink at `link` ends at inside HEAD's tree, resolved as the file
    system resolves it in a checkout; None where `Path.is_file()` would be False there (a target missing, a
    directory, a submodule, a path through a file, a chain past MAX_LINK_HOPS).

    Raises _Escapes for a target that is absolute or climbs out of the repository: a checkout would read a file
    HEAD does not hold.
    """
    hops = 0
    resolved: list[str] = []  # the components walked so far, every one a directory of HEAD's tree
    pending = link.split("/")
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise _Escapes(link)
            resolved.pop()
            continue
        here = "/".join([*resolved, part])
        entry = entries.get(here)
        if entry is not None and entry[0] == SYMLINK_MODE:
            hops += 1
            if hops > MAX_LINK_HOPS:
                return None
            target = git_bytes(top, "cat-file", "blob", entry[2]).decode("utf-8", errors="surrogateescape")
            if target.startswith("/"):
                raise _Escapes(link)
            pending = target.split("/") + pending  # relative to the link's own directory: `resolved`
            continue
        if pending and (entry is None or entry[1] != "tree"):
            return None  # a path through a missing entry or a file (`file/`, `missing/..`) resolves to nothing
        resolved.append(part)
    entry = entries.get("/".join(resolved))
    return entry[2] if entry is not None and entry[1] == "blob" and entry[0] in REGULAR_MODES else None


def _head_ignores(top: Path) -> tuple[dict[str, GitIgnoreSpec], frozenset[str]]:
    """Each directory's ignore rules as HEAD holds them ('' is the root), parsed as semble parses a checkout's,
    and the directories whose rules HEAD cannot answer for.

    A symlinked ignore file is read through its link, inside HEAD's tree; one that resolves to nothing gives no
    rules, as `Path.is_file()` is False for it in a checkout. A directory is sealed (it and everything under it
    out of scope) when one of its ignore files points outside the repository, or when it holds two names that
    differ only in case (`.gitignore` and `.GitIgnore`: which one a case-insensitive checkout holds is
    unknowable). Sealing fails closed: the cloud then holds less than the local index, never more.

    A repository with no commit has no files, so no rules. A git failure is raised, never read as "no rules":
    that would widen what is sent.
    """
    head = rev_parse(top, "HEAD")
    if head is None:
        return {}, frozenset()
    entries: dict[str, _Entry] = {}
    named: dict[str, dict[str, list[str]]] = {}  # directory -> ignore name -> the paths spelling it
    for record in git(top, "ls-tree", "-r", "-t", "-z", "--full-tree", head).split("\0"):
        info, _, path = record.partition("\t")
        parts = info.split(" ")
        if not path or len(parts) != 3:
            continue
        entries[path] = (parts[0], parts[1], parts[2])
        directory, _, name = path.rpartition("/")
        if name.lower() in IGNORE_FILES:
            named.setdefault(directory, {}).setdefault(name.lower(), []).append(path)
    rules: dict[str, GitIgnoreSpec] = {}
    sealed: set[str] = set()
    for directory, found in named.items():
        lines: list[str] = []
        try:
            for name in IGNORE_FILES:
                spellings = found.get(name, [])
                if len(spellings) > 1:
                    raise _Escapes(directory)
                if not spellings:
                    continue
                oid = _follow(top, entries, spellings[0])
                if oid is not None:
                    data = git_bytes(top, "cat-file", "blob", oid)
                    lines.extend(data.decode("utf-8", errors="ignore").splitlines())
        except _Escapes:
            sealed.add(directory)
            continue
        if lines:
            rules[directory] = GitIgnoreSpec.from_lines(lines)
    return rules, frozenset(sealed)


class CodeCloudCorpus:
    """The code corpus: what the local code index would hold at HEAD, less the docs corpus and the deny list."""

    name: Literal["docs", "code"] = "code"
    hit_kind: Literal["doc", "code"] = "code"
    note_prefix = "cloud code"
    stamp_doc = CODE_STAMP_DOC
    lease_doc = CODE_LEASE_DOC
    query_task = CODE_QUERY_TASK
    purges_out_of_scope = True

    def __init__(self, cfg: Config, top: Path) -> None:
        cloud = _cloud(cfg)
        if cloud.code is None:
            raise CloudUnavailable("cloud code is not configured (set cloud.code)")
        self.collection = cloud.code.collection
        self._top = Path(top)
        self._docs = Corpus(self._top, cfg, DocIndex(self._top))
        self._exclude = _compile(cloud.code.exclude, "cloud.code.exclude")
        self._extensions = frozenset(get_extensions(content_types(cfg.code.content)))
        self._embedder_id = embedder_id(cloud.vertex)
        # semble's walker skips its default directories first, with this matcher (`walk_files`)
        self._base = GitIgnoreSpec.from_lines(sorted(_DEFAULT_IGNORED_DIRS), backend="simple")
        self._lock = threading.Lock()
        self._ignores: dict[str, GitIgnoreSpec] | None = None  # HEAD's, read on first use
        self._sealed: frozenset[str] = frozenset()  # directories whose ignore rules HEAD cannot answer for
        self._dirs: dict[str, list[IgnoreSpec] | None] = {}

    # -- scope ------------------------------------------------------------------------------------

    def in_scope(self, path: str) -> bool:
        path = norm_rel(path)
        if not path or _denied(path) or self._exclude.match_file(path) or self._docs.in_scope(path):
            return False
        return self._walker_keeps(path)

    def _walker_keeps(self, path: str) -> bool:
        """What `semble.index.file_walker.walk_files` decides for `path` in a checkout of HEAD."""
        with self._lock:
            specs = self._specs_in(path.rpartition("/")[0])
        if specs is None:
            return False
        ignored, negated = _is_ignored(Path(path), False, specs)
        # a negation naming a suffix (`!special.kjs`) takes the file whatever its extension, as semble does
        return not ignored and (negated or PurePosixPath(path).suffix.lower() in self._extensions)

    def _specs_in(self, directory: str) -> list[IgnoreSpec] | None:
        """The ignore specs in force for the entries of `directory` ('' is the root); None when semble's walker
        never enters it. Called under the lock."""
        if directory in self._dirs:
            return self._dirs[directory]
        if self._ignores is None:
            self._ignores, self._sealed = _head_ignores(self._top)
        specs: list[IgnoreSpec] | None
        if not directory:
            specs = [IgnoreSpec(base=_ROOT, spec=self._base)]
        else:
            outer = self._specs_in(directory.rpartition("/")[0])
            specs = None if outer is None or _is_ignored(Path(directory), True, outer)[0] else outer
        if directory in self._sealed:
            specs = None
        own = self._ignores.get(directory)
        if specs is not None and own is not None:
            specs = [*specs, IgnoreSpec(base=Path(directory) if directory else _ROOT, spec=own)]
        self._dirs[directory] = specs
        return specs

    # -- reading and cutting -----------------------------------------------------------------------

    def readable(self, path: str, data: bytes) -> str | None:
        return decode_text(data, CODE_MAX_FILE_BYTES)

    def chunks(self, path: str, text: str) -> list[CloudChunk]:
        cut = chunk_source(text, path, detect_language(PurePosixPath(path)))
        return [
            CloudChunk(ordinal, chunk.start_line, chunk.end_line, (), chunk.content[:CODE_TEXT_CAP])
            for ordinal, chunk in enumerate(cut)
        ]

    def fields(self, path: str, chunk: CloudChunk) -> dict[str, Any]:
        return {"language": detect_language(PurePosixPath(path)), "headingPath": []}

    def chunk_identity(self) -> dict[str, Any]:
        return {"chunkerId": CODE_CHUNKER_ID, "embedderId": self._embedder_id}

    # -- the stamp ---------------------------------------------------------------------------------

    def chunker_stamp(self) -> dict[str, Any]:
        return {"chunker_id": CODE_CHUNKER_ID}

    def chunker_matches(self, stamp: CorpusStamp) -> bool:
        return stamp.chunker_id == CODE_CHUNKER_ID

    def resumable_current(self, chunk0: Mapping[str, Any] | None, sha: str) -> bool:
        """A rewrite cut short resumes: chunk 0 already has this sha, this chunker and this embedder."""
        return (
            chunk0 is not None
            and chunk0.get("fileSha256") == sha
            and chunk0.get("chunkerId") == CODE_CHUNKER_ID
            and chunk0.get("embedderId") == self._embedder_id
        )


def corpora_for(cfg: Config, top: Path, only: str | None = None) -> list[CloudCorpus]:
    """The configured cloud corpora, docs first; `only` ("docs" or "code") keeps that one, if configured."""
    if only not in (None, "docs", "code"):
        raise ValueError(f"unknown cloud corpus {only!r} (expected docs or code)")
    if cfg.cloud is None:
        return []
    found: list[CloudCorpus] = []
    if cfg.cloud.docs and only in (None, "docs"):
        found.append(DocsCloudCorpus(cfg, top))
    if cfg.cloud.code is not None and only in (None, "code"):
        found.append(CodeCloudCorpus(cfg, top))
    return found
