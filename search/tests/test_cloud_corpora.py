"""The cloud corpus descriptions (design section 5): which files each corpus holds, how it reads and cuts them.

The docs corpus is today's behaviour, moved. The code corpus is what semble's own walker would hold over HEAD,
minus the docs corpus, the deny list and `cloud.code.exclude`; its bytes, and the ignore files that decide its
scope, come from git, never the working tree. The parity test holds the scope equal to semble's walker over a
checkout of the same commit, and the boundary pins hold semble's cuts still across a lock bump.
"""

from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
from typing import Any

import pytest
import semble
from semble.chunking.chunking import chunk_source
from semble.index.file_walker import walk_files
from semble.index.files import detect_language, get_extensions

import doc_search.cloud.corpora as corpora
from doc_search.chunker import CHUNKER_VERSION, CloudChunk, chunk_lines, chunk_markdown
from doc_search.cloud.corpora import (
    CODE_DENY,
    CODE_MAX_FILE_BYTES,
    CloudCorpus,
    CodeCloudCorpus,
    DocsCloudCorpus,
    corpora_for,
)
from doc_search.cloud.read import STAMP_DOC, CorpusStamp, _parse_stamp
from doc_search.cloud.vertex import CODE_QUERY_TASK, QUERY_TASK
from doc_search.config import CODE_LEASE_DOC, CODE_STAMP_DOC, Config, load_config
from doc_search.corpus import Corpus
from doc_search.docindex import DocIndex
from doc_search.engines import _content_types, content_types
from doc_search.repo import GitError

EMBEDDER_ID = "vertex:gemini-embedding-001/768"
CHUNKER_ID = "semble-0.7"


def make_cfg(
    tmp_path: Path,
    *,
    content: tuple[str, ...] = ("code",),
    code: bool = True,
    docs: bool = True,
    exclude: tuple[str, ...] = (),
    docs_include: tuple[str, ...] | None = None,
) -> Config:
    """A config with a cloud object, read from its own directory (never the repository under test)."""
    where = tmp_path / f"cfg-{len(list(tmp_path.glob('cfg-*')))}"
    raw: dict[str, Any] = {
        "code": {"content": list(content)},
        "cloud": {
            "vertex": {"project": "p"},
            "firestore": {"project": "p"},
            "docs": docs,
            "code": {"exclude": list(exclude)} if code else None,
        },
    }
    if docs_include is not None:
        raw["docs"] = {"include": list(docs_include)}
    (where / "docs/search").mkdir(parents=True)
    (where / "docs/search/config.json").write_text(json.dumps(raw), encoding="utf-8")
    cfg = load_config(where, env={})
    assert cfg is not None
    return cfg


def commit_all(repo: Any, files: dict[str, str], msg: str = "files") -> str:
    """Write `files` and commit everything, ignored files included: a repository tracks what it ignores too."""
    for rel, text in files.items():
        repo.write(rel, text)
    repo.git("add", "-f", "-A", ".")
    repo.git("commit", "-q", "--allow-empty", "-m", msg)
    return repo.git("rev-parse", "HEAD").strip()


def head_files(repo: Any) -> list[str]:
    out = repo.git("ls-tree", "-r", "-z", "--full-tree", "HEAD")
    paths = []
    for record in out.split("\0"):
        info, _, path = record.partition("\t")
        if path and info.split(" ")[0] in ("100644", "100755"):
            paths.append(path)
    return sorted(paths)


def scope(corpus: CloudCorpus, repo: Any) -> set[str]:
    return {path for path in head_files(repo) if corpus.in_scope(path)}


# --- the docs corpus: today's behaviour --------------------------------------------------------------


SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service.

## Rounding

Refunds round half up to the nearest cent.

## Totals

