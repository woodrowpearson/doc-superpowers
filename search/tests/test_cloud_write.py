"""The cloud write path: base guard, lease, catch-up and full runs, per-file sha check, deletes, orphans, stamp.

Everything runs against `FakeGenai` and `FakeFirestore` (tests/fakes.py) and throwaway git repositories: no
network, no credentials. The google libraries are needed for the real pieces the indexer builds around the
fakes (`firestore.transactional`, `Vector`, `FieldFilter`, `SERVER_TIMESTAMP`), so the module needs the
cloud extra.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import re
import socket
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from fakes import FakeFirestore, FakeGenai

import doc_search.cloud.write as write
from doc_search.chunker import CHUNKER_VERSION
from doc_search.cloud import CloudUnavailable
from doc_search.cloud.corpora import CODE_CHUNKER_ID, CodeCloudCorpus, DocsCloudCorpus
from doc_search.cloud.vertex import VertexEmbedder
from doc_search.cloud.write import (
    MODES,
    BaseRefError,
    CloudIndexer,
    CorpusRefused,
    IndexReport,
    LeaseHeld,
    LeaseLost,
    repo_identity,
)
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
UNKNOWN_COMMIT = "0123456789abcdef0123456789abcdef01234567"
GONE: Any = object()  # a stamp field to leave out


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

    @property
    def repo_id(self) -> str:
        """The root commit(s) of the test repository, as the stamp names them."""
        return self.repo.git("rev-list", "--max-parents=0", "HEAD").strip()

    def writes(self) -> tuple[int, int, int, int]:
        """What a run could change or spend: lease transactions, batches, documents set, embeddings."""
        calls = self.fs.calls
        return calls["transaction"], calls["batch_commit"], calls["document_set"], len(self.genai.calls)

    def steal_lease(self, holder: str = "b:2", *, wait: float = 0.0) -> None:
        """Another host takes the lease now (and `wait` seconds pass)."""
        self.fs.put("corpus_meta", "catch_up_lease", {"holder": holder, "expires_at": self.clock.at(+900)})
        self.clock.now += wait

    def commit(self, files: dict[str, str | None], msg: str = "change") -> str:
        for path, text in files.items():
            if text is None:
                (self.repo.root / path).unlink()
            else:
                self.repo.write(path, text)
        self.head = self.repo.commit(msg)
        return self.head


def put_stamp(w: World, commit: str | None = None, **fields: Any) -> None:
    """The corpus stamp as this indexer writes it. A field given as GONE is left out (an older indexer's stamp)."""
    doc = {
        "built_from_commit": commit or w.head,
        "built_at": w.fs.server_time,
        "mode": "full",
        "embedder_id": EMBEDDER_ID,
        "repo_id": w.repo_id,
        "chunker_version": CHUNKER_VERSION,
        **fields,
    }
    w.fs.put("corpus_meta", "index", {key: value for key, value in doc.items() if value is not GONE})


def make_world(
    git_repo, files: dict[str, str] | None = None, *, base_ref: str | None = "main", holder: str | None = "a:1"
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
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})

    assert w.run("full").stamp == w.head, "HEAD is the base"

    behind = make_world(git_repo)
    first = behind.head
    behind.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    behind.repo.git("checkout", "-q", "--detach", first)

    assert behind.run("full").stamp == first, "HEAD is an ancestor of the base"


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


def test_the_default_holder_is_host_pid_and_a_random_suffix(git_repo) -> None:
    """`host:pid` alone is not unique (containers reuse a pid on one host name): a random suffix makes it so."""
    seen: list[str] = []
    for _ in range(2):
        w = make_world(git_repo, holder=None)
        during: list[dict[str, Any] | None] = []
        w.genai.on_call = lambda w=w, during=during: during.append(w.lease())
        assert w.run("full").stamped
        seen.append(during[0]["holder"])

    for holder in seen:
        assert re.fullmatch(rf"{re.escape(socket.gethostname())}:{os.getpid()}:[0-9a-f]{{8}}", holder), holder
    assert seen[0] != seen[1], "two runs of one process are two holders"


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


