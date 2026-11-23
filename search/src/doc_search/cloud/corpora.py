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

# The ignore files semble's walker reads in each directory, in its order (`_load_ignore_for_dir`).
IGNORE_FILES = (".gitignore", ".sembleignore")

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


def _head_ignores(top: Path) -> dict[str, GitIgnoreSpec]:
    """Each directory's ignore rules as HEAD holds them ('' is the root), parsed as semble parses a checkout's.

    A repository with no commit has no files, so no rules. A git failure is raised, never read as "no rules":
    that would widen what is sent.
    """
    head = rev_parse(top, "HEAD")
    if head is None:
        return {}
    blobs: dict[str, dict[str, str]] = {}
    for record in git(top, "ls-tree", "-r", "-z", "--full-tree", head).split("\0"):
        info, _, path = record.partition("\t")
        parts = info.split(" ")
        if not path or len(parts) != 3 or parts[1] != "blob" or parts[0] not in REGULAR_MODES:
            continue
        directory, _, name = path.rpartition("/")
        if name in IGNORE_FILES:
            blobs.setdefault(directory, {})[name] = parts[2]
    rules: dict[str, GitIgnoreSpec] = {}
    for directory, found in blobs.items():
        lines: list[str] = []
        for name in IGNORE_FILES:
            if name in found:
                data = git_bytes(top, "cat-file", "blob", found[name])
                lines.extend(data.decode("utf-8", errors="ignore").splitlines())
        if lines:
            rules[directory] = GitIgnoreSpec.from_lines(lines)
    return rules


class CodeCloudCorpus:
    """The code corpus: what the local code index would hold at HEAD, less the docs corpus and the deny list."""

    name: Literal["docs", "code"] = "code"
    hit_kind: Literal["doc", "code"] = "code"
    note_prefix = "cloud code"
    stamp_doc = CODE_STAMP_DOC
    lease_doc = CODE_LEASE_DOC
    query_task = CODE_QUERY_TASK

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
            self._ignores = _head_ignores(self._top)
        specs: list[IgnoreSpec] | None
        if not directory:
            specs = [IgnoreSpec(base=_ROOT, spec=self._base)]
        else:
            outer = self._specs_in(directory.rpartition("/")[0])
            specs = None if outer is None or _is_ignored(Path(directory), True, outer)[0] else outer
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