The refund total is the sum of the rounded line amounts.
"""


def test_docs_corpus_matches_todays_chunks(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    commit_all(repo, {"docs/specs/SPEC-1.md": SPEC, "docs/notes.txt": "line one\nline two\n", "app.py": "x = 1\n"})
    cfg = make_cfg(tmp_path, docs_include=("docs/**/*.md", "docs/**/*.txt", "*.md"))
    corpus = DocsCloudCorpus(cfg, repo.root)
    today = Corpus(repo.root, cfg, DocIndex(repo.root))

    assert (corpus.name, corpus.hit_kind, corpus.note_prefix) == ("docs", "doc", "cloud")
    assert (corpus.collection, corpus.stamp_doc, corpus.lease_doc) == ("doc_chunks", STAMP_DOC, "catch_up_lease")
    assert corpus.query_task == QUERY_TASK
    for path in ("docs/specs/SPEC-1.md", "docs/notes.txt", "app.py", "docs/archive/old.md", "gone/deleted.md"):
        assert corpus.in_scope(path) == today.in_scope(path), path

    title = today.meta("docs/specs/SPEC-1.md").title
    md = corpus.chunks("docs/specs/SPEC-1.md", SPEC)
    assert md == chunk_markdown("docs/specs/SPEC-1.md", SPEC, title) and len(md) >= 1
    txt = corpus.chunks("docs/notes.txt", "line one\nline two\n")
    assert txt == chunk_lines("docs/notes.txt", "line one\nline two\n", "notes")
    assert corpus.fields("docs/specs/SPEC-1.md", md[-1]) == {
        "docType": "spec",
        "headingPath": list(md[-1].heading_path),
    }
    assert corpus.fields("docs/notes.txt", txt[0])["docType"] == "other"

    assert corpus.readable("a.md", b"\xef\xbb\xbf# T\n") == "# T\n"  # a BOM dropped
    assert corpus.readable("a.md", b"a" * (1 << 20)) == "a" * (1 << 20)
    assert corpus.readable("a.md", b"a" * ((1 << 20) + 1)) is None
    assert corpus.readable("a.md", b"a\0b") is None
    assert corpus.readable("a.md", b"\xff\xfe") is None

    assert corpus.chunker_stamp() == {"chunker_version": CHUNKER_VERSION}
    ours = CorpusStamp("c" * 40, None, "full", EMBEDDER_ID, None, CHUNKER_VERSION)
    assert corpus.chunker_matches(ours)
    assert not corpus.chunker_matches(CorpusStamp("c" * 40, None, "full", EMBEDDER_ID, None, CHUNKER_VERSION + 1))
    # a stamp naming an embedder but no chunker version was written before the version existed: other cuts
    assert not corpus.chunker_matches(CorpusStamp("c" * 40, None, "full", EMBEDDER_ID, None, None))
    # a stamp naming neither (the first writer's) is trusted, as `_plan` trusts it today
    assert corpus.chunker_matches(CorpusStamp("c" * 40, None, None, None))
    chunk0 = {"fileSha256": "s", "chunkerId": CHUNKER_ID, "embedderId": EMBEDDER_ID}
    assert corpus.resumable_current(chunk0, "s") is False  # a docs rewrite trusts no sha, as today
    assert corpus.resumable_current(None, "s") is False


# --- the code corpus: scope --------------------------------------------------------------------------


def test_code_corpus_scope(git_repo, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    commit_all(
        repo,
        {
            "app.py": "x = 1\n",
            "ios/View.swift": "let x = 1\n",
            "docs/guide.md": "# Guide\n",
            "README.md": "# Readme\n",
            "logo.png": "not really a png\n",
            "old.py": "y = 2\n",
        },
    )
    (repo.root / "old.py").unlink()
    commit_all(repo, {}, "delete old.py")
    cfg = make_cfg(tmp_path, content=("all",))
    corpus = CodeCloudCorpus(cfg, repo.root)

    assert (corpus.name, corpus.hit_kind, corpus.note_prefix) == ("code", "code", "cloud code")
    assert (corpus.collection, corpus.stamp_doc, corpus.lease_doc) == ("code_chunks", CODE_STAMP_DOC, CODE_LEASE_DOC)
    assert corpus.query_task == CODE_QUERY_TASK
    assert corpus.in_scope("app.py") and corpus.in_scope("ios/View.swift") and corpus.in_scope("./app.py")
    # the docs corpus keeps its own files, even when `code.content: ["all"]` takes markdown
    assert ".md" in get_extensions(content_types(("all",)))
    assert not corpus.in_scope("docs/guide.md") and not corpus.in_scope("README.md")
    assert not corpus.in_scope("logo.png")

    # deleted paths answer from the path and HEAD's rules alone: no read, no further git call
    def no_git(*_: Any, **__: Any) -> Any:
        raise AssertionError("in_scope asked git again")

    monkeypatch.setattr(corpora, "git", no_git)
    monkeypatch.setattr(corpora, "git_bytes", no_git)
    monkeypatch.setattr(corpora, "rev_parse", no_git)
    assert not (repo.root / "old.py").exists()
    assert corpus.in_scope("old.py")  # deleted at HEAD
    assert corpus.in_scope("never/existed.py")
    assert not corpus.in_scope("never/existed.png")


def test_code_corpus_follows_sembleignore(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    commit_all(
        repo,
        {
            ".sembleignore": "docs/archive/\n",
            "docs/archive/old.py": "old = 1\n",
            "tools/.gitignore": "gen/\n",
            "tools/gen/out.py": "generated = 1\n",
            "tools/main.py": "main = 1\n",
            "dist/app.js": "var app = 1;\n",
            "src/app.py": "app = 1\n",
        },
    )
    # what the working tree says, but HEAD does not, decides nothing
    repo.write(".sembleignore", "docs/archive/\nsrc/\n")
    repo.write("tools/.sembleignore", "main.py\n")
    repo.write("tools/gen/.gitignore", "!out.py\n")
    (repo.root / "tools/.gitignore").unlink()
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)

    assert scope(corpus, repo) == {"src/app.py", "tools/main.py"}
    assert not corpus.in_scope("docs/archive/old.py")
    assert not corpus.in_scope("tools/gen/out.py")
    assert not corpus.in_scope("dist/app.js")


PARITY_FILES = {
    ".gitignore": "*.log\ngen/\nvendor/\n",
    ".sembleignore": "legacy/\n",
    "app.py": "app = 1\n",
    "server.log": "log\n",
    "gen/x.py": "x = 1\n",
    "legacy/old.py": "old = 1\n",
    "pkg/.gitignore": "tmp_*.py\n",
    "pkg/a.py": "a = 1\n",
    "pkg/tmp_b.py": "b = 1\n",
    "pkg/legacy/x.py": "x = 1\n",
    "pkg/sub/.gitignore": "*.py\n!keep.py\n!special.kjs\n",
    "pkg/sub/.sembleignore": "notes/\n",
    "pkg/sub/drop.py": "drop = 1\n",
    "pkg/sub/keep.py": "keep = 1\n",
    "pkg/sub/special.kjs": "special\n",
    "pkg/sub/view.swift": "let v = 1\n",
    "pkg/sub/notes/n.py": "n = 1\n",
    # an ignored directory is never entered, so its own negation cannot take a file back
    "vendor/.gitignore": "!keep.py\n",
    "vendor/keep.py": "keep = 1\n",
    "node_modules/lib/index.js": "module.exports = 1;\n",
    "dist/app.js": "var app = 1;\n",
    "build/out.go": "package out\n",
    ".venv/lib/site.py": "site = 1\n",
    "web/app.ts": "export const app = 1;\n",
    "config/settings.yaml": "a: 1\n",
    ".github/workflows/ci.yml": "on: push\n",
    "docs/guide.md": "# Guide\n",
    "docs/archive/old.md": "# Old\n",
    "README.md": "# Readme\n",
    "Makefile": "all:\n",
}


@pytest.mark.parametrize("content", [("code",), ("all",), ("code", "config")])
def test_code_corpus_parity_with_semble_walker(git_repo, tmp_path: Path, content: tuple[str, ...]) -> None:
    repo = git_repo()
    commit_all(repo, PARITY_FILES)
    assert repo.git("status", "--porcelain", "--ignored") == ""  # the checkout is exactly HEAD
    cfg = make_cfg(tmp_path, content=content)
    corpus = CodeCloudCorpus(cfg, repo.root)
    docs = Corpus(repo.root, cfg, DocIndex(repo.root))

    walked = {
        p.relative_to(repo.root).as_posix() for p in walk_files(repo.root, get_extensions(content_types(content)))
    }
    expected = {path for path in walked if not docs.in_scope(path)}
    assert scope(corpus, repo) == expected
    # the fixture exercises each rule: three depths of ignores, a negation, default dirs, the docs corpus
    assert {"app.py", "pkg/a.py", "pkg/sub/keep.py", "pkg/sub/special.kjs", "pkg/sub/view.swift"} <= expected
    assert not expected & {
        "gen/x.py",
        "legacy/old.py",
        "pkg/legacy/x.py",
        "pkg/tmp_b.py",
        "pkg/sub/drop.py",
        "pkg/sub/notes/n.py",
        "vendor/keep.py",
        "node_modules/lib/index.js",
        "dist/app.js",
        "build/out.go",
        ".venv/lib/site.py",
    }
    if "all" in content:
        assert "docs/archive/old.md" in expected and "docs/guide.md" in walked - expected


def link(repo: Any, rel: str, target: str) -> None:
    path = repo.root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(target, path)


def test_code_corpus_parity_with_symlinked_ignores(git_repo, tmp_path: Path) -> None:
    """semble reads an ignore file through its link (`Path.is_file()` follows it); so does the cloud scope,
    inside HEAD's tree. A link that resolves to nothing gives no rules on both sides."""
    repo = git_repo()
    commit_all(
        repo,
        {
            "shared/root.ignore": "private/\n",
            "shared/sub.ignore": "gen/\n",
            "shared/lib.ignore": "old_*.py\n",
            "shared/tools.ignore": "scratch.py\n",
            "a.py": "a = 1\n",
            "private/leak.py": "leak = 1\n",
            "sub/gen/out.py": "out = 1\n",
            "sub/main.py": "main = 1\n",
            "lib/old_x.py": "x = 1\n",
            "lib/new_x.py": "x = 1\n",
            "tools/scratch.py": "s = 1\n",
            "tools/run.py": "r = 1\n",
            "dangling/kept.py": "k = 1\n",
            "dirlink/kept.py": "k = 1\n",
            "through/kept.py": "k = 1\n",
        },
    )
    link(repo, ".gitignore", "shared/root.ignore")  # in-tree target
    link(repo, "sub/.sembleignore", "../shared/sub.ignore")
    link(repo, "links/l1", "../shared/lib.ignore")
    link(repo, "lib/.gitignore", "../links/l1")  # a chain of two links
    link(repo, "conf", "shared")  # a symlinked directory on the way to the target
    link(repo, "tools/.gitignore", "../conf/tools.ignore")
    link(repo, "dangling/.gitignore", "../nowhere.ignore")  # missing: no rules
    link(repo, "dirlink/.gitignore", "../shared")  # a directory: no rules
    link(repo, "through/.gitignore", "../a.py/x")  # through a file: no rules
    commit_all(repo, {}, "links")
    assert repo.git("status", "--porcelain", "--ignored") == ""
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)

    walked = {p.relative_to(repo.root).as_posix() for p in walk_files(repo.root, get_extensions(content_types(("code",))))}
    assert scope(corpus, repo) == walked
    assert walked == {
        "a.py",
        "sub/main.py",
        "lib/new_x.py",
        "tools/run.py",
        "dangling/kept.py",
        "dirlink/kept.py",
        "through/kept.py",
    }