def test_a_lease_lost_before_the_orphan_prune_stops_the_run(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.add_chunk("docs/gone.md", "a doc deleted long ago")
    w.genai.on_call = w.steal_lease

    with pytest.raises(LeaseLost) as lost:
        w.run("full")

    assert lost.value.holder == "b:2" and str(lost.value) == "lease lost to b:2"
    assert lost.value.report.files_written == 4 and not lost.value.report.stamped
    assert "docs/gone.md" in w.paths(), "the prune did not run"
    assert w.stamp() is None, "and nothing was stamped"
    assert w.lease()["holder"] == "b:2", "the release leaves a lease another host took"


def test_a_lease_lost_before_the_stamp_stops_the_run(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    stamp = dict(w.stamp())
    w.genai.on_call = w.steal_lease

    with pytest.raises(LeaseLost, match="lease lost to b:2"):
        w.run("catch-up")

    assert w.stamp() == stamp and w.lease()["holder"] == "b:2"


def test_a_lease_lost_mid_run_stops_the_remaining_writes(git_repo) -> None:
    w = make_world(git_repo)
    w.genai.on_call = lambda: w.steal_lease(wait=400)

    with pytest.raises(LeaseLost) as lost:
        w.run("full")

    assert lost.value.report.files_written == 0 and len(w.genai.calls) == 1, "the file in flight is not written"
    assert w.paths() == set() and w.stamp() is None


def test_the_lease_is_renewed_every_five_minutes(git_repo) -> None:
    w = make_world(git_repo)
    seen: list[tuple[float, datetime]] = []

    def tick() -> None:
        seen.append((w.clock.now, w.lease()["expires_at"]))
        w.clock.now += 400

    w.genai.on_call = tick
    assert w.run("full").stamped

    assert len(seen) == 4
    first_now, first_expiry = seen[0]
    assert first_expiry == datetime.fromtimestamp(first_now + 1800, UTC)
    for now, expiry in seen[1:]:
        assert expiry == datetime.fromtimestamp(now + 1800, UTC), "renewed before each file, 400 s after the last"

    quick = make_world(git_repo)
    seen_quick: list[datetime] = []

    def quick_tick() -> None:
        seen_quick.append(quick.lease()["expires_at"])
        quick.clock.now += 10

    quick.genai.on_call = quick_tick
    assert quick.run("full").stamped
    assert len(set(seen_quick)) == 1, "no renewal inside five minutes"


def test_a_vanished_lease_is_lost_not_taken_again(git_repo) -> None:
    """Only a holder deletes the document, so a missing one mid-run means another run held and released it."""
    w = make_world(git_repo)

    def vanish() -> None:
        w.fs.collection("corpus_meta").docs.pop("catch_up_lease", None)
        w.clock.now += 400

    w.genai.on_call = vanish

    with pytest.raises(LeaseLost, match="lease vanished; another run may have written") as lost:
        w.run("full")

    assert lost.value.holder is None
    assert lost.value.report.files_written == 0 and len(w.genai.calls) == 1, "the file in flight is not written"
    assert w.paths() == set() and w.stamp() is None
    assert w.lease() is None, "nothing stamped, and the lease document was not re-created"


def test_a_run_that_stalled_past_its_lease_stops(git_repo) -> None:
    """The laptop sleeps: our lease expires, host B takes it, catches up, stamps its newer HEAD and releases."""
    w = make_world(git_repo)
    newer = "f" * 40
    stamp_of_b: list[dict[str, Any]] = []

    def stall_while_b_runs() -> None:
        w.clock.now += 2000
        w.fs.set_stamp(newer, embedder_id=EMBEDDER_ID, repo_id=w.repo_id, chunker_version=CHUNKER_VERSION)
        w.fs.collection("corpus_meta").docs.pop("catch_up_lease", None)  # B released it
        stamp_of_b.append(dict(w.stamp()))

    w.genai.on_call = stall_while_b_runs

    with pytest.raises(LeaseLost) as lost:
        w.run("full")

    assert lost.value.holder is None and len(w.genai.calls) == 1, "no further embedding"
    assert lost.value.report.files_written == 0 and w.paths() == set(), "the file whose embed stalled is not written"
    assert stamp_of_b[0]["built_from_commit"] == newer and w.stamp() == stamp_of_b[0], "B's stamp is untouched"
    assert w.lease() is None

    # the same stall in the only file of a catch-up: its older chunks do not land under a newer stamp
    last = make_world(git_repo)
    last.run("full")
    old_text = last.chunks(GUIDE_PATH)[0]["text"]
    last.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    last.genai.on_call = lambda: (
        setattr(last.clock, "now", last.clock.now + 2000),
        last.fs.collection("corpus_meta").docs.pop("catch_up_lease", None),
    )
    before = dict(last.stamp())

    with pytest.raises(LeaseLost, match="lease vanished") as lost:
        last.run("catch-up")

    assert lost.value.report.files_written == 0 and last.chunks(GUIDE_PATH)[0]["text"] == old_text
    assert last.stamp() == before

    # the lease vanishing without the clock moving is caught by the check before the stamp
    quiet = make_world(git_repo)
    quiet.run("full")
    quiet.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    quiet.genai.on_call = lambda: quiet.fs.collection("corpus_meta").docs.pop("catch_up_lease", None)
    before = dict(quiet.stamp())

    with pytest.raises(LeaseLost, match="lease vanished") as lost:
        quiet.run("catch-up")

    assert lost.value.report.files_written == 1, "nothing told this run to look earlier"
    assert quiet.stamp() == before


def test_a_stall_before_a_purge_stops_it(git_repo, monkeypatch: pytest.MonkeyPatch) -> None:
    """A file that can no longer be indexed has its chunks purged, and that is a write like any other."""
    w = make_world(git_repo, {GUIDE_PATH: GUIDE})
    w.run("full")
    (w.repo.root / GUIDE_PATH).write_bytes(b"# Setup\n\xff\xfe not utf-8\n")
    w.commit({})
    is_current = w.indexer._is_current

    def stalled(db: Any, path: str, sha: str) -> bool:
        w.clock.now += 2000
        w.fs.collection("corpus_meta").docs.pop("catch_up_lease", None)
        return is_current(db, path, sha)

    monkeypatch.setattr(w.indexer, "_is_current", stalled)

    with pytest.raises(LeaseLost, match="lease vanished"):
        w.run("catch-up")

    assert w.chunks(GUIDE_PATH), "its chunks were not purged under a lease this run no longer holds"


def test_lease_transaction_retries_on_contention(git_repo) -> None:
    """The lease is a real `@firestore.transactional` over the fake's transaction protocol."""
    w = make_world(git_repo)
    w.fs.commit_conflicts = [Aborted("contention")]

    report = w.run("full")

    assert report.stamped
    assert w.fs.transaction_begins[:2] == [None, b"txn-1"], "the retry names the first attempt"
    assert w.fs.calls["transaction_begin"] >= 4 and w.fs.calls["transaction_commit"] == 3, (
        "three commits: acquire, the check before the stamp, release"
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
        "repo_id": w.repo_id,
        "chunker_version": CHUNKER_VERSION,
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
    assert (nothing.files_written, nothing.files_deleted, nothing.stamped) == (0, 0, False)
    assert nothing.notes == ["corpus is at HEAD"], "the stamp is already HEAD: there is nothing to do"


def test_catch_up_falls_back_without_stamp(git_repo) -> None:
    w = make_world(git_repo)

    report = w.run("catch-up")

    assert report.mode == "full", "no stamp: a full run"
    assert report.files_written == 4 and w.stamp()["mode"] == "full"


def test_catch_up_refuses_a_stamp_this_clone_does_not_have(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    put_stamp(w, UNKNOWN_COMMIT)
    before, stamp = w.writes(), dict(w.stamp())

    with pytest.raises(CorpusRefused, match="stamp 0123456 is not in this clone; git fetch first"):
        w.run("catch-up")
    with pytest.raises(CorpusRefused, match="stamp 0123456 is not in this clone; git fetch first"):
        w.run("catch-up", allow_off_base=True)  # a catch-up has nothing to diff from, whatever is allowed
    with pytest.raises(CorpusRefused, match="not in this clone"):
        w.run("full", force=True)  # force is for the identity and the prune cap only
    with pytest.raises(CorpusRefused, match="not in this clone"):
        w.run("prune-orphans")

    assert w.writes() == before and w.stamp() == stamp, "no lease, no embedding, no write"

    report = w.run("full", allow_off_base=True)  # the explicit override of an explicit full run

    assert report.stamped and w.stamp()["built_from_commit"] == w.head


def test_catch_up_at_the_stamp_is_a_no_op(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    before, stamp = w.writes(), dict(w.stamp())

    report = w.run("catch-up")

    assert report.notes == ["corpus is at HEAD"] and report.mode == "catch-up"
    assert not report.stamped and report.stamp is None and report.files_failed == {}
    assert w.writes() == before and w.stamp() == stamp, "nothing written, not even the lease"

    assert w.run("full").stamped, "an explicit full run at the stamp still verifies the corpus"


def test_catch_up_behind_the_corpus_is_a_no_op_and_full_refuses(git_repo) -> None:
    w = make_world(git_repo)
    first = w.head
    newer = w.commit({GUIDE_PATH: GUIDE + "\nNewer.\n"})
    w.run("full")
    w.repo.git("checkout", "-q", "--detach", first)  # fetched, not pulled: HEAD is behind the corpus
    before, stamp = w.writes(), dict(w.stamp())
    note = f"corpus is ahead of HEAD ({newer[:7]}); pull to catch up"

    assert w.run("catch-up").notes == [note]
    put_stamp(w, newer, embedder_id="vertex:gemini-embedding-001/256")
    assert w.run("catch-up").notes == [note], "not even another embedder's stamp rolls the corpus back"
    put_stamp(w, newer)
    for mode in ("full", "prune-orphans"):
        with pytest.raises(CorpusRefused, match=rf"ahead of HEAD \({newer[:7]}\).*--allow-off-base"):
            w.run(mode)

    assert w.writes() == before and w.stamp() == stamp
    assert "Newer" in w.chunks(GUIDE_PATH)[0]["text"], "the newer content is still there"

    report = w.run("full", allow_off_base=True)  # rolling back is possible, on purpose

    assert report.stamped and w.stamp()["built_from_commit"] == first
    assert "Newer" not in w.chunks(GUIDE_PATH)[0]["text"]


def test_catch_up_over_diverged_histories_is_a_full_run(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    w.fs.add_chunk("docs/gone.md", "a doc deleted long ago")
    w.repo.git("checkout", "-q", "-b", "side")
    side = w.commit({"docs/side.md": "# Side\n\nOn a side branch.\n"}, "side")
    w.repo.git("checkout", "-q", "main")
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    put_stamp(w, side)

    report = w.run("catch-up")

    assert report.mode == "full" and report.stamped and report.stamp == w.head
    assert report.files_written == 1 and report.files_skipped == 3 and report.orphans_removed == 1
    assert w.stamp()["mode"] == "full"


def test_catch_up_from_a_stamp_of_another_embedder_is_a_full_rebuild(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    calls = len(w.genai.calls)
    put_stamp(w, embedder_id="vertex:gemini-embedding-001/256")

    report = w.run("catch-up")

    assert report.mode == "full" and report.files_written == 4 and report.files_skipped == 0, "every vector is replaced"
    assert len(w.genai.calls) > calls
    assert w.stamp()["embedder_id"] == EMBEDDER_ID

    # a stamp that names no embedder (consumer's) is taken as compatible
    w.fs.put("corpus_meta", "index", {"built_from_commit": w.head, "mode": "catch-up"})
    assert w.run("catch-up").notes == ["corpus is at HEAD"]
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})
    assert w.run("catch-up").mode == "catch-up"


def test_a_chunker_change_forces_a_full_rebuild(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")

    put_stamp(w, chunker_version=CHUNKER_VERSION + 1)
    report = w.run("catch-up")
    assert report.mode == "full" and report.files_written == 4 and report.files_skipped == 0
    assert w.stamp()["chunker_version"] == CHUNKER_VERSION

    put_stamp(w, chunker_version=GONE)  # a stamp this indexer wrote, from before it named a version
    report = w.run("full")
    assert report.files_written == 4 and report.files_skipped == 0, "an explicit full run trusts no sha either"

    put_stamp(w, chunker_version=GONE, embedder_id=GONE, repo_id=GONE)  # consumer's stamp names none of them
    report = w.run("catch-up")
    assert report.mode == "catch-up" and report.notes == ["corpus is at HEAD"]


def test_same_sha_skipped(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    calls = len(w.genai.calls)

    report = w.run("full")

    assert (report.files_written, report.files_skipped, report.chunks_written) == (0, 4, 0)
    assert len(w.genai.calls) == calls, "no embedding for an unchanged file"
    assert report.stamped, "an unchanged corpus is still stamped"

    # consumer's chunks carry no line range: those files are rewritten, once
    legacy = w.chunks(README_PATH)[0]
    docs = w.fs.collection("doc_chunks").docs
    old_id = next(i for i, d in docs.items() if d["path"] == README_PATH)
    del docs[old_id]
    w.fs.put(
        "doc_chunks", "AUTO_ID_FROM_CONSUMER", {k: v for k, v in legacy.items() if k not in ("startLine", "endLine")}
    )

    report = w.run("full")

    assert (report.files_written, report.files_skipped) == (1, 3)
    assert "AUTO_ID_FROM_CONSUMER" not in docs and len(w.chunks(README_PATH)) == 1
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
    put_stamp(w)
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


# --- whose corpus it is, and how much a prune may take ---------------------------------------------------


def test_a_corpus_of_another_repository_is_refused(git_repo) -> None:
    w = make_world(git_repo)
    w.run("full")
    assert w.stamp()["repo_id"] == w.repo_id and w.stamp()["chunker_version"] == CHUNKER_VERSION
    put_stamp(w, repo_id="1" * 40 + "," + "2" * 40)
    before, stamp = w.writes(), dict(w.stamp())

    for mode in MODES:
        with pytest.raises(
            CorpusRefused,
            match=(
                r"corpus belongs to another repository \(repo_id 1111111,2222222\); "
                r"use a different collection or force"
            ),
        ):
            w.run(mode)
    assert w.writes() == before and w.stamp() == stamp, "refused before anything is written"

    report = w.run("full", force=True)

    assert report.stamped and w.stamp()["repo_id"] == w.repo_id, "forced: the corpus is now this repository's"


def test_a_stamp_without_a_repo_id_is_accepted_and_the_next_stamp_names_the_repository(git_repo) -> None:
    w = make_world(git_repo)
    w.fs.put("corpus_meta", "index", {"built_from_commit": w.head, "built_at": "2026-01-01", "mode": "catch-up"})
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})

    report = w.run("catch-up")

    assert report.mode == "catch-up" and report.files_written == 1 and report.stamped
    assert w.stamp()["repo_id"] == w.repo_id and w.stamp()["chunker_version"] == CHUNKER_VERSION


def test_repo_identity(git_repo, tmp_path: Path) -> None:
    w = make_world(git_repo)
    root = w.head
    assert repo_identity(w.repo.root, w.head) == root == w.repo_id

    # a repository with two roots: both, sorted
    w.repo.git("checkout", "-q", "--orphan", "other")
    w.repo.git("rm", "-rfq", ".")
    w.repo.write("other.md", "# Other\n")
    other_root = w.repo.commit("other root")
    w.repo.git("checkout", "-q", "main")
    w.repo.git("merge", "-q", "--allow-unrelated-histories", "-m", "merge", "other")
    merged = w.repo.git("rev-parse", "HEAD").strip()
    assert repo_identity(w.repo.root, merged) == ",".join(sorted([root, other_root]))

    # a shallow clone cannot know its roots: no identity, so nothing to compare
    clone = tmp_path / "shallow"
    w.repo.git("clone", "-q", "--depth", "1", f"file://{w.repo.root}", str(clone))
    assert repo_identity(clone, "HEAD") is None


def known_docs(count: int) -> dict[str, str]:
    return {f"docs/n/{i:03d}.md": f"# Note {i}\n\nBody {i}.\n" for i in range(count)}


def seed_cloud(w: World, known: int, orphans: int) -> list[str]:
    for i in range(known):
        w.fs.add_chunk(f"docs/n/{i:03d}.md", f"# Note {i}", start=1, end=1)
    gone = [f"docs/gone/{i:02d}.md" for i in range(orphans)]
    for path in gone:
        w.fs.add_chunk(path, "a doc deleted long ago")
    return gone


def test_prune_cap(git_repo) -> None:
    # 35 orphans among 335 paths: the cap is max(20, 10%) = 33.5
    w = make_world(git_repo, known_docs(300))
    gone = seed_cloud(w, 300, 35)

    report = w.run("prune-orphans")

    assert report.orphans_removed == 0 and report.orphans_pending == 35
    assert "stamped" not in report.notes[0], "prune-orphans never stamps: its note does not say so"
    assert report.orphans_sample == gone[:10], "the first ten, in order"
    assert not report.stamped and set(gone) <= w.paths(), "nothing was deleted"

    forced = w.run("prune-orphans", force=True)

    assert forced.orphans_removed == 35 and forced.orphans_pending == 0 and not set(gone) & w.paths()

    # 25 orphans among 325 paths: more than 20, but under 10% (32.5)
    w = make_world(git_repo, known_docs(300))
    seed_cloud(w, 300, 25)
    assert w.run("prune-orphans").orphans_removed == 25

    # in a small corpus the floor of 20 applies: 20 go, 21 do not
    w = make_world(git_repo)
    seed_cloud(w, 0, 20)
    assert w.run("prune-orphans").orphans_removed == 20
    w = make_world(git_repo)
    seed_cloud(w, 0, 21)
    capped = w.run("prune-orphans")
    assert capped.orphans_removed == 0 and capped.orphans_pending == 21 and len(capped.orphans_sample) == 10


def test_the_prune_cap_measures_the_corpus_as_it_was_before_the_run(git_repo) -> None:
    # another repository's 25 docs share the collection, there is no stamp to name an owner, and this repository
    # has 300 docs: measured after the run writes them the cap would be 32.5, before it is 20
    w = make_world(git_repo, known_docs(300))
    foreign = seed_cloud(w, 0, 25)

    report = w.run("catch-up")

    assert report.mode == "full" and report.files_written == 300 and report.files_failed == {}
    assert report.orphans_pending == 25 and report.orphans_removed == 0
    assert not report.stamped and w.stamp() is None
    assert set(foreign) <= w.paths(), "the other repository's docs are still there"
    assert "nothing stamped" in report.notes[0]

    forced = w.run("full", force=True)

    assert forced.orphans_removed == 25 and forced.stamped


def test_a_capped_run_writes_everything_else_but_does_not_stamp(git_repo) -> None:
    w = make_world(git_repo)
    seed_cloud(w, 0, 21)

    report = w.run("full")

    assert report.files_written == 4 and report.files_failed == {}, "the rest of the run went through"
    assert report.orphans_pending == 21 and report.orphans_removed == 0
    assert not report.stamped and report.stamp is None and w.stamp() is None

    report = w.run("full", force=True)

    assert report.orphans_removed == 21 and report.orphans_pending == 0 and report.stamped


def test_force_does_not_bypass_the_base_guard(git_repo) -> None:
    w = make_world(git_repo)
    w.repo.git("checkout", "-q", "-b", "feature")
    w.commit({GUIDE_PATH: GUIDE + "\nMore.\n"})

    with pytest.raises(BaseRefError):
        w.run("full", force=True)


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


# --- the code corpus (design sections 5 and 6) ------------------------------------------------------------

CODE_FIELDS = {
    "path",
    "chunkIndex",
    "text",
    "startLine",
    "endLine",
    "fileSha256",
    "chunkerId",
    "embedderId",
    "embedding",
    "language",
    "headingPath",
    "lastIndexedAt",
}
CODE_STAMP = ("corpus_meta", "code-index")
CODE_LEASE = ("corpus_meta", "code_catch_up_lease")
OTHER_EMBEDDER = "vertex:gemini-embedding-001/256"
APP = "def main():\n    return 1\n"
CODE = {"app.py": APP, "docs/guide.md": "# Guide\n\nHow to run the app.\n"}


def py(name: str) -> str:
    """A small python file whose one chunk names it."""
    return f"def {name}():\n    return '{name}'\n"


class CodeWorld(World):
    """A world whose indexer writes the code corpus. Each run builds its config, corpus and indexer anew, as the
    CLI does: a corpus reads HEAD's scope (its ignore files, the config) once."""

    def run(self, mode: str = "full", **kw: Any) -> IndexReport:
        self.indexer = code_indexer(self.repo, self.fs, self.genai, self.clock)
        return self.indexer.run(mode, **kw)  # type: ignore[arg-type]

    def chunks(self, path: str) -> list[dict[str, Any]]:
        docs = self.fs.collection("code_chunks").docs.values()
        return sorted((d for d in docs if d["path"] == path), key=lambda d: d["chunkIndex"])

    def paths(self) -> set[str]:
        return {d["path"] for d in self.fs.collection("code_chunks").docs.values()}

    def stamp(self) -> dict[str, Any] | None:
        return self.fs.collection(CODE_STAMP[0]).docs.get(CODE_STAMP[1])

    def lease(self) -> dict[str, Any] | None:
        return self.fs.collection(CODE_LEASE[0]).docs.get(CODE_LEASE[1])

    def steal_lease(self, holder: str = "b:2", *, wait: float = 0.0) -> None:
        self.fs.put(*CODE_LEASE, {"holder": holder, "expires_at": self.clock.at(+900)})
        self.clock.now += wait

    def put_stamp(self, **fields: Any) -> None:
        """The code stamp as this indexer writes it, with `fields` over it."""
        doc = {
            "built_from_commit": self.head,
            "built_at": self.fs.server_time,
            "mode": "full",
            "embedder_id": EMBEDDER_ID,
            "repo_id": self.repo_id,
            "chunker_id": CODE_CHUNKER_ID,
            **fields,
        }
        self.fs.put(*CODE_STAMP, doc)

    def mark(self, path: str | None = None, **fields: Any) -> None:
        """Set `fields` on the stored chunks of `path` (every path when None): what an older run wrote."""
        for doc in self.fs.collection("code_chunks").docs.values():
            if path is None or doc["path"] == path:
                doc.update(fields)


def code_config(exclude: tuple[str, ...] = ()) -> str:
    cloud: dict[str, Any] = {
        "vertex": {"project": "p"},
        "firestore": {"project": "p", "base_ref": "main"},
        "code": {"exclude": list(exclude)},
    }
    return json.dumps({"code": {"content": ["code"]}, "cloud": cloud})


def code_indexer(repo: Any, fs: FakeFirestore, genai: FakeGenai, clock: Clock) -> CloudIndexer:
    cfg = load_config(repo.root, {})
    assert cfg is not None and cfg.cloud is not None and cfg.cloud.code is not None
    embedder = VertexEmbedder(cfg.cloud, client=genai, sleep=no_sleep)
    corpus = CodeCloudCorpus(cfg, repo.root)
    return CloudIndexer(cfg, repo.root, embedder, client=fs, clock=clock, holder="a:1", corpus=corpus)


def make_code_world(git_repo, files: dict[str, str] | None = None, exclude: tuple[str, ...] = ()) -> CodeWorld:
    repo = git_repo()
    repo.write("docs/search/config.json", code_config(exclude))
    for path, text in (CODE if files is None else files).items():
        repo.write(path, text)
    head = repo.commit("seed")
    fs, genai, clock = FakeFirestore(), FakeGenai(), Clock()
    indexer = code_indexer(repo, fs, genai, clock)
    return CodeWorld(repo, indexer._cfg, fs, genai, clock, indexer, head)


def test_code_run_writes_code_fields(git_repo) -> None:
    w = make_code_world(git_repo)

    report = w.run("full")

    assert report.files_written == 1 and report.stamped and report.files_failed == {}
    assert w.paths() == {"app.py"}, "the docs corpus's file is the docs leg's"
    assert "doc_chunks" not in w.fs.collections or not w.fs.collection("doc_chunks").docs
    (chunk,) = w.chunks("app.py")
    assert set(chunk) == CODE_FIELDS, "exactly the code fields: no docType"
    assert chunk["chunkerId"] == CODE_CHUNKER_ID and chunk["embedderId"] == EMBEDDER_ID
    assert chunk["language"] == "python" and chunk["headingPath"] == []
    assert chunk["fileSha256"] == hashlib.sha256(APP.encode()).hexdigest()
    assert (chunk["startLine"], chunk["endLine"]) == (1, 2) and "def main" in chunk["text"]
    assert isinstance(chunk["embedding"], Vector) and len(list(chunk["embedding"])) == 768
    assert chunk["lastIndexedAt"] == w.fs.server_time
    assert w.genai.calls[0].task_type == "RETRIEVAL_DOCUMENT"


def test_code_text_is_capped(git_repo) -> None:
    body = "x = [\n" + "".join(f"    {i},\n" for i in range(3000)) + "]\n"
    w = make_code_world(git_repo, {"big.py": body})

    w.run("full")

    texts = [d["text"] for d in w.chunks("big.py")]
    assert texts and all(len(text) <= 6000 for text in texts)
    assert all(len(text) <= 6000 for text in w.embedded())


def test_code_run_stamps_code_index(git_repo) -> None:
    w = make_code_world(git_repo)

    w.run("full")

    assert w.stamp() == {
        "built_from_commit": w.head,
        "built_at": w.fs.server_time,
        "mode": "full",
        "embedder_id": EMBEDDER_ID,
        "repo_id": w.repo_id,
        "chunker_id": CODE_CHUNKER_ID,
    }
    assert "index" not in w.fs.collection("corpus_meta").docs, "the docs stamp is untouched"


def test_code_lease_is_its_own(git_repo) -> None:
    w = make_code_world(git_repo)
    docs_lease = {"holder": "b:2", "expires_at": w.clock.at(+900)}
    w.fs.put(*LEASE_PATH, docs_lease)
    held: list[Any] = []
    w.genai.on_call = lambda: held.append(w.lease())

    report = w.run("full")

    assert report.stamped, "another host's docs lease does not block the code corpus"
    assert held and held[0]["holder"] == "a:1", "the run held the code lease"
    assert w.lease() is None, "and released it"
    assert w.fs.collection(LEASE_PATH[0]).docs[LEASE_PATH[1]] == docs_lease, "the docs lease is untouched"

    w.commit({"app.py": APP + "\n\ndef more():\n    return 2\n"})
    w.genai.on_call = None
    w.steal_lease()
    with pytest.raises(LeaseHeld, match="the corpus lease is held by b:2"):
        w.run("catch-up")


def test_code_catch_up_rewrites_only_changed_files(git_repo) -> None:
    w = make_code_world(git_repo, {"a.py": py("a"), "b.py": py("b"), "c.py": py("c"), "docs/guide.md": "# G\n"})
    first = w.run("full")
    assert first.files_written == 3
    calls = len(w.genai.calls)

    w.commit({"b.py": py("bee"), "d.py": py("d"), "c.py": None, "docs/guide.md": "# G\n\nMore.\n"})
    report = w.run("catch-up")

    assert (report.mode, report.files_written, report.files_deleted, report.files_skipped) == ("catch-up", 2, 1, 0)
    assert report.stamped and w.stamp()["built_from_commit"] == w.head and w.stamp()["mode"] == "catch-up"
    assert w.paths() == {"a.py", "b.py", "d.py"}
    new = [text for call in w.genai.calls[calls:] for text in call.texts]
    assert len(new) == 2 and any("bee" in t for t in new) and any("'d'" in t for t in new)
    assert not any("'a'" in t for t in new), "a.py did not change"


def test_another_semble_makes_a_full_run(git_repo) -> None:
    w = make_code_world(git_repo, {"a.py": py("a"), "b.py": py("b")})
    w.run("full")
    calls = len(w.genai.calls)
    w.put_stamp(chunker_id="semble-0.6")
    w.mark(chunkerId="semble-0.6")  # what that semble's run wrote

    report = w.run("catch-up")

    assert report.mode == "full" and report.files_written == 2 and report.files_skipped == 0
    assert len(w.genai.calls) > calls and w.stamp()["chunker_id"] == CODE_CHUNKER_ID
    assert {d["chunkerId"] for d in w.fs.collection("code_chunks").docs.values()} == {CODE_CHUNKER_ID}


def test_code_file_grown_past_limit_is_purged(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "lib.py": py("lib")})
    w.run("full")
    assert w.chunks("app.py")

    grown = APP + "#" * (1_000_001 - len(APP) - 1) + "\n"
    assert len(grown.encode()) == 1_000_001
    w.commit({"app.py": grown})
    report = w.run("catch-up")

    assert report.files_deleted == 1 and report.files_written == 0 and report.files_failed == {}
    assert w.paths() == {"lib.py"}
    assert report.stamped and w.stamp()["built_from_commit"] == w.head, "a content defect is not a failure"


def test_code_file_turned_binary_is_purged(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "lib.py": py("lib")})
    w.run("full")

    w.commit({"app.py": APP + "\0\n"})
    report = w.run("catch-up")

    assert report.files_deleted == 1 and report.files_failed == {} and w.paths() == {"lib.py"}
    assert report.stamped and w.stamp()["built_from_commit"] == w.head


FOUR = {"a.py": py("a"), "b.py": py("b"), "c.py": py("c"), "d.py": py("d")}


def test_code_rewrite_resumes(git_repo) -> None:
    w = make_code_world(git_repo, FOUR)
    w.run("full")
    w.put_stamp(embedder_id=OTHER_EMBEDDER)
    w.mark(embedderId=OTHER_EMBEDDER)  # every vector is another embedder's: a rewrite
    old_stamp = dict(w.stamp())
    calls = 0

    def third_loses_the_lease() -> None:
        nonlocal calls
        calls += 1
        if calls == 3:
            w.steal_lease(wait=400)

    w.genai.on_call = third_loses_the_lease
    with pytest.raises(LeaseLost) as lost:
        w.run("catch-up")

    assert lost.value.report.files_written == 2, "a.py and b.py were rewritten before the lease went"
    assert w.stamp() == old_stamp, "nothing stamped"
    assert {p for p in FOUR if w.chunks(p)[0]["embedderId"] == EMBEDDER_ID} == {"a.py", "b.py"}

    del w.fs.collection(CODE_LEASE[0]).docs[CODE_LEASE[1]]  # the other host finished
    stamps: list[Any] = []
    w.genai.on_call = lambda: stamps.append(dict(w.stamp()))
    before = len(w.genai.calls)

    report = w.run("catch-up")

    assert report.mode == "full" and (report.files_written, report.files_skipped) == (2, 2)
    new = [text for call in w.genai.calls[before:] for text in call.texts]
    assert len(new) == 2 and any("'c'" in t for t in new) and any("'d'" in t for t in new), "only the other two"
    assert stamps == [old_stamp, old_stamp], "the stamp is not written while files remain"
    assert w.stamp()["embedder_id"] == EMBEDDER_ID and w.stamp()["built_from_commit"] == w.head


def test_code_rewrite_redoes_a_file_of_the_old_chunker(git_repo) -> None:
    w = make_code_world(git_repo, FOUR)
    w.run("full")
    w.put_stamp(embedder_id=OTHER_EMBEDDER)  # a rewrite; every chunk 0 already has this run's identity...
    w.mark("a.py", chunkerId="semble-0.6")  # ...but a.py's, which an older chunker cut
    w.mark("b.py", fileSha256="0" * 64)  # and b.py's, which is of other bytes
    before = len(w.genai.calls)

    report = w.run("catch-up")

    assert report.mode == "full" and (report.files_written, report.files_skipped) == (2, 2)
    new = [text for call in w.genai.calls[before:] for text in call.texts]
    assert len(new) == 2 and any("'a'" in t for t in new) and any("'b'" in t for t in new)
    assert w.chunks("a.py")[0]["chunkerId"] == CODE_CHUNKER_ID


def test_docs_run_unchanged_by_code_config(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/search/config.json", code_config())
    for path, text in {**DOCS, "app.py": APP}.items():
        repo.write(path, text)
    repo.commit("seed")
    cfg = load_config(repo.root, {})
    assert cfg is not None and cfg.cloud is not None and cfg.cloud.code is not None
    fs, genai = FakeFirestore(), FakeGenai()
    embedder = VertexEmbedder(cfg.cloud, client=genai, sleep=no_sleep)
    for corpus in (None, DocsCloudCorpus(cfg, repo.root)):
        CloudIndexer(cfg, repo.root, embedder, client=fs, clock=Clock(), holder="a:1", corpus=corpus).run("full")

        docs = fs.collection("doc_chunks").docs
        assert {d["path"] for d in docs.values()} == set(DOCS), "no code in the docs corpus"
        assert all(set(d) == FIELDS for d in docs.values()), "exactly today's fields: no chunkerId, no embedderId"
        stamp = fs.collection("corpus_meta").docs["index"]
        assert stamp["chunker_version"] == CHUNKER_VERSION and "chunker_id" not in stamp
        assert "code-index" not in fs.collection("corpus_meta").docs
        assert "code_chunks" not in fs.collections


# --- R1: regular files only ----------------------------------------------------------------------------


def test_code_corpus_takes_regular_blobs_only(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "lib.py": py("lib")})
    os.symlink("app.py", w.repo.root / "link.py")
    sub = w.repo.git("rev-parse", "HEAD").strip()
    w.repo.git("update-index", "--add", "--cacheinfo", f"160000,{sub},vendored.py")
    w.head = w.repo.commit("a link and a gitlink")
    corpus = CodeCloudCorpus(w.indexer._cfg, w.repo.root)
    assert corpus.in_scope("link.py") and corpus.in_scope("vendored.py"), "scope is a path test alone"

    report = w.run("full")

    assert w.paths() == {"app.py", "lib.py"} and report.files_written == 2

    os.unlink(w.repo.root / "lib.py")
    os.symlink("app.py", w.repo.root / "lib.py")  # a file that turned into a link leaves the corpus
    w.head = w.repo.commit("lib is a link now")
    report = w.run("catch-up")

    assert w.paths() == {"app.py"} and report.files_deleted == 1 and report.files_written == 0
    assert report.stamped


# --- R2: a file HEAD still holds that left code scope ------------------------------------------------


def test_code_catch_up_drops_a_changed_file_that_left_scope(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "old/x.py": py("x"), "old/y.py": py("y")})
    w.run("full")
    assert w.paths() == {"app.py", "old/x.py", "old/y.py"}

    w.commit({"old/x.py": py("xx"), "old/.sembleignore": "*.py\n"})
    report = w.run("catch-up")

    assert w.paths() == {"app.py"}, "both left scope: the changed one, and the one the new ignore file covers"
    assert report.files_deleted == 1, "the changed file goes as a removed file would"
    assert report.orphans_removed == 1, "the ignore file changed: the indexed paths were checked too"
    assert report.files_written == 0 and report.stamped


def test_code_full_and_prune_orphans_drop_what_left_scope(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "legacy/a.py": py("a"), "legacy/b.py": py("b")})
    w.run("full")
    w.commit({".gitignore": "legacy/\n"})

    report = w.run("prune-orphans")

    assert report.orphans_removed == 2 and w.paths() == {"app.py"} and not report.stamped

    w.commit({".gitignore": "legacy/b.py\n"})  # a.py comes back in; b.py stays out
    report = w.run("full")

    assert w.paths() == {"app.py", "legacy/a.py"} and report.orphans_removed == 0, "b.py's chunks went already"
    assert report.files_written == 1 and report.stamped

    w.commit({".gitignore": "legacy/a.py\n"})  # and now the other way round
    report = w.run("full")

    assert w.paths() == {"app.py", "legacy/b.py"} and report.orphans_removed == 1 and report.stamped


def test_code_out_of_scope_orphans_obey_the_cap(git_repo) -> None:
    legacy = {f"legacy/m{i:02d}.py": py(f"m{i:02d}") for i in range(21)}
    w = make_code_world(git_repo, {"app.py": APP, **legacy})
    w.run("full")
    w.commit({".gitignore": "legacy/\n"})

    report = w.run("catch-up")

    assert report.orphans_pending == 21 and report.orphans_removed == 0 and not report.stamped
    assert set(legacy) <= w.paths(), "too many to prune without force"

    forced = w.run("full", force=True)

    assert forced.orphans_removed == 21 and forced.stamped and w.paths() == {"app.py"}


@pytest.mark.parametrize("ignore", ["src/.GitIgnore", "src/.sembleignore", ".gitignore"])
def test_code_catch_up_rechecks_scope_when_an_ignore_file_changes(git_repo, ignore: str) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "src/gen.py": py("gen"), "src/keep.py": py("keep")})
    w.run("full")

    w.commit({ignore: "gen.py\n" if ignore.startswith("src/") else "src/gen.py\n"})
    report = w.run("catch-up")

    assert w.paths() == {"app.py", "src/keep.py"} and report.orphans_removed == 1 and report.stamped


