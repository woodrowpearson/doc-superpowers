"""The cloud write path: base guard, lease, catch-up and full runs, per-file sha check, deletes, orphans, stamp.

Everything runs against `FakeGenai` and `FakeFirestore` (tests/fakes.py) and throwaway git repositories: no
network, no credentials. The google libraries are needed for the real pieces the indexer builds around the
fakes (`firestore.transactional`, `Vector`, `FieldFilter`, `SERVER_TIMESTAMP`), so the module needs the
cloud extra.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import pytest
from fakes import FakeFirestore, FakeGenai

import doc_search.cloud.write as write
from doc_search.cloud import CloudUnavailable
from doc_search.cloud.vertex import VertexEmbedder
from doc_search.cloud.write import BaseRefError, CloudIndexer, IndexReport, LeaseHeld
from doc_search.config import Config, load_config
from doc_search.repo import GitError

pytest.importorskip("google.genai")
firestore = pytest.importorskip("google.cloud.firestore")
Vector = pytest.importorskip("google.cloud.firestore_v1.vector").Vector
Aborted = pytest.importorskip("google.api_core.exceptions").Aborted

SPEC_PATH = "docs/specs/SPEC-PAY-004.md"
GUIDE_PATH = "docs/guides/setup.md"
ADR_PATH = "docs/adr/ADR-001.md"
README_PATH = "README.md"

SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

## Rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""
GUIDE = "# Setup\n\nInstall the tool and run it.\n"
ADR = "---\ntype: ADR\n---\n# Use Firestore\n\nWe store chunks in Firestore.\n"
README = "# Project\n\nA payment service.\n"

DOCS = {SPEC_PATH: SPEC, GUIDE_PATH: GUIDE, ADR_PATH: ADR, README_PATH: README}
FIELDS = {
    "path",
    "chunkIndex",
    "text",
    "embedding",
    "headingPath",
    "lastIndexedAt",
    "fileSha256",
    "docType",
    "startLine",
    "endLine",
}
LEASE_PATH = ("corpus_meta", "catch_up_lease")
EMBEDDER_ID = "vertex:gemini-embedding-001/768"


class Clock:
    """The indexer's wall clock, in epoch seconds."""

    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now

    def at(self, offset: float = 0.0) -> datetime:
        return datetime.fromtimestamp(self.now + offset, tz=UTC)


def no_sleep(_: float) -> None:
    pass


@dataclass
class World:
    repo: Any
    cfg: Config
    fs: FakeFirestore
    genai: FakeGenai
    clock: Clock
    indexer: CloudIndexer
    head: str

    def run(self, mode: str = "full", **kw: Any) -> IndexReport:
        return self.indexer.run(mode, **kw)  # type: ignore[arg-type]

    def chunks(self, path: str) -> list[dict[str, Any]]:
        docs = self.fs.collection("doc_chunks").docs.values()
        return sorted((d for d in docs if d["path"] == path), key=lambda d: d["chunkIndex"])

    def paths(self) -> set[str]:
        return {d["path"] for d in self.fs.collection("doc_chunks").docs.values()}

    def stamp(self) -> dict[str, Any] | None:
        return self.fs.collection("corpus_meta").docs.get("index")

    def lease(self) -> dict[str, Any] | None:
        return self.fs.collection(LEASE_PATH[0]).docs.get(LEASE_PATH[1])

    def embedded(self) -> list[str]:
        """Every text sent to the embedder, in order."""
        return [text for call in self.genai.calls if not call.failed for text in call.texts]

    def commit(self, files: dict[str, str | None], msg: str = "change") -> str:
        for path, text in files.items():
            if text is None:
                (self.repo.root / path).unlink()
            else:
                self.repo.write(path, text)
        self.head = self.repo.commit(msg)
        return self.head