def test_code_corpus_seals_a_directory_whose_ignore_file_escapes(git_repo, tmp_path: Path) -> None:
    """A link out of the repository (or to an absolute path, or into `.git`) names a file HEAD does not hold, and
    a chain past MAX_LINK_HOPS (a loop) one HEAD cannot answer for: that directory and everything under it are
    out of scope, so the cloud holds less than the local index, never more."""
    repo = git_repo()
    commit_all(
        repo,
        {
            "a.py": "a = 1\n",
            "esc/x.py": "x = 1\n",
            "esc/deep/y.py": "y = 1\n",
            "abs/z.py": "z = 1\n",
            "back/w.py": "w = 1\n",
            "gitdir/u.py": "u = 1\n",
            "gitcase/t.py": "t = 1\n",
            "gitback/s.py": "s = 1\n",
            "loop/r.py": "r = 1\n",
            "other/v.py": "v = 1\n",
        },
    )
    link(repo, "esc/.gitignore", "../../outside.ignore")
    link(repo, "abs/.sembleignore", "/etc/hosts")
    link(repo, "back/.gitignore", f"../../{repo.root.name}/other/v.py")  # out and back in: still out
    link(repo, "gitdir/.gitignore", "../.git/info/exclude")  # a checkout reads it; HEAD never holds it
    link(repo, "gitcase/.gitignore", "../.GIT/info/exclude")  # the same file on a case-insensitive checkout
    link(repo, "gitback/.sembleignore", "../.git/../other/v.py")  # through `.git` and back: still sealed
    link(repo, "loop/.gitignore", "other")  # a loop: past MAX_LINK_HOPS (ELOOP in a checkout)
    link(repo, "loop/other", ".gitignore")
    commit_all(repo, {}, "escaping links")
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)
    assert scope(corpus, repo) == {"a.py", "other/v.py"}
    assert not corpus.in_scope("esc/deep/new.py")