def test_code_catch_up_drops_a_file_deleted_as_its_directory_is_ignored(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "legacy/x.py": py("x")})
    w.run("full")

    w.commit({"legacy/x.py": None, ".gitignore": "legacy/\n"})  # out of scope now, and gone
    report = w.run("catch-up")

    assert w.paths() == {"app.py"} and report.stamped


def test_code_catch_up_rechecks_scope_when_the_config_changes(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "gen/out.py": py("out")})
    w.run("full")

    w.commit({"docs/search/config.json": code_config(exclude=("gen/**",))})
    report = w.run("catch-up")

    assert w.paths() == {"app.py"} and report.orphans_removed == 1 and report.stamped


def test_code_catch_up_without_a_scope_change_scans_nothing(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "lib.py": py("lib")})
    w.run("full")
    w.fs.add_chunk("gone.py", "a file deleted long ago", collection="code_chunks", start=1, end=1)

    w.commit({"lib.py": py("lib2")})
    report = w.run("catch-up")

    assert report.orphans_removed == 0 and "gone.py" in w.paths(), "a plain catch-up does not reconcile"


def test_docs_keep_a_doc_that_left_scope(git_repo) -> None:
    w = make_world(git_repo, {**DOCS, "docs/old/legacy.md": "# Legacy\n\nOld.\n"})
    w.run("full")
    config = json.loads((w.repo.root / "docs/search/config.json").read_text(encoding="utf-8"))
    config["docs"] = {"exclude": ["docs/old/**"]}
    w.commit({"docs/search/config.json": json.dumps(config), ".gitignore": "docs/old/\n"})
    w.indexer = CloudIndexer(
        load_config(w.repo.root, {}), w.repo.root, w.indexer._embedder, client=w.fs, clock=w.clock, holder="a:1"
    )

    for mode in ("catch-up", "full", "prune-orphans"):
        report = w.run(mode)
        assert report.orphans_removed == 0 and report.files_deleted == 0
        assert "docs/old/legacy.md" in w.paths(), f"{mode}: an out-of-scope doc HEAD still holds keeps its chunks"