def make_world(
    git_repo, files: dict[str, str] | None = None, *, base_ref: str | None = "main", holder: str = "a:1"
) -> World:
    repo = git_repo()
    cloud: dict[str, Any] = {"vertex": {"project": "p"}, "firestore": {"project": "p", "base_ref": base_ref}}
    repo.write("docs/search/config.json", json.dumps({"cloud": cloud}))
    for path, text in (DOCS if files is None else files).items():
        repo.write(path, text)
    head = repo.commit("seed")
    cfg = load_config(repo.root, {})
    assert cfg is not None and cfg.cloud is not None
    fs, genai, clock = FakeFirestore(), FakeGenai(), Clock()
    embedder = VertexEmbedder(cfg.cloud, client=genai, sleep=no_sleep)
    indexer = CloudIndexer(cfg, repo.root, embedder, client=fs, clock=clock, holder=holder)
    return World(repo, cfg, fs, genai, clock, indexer, head)


# --- the base guard ------------------------------------------------------------------------------------


def test_refuses_off_base(git_repo) -> None:
    w = make_world(git_repo)
    w.repo.git("checkout", "-q", "-b", "feature")
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"}, "feature work")

    with pytest.raises(BaseRefError, match=r"not.*main"):
        w.run("full")

    assert w.fs.collections == {} or all(not c.docs for c in w.fs.collections.values()), "nothing was written"
    assert w.fs.calls["transaction"] == 0 and w.genai.calls == [], "not even the lease or an embedding"

    report = w.run("full", allow_off_base=True)

    assert report.stamped and report.stamp == w.head
    assert w.stamp()["built_from_commit"] == w.head


def test_head_may_be_base_or_behind_it(git_repo) -> None:
    w = make_world(git_repo)
    first = w.head
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    assert w.run("full").stamp == w.head, "HEAD is the base"

    w.repo.git("checkout", "-q", "--detach", first)
    report = w.run("full")

    assert report.stamp == first, "HEAD is an ancestor of the base"


def test_base_ref_must_resolve(git_repo) -> None:
    w = make_world(git_repo, base_ref="origin/trunk")

    with pytest.raises(BaseRefError, match=r"origin/trunk.*fetch"):
        w.run("full")
    assert w.genai.calls == []

    # no configured base_ref and no origin/HEAD either
    w = make_world(git_repo, base_ref=None)
    with pytest.raises(BaseRefError, match="base_ref"):
        w.run("full")

    # origin/HEAD names the default branch
    w.repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
    w.repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    assert w.run("full").stamped


def test_allow_off_base_does_not_need_a_resolvable_base(git_repo) -> None:
    w = make_world(git_repo, base_ref=None)

    assert w.run("full", allow_off_base=True).stamped


# --- the lease -----------------------------------------------------------------------------------------