def test_code_corpus_ignore_names_are_case_insensitive(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    commit_all(repo, {"cased/.GitIgnore": "drop.py\n", "cased/drop.py": "d\n", "cased/keep.py": "k\n"})
    # two spellings in one directory, as only a case-sensitive host can commit them: which one a case-insensitive
    # checkout holds is unknowable, so the directory is sealed
    rules = tmp_path / "rules.txt"
    rules.write_text("nothing.py\n", encoding="utf-8")
    blob = repo.git("hash-object", "-w", str(rules)).strip()
    for name in (".gitignore", ".GITIGNORE"):
        repo.git("update-index", "--add", "--cacheinfo", f"100644,{blob},twice/{name}")
    repo.write("twice/a.py", "a\n")
    repo.write("plain.py", "p\n")
    repo.git("add", "twice/a.py", "plain.py")
    repo.git("commit", "-q", "-m", "two spellings")
    assert {".gitignore", ".GITIGNORE"} <= {p.rpartition("/")[2] for p in head_files(repo)}
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)
    assert scope(corpus, repo) == {"cased/keep.py", "plain.py"}


def test_code_corpus_deny_list(git_repo, tmp_path: Path) -> None:
    assert CODE_DENY == (
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
    denied = (
        "prod.tfvars",
        "deploy/key.pem",
        ".env.local",
        "cfg/aws_credentials.json",
        "Secrets.swift",
        "ID_RSA.pub",
        "app/secretary.py",  # `*secret*` is deliberately broad
        "infra/vars.tfvars.json",
        "certs/server.KEY",
        "keys/store.p12",
        "keys/store.pfx",
        "keys/store.jks",
        "keys/release.keystore",
        ".env",
        "conf/prod.env",
        "home/id_ed25519",
        "home/id_ecdsa.pub",
        "lib/client_secrets.py",
        "lib/credential_store.py",
        ".npmrc",
        ".pypirc",
        ".netrc",
    )
    for path in denied:
        assert corpora._denied(path), path
    for path in ("app/main.py", "deploy/main.tf", "pkg/keyboard.py", "envoy.py", "src/rsa.py"):
        assert not corpora._denied(path), path

    repo = git_repo()
    commit_all(repo, {**{path: "x = 1\n" for path in denied}, "app/main.py": "x\n", "deploy/main.tf": "x\n"})
    corpus = CodeCloudCorpus(make_cfg(tmp_path, content=("all",)), repo.root)
    assert scope(corpus, repo) == {"app/main.py", "deploy/main.tf"}
    # without the deny list, these would be in: the list is what keeps them out
    walked = {p.relative_to(repo.root).as_posix() for p in walk_files(repo.root, get_extensions(content_types(("all",))))}
    assert {"prod.tfvars", "deploy/key.pem", "Secrets.swift", "app/secretary.py"} <= walked


def test_code_corpus_exclude_globs(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    commit_all(
        repo,
        {"generated/x.py": "x\n", "api/v1.pb.go": "package api\n", "api/v1.go": "package api\n", "src/gen.py": "x\n"},
    )
    corpus = CodeCloudCorpus(make_cfg(tmp_path, exclude=("generated/", "*.pb.go")), repo.root)
    assert scope(corpus, repo) == {"api/v1.go", "src/gen.py"}
    assert not corpus.in_scope("generated/deep/y.py")


# --- the code corpus: reading and cutting -------------------------------------------------------------


def test_code_readable_limits(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)
    assert CODE_MAX_FILE_BYTES == 1_000_000
    assert corpus.readable("a.py", b"a" * 1_000_000) == "a" * 1_000_000
    assert corpus.readable("a.py", b"a" * 1_000_001) is None
    assert corpus.readable("a.py", b"x = 1\0\n") is None
    assert corpus.readable("a.py", b"x = '\xff'\n") is None
    assert corpus.readable("a.py", "x = 'é'\n".encode()) == "x = 'é'\n"


def test_code_readable_ignores_sembles_env_override(git_repo, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import semble.index.files

    monkeypatch.setattr(semble.index.files, "MAX_FILE_BYTES", 10)  # what SEMBLE_MAX_FILE_BYTES=10 would set
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    assert corpus.readable("a.py", b"a" * 1_000_000) is not None


THREE_FUNCTIONS = '''"""Refund helpers."""


def round_half_up(amount: float) -> int:
    """Round an amount in cents half up, as the refund policy says, never half to even."""
    cents = int(amount * 100)
    remainder = amount * 100 - cents
    if remainder >= 0.5:
        cents += 1
    return cents


def refund_total(lines: list[float]) -> int:
    """The refund total is the sum of the rounded line amounts, never the rounded sum of the lines."""
    total = 0
    for line in lines:
        total += round_half_up(line)
    return total


def tax_for(total: int, rate: float) -> int:
    """The tax on a refund total, rounded half up to the nearest cent before any discount applies."""
    tax = total * rate
    if tax < 0:
        raise ValueError("a negative tax is not a refund")
    return round_half_up(tax / 100)
'''


def test_code_corpus_chunks_are_sembles(git_repo, tmp_path: Path) -> None:
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    chunks = corpus.chunks("pay/refunds.py", THREE_FUNCTIONS)
    theirs = chunk_source(THREE_FUNCTIONS, "pay/refunds.py", "python")
    assert len(theirs) > 1
    assert [(c.start_line, c.end_line) for c in chunks] == [(c.start_line, c.end_line) for c in theirs]
    assert chunks == [
        CloudChunk(ordinal, c.start_line, c.end_line, (), c.content) for ordinal, c in enumerate(theirs)
    ]
    assert corpus.fields("pay/refunds.py", chunks[0]) == {"language": "python", "headingPath": []}
    assert corpus.fields("ios/View.swift", chunks[0]) == {"language": "swift", "headingPath": []}
    assert corpus.chunks("empty.py", "\n\n") == []


SWIFT = """import Foundation

struct Refund {
    let amount: Double
    let reason: String

    func roundedCents() -> Int {
        let cents = amount * 100
        return Int(cents.rounded(.toNearestOrAwayFromZero))
    }
}

final class RefundService {
    private var refunds: [Refund] = []

    func add(_ refund: Refund) {
        refunds.append(refund)
    }

    func total() -> Int {
        refunds.reduce(0) { sum, refund in sum + refund.roundedCents() }
    }

    func describe() -> String {
        refunds.map { "\\($0.reason): \\($0.roundedCents())" }.joined(separator: ", ")
    }
}

enum RefundError: Error {
    case negativeAmount
    case missingReason
    case overLimit(limit: Int)
}

func validate(_ refund: Refund, limit: Int) throws {
    if refund.amount < 0 { throw RefundError.negativeAmount }
    if refund.reason.isEmpty { throw RefundError.missingReason }
    if refund.roundedCents() > limit { throw RefundError.overLimit(limit: limit) }
}
"""

TYPESCRIPT = """export interface Refund {
  amount: number;
  reason: string;
}

export function roundedCents(refund: Refund): number {
  const cents = refund.amount * 100;
  return Math.round(cents);
}

export class RefundService {
  private refunds: Refund[] = [];

  add(refund: Refund): void {
    this.refunds.push(refund);
  }

  total(): number {
    return this.refunds.reduce((sum, refund) => sum + roundedCents(refund), 0);
  }

  describe(): string {
    return this.refunds.map((r) => `${r.reason}: ${roundedCents(r)}`).join(", ");
  }
}

export function validate(refund: Refund, limit: number): void {
  if (refund.amount < 0) {
    throw new Error("negative amount");
  }
  if (!refund.reason) {
    throw new Error("missing reason");
  }
  if (roundedCents(refund) > limit) {
    throw new Error(`over the limit of ${limit}`);
  }
}
"""

GO = """package refunds

import (
	"errors"
	"fmt"
	"math"
	"strings"
)

type Refund struct {
	Amount float64
	Reason string
}

func (r Refund) RoundedCents() int {
	return int(math.Round(r.Amount * 100))
}

type Service struct {
	refunds []Refund
}

func (s *Service) Add(r Refund) {
	s.refunds = append(s.refunds, r)
}

func (s *Service) Total() int {
	total := 0
	for _, r := range s.refunds {
		total += r.RoundedCents()
	}
	return total
}

func (s *Service) Describe() string {
	parts := make([]string, 0, len(s.refunds))
	for _, r := range s.refunds {
		parts = append(parts, fmt.Sprintf("%s: %d", r.Reason, r.RoundedCents()))
	}
	return strings.Join(parts, ", ")
}

func Validate(r Refund, limit int) error {
	if r.Amount < 0 {
		return errors.New("negative amount")
	}
	if r.Reason == "" {
		return errors.New("missing reason")
	}
	if r.RoundedCents() > limit {
		return fmt.Errorf("over the limit of %d", limit)
	}
	return nil
}
"""

KOTLIN = """package refunds

import kotlin.math.roundToInt

data class Refund(val amount: Double, val reason: String) {
    fun roundedCents(): Int = (amount * 100).roundToInt()
}

class RefundService {
    private val refunds = mutableListOf<Refund>()

    fun add(refund: Refund) {
        refunds.add(refund)
    }

    fun total(): Int = refunds.sumOf { it.roundedCents() }

    fun describe(): String = refunds.joinToString(", ") { "${it.reason}: ${it.roundedCents()}" }
}

sealed class RefundError(message: String) : Exception(message) {
    object NegativeAmount : RefundError("negative amount")
    object MissingReason : RefundError("missing reason")
    class OverLimit(limit: Int) : RefundError("over the limit of $limit")
}

fun validate(refund: Refund, limit: Int) {
    if (refund.amount < 0) throw RefundError.NegativeAmount
    if (refund.reason.isEmpty()) throw RefundError.MissingReason
    if (refund.roundedCents() > limit) throw RefundError.OverLimit(limit)
}
"""

SHELL = """#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: refunds.sh <command> [args]" >&2
  echo "commands: total, describe, validate" >&2
  exit 2
}

round_cents() {
  local amount="$1"
  printf '%.0f\\n' "$(echo "$amount * 100" | bc -l)"
}

total() {
  local sum=0
  while read -r amount _; do
    sum=$((sum + $(round_cents "$amount")))
  done
  echo "$sum"
}

describe() {
  while read -r amount reason; do
    echo "$reason: $(round_cents "$amount")"
  done
}

validate() {
  local limit="$1"
  while read -r amount reason; do
    if [ -z "$reason" ]; then
      echo "missing reason" >&2
      return 1
    fi
    if [ "$(round_cents "$amount")" -gt "$limit" ]; then
      echo "over the limit of $limit" >&2
      return 1
    fi
  done
}

case "${1:-}" in
  total) total ;;
  describe) describe ;;
  validate) shift; validate "$@" ;;
  *) usage ;;
esac
"""

# Each file's (start, end) lines, written out: a semble patch that moves a cut fails here, by language, and the
# chunker id is then raised by hand (`semble-0.7.r2`) so the next catch-up re-embeds instead of mixing cuts.
PINNED = {
    "pay/refunds.py": (THREE_FUNCTIONS, "python", [(1, 18), (21, 26)]),
    "ios/Refund.swift": (SWIFT, "swift", [(1, 33), (35, 39)]),
    "web/refund.ts": (TYPESCRIPT, "typescript", [(1, 25), (27, 37)]),
    "svc/refunds.go": (GO, "go", [(1, 41), (43, 54)]),
    "android/Refund.kt": (KOTLIN, "kotlin", [(1, 25), (27, 31)]),
    "bin/refunds.sh": (SHELL, "bash", [(1, 41), (43, 48)]),
}


@pytest.mark.parametrize("path", sorted(PINNED))
def test_code_chunk_boundaries_pinned(git_repo, tmp_path: Path, path: str) -> None:
    text, language, expected = PINNED[path]
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    assert detect_language(PurePosixPath(path)) == language
    assert corpus.fields(path, corpus.chunks(path, text)[0])["language"] == language
    assert [(c.start_line, c.end_line) for c in corpus.chunks(path, text)] == expected


def test_code_chunk_text_is_capped_at_6000(git_repo, tmp_path: Path) -> None:
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    text = 'def big():\n    x = "' + "a" * 7000 + '"\n    return x\n'
    chunks = corpus.chunks("big.py", text)
    theirs = chunk_source(text, "big.py", "python")
    assert max(len(c.content) for c in theirs) > 6000
    assert [c.text for c in chunks] == [c.content[:6000] for c in theirs]
    assert max(len(c.text) for c in chunks) == 6000


# --- stamps, rewrites, the list of corpora -------------------------------------------------------------


def test_code_stamp_is_major_minor(git_repo, tmp_path: Path) -> None:
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    major, minor = semble.__version__.split(".")[:2]
    assert corpus.chunker_stamp() == {"chunker_id": f"semble-{major}.{minor}"} == {"chunker_id": CHUNKER_ID}

    stamp = _parse_stamp({"built_from_commit": "c" * 40, "embedder_id": EMBEDDER_ID, "chunker_id": CHUNKER_ID})
    assert stamp is not None and stamp.chunker_id == CHUNKER_ID and stamp.chunker_version is None
    assert corpus.chunker_matches(stamp)
    newer = _parse_stamp({"built_from_commit": "c" * 40, "embedder_id": EMBEDDER_ID, "chunker_id": "semble-0.8"})
    assert newer is not None and not corpus.chunker_matches(newer)
    unnamed = _parse_stamp({"built_from_commit": "c" * 40, "embedder_id": EMBEDDER_ID})
    assert unnamed is not None and unnamed.chunker_id is None and not corpus.chunker_matches(unnamed)
    # a docs stamp is parsed as before: no chunker id
    docs = _parse_stamp({"built_from_commit": "c" * 40, "chunker_version": CHUNKER_VERSION})
    assert docs == CorpusStamp("c" * 40, None, None, None, None, CHUNKER_VERSION, None)


def test_code_resumable_current(git_repo, tmp_path: Path) -> None:
    corpus = CodeCloudCorpus(make_cfg(tmp_path), git_repo().root)
    chunk0 = {"fileSha256": "s", "chunkerId": CHUNKER_ID, "embedderId": EMBEDDER_ID, "startLine": 1, "endLine": 3}
    assert corpus.resumable_current(chunk0, "s") is True
    assert corpus.resumable_current(chunk0, "other sha") is False
    assert corpus.resumable_current({**chunk0, "chunkerId": "semble-0.6"}, "s") is False
    assert corpus.resumable_current({**chunk0, "embedderId": "vertex:other/768"}, "s") is False
    assert corpus.resumable_current({k: v for k, v in chunk0.items() if k != "embedderId"}, "s") is False
    assert corpus.resumable_current(None, "s") is False


def test_corpora_for_order_and_only(git_repo, tmp_path: Path) -> None:
    top = git_repo().root
    both = make_cfg(tmp_path)
    assert [c.name for c in corpora_for(both, top)] == ["docs", "code"]
    assert [type(c) for c in corpora_for(both, top)] == [DocsCloudCorpus, CodeCloudCorpus]
    assert [c.name for c in corpora_for(both, top, "docs")] == ["docs"]
    assert [c.name for c in corpora_for(both, top, "code")] == ["code"]
    docs_only = make_cfg(tmp_path, code=False)
    assert [c.name for c in corpora_for(docs_only, top)] == ["docs"]
    assert corpora_for(docs_only, top, "code") == []
    code_only = make_cfg(tmp_path, docs=False)
    assert [c.name for c in corpora_for(code_only, top)] == ["code"]
    assert corpora_for(code_only, top, "docs") == []
    no_cloud = make_cfg(tmp_path)
    no_cloud = Config(no_cloud.docs, no_cloud.code, None, no_cloud.search, no_cloud.required, no_cloud.requires)
    assert corpora_for(no_cloud, top) == []
    with pytest.raises(ValueError, match="corpus"):
        corpora_for(both, top, "everything")


def test_content_types_keeps_its_old_name() -> None:
    assert _content_types is content_types
    assert len(content_types(("all",))) == 3


def test_code_scope_fails_closed_when_git_fails(git_repo, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = git_repo()
    commit_all(repo, {".gitignore": "private/\n", "a.py": "a\n"})
    corpus = CodeCloudCorpus(make_cfg(tmp_path), repo.root)

    def broken(*_: Any, **__: Any) -> Any:
        raise GitError("git ls-tree failed")

    monkeypatch.setattr(corpora, "git", broken)
    with pytest.raises(GitError):  # never "no ignore rules": that would widen what is sent
        corpus.in_scope("a.py")