def test_code_catch_up_writes_files_that_enter_scope(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "legacy/a.py": py("a")})
    w.commit({".gitignore": "legacy/\n# keep\n"})  # legacy/a.py stays tracked, but out of scope
    w.run("full")
    assert w.paths() == {"app.py"}

    w.commit({".gitignore": "# keep\n"})  # the ignore line goes: a.py is in scope again, its own range untouched
    report = w.run("catch-up")

    assert w.paths() == {"app.py", "legacy/a.py"} and report.files_written == 1 and report.stamped
    assert w.chunks("legacy/a.py")[0]["fileSha256"] == hashlib.sha256(py("a").encode()).hexdigest()


def test_code_rescope_queries_only_indexed_paths_for_drops(git_repo, monkeypatch: pytest.MonkeyPatch) -> None:
    w = make_code_world(git_repo, {"app.py": APP, "docs/guide.md": "# G\n"})
    w.run("full")
    w.commit({"docs/guide.md": "# G\n\nMore.\n", "notes.txt": "n\n", ".gitignore": "# nothing\n"})
    purged: list[str] = []
    real = CloudIndexer._drop_file

    def spy(self: CloudIndexer, db: Any, path: str, report: IndexReport) -> None:
        purged.append(path)
        real(self, db, path, report)

    monkeypatch.setattr(CloudIndexer, "_drop_file", spy)
    report = w.run("catch-up")

    assert purged == [], "none of the changed paths was ever in the code corpus"
    assert report.stamped and w.paths() == {"app.py"}