def test_lease_held_and_expired(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.put(
        "corpus_meta",
        "catch_up_lease",
        {"holder": "other:9", "acquired_at": w.clock.at(-60), "expires_at": w.clock.at(+600)},
    )

    with pytest.raises(LeaseHeld) as held:
        w.run("full")

    assert held.value.holder == "other:9" and held.value.expires_at == w.clock.at(+600)
    assert "other:9" in str(held.value)
    assert w.paths() == set() and w.genai.calls == [], "nothing was indexed"
    assert w.lease()["holder"] == "other:9", "and the other holder's lease is untouched"

    # a lease whose expiry has passed is free
    w.clock.now += 601
    during: list[dict[str, Any] | None] = []
    w.genai.on_call = lambda: during.append(w.lease())

    report = w.run("full")

    assert report.stamped and w.paths() == set(DOCS)
    assert during and during[0]["holder"] == "a:1", "the lease is held while the run works"
    assert during[0]["expires_at"] == w.clock.at(+1800), "for 1800 seconds"
    assert set(during[0]) == {"holder", "acquired_at", "expires_at"}
    assert w.lease() is None, "and released at the end"


def test_a_lease_without_a_usable_expiry_is_live(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.put("corpus_meta", "catch_up_lease", {"holder": "other:9"})

    with pytest.raises(LeaseHeld) as held:
        w.run("full")

    assert held.value.holder == "other:9" and held.value.expires_at is None


def test_own_lease_is_refreshed(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.put("corpus_meta", "catch_up_lease", {"holder": "a:1", "expires_at": w.clock.at(+600)})

    assert w.run("full").stamped
    assert w.lease() is None


def test_lease_is_released_when_the_run_dies(git_repo) -> None:
    w = make_world(git_repo)
    w.genai.script = [CloudUnavailable("no credentials (run gcloud auth application-default login)")]

    with pytest.raises(CloudUnavailable, match="no credentials"):
        w.run("full")

    assert w.lease() is None, "released in finally"
    assert w.stamp() is None


def test_release_leaves_a_lease_someone_else_took(git_repo) -> None:
    w = make_world(git_repo)

    def expire_and_steal() -> None:
        w.fs.put("corpus_meta", "catch_up_lease", {"holder": "b:2", "expires_at": w.clock.at(+900)})

    w.genai.on_call = expire_and_steal
    w.run("full")

    assert w.lease()["holder"] == "b:2"


def test_lease_transaction_retries_on_contention(git_repo) -> None:
    """The lease is a real `@firestore.transactional` over the fake's transaction protocol."""
    w = make_world(git_repo)
    w.fs.commit_conflicts = [Aborted("contention")]

    report = w.run("full")

    assert report.stamped
    assert w.fs.transaction_begins[:2] == [None, b"txn-1"], "the retry names the first attempt"
    assert w.fs.calls["transaction_begin"] >= 3 and w.fs.calls["transaction_commit"] == 2, (
        "two commits: acquire, release"
    )


# --- what a run writes ---------------------------------------------------------------------------------


def test_schema_fields_exact(git_repo) -> None:
    w = make_world(git_repo)
    report = w.run("full")

    assert report == IndexReport(
        "full",
        files_written=4,
        files_deleted=0,
        orphans_removed=0,
        files_failed={},
        stamped=True,
        stamp=w.head,
        files_skipped=0,
        chunks_written=5,
    )
    docs = w.fs.collection("doc_chunks").docs
    assert len(docs) == 5
    for doc in docs.values():
        assert set(doc) == FIELDS, "exactly the ten fields"
    first, second = w.chunks(SPEC_PATH)
    assert isinstance(first["embedding"], Vector) and len(list(first["embedding"])) == 768
    assert w.genai.calls[0].dims == 768 and w.genai.calls[0].task_type == "RETRIEVAL_DOCUMENT"
    assert first["path"] == SPEC_PATH and (first["chunkIndex"], second["chunkIndex"]) == (0, 1)
    assert first["text"] == "# Refunds\n\nRefund rounding rules for the payment service, SPEC-PAY-004."
    assert second["text"].startswith("## Rounding\n")
    assert (first["startLine"], first["endLine"]) == (4, 6), "true line numbers: the front matter counts"
    assert (second["startLine"], second["endLine"]) == (8, 11)
    assert first["headingPath"] == ["Refunds"] and second["headingPath"] == ["Refunds", "Rounding"]
    assert first["fileSha256"] == hashlib.sha256(SPEC.encode()).hexdigest() == second["fileSha256"]
    assert first["docType"] == "spec" and w.chunks(GUIDE_PATH)[0]["docType"] == "guide"
    assert w.chunks(ADR_PATH)[0]["docType"] == "adr", "front matter says ADR; the cloud stores it lowercase"
    assert w.chunks(README_PATH)[0]["docType"] == "other"
    assert first["lastIndexedAt"] == w.fs.server_time, "a server timestamp"
    assert all(isinstance(d["chunkIndex"], int) and isinstance(d["startLine"], int) for d in docs.values())

    stamp = w.stamp()
    assert stamp == {
        "built_from_commit": w.head,
        "built_at": w.fs.server_time,
        "mode": "full",
        "embedder_id": EMBEDDER_ID,
    }
    # the sha is of the file's bytes: a file with CRLF line ends hashes as it is, not as the chunker reads it
    w.commit({GUIDE_PATH: "# Setup\r\n\r\nInstall it.\r\n"})
    w.run("full")
    (guide,) = w.chunks(GUIDE_PATH)
    assert guide["fileSha256"] == hashlib.sha256(b"# Setup\r\n\r\nInstall it.\r\n").hexdigest()
    assert guide["text"] == "# Setup\n\nInstall it."


def test_chunk_ids_are_stable_and_a_rewrite_leaves_no_stale_chunks(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    ids = set(w.fs.collection("doc_chunks").docs)
    assert len(ids) == 5

    w.commit({SPEC_PATH: SPEC.replace("never the rounded sum", "never anything else")})
    report = w.run("catch-up")

    assert report.files_written == 1 and set(w.fs.collection("doc_chunks").docs) == ids, "same ids, overwritten"

    w.commit({SPEC_PATH: "# Refunds\n\nShort now.\n"})
    w.run("catch-up")

    assert len(w.chunks(SPEC_PATH)) == 1 and len(w.fs.collection("doc_chunks").docs) == 4, "the second chunk is gone"
    assert w.chunks(SPEC_PATH)[0]["text"] == "# Refunds\n\nShort now."


def test_full_then_catch_up_only_changed(git_repo) -> None:
    w = make_world(git_repo)
    first = w.run("full")
    assert first.files_written == 4 and w.stamp()["mode"] == "full"
    embedded = len(w.genai.calls)

    w.commit(
        {
            GUIDE_PATH: GUIDE + "\nA new paragraph about caching.\n",  # changed
            "docs/guides/new.md": "# New\n\nBrand new guide.\n",  # added
            ADR_PATH: None,  # deleted
            "src/code.py": "x = 1\n",  # not a doc
        }
    )

    report = w.run("catch-up")

    assert (report.mode, report.files_written, report.files_deleted, report.orphans_removed) == ("catch-up", 2, 1, 0)
    assert report.files_failed == {} and report.stamped and report.stamp == w.head
    assert w.paths() == {SPEC_PATH, GUIDE_PATH, "docs/guides/new.md", README_PATH}
    new_texts = [text for call in w.genai.calls[embedded:] for text in call.texts]
    assert len(new_texts) == 2 and any("caching" in t for t in new_texts) and any("Brand new" in t for t in new_texts)
    assert w.stamp()["built_from_commit"] == w.head and w.stamp()["mode"] == "catch-up"

    nothing = w.run("catch-up")
    assert (nothing.files_written, nothing.files_deleted, nothing.stamped) == (0, 0, True)


def test_catch_up_falls_back_without_stamp(git_repo) -> None:
    w = make_world(git_repo)

    report = w.run("catch-up")

    assert report.mode == "full", "no stamp: a full run"
    assert report.files_written == 4 and w.stamp()["mode"] == "full"

    # a stamp this tree does not have (or one that is not an ancestor of HEAD) is no stamp either
    w.fs.set_stamp("0123456789abcdef0123456789abcdef01234567", embedder_id=EMBEDDER_ID)
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    again = w.run("catch-up")
    assert again.mode == "full" and again.files_written == 1 and again.files_skipped == 3

    w.repo.git("checkout", "-q", "-b", "side", "HEAD~1")
    w.commit({"docs/side.md": "# Side\n\nOn a side branch.\n"}, "side")
    side = w.head
    w.repo.git("checkout", "-q", "main")
    w.fs.set_stamp(side, embedder_id=EMBEDDER_ID)
    assert w.run("catch-up").mode == "full", "a stamp on a branch HEAD does not contain"


def test_catch_up_from_a_stamp_of_another_embedder_is_a_full_rebuild(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    calls = len(w.genai.calls)
    w.fs.set_stamp(w.head, embedder_id="vertex:gemini-embedding-001/256")

    report = w.run("catch-up")

    assert report.mode == "full" and report.files_written == 4 and report.files_skipped == 0, "every vector is replaced"
    assert len(w.genai.calls) > calls
    assert w.stamp()["embedder_id"] == EMBEDDER_ID

    # a stamp that names no embedder (abundance's) is taken as compatible
    w.fs.put("corpus_meta", "index", {"built_from_commit": w.head, "mode": "catch-up"})
    assert w.run("catch-up").mode == "catch-up"


def test_same_sha_skipped(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    calls = len(w.genai.calls)

    report = w.run("full")

    assert (report.files_written, report.files_skipped, report.chunks_written) == (0, 4, 0)
    assert len(w.genai.calls) == calls, "no embedding for an unchanged file"
    assert report.stamped, "an unchanged corpus is still stamped"

    # abundance's chunks carry no line range: those files are rewritten, once
    legacy = w.chunks(README_PATH)[0]
    docs = w.fs.collection("doc_chunks").docs
    old_id = next(i for i, d in docs.items() if d["path"] == README_PATH)
    del docs[old_id]
    w.fs.put(
        "doc_chunks", "AUTO_ID_FROM_ABUNDANCE", {k: v for k, v in legacy.items() if k not in ("startLine", "endLine")}
    )

    report = w.run("full")

    assert (report.files_written, report.files_skipped) == (1, 3)
    assert "AUTO_ID_FROM_ABUNDANCE" not in docs and len(w.chunks(README_PATH)) == 1
    assert "startLine" in w.chunks(README_PATH)[0]


def test_delete_requires_ls_tree(git_repo, monkeypatch: pytest.MonkeyPatch) -> None:
    w = make_world(git_repo)
    w.run("full")
    old_stamp = dict(w.stamp())
    w.commit({GUIDE_PATH: None})

    real_git = write.git

    def git_that_cannot_say(top, *args):
        if args[:1] == ("ls-tree",) and "--" in args:
            raise GitError("git ls-tree failed (128): cannot read the tree")
        return real_git(top, *args)

    with monkeypatch.context() as patch:
        patch.setattr(write, "git", git_that_cannot_say)
        report = w.run("catch-up")

    assert GUIDE_PATH in report.files_failed and "ls-tree" in report.files_failed[GUIDE_PATH]
    assert report.files_deleted == 0 and w.chunks(GUIDE_PATH), "unknown is never read as deleted"
    assert not report.stamped and w.stamp() == old_stamp

    report = w.run("catch-up")

    assert report.files_deleted == 1 and not w.chunks(GUIDE_PATH) and report.stamped


def test_indexes_head_not_the_working_tree(git_repo) -> None:
    w = make_world(git_repo)
    w.repo.write(GUIDE_PATH, "# Setup\n\nUNCOMMITTED edit.\n")  # modified, not committed
    (w.repo.root / README_PATH).unlink()  # removed from the working tree, still in HEAD
    w.repo.write("docs/untracked.md", "# Untracked\n\nNot in any commit.\n")

    report = w.run("full")

    assert report.stamped and report.files_failed == {}
    assert w.paths() == set(DOCS), "what HEAD has, and nothing it does not"
    assert w.chunks(GUIDE_PATH)[0]["text"] == "# Setup\n\nInstall the tool and run it."
    assert w.chunks(README_PATH), "a file deleted only in the working tree is not deleted from the cloud"


def test_orphans_reconciled(git_repo) -> None:
    w = make_world(git_repo, {**DOCS, "docs/archive/old.md": "# Old\n\nArchived.\n"})
    w.fs.add_chunk("docs/gone.md", "a doc deleted long ago", doc_type="spec")
    w.fs.add_chunk("docs/also-gone.md", "another one", index=0)
    w.fs.add_chunk("docs/also-gone.md", "another one, second chunk", index=1)
    w.fs.add_chunk("docs/archive/old.md", "archived but still in the tree", doc_type="archive")
    scans = w.fs.calls["stream"]

    report = w.run("catch-up")

    assert report.mode == "full" and report.orphans_removed == 2, "no stamp: the catch-up became a full run"
    assert w.paths() == set(DOCS) | {"docs/archive/old.md"}, "an archived doc still exists: not an orphan"
    assert w.fs.calls["stream"] > scans

    # a real catch-up does not reconcile; --prune-orphans does, and only that
    w.fs.add_chunk("docs/gone-again.md", "gone")
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    assert w.run("catch-up").orphans_removed == 0 and "docs/gone-again.md" in w.paths()

    calls = len(w.genai.calls)
    stamp = dict(w.stamp())
    w.commit({GUIDE_PATH: GUIDE + "\nEven more.\n"})
    report = w.run("prune-orphans")

    assert (report.mode, report.orphans_removed, report.files_written) == ("prune-orphans", 1, 0)
    assert "docs/gone-again.md" not in w.paths()
    assert len(w.genai.calls) == calls, "pruning embeds nothing"
    assert not report.stamped and report.stamp is None and w.stamp() == stamp, (
        "and does not claim the corpus is current"
    )
    assert "Even more" not in w.chunks(GUIDE_PATH)[0]["text"], "a live doc is not touched by a prune"


def test_no_stamp_on_failure(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.set_stamp("0" * 40, embedder_id=EMBEDDER_ID)
    before = dict(w.stamp())
    w.genai.script = [ValueError("boom")]

    report = w.run("full")

    assert list(report.files_failed) == [README_PATH], "the first file by name"
    assert report.files_failed[README_PATH] == "ValueError: boom"
    assert not report.stamped and report.stamp is None and w.stamp() == before
    assert report.files_written == 3 and w.paths() == set(DOCS) - {README_PATH}, "the other files went through"
    assert w.lease() is None

    again = w.run("full")

    assert again.files_failed == {} and again.stamped and again.files_written == 1 and again.files_skipped == 3
    assert w.stamp()["built_from_commit"] == w.head


def test_a_failed_write_leaves_the_old_chunks_and_no_stamp(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    old = w.chunks(GUIDE_PATH)
    stamp = dict(w.stamp())
    w.commit({GUIDE_PATH: GUIDE + "\nMore text.\n"})
    w.fs.fail_once["batch_commit"] = OSError("deadline")

    report = w.run("catch-up")

    assert list(report.files_failed) == [GUIDE_PATH] and "OSError: deadline" in report.files_failed[GUIDE_PATH]
    assert w.chunks(GUIDE_PATH) == old and not report.stamped and w.stamp() == stamp

    assert w.run("catch-up").files_written == 1, "retried by the next run's range"


def test_unindexable_files_are_dropped_not_failed(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    assert w.chunks(GUIDE_PATH)
    (w.repo.root / GUIDE_PATH).write_bytes(b"# Setup\n\xff\xfe not utf-8\n")
    w.commit({"docs/guides/empty.md": "\n\n"})

    report = w.run("full")

    assert report.files_failed == {} and report.stamped, "a content defect would fail every run: it is not a failure"
    assert not w.chunks(GUIDE_PATH) and not w.chunks("docs/guides/empty.md")
    assert report.files_deleted == 1


def test_batches_hold_at_most_500_operations(git_repo) -> None:
    paragraph = "word " * 190  # one chunk each at the default target
    big = "\n\n".join(f"para{i} {paragraph}" for i in range(620)) + "\n"
    assert len(big.encode()) < 1 << 20
    w = make_world(git_repo, {"docs/big.md": big})

    report = w.run("full")

    assert report.chunks_written > 500 and len(w.chunks("docs/big.md")) == report.chunks_written
    assert w.fs.commit_sizes and max(w.fs.commit_sizes) <= 500
    assert [d["chunkIndex"] for d in w.chunks("docs/big.md")] == list(range(report.chunks_written))
    sets = [doc_id for commit in w.fs.commit_log for op, doc_id in commit if op == "set"]
    assert sets[-1] == write.chunk_id("docs/big.md", 0), "chunk 0 carries the sha the next run trusts: it commits last"
    assert sets[0] == write.chunk_id("docs/big.md", report.chunks_written - 1)

    w.fs.commit_sizes.clear()
    w.commit({"docs/big.md": "# Big\n\nNow short.\n"})
    w.run("catch-up")

    assert len(w.chunks("docs/big.md")) == 1 and max(w.fs.commit_sizes) <= 500
    assert sum(w.fs.commit_sizes) >= report.chunks_written, "every stale chunk was deleted, in several batches"


def test_construction_and_modes_are_checked(git_repo) -> None:
    w = make_world(git_repo)
    with pytest.raises(ValueError, match="mode"):
        w.run("everything")

    bare = load_config(w.repo.root, {})
    assert bare is not None
    (w.repo.root / "docs/search/config.json").write_text("{}", encoding="utf-8")
    off = load_config(w.repo.root, {})
    assert off is not None and off.cloud is None
    with pytest.raises(CloudUnavailable, match="cloud"):
        CloudIndexer(off, w.repo.root, VertexEmbedder(bare.cloud, client=w.genai))


def test_reads_and_commits_are_bounded(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")

    assert w.fs.request_options, "reads were recorded"
    for op, options in w.fs.request_options:
        assert options.get("timeout"), f"{op} has a timeout"