def test_code_chunks_name_the_embedder_used(git_repo) -> None:
    w = make_code_world(git_repo, {"app.py": APP})
    cfg = load_config(w.repo.root, {})
    assert cfg is not None and cfg.cloud is not None
    other = dataclasses.replace(cfg.cloud, vertex=dataclasses.replace(cfg.cloud.vertex, dimensions=256))
    embedder = VertexEmbedder(other, client=FakeGenai(dims=256), sleep=no_sleep)
    corpus = CodeCloudCorpus(cfg, w.repo.root)  # its config says 768
    indexer = CloudIndexer(cfg, w.repo.root, embedder, client=w.fs, clock=w.clock, holder="a:1", corpus=corpus)

    indexer.run("full")

    assert embedder.id == OTHER_EMBEDDER
    assert w.chunks("app.py")[0]["embedderId"] == OTHER_EMBEDDER == w.stamp()["embedder_id"]


@pytest.mark.parametrize(("field", "value"), [("embedderId", OTHER_EMBEDDER), ("chunkerId", "semble-0.6")])
def test_code_non_rewrite_replaces_chunks_of_another_identity(git_repo, field: str, value: str) -> None:
    w = make_code_world(git_repo, FOUR)
    w.run("full")
    w.mark("a.py", **{field: value})  # what a rewrite cut short left, under this run's stamp
    before = len(w.genai.calls)

    report = w.run("full")  # not a rewrite: the stamp names this run's embedder and chunker

    assert (report.files_written, report.files_skipped) == (1, 3)
    new = [text for call in w.genai.calls[before:] for text in call.texts]
    assert len(new) == 1 and "'a'" in new[0]
    assert w.chunks("a.py")[0][field] == (EMBEDDER_ID if field == "embedderId" else CODE_CHUNKER_ID)
