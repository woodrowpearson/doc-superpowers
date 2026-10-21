"""The `doc-search` command line: exit codes, init, index, query, status and the known-answer eval.

The CLI is driven in-process through `main(argv)` with the working directory moved into a throwaway
repository. Local builds run on the tiny test model. The cloud write path is reached through the
`make_indexer` seam: stubs for the exit-code mapping, the real indexer over the fakes for one end-to-end run.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from semble import SembleIndex

from doc_search import cli
from doc_search.cli import main
from doc_search.cloud import CloudUnavailable
from doc_search.cloud.read import DegradedLeg
from doc_search.cloud.write import BaseRefError, CorpusRefused, IndexReport, LeaseHeld, LeaseLost
from doc_search.config import CONFIG_REL, DEFAULTS, INERT_LINE, load_config
from doc_search.encode_cache import encode_cache_path
from doc_search.engines import IndexPool, WorktreeIndexes
from doc_search.evaluate import EvalFileError, run_eval, score_ranking
from doc_search.progress import read_progress
from doc_search.transformer import TransformerSpec
from doc_search.types import Hit, SearchRequest
from fakes_transformer import fake_encoder, release_builds, wait_until

SPEC_PATH = "docs/specs/SPEC-PAY-004.md"
SHIPPING_PATH = "docs/shipping.md"
CODE_PATH = "src/refund.py"

SPEC = """---
status: accepted
---
# Refunds

Refund rounding rules for the payment service, SPEC-PAY-004.

## Rounding

Refunds round half up to the nearest cent. The refund total is the sum of the
rounded line amounts, never the rounded sum.
"""

SHIPPING = """# Shipping

Orders ship from the nearest warehouse. The shipping fee is a flat rate per order.
"""

REFUND_PY = '''def refund_total(lines):
    """Sum the rounded line amounts of a refund."""
    total = 0
    for amount in lines:
        total += round(amount, 2)
    return total
'''

CLOUD = {"vertex": {"project": "p"}, "firestore": {"project": "p", "base_ref": "main"}}


def seed(repo, tiny_model: str, **config) -> None:
    repo.write(SPEC_PATH, SPEC)
    repo.write(SHIPPING_PATH, SHIPPING)
    repo.write(CODE_PATH, REFUND_PY)
    repo.write(CONFIG_REL, json.dumps({"docs": {"model": tiny_model}, "code": {"model": tiny_model}, **config}))
    repo.commit("seed")


@pytest.fixture
def repo(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch):
    """An enabled repository (tiny models) that is the process's working directory."""
    made = git_repo()
    seed(made, tiny_model)
    monkeypatch.chdir(made.root)
    return made


@dataclass
class Ran:
    code: int
    out: str
    err: str

    @property
    def lines(self) -> list[str]:
        return self.out.splitlines()


@pytest.fixture
def run(capsys):
    def go(*argv: str) -> Ran:
        code = main(list(argv))
        out, err = capsys.readouterr()
        return Ran(code, out, err)

    return go


@pytest.fixture
def warm_pool(repo, monkeypatch: pytest.MonkeyPatch) -> IndexPool:
    """The repository's indexes already built, and the one pool every verb of the test gets."""
    pool = IndexPool(load_config(repo.root, {}))
    assert isinstance(pool.get(repo.root, wait_s=60), WorktreeIndexes)
    monkeypatch.setattr("doc_search.server.IndexPool", lambda cfg, **kwargs: pool)  # kwargs: fallback=False
    return pool


@pytest.fixture
def spec(fake_transformer: TransformerSpec):
    """The fake transformer's spec; at the end every held encode is let go and every build thread joined."""
    yield fake_transformer
    release_builds()


@pytest.fixture
def tx_repo(git_repo, tiny_model: str, spec: TransformerSpec, monkeypatch: pytest.MonkeyPatch):
    """An enabled repository whose docs model is the fake transformer, as the process's working directory."""
    made = git_repo()
    seed(made, tiny_model, docs={"model": "transformer:test-tiny"})
    monkeypatch.chdir(made.root)
    return made


def build_held_elsewhere(made, spec: TransformerSpec) -> tuple[IndexPool, WorktreeIndexes]:
    """A server's pool, standing in for another process: the static index built and saved, the transformer build held
    mid-encode with its progress published (the command line's fresh process reads it from the file)."""
    fake_encoder(spec).gate.clear()
    pool = IndexPool(load_config(made.root, {}))
    served = pool.get(made.root, wait_s=60)
    assert isinstance(served, WorktreeIndexes) and served.docs_fallback

    def published():
        view = read_progress(made.root)
        return view if view is not None and view.phase == "encoding" else None

    wait_until(published, "the held build to publish that it encodes")
    return pool, served


def cases_file(tmp_path: Path, *lines: object, name: str = "known.jsonl") -> Path:
    path = tmp_path / name
    path.write_text("\n".join(line if isinstance(line, str) else json.dumps(line) for line in lines) + "\n")
    return path


KNOWN = [
    {"query": "refund rounding half up", "expect": [SPEC_PATH], "kind": "paraphrase"},
    {"query": "SPEC-PAY-004", "expect": [SPEC_PATH], "kind": "identifier"},
    {"query": "shipping fee flat rate per order", "expect": [SHIPPING_PATH], "kind": "legacy"},
    {"query": "refund total rounded amounts", "expect": [CODE_PATH], "kind": "code"},
]


# --- exit codes and the inert contract -------------------------------------------------------------------


def test_exit_codes(git_repo, tiny_model: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, run) -> None:
    # usage: 3 (an unknown verb, no verb, an unknown option, a bad choice)
    assert run("bogus").code == 3
    assert run().code == 3
    assert run("status", "--nope").code == 3
    assert run("query", "x", "--scope", "everything").code == 3
    refused = run("bogus")
    assert refused.out == "" and refused.err.startswith("usage: doc-search") and "doc-search: " in refused.err

    # could not run: outside a git work tree
    plain = tmp_path / "plain"
    plain.mkdir()
    monkeypatch.chdir(plain)
    outside = run("status")
    assert outside.code == 2 and outside.out == ""
    assert outside.err.startswith("doc-search: not inside a git work tree") and outside.err.count("\n") == 1
    probe = run("status", "--format", "json")  # a JSON probe still gets JSON
    assert probe.code == 2 and probe.err == outside.err
    assert json.loads(probe.out) == {"enabled": False, "error": outside.err.strip()}

    # inert: every verb but init prints the one line and exits 0
    inert = git_repo()
    inert.write("docs/a.md", "# A\n")
    inert.commit("seed")
    monkeypatch.chdir(inert.root)
    for argv in (("status",), ("query", "a doc"), ("index",), ("index", "--cloud"), ("eval", "none.jsonl")):
        done = run(*argv)
        assert (done.code, done.out, done.err) == (0, INERT_LINE + "\n", ""), argv
    as_json = run("status", "--format", "json")
    assert as_json.code == 0 and json.loads(as_json.out)["enabled"] is False
    assert INERT_LINE == "doc-search: not enabled (no docs/search/config.json)"

    # invalid config: 2, one stderr line, nothing on stdout
    broken = git_repo()
    broken.write(CONFIG_REL, "{ not json")
    broken.commit("seed")
    monkeypatch.chdir(broken.root)
    for argv in (("status",), ("query", "a doc"), ("index",), ("eval", "none.jsonl")):
        done = run(*argv)
        assert done.code == 2 and done.out == "", argv
        assert done.err.startswith("doc-search: invalid config: ") and "malformed JSON" in done.err
        assert done.err.count("\n") == 1
    probe = run("status", "--format", "json")
    assert probe.code == 2 and probe.err.startswith("doc-search: invalid config: ")
    assert json.loads(probe.out) == {"enabled": False, "error": probe.err.strip()}

    bad_glob = git_repo()
    bad_glob.write(CONFIG_REL, json.dumps({"docs": {"model": tiny_model, "include": ["!"]}}))
    bad_glob.commit("seed")
    monkeypatch.chdir(bad_glob.root)
    done = run("status")
    assert done.code == 2 and done.err.startswith("doc-search: invalid config: docs.")


def test_serve_hands_the_launch_directory_to_the_server(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    served: list[Path] = []
    monkeypatch.setattr("doc_search.server.serve", served.append)

    assert run("serve").code == 0
    assert served == [Path.cwd()]
    assert run("serve", "extra").code == 3


# --- init ------------------------------------------------------------------------------------------------


def test_init_writes_once(git_repo, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, run) -> None:
    fresh = git_repo()
    fresh.write("README.md", "# Hello\n")
    fresh.write("docs/guide.md", "# Guide\n")
    fresh.write("services/pay/NOTES.md", "# Notes\n")
    fresh.write("src/app.py", "x = 1\n")
    fresh.commit("seed")
    monkeypatch.chdir(fresh.root)

    done = run("init")

    assert done.code == 0 and done.err == ""
    written = (fresh.root / CONFIG_REL).read_text()
    assert written == json.dumps(DEFAULTS, indent=2) + "\n"  # the defaults verbatim, nothing widened
    assert json.loads(written)["docs"]["include"] == ["docs/**/*.md", "*.md"]
    assert done.lines[-1] == "corpus: 3 files would be indexed"
    assert any(line.startswith("docs.include") and "docs/**/*.md" in line for line in done.lines)
    assert any(line.startswith("cloud") and "off" in line for line in done.lines)
    assert "docs.threads: auto" in done.lines
    assert len(done.lines) >= 6  # one line per choice

    (fresh.root / CONFIG_REL).write_text('{"search": {"default_limit": 3}}\n')  # an edit init must not touch
    again = run("init")

    assert again.code == 0 and again.err == ""
    assert again.out == "doc-search: docs/search/config.json exists; not changed\n"
    assert (fresh.root / CONFIG_REL).read_text() == '{"search": {"default_limit": 3}}\n'

    # from a subdirectory the file goes to the repository top
    sub = git_repo()
    sub.write("src/app.py", "x = 1\n")
    sub.commit("seed")
    monkeypatch.chdir(sub.root / "src")
    assert run("init").code == 0
    assert (sub.root / CONFIG_REL).is_file() and not (sub.root / "src" / "docs").exists()

    # the file it wrote enables doc-search with no further edit
    assert load_config(sub.root, {}) is not None

    outside = tmp_path / "plain"
    outside.mkdir()
    monkeypatch.chdir(outside)
    nowhere = run("init")
    assert nowhere.code == 2 and nowhere.err.startswith("doc-search: not inside a git work tree")


# --- query -----------------------------------------------------------------------------------------------


def test_query_text(repo, run) -> None:
    done = run("query", "refund rounding half up")

    assert done.code == 0 and done.err == ""
    assert done.out.startswith("doc-search · docs: semble ")
    assert f"[doc] {SPEC_PATH}:" in done.out
    assert f"[code] {CODE_PATH}:" in done.out
    assert len(done.out) <= 8000

    docs = run("query", "refund rounding", "--scope", "docs", "--limit", "3")
    assert f"[doc] {SPEC_PATH}" in docs.out and "[code]" not in docs.out

    code = run("query", "refund total", "--scope", "code")
    assert f"[code] {CODE_PATH}" in code.out and "[doc]" not in code.out

    filtered = run("query", "refund", "--doc-type", "spec", "--path-prefix", "docs/", "--scope", "docs")
    assert SPEC_PATH in filtered.out and SHIPPING_PATH not in filtered.out


def test_query_json_shape(repo, run) -> None:
    done = run("query", "refund rounding half up", "--format", "json", "--limit", "5")

    assert done.code == 0 and done.err == ""
    payload = json.loads(done.out)
    assert set(payload) == {"header", "hits"}
    assert set(payload["header"]) == {"docs_model", "code", "cloud", "notes", "truncated"}
    assert payload["header"]["notes"] == [] and payload["header"]["truncated"] is False
    assert payload["hits"], "the seeded docs answer this query"
    assert len(payload["hits"]) <= 5
    first = payload["hits"][0]
    assert set(first) == {
        "kind", "path", "start_line", "end_line", "snippet", "heading_path", "doc_type", "status", "links",
        "more_in_file", "legs",
    }  # fmt: skip
    assert {hit["path"] for hit in payload["hits"]} >= {SPEC_PATH, CODE_PATH}
    spec = next(hit for hit in payload["hits"] if hit["path"] == SPEC_PATH)
    assert spec["kind"] == "doc" and spec["status"] == "accepted" and isinstance(spec["heading_path"], list)


def test_query_refusals(repo, run, tmp_path: Path) -> None:
    empty = run("query", "   ")
    assert empty.code == 3 and empty.out == ""
    assert empty.err == "doc-search: invalid request: query is empty\n"

    foreign = tmp_path / "elsewhere"
    foreign.mkdir()
    elsewhere = run("query", "refund", "--worktree", str(foreign))
    assert elsewhere.code == 2 and "not a worktree of this repository" in elsewhere.err and elsewhere.out == ""

    other = repo.add_worktree("b", "branch-b")
    (other / "docs" / "discount.md").write_text("# Discount\n\nThe discount rate applies before the tax.\n")
    repo.git("add", "-A", cwd=other)
    repo.git("commit", "-q", "-m", "discount", cwd=other)
    there = run("query", "discount rate tax", "--scope", "docs", "--worktree", str(other))
    assert there.code == 0 and "docs/discount.md" in there.out


# --- index (local) ---------------------------------------------------------------------------------------


def test_index_local_builds(repo, run, semble_cache: Path) -> None:
    done = run("index")

    assert done.code == 0 and done.err == ""
    by_kind = {line.split(":")[0]: line for line in done.lines}
    assert set(by_kind) == {"docs", "code"}
    for kind, line in by_kind.items():
        match = re.fullmatch(rf"{kind}: (\d+) chunks, (\d+) files, (\d+\.\d+) s", line)
        assert match, line
        assert int(match[1]) >= 1 and int(match[2]) >= 1
    assert any(semble_cache.iterdir()), "the indexes were saved in semble's cache"

    again = run("index")  # a second run finds them in the cache
    assert again.code == 0 and {line.split(":")[0] for line in again.lines} == {"docs", "code"}


def test_index_with_code_off(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, run) -> None:
    made = git_repo()
    seed(made, tiny_model, code={"enabled": False})
    monkeypatch.chdir(made.root)

    done = run("index")

    assert done.code == 0
    assert done.lines[0].startswith("docs: ") and done.lines[1].startswith("code: off")


def test_index_build_error_is_exit_2(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(cls, *args, **kwargs):
        raise RuntimeError("no model for you")

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(boom))

    done = run("index")

    assert done.code == 2
    assert "docs index failed" in done.err and "no model for you" in done.err
    assert "code index failed" in done.err


@pytest.mark.parametrize("verb", ["index", "query", "eval"])
def test_foreground_verbs_print_the_transformer_build_progress(
    tx_repo, spec: TransformerSpec, run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, verb: str
) -> None:
    argv = {
        "index": ("index",),
        "query": ("query", "refund rounding"),
        "eval": ("eval", str(cases_file(tmp_path, KNOWN[0]))),
    }[verb]
    assert cli.PROGRESS_EVERY_S == 30.0
    monkeypatch.setattr(cli, "PROGRESS_EVERY_S", 0.05)
    encoder = fake_encoder(spec)
    encoder.gate.clear()  # the build holds mid-encode until a progress line has been printed
    encoding = threading.Event()
    printed = cli._print_progress

    def spy(line: str) -> None:
        printed(line)
        if "chunks encoded" in line:
            encoding.set()

    monkeypatch.setattr(cli, "_print_progress", spy)
    opener = threading.Thread(target=lambda: (encoding.wait(30), encoder.gate.set()), name="test-opener", daemon=True)
    opener.start()

    done = run(*argv)
    opener.join(5)

    assert done.code == 0, done
    assert "doc-search: docs: transformer index building, 0 chunks encoded" in done.err.splitlines()
    assert all(line.startswith("doc-search: docs: transformer index") for line in done.err.splitlines()), done.err
    assert [t.name for t in threading.enumerate() if t.name == "doc-search-progress"] == [], "stopped with the verb"


def test_foreground_progress_stops_when_the_verb_returns(
    tx_repo, spec: TransformerSpec, run, capsys, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(cli, "PROGRESS_EVERY_S", 0.02)
    assert run("index").code == 0  # nothing held: the build is done in moments
    capsys.readouterr()

    time.sleep(0.2)  # many intervals pass; the printer must be gone

    assert capsys.readouterr().err == ""


# --- status ----------------------------------------------------------------------------------------------


class BuildSpy:
    """Counts every call that would build or load an index: `status` must make none."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self.calls: list[str] = []
        for name in ("from_path", "load_from_disk"):
            real = getattr(SembleIndex, name)  # a bound classmethod

            def spy(cls, *args, _real=real, _name=name, **kwargs):
                self.calls.append(_name)
                return _real(*args, **kwargs)

            monkeypatch.setattr(SembleIndex, name, classmethod(spy))


def build_threads() -> list[str]:
    return [t.name for t in threading.enumerate() if t.name.startswith("doc-search-")]


def touch(path: Path) -> None:
    """Change a file the way an edit does: new content and an mtime that cannot equal the old one."""
    stat = path.stat()
    path.write_text(path.read_text() + "\nAn edit.\n")
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))


def test_status_text_and_json(repo, run, warm_pool: IndexPool) -> None:
    text = run("status")
    assert text.code == 0 and text.err == ""
    assert text.lines[0] == "doc-search status"
    assert "docs index: ready" in text.out and "code index: ready" in text.out
    assert text.lines[-2:] == ["docs cache: valid", "code cache: valid"]

    done = run("status", "--format", "json")
    payload = json.loads(done.out)

    assert done.code == 0
    assert payload["enabled"] is True and payload["ready"] is True
    assert payload["worktree"] == str(repo.root) and payload["config"] == str(repo.root / CONFIG_REL)
    assert payload["docs"]["state"] == "ready" and payload["docs"]["chunks"] >= 1
    assert payload["code"]["state"] == "ready" and payload["code"]["files"] >= 1
    assert payload["docs"]["error"] is None
    assert payload["cache"] == {"docs": "valid", "code": "valid", "docs_fallback": None}
    assert payload["docs"]["transformer"] is None and payload["encode_cache"] is None
    assert payload["corpus_files"] == 2
    assert payload["cloud"] is None
    assert isinstance(payload["semble"], str)


def test_status_in_memory_ready_counts_even_when_the_disk_is_stale(repo, run, warm_pool: IndexPool) -> None:
    touch(repo.root / SHIPPING_PATH)  # the pool holds the indexes it built; the saved ones no longer validate

    payload = json.loads(run("status", "--format", "json").out)

    assert payload["cache"]["docs"] == "stale"
    assert payload["docs"]["state"] == "ready" and payload["ready"] is True


def test_status_of_a_fresh_process_without_a_cache(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    """Nothing saved: `absent`, not ready, and nothing built, loaded or started, so it answers at once."""
    spy = BuildSpy(monkeypatch)

    start = time.monotonic()
    text = run("status")
    as_json = run("status", "--format", "json")
    took = time.monotonic() - start

    assert took < 2.0, f"status took {took:.1f} s"
    assert text.code == 0 and "docs cache: absent" in text.lines and "code cache: absent" in text.lines
    assert "docs index: not loaded" in text.out and "building" not in text.out
    payload = json.loads(as_json.out)
    assert as_json.code == 0 and payload["enabled"] is True and payload["ready"] is False
    assert payload["cache"] == {"docs": "absent", "code": "absent", "docs_fallback": None}
    assert payload["docs"]["state"] == "unloaded" and payload["docs"]["chunks"] is None
    assert payload["corpus_files"] == 2
    assert spy.calls == [] and build_threads() == []


def test_status_after_index_is_valid_and_ready(repo, run, monkeypatch: pytest.MonkeyPatch) -> None:
    assert run("index").code == 0  # another process saved the indexes
    spy = BuildSpy(monkeypatch)

    text = run("status")
    payload = json.loads(run("status", "--format", "json").out)

    assert text.lines[-2:] == ["docs cache: valid", "code cache: valid"]
    assert payload["cache"] == {"docs": "valid", "code": "valid", "docs_fallback": None}
    assert payload["ready"] is True
    assert payload["docs"]["state"] == "unloaded", "ready from the disk: this process loaded nothing"
    assert spy.calls == [] and build_threads() == [], "valid is read from the cache, not by loading the index"


def test_status_after_a_change_is_stale(repo, run) -> None:
    assert run("index").code == 0

    touch(repo.root / SHIPPING_PATH)  # a doc edited since the indexes were saved
    payload = json.loads(run("status", "--format", "json").out)
    assert payload["cache"] == {"docs": "stale", "code": "valid", "docs_fallback": None}
    assert payload["ready"] is False
    assert run("status").lines[-2:] == ["docs cache: stale", "code cache: valid"]

    assert run("index").code == 0  # refreshing makes them valid again
    assert json.loads(run("status", "--format", "json").out)["ready"] is True

    repo.write("src/other.py", "def other():\n    return 1\n")  # a new code file
    payload = json.loads(run("status", "--format", "json").out)
    assert payload["cache"] == {"docs": "valid", "code": "stale", "docs_fallback": None} and payload["ready"] is False


def test_status_with_code_off(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, run) -> None:
    made = git_repo()
    seed(made, tiny_model, code={"enabled": False})
    monkeypatch.chdir(made.root)
    before = json.loads(run("status", "--format", "json").out)
    assert before["cache"] == {"docs": "absent", "code": "off", "docs_fallback": None} and before["ready"] is False

    assert run("index").code == 0
    payload = json.loads(run("status", "--format", "json").out)

    assert payload["cache"] == {"docs": "valid", "code": "off", "docs_fallback": None}
    assert payload["code"]["state"] == "off"
    assert payload["ready"] is True
    assert run("status").lines[-2:] == ["docs cache: valid", "code cache: off"]


def test_status_static_config_has_no_transformer_members(repo, run, warm_pool: IndexPool) -> None:
    payload = json.loads(run("status", "--format", "json").out)

    assert payload["docs"]["transformer"] is None and payload["encode_cache"] is None
    assert payload["cache"]["docs_fallback"] is None
    text = run("status")
    assert "encode cache" not in text.out and "docs fallback cache" not in text.out


def test_status_transformer_before_anything_is_built(tx_repo, spec: TransformerSpec, run) -> None:
    text = run("status")
    payload = json.loads(run("status", "--format", "json").out)

    assert text.code == 0 and text.err == ""
    assert text.lines[-3:] == ["docs cache: absent", "docs fallback cache: absent", "code cache: absent"]
    assert "docs model: transformer:test-tiny (" in text.out
    assert f"encode cache: {encode_cache_path(spec)} (empty)" in text.lines
    assert payload["docs"]["transformer"] == {"model": spec.model_path, "progress": None}
    assert payload["docs"]["model"] == "transformer:test-tiny" and payload["docs"]["state"] == "unloaded"
    assert payload["encode_cache"] == {"path": str(encode_cache_path(spec)), "bytes": None}
    assert payload["cache"] == {"docs": "absent", "code": "absent", "docs_fallback": "absent"}
    assert payload["ready"] is False


def test_status_reads_the_build_another_process_publishes(tx_repo, spec: TransformerSpec, run) -> None:
    pool, served = build_held_elsewhere(tx_repo, spec)
    chunks = len(served.docs.chunks)

    text = run("status")
    payload = json.loads(run("status", "--format", "json").out)

    # the text: the tool's, then the caches (the transformer's and the static fallback's), then the other process's line
    progress = f"docs: transformer index building, 0 / {chunks} chunks encoded"
    assert text.code == 0 and text.err == ""
    assert text.lines[-4:] == ["docs cache: absent", "docs fallback cache: valid", "code cache: valid", progress]
    assert "docs index: not loaded (status does not load it; a search of this worktree does)" in text.lines

    # the JSON: the same facts as members
    assert payload["docs"]["transformer"]["model"] == spec.model_path
    shown = payload["docs"]["transformer"]["progress"]
    assert shown["phase"] == "encoding" and shown["total"] == chunks and shown["done"] == 0
    assert shown["pid"] == os.getpid() and set(shown) == set(pool.progress(tx_repo.root).as_dict())
    assert payload["encode_cache"]["path"] == str(encode_cache_path(spec))
    assert isinstance(payload["encode_cache"]["bytes"], int)
    assert payload["cache"] == {"docs": "absent", "code": "valid", "docs_fallback": "valid"}
    assert payload["ready"] is True, "the static index is valid on disk, so a search answers"
    assert payload["docs"]["state"] == "unloaded" and payload["docs"]["error"] is None


def test_status_in_a_process_that_builds_names_the_build_once(tx_repo, spec: TransformerSpec, run, monkeypatch) -> None:
    """The pool holds the build itself: the tool's text has its line, and the file it publishes is not read twice."""
    pool, served = build_held_elsewhere(tx_repo, spec)
    monkeypatch.setattr("doc_search.server.IndexPool", lambda cfg, **kwargs: pool)

    text = run("status")
    payload = json.loads(run("status", "--format", "json").out)

    line = f"docs: transformer index building, 0 / {len(served.docs.chunks)} chunks encoded"
    assert text.lines.count(line) == 1
    assert "docs index: ready (semble's static index, while the transformer index builds)" in text.lines
    assert payload["docs"]["transformer"]["progress"]["phase"] == "encoding"
    assert payload["docs"]["state"] == "ready"


class SlowCloudLeg:
    """A cloud leg whose `status_lines` hangs for up to 10 s (until `gate` is set), as a stamp read can."""

    def __init__(self) -> None:
        self.gate = threading.Event()

    def hits(self, *args, **kwargs):  # pragma: no cover - status never searches
        raise AssertionError("status must not search the cloud")

    def status_lines(self, worktree: Path) -> list[str]:
        self.gate.wait(10)
        return ["cloud: late"]


@pytest.mark.parametrize("fmt", ["text", "json"])
def test_status_bounds_the_cloud_lines(git_repo, tiny_model: str, monkeypatch: pytest.MonkeyPatch, run, fmt) -> None:
    made = git_repo()
    seed(made, tiny_model, cloud=CLOUD)
    monkeypatch.chdir(made.root)
    leg = SlowCloudLeg()
    monkeypatch.setattr("doc_search.server.build_cloud_leg", lambda cfg, corpus_for=None: leg)
    try:
        start = time.monotonic()
        done = run("status", "--format", fmt)
        took = time.monotonic() - start
    finally:
        leg.gate.set()

    assert took < 4.0, f"status took {took:.1f} s"
    assert done.code == 0
    line = "cloud: status unavailable (timed out after 3 s)"
    if fmt == "text":
        assert line in done.lines and "cloud: late" not in done.out
    else:
        payload = json.loads(done.out)
        assert payload["cloud"] == {"configured": True, "lines": [line]}
        assert payload["ready"] is False
        assert payload["cache"] == {"docs": "absent", "code": "absent", "docs_fallback": None}


# --- index --cloud: the exit-code mapping ----------------------------------------------------------------


@dataclass
class StubIndexer:
    report: IndexReport | None = None
    raises: BaseException | None = None
    calls: list[tuple] = field(default_factory=list)

    def run(self, mode, allow_off_base=False, force=False):
        self.calls.append((mode, allow_off_base, force))
        if self.raises is not None:
            raise self.raises
        return self.report or IndexReport(mode)


@pytest.fixture
def stub(monkeypatch: pytest.MonkeyPatch):
    holder = StubIndexer()
    monkeypatch.setattr(cli, "make_indexer", lambda cfg, top: holder)
    return holder


def test_cloud_index_passes_the_flags_through(repo, run, stub: StubIndexer) -> None:
    assert run("index", "--cloud").code == 0
    assert run("index", "--cloud", "--catch-up").code == 0
    assert run("index", "--cloud", "--full", "--allow-off-base").code == 0
    assert run("index", "--cloud", "--prune-orphans", "--force").code == 0
    assert run("index", "--cloud", "--full", "--allow-off-base", "--force").code == 0

    assert stub.calls == [
        ("catch-up", False, False),
        ("catch-up", False, False),
        ("full", True, False),
        ("prune-orphans", False, True),
        ("full", True, True),
    ]


def test_cloud_index_flags_need_cloud_and_exclude_each_other(repo, run, stub: StubIndexer) -> None:
    for argv in (
        ("index", "--full"),
        ("index", "--catch-up"),
        ("index", "--prune-orphans"),
        ("index", "--allow-off-base"),
        ("index", "--force"),
        ("index", "--cloud", "--full", "--catch-up"),
        ("index", "--cloud", "--full", "--prune-orphans"),
    ):
        assert run(*argv).code == 3, argv
    assert stub.calls == []


def test_cloud_index_report(repo, run, stub: StubIndexer) -> None:
    stub.report = IndexReport(
        "full",
        files_written=4,
        files_skipped=7,
        files_deleted=1,
        chunks_written=19,
        orphans_removed=2,
        stamped=True,
        stamp="0123456789abcdef0123456789abcdef01234567",
        notes=["corpus was empty"],
    )

    done = run("index", "--cloud", "--full")

    assert done.code == 0 and done.err == ""
    assert "mode: full" in done.out
    assert "files: 4 written, 7 skipped, 1 deleted" in done.out
    assert "chunks written: 19" in done.out
    assert "orphans: 2 removed, 0 pending" in done.out
    assert "stamped: yes (0123456789abcdef0123456789abcdef01234567)" in done.out
    assert "note: corpus was empty" in done.out

    stub.report = IndexReport("catch-up", notes=["corpus is at HEAD"])
    noop = run("index", "--cloud")
    assert noop.code == 0 and "stamped: no" in noop.out and "note: corpus is at HEAD" in noop.out


def test_cloud_index_findings_are_exit_1(repo, run, stub: StubIndexer) -> None:
    stub.report = IndexReport("full", files_written=1, files_failed={"docs/a.md": "ValueError: boom"})
    failed = run("index", "--cloud", "--full")
    assert failed.code == 1 and "failed: docs/a.md: ValueError: boom" in failed.out and "stamped: no" in failed.out

    stub.report = IndexReport("full", orphans_pending=31, orphans_sample=["x/a.md", "x/b.md"])
    pending = run("index", "--cloud", "--full")
    assert pending.code == 1
    assert "orphans: 0 removed, 31 pending" in pending.out and "x/a.md, x/b.md" in pending.out


def test_cloud_index_could_not_run_is_exit_2(repo, run, stub: StubIndexer) -> None:
    held = LeaseHeld("other:9", None)
    for error, needle in (
        (BaseRefError("HEAD (abc1234) is not main"), "is not main"),
        (held, "other:9"),
        (CorpusRefused("corpus belongs to another repository"), "another repository"),
        (CloudUnavailable("no credentials"), "no credentials"),
        (RuntimeError("PermissionDenied: 403"), "PermissionDenied"),
    ):
        stub.raises = error
        done = run("index", "--cloud")
        assert done.code == 2, error
        assert done.err.startswith("doc-search: ") and needle in done.err and done.err.count("\n") == 1
        assert "Traceback" not in done.err

    stub.raises = LeaseLost("b:2", IndexReport("full", files_written=3))
    lost = run("index", "--cloud", "--full")
    assert lost.code == 2
    assert "files: 3 written" in lost.out, "what the run had done is still reported"
    assert "b:2" in lost.err and lost.err.count("\n") == 1


def test_cloud_index_without_a_cloud_object_is_exit_2(repo, run) -> None:
    done = run("index", "--cloud")

    assert done.code == 2 and done.out == ""
    assert done.err.startswith("doc-search: ") and "cloud is not configured" in done.err


def test_cloud_index_end_to_end_over_the_fakes(git_repo, tiny_model: str, monkeypatch, run) -> None:
    pytest.importorskip("google.genai")
    pytest.importorskip("google.cloud.firestore")
    from fakes import FakeFirestore, FakeGenai

    from doc_search.cloud.vertex import VertexEmbedder
    from doc_search.cloud.write import CloudIndexer

    made = git_repo()
    seed(made, tiny_model, cloud=CLOUD)
    monkeypatch.chdir(made.root)
    fs, genai = FakeFirestore(), FakeGenai()

    def fake_indexer(cfg, top):
        embedder = VertexEmbedder(cfg.cloud, client=genai, sleep=lambda _: None)
        return CloudIndexer(cfg, top, embedder, client=fs, holder="a:1")

    monkeypatch.setattr(cli, "make_indexer", fake_indexer)

    done = run("index", "--cloud", "--full")

    assert done.code == 0, done
    head = made.git("rev-parse", "HEAD").strip()
    assert "mode: full" in done.out and f"stamped: yes ({head})" in done.out
    assert {d["path"] for d in fs.collection("doc_chunks").docs.values()} >= {SPEC_PATH, SHIPPING_PATH}
    assert fs.collection("corpus_meta").docs["index"]["built_from_commit"] == head

    again = run("index", "--cloud")
    assert again.code == 0 and "corpus is at HEAD" in again.out


# --- eval ------------------------------------------------------------------------------------------------


def test_score_ranking() -> None:
    assert score_ranking(["a", "b", "c"], ["a"], 3) == (1.0, 1.0)
    assert score_ranking(["a", "b", "c"], ["c"], 3) == (1.0, pytest.approx(1 / 3))
    assert score_ranking(["a", "b", "c"], ["c"], 2) == (0.0, 0.0)  # beyond k does not count
    assert score_ranking(["x", "a", "b"], ["a", "b", "z"], 3) == (pytest.approx(2 / 3), 0.5)
    assert score_ranking(["a", "a", "b"], ["b"], 3) == (1.0, pytest.approx(1 / 3))  # no dedupe here: callers do it
    assert score_ranking([], ["a"], 10) == (0.0, 0.0)
    assert score_ranking(["a"], ["a", "a"], 10) == (1.0, 1.0)  # a repeated expectation counts once


LEG_ROW = re.compile(
    r"^(?P<leg>docs|code|cloud|all|semble-single)\s+recall@(?P<k>\d+) (?P<recall>\d\.\d+)\s+MRR (?P<mrr>\d\.\d+)"
)
DECISION = re.compile(r"^semble-single within 0\.02 of joined \(recall@k and MRR\): (yes|no)$")


def rows(out: str) -> dict[str, tuple[float, float]]:
    found = {}
    for line in out.splitlines():
        if match := LEG_ROW.match(line):
            found[match["leg"]] = (float(match["recall"]), float(match["mrr"]))
    return found


def test_eval_legs_and_decision_line(repo, run, tmp_path: Path) -> None:
    path = cases_file(tmp_path, *KNOWN)

    done = run("eval", str(path), "--k", "10")

    assert done.code == 0 and done.err == ""
    scored = rows(done.out)
    assert list(scored) == ["docs", "code", "all", "semble-single"], "no cloud leg when cloud is off"
    for recall, mrr in scored.values():
        assert 0.0 <= mrr <= recall <= 1.0
    # two docs and one code file: everything is within the top 10 of its own scope, and only there
    assert scored["docs"][0] == pytest.approx(0.75)  # all but the code case
    assert scored["code"][0] == pytest.approx(0.25)  # the code case alone
    assert scored["all"][0] == pytest.approx(1.0)
    assert scored["semble-single"][0] == pytest.approx(1.0)
    assert done.lines[0].startswith("doc-search eval") and "4 queries" in done.lines[0] and "k=10" in done.lines[0]
    assert DECISION.match(done.lines[-1]), done.lines[-1]
    assert done.lines[-1].endswith("yes"), "both joined and single answer every case here"

    # per-kind breakdown under each leg
    for kind in ("paraphrase", "identifier", "legacy", "code"):
        assert sum(1 for line in done.lines if re.match(rf"\s+{kind}\s+\(1\)\s+recall@10 ", line)) == 4, kind


OLD_PATH = "docs/old-gateway.md"
OLD = "---\nstatus: deprecated\n---\n# Legacy gateway\n\nThe legacy gateway was retired after the migration.\n"
SUPERSEDED_PATH = "docs/older-gateway.md"
SUPERSEDED = "---\nstatus: superseded\n---\n# Older gateway\n\nThe older gateway notes of 2025.\n"


def test_eval_scores_terminal_docs_on_the_docs_and_joined_legs(repo, run, tmp_path: Path) -> None:
    """semble-single cannot filter on status, so the docs and all legs do not either: the comparison is fair."""
    repo.write(OLD_PATH, OLD)
    repo.write(SUPERSEDED_PATH, SUPERSEDED)
    repo.commit("a deprecated doc and a superseded one")
    path = cases_file(
        tmp_path,
        {"query": "legacy gateway retired migration", "expect": [OLD_PATH]},
        {"query": "older gateway notes", "expect": [SUPERSEDED_PATH]},
    )

    done = run("eval", str(path), "--k", "10")

    assert done.code == 0
    assert "(terminal docs included)" in done.lines[0], done.lines[0]
    scored = rows(done.out)
    assert scored["docs"][0] == 1.0, "a deprecated and a superseded doc are found by the docs leg"
    assert scored["all"][0] == 1.0
    assert scored["semble-single"][0] == 1.0
    # an ordinary search still hides them: only the eval widens the allowed set
    hidden = run("query", "legacy gateway retired migration", "--scope", "docs")
    assert OLD_PATH not in hidden.out and SUPERSEDED_PATH not in hidden.out


def test_run_eval_asks_for_terminal_docs_and_the_cloud_alone_is_allowed_them(repo, tmp_path: Path) -> None:
    repo.write(OLD_PATH, OLD)
    repo.commit("a deprecated doc")
    _, info, pool, corpus_for, searcher = eval_parts(repo)
    cloud = StubCloud([OLD_PATH, SPEC_PATH])
    asked: list[SearchRequest] = []
    real = searcher.search
    searcher.search = lambda req, worktree: asked.append(req) or real(req, worktree)  # type: ignore[method-assign]
    path = cases_file(tmp_path, {"query": "legacy gateway", "expect": [OLD_PATH]})

    report = run_eval(searcher, pool, path, 10, info.top, cloud=cloud, corpus_for=corpus_for)

    by_scope = {req.scope: req.include_terminal for req in asked}
    assert by_scope == {"docs": True, "code": False, "all": True}
    assert report.recall("docs") == 1.0 and report.recall("all") == 1.0
    assert report.recall("cloud") == 1.0, "the cloud leg alone is allowed the deprecated doc"
    assert cloud.asked == [("legacy gateway", 3, 30)], "its allowed set holds all three docs, the deprecated one too"
    assert "(terminal docs included)" in report.render().splitlines()[0]


def test_eval_identifier_ranks_first(repo, run, tmp_path: Path) -> None:
    path = cases_file(tmp_path, {"query": "SPEC-PAY-004", "expect": [SPEC_PATH]})

    done = run("eval", str(path))

    assert rows(done.out)["docs"] == (1.0, 1.0), "the ident leg puts the named spec first"
    assert not any(re.match(r"\s+\w+\s+\(\d+\)", line) for line in done.lines), "no kinds, no breakdown"


def test_eval_reports_only_the_legs_that_ran(repo, run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # code off: the code leg and the single index (nothing to join) are skipped, with the reason; the rest run
    made = repo
    made.write(CONFIG_REL, json.dumps({**json.loads((made.root / CONFIG_REL).read_text()), "code": {"enabled": False}}))
    made.commit("code off")
    done = run("eval", str(cases_file(tmp_path, KNOWN[0])))

    assert done.code == 0
    assert re.search(r"^code\s+skipped: ", done.out, re.M) and re.search(r"^semble-single\s+skipped: ", done.out, re.M)
    assert list(rows(done.out)) == ["docs", "all"]
    assert done.lines[-1] == "semble-single within 0.02 of joined (recall@k and MRR): no"


def test_eval_skips_the_legs_that_cannot_answer(repo, run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Every index fails to build: no leg is scored 0, each says why, and the decision is no."""

    def boom(cls, *args, **kwargs):
        raise RuntimeError("no model for you")

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(boom))
    path = cases_file(tmp_path, KNOWN[0])

    done = run("eval", str(path))

    assert done.code == 0
    assert rows(done.out) == {}
    for leg in ("docs", "code", "all", "semble-single"):
        assert re.search(rf"^{leg}\s+skipped: .*(no model for you|index failed)", done.out, re.M), (leg, done.out)
    assert done.lines[-1] == "semble-single within 0.02 of joined (recall@k and MRR): no"

    unchecked = run("eval", str(path), "--min-recall", "0.5")
    assert unchecked.code == 2 and "`all` leg did not run" in unchecked.err


def test_eval_skips_the_single_index_for_a_transformer_model(
    tx_repo, spec: TransformerSpec, run, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One index over docs and code would encode the code with the transformer: the leg says so, and builds nothing."""
    built: list[tuple[str, ...]] = []
    real = SembleIndex.from_path.__func__

    def from_path(cls, path, *args, **kwargs):
        built.append(tuple(c.name for c in kwargs.get("content", ())))
        return real(cls, path, *args, **kwargs)

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(from_path))

    done = run("eval", str(cases_file(tmp_path, KNOWN[0])))

    assert done.code == 0, done
    reason = "docs.model is a transformer model: the single index would encode the code with it"
    assert re.search(rf"^semble-single\s+skipped: {re.escape(reason)}$", done.out, re.M), done.out
    assert ("DOCS", "CODE") not in built and ("DOCS",) in built
    assert set(rows(done.out)) == {"docs", "code", "all"}
    assert done.lines[-1] == "semble-single within 0.02 of joined (recall@k and MRR): no"


def test_eval_decision_rule(repo, tmp_path: Path) -> None:
    """`yes` unless the single index is worse than the joined one by more than 0.02 on recall or MRR."""
    from doc_search.evaluate import EvalReport, LegResult, Score

    def report(all_: tuple[float, float], single: tuple[float, float]) -> EvalReport:
        legs = [
            LegResult("all", Score(10, *all_), {}, []),
            LegResult("semble-single", Score(10, *single), {}, []),
        ]
        return EvalReport("q.jsonl", 10, 10, legs)

    assert report((0.9, 0.8), (0.9, 0.8)).decision() is True
    assert report((0.9, 0.8), (0.885, 0.785)).decision() is True
    assert report((0.9, 0.8), (0.87, 0.8)).decision() is False  # recall 0.03 short
    assert report((0.9, 0.8), (0.9, 0.77)).decision() is False  # MRR 0.03 short
    assert report((0.9, 0.8), (0.99, 0.95)).decision() is True  # better is within
    skipped = EvalReport(
        "q.jsonl",
        10,
        10,
        [LegResult("all", Score(10, 0.9, 0.8), {}, []), LegResult("semble-single", None, {}, [], skipped="off")],
    )
    assert skipped.decision() is False
    assert report((0.9, 0.8), (0.9, 0.8)).decision_line() == (
        "semble-single within 0.02 of joined (recall@k and MRR): yes"
    )


def test_eval_malformed_line_exit_3(repo, run, tmp_path: Path) -> None:
    for bad, why in (
        ("{ not json", "not valid JSON"),
        ('["a list"]', "object"),
        (json.dumps({"query": "q"}), "expect"),
        (json.dumps({"query": "q", "expect": []}), "expect"),
        (json.dumps({"query": "q", "expect": "docs/a.md"}), "expect"),
        (json.dumps({"query": "q", "expect": [3]}), "expect"),
        (json.dumps({"query": "  ", "expect": ["a.md"]}), "query"),
        (json.dumps({"expect": ["a.md"]}), "query"),
        (json.dumps({"query": "q", "expect": ["a.md"], "kind": 3}), "kind"),
    ):
        path = cases_file(tmp_path, KNOWN[0], "", bad, KNOWN[1], name="bad.jsonl")  # the bad one is on line 3

        done = run("eval", str(path))

        assert done.code == 3, bad
        assert done.out == ""
        assert done.err.startswith("doc-search: eval: ") and "line 3" in done.err and why in done.err, done.err
        assert "bad.jsonl" in done.err and done.err.count("\n") == 1

    nothing = cases_file(tmp_path, "", "", name="empty.jsonl")
    assert run("eval", str(nothing)).code == 3

    binary = tmp_path / "binary.jsonl"
    binary.write_bytes(b'{"query": "q", "expect": ["a.md"]}\n\xff\xfe\n')
    garbage = run("eval", str(binary))
    assert garbage.code == 3 and "binary.jsonl" in garbage.err and "UTF-8" in garbage.err

    missing = run("eval", str(tmp_path / "missing.jsonl"))
    assert missing.code == 2 and missing.err.startswith("doc-search: eval: cannot read ")

    assert run("eval", str(cases_file(tmp_path, KNOWN[0])), "--k", "0").code == 3
    assert run("eval", str(cases_file(tmp_path, KNOWN[0])), "--k", "51").code == 3
    assert run("eval", str(cases_file(tmp_path, KNOWN[0])), "--min-recall", "1.5").code == 3


def test_eval_file_error_names_the_line(tmp_path: Path) -> None:
    path = cases_file(tmp_path, KNOWN[0], "{", name="q.jsonl")

    with pytest.raises(EvalFileError) as caught:
        run_eval(None, None, path, 10, tmp_path)  # type: ignore[arg-type]  # parsed before anything is touched

    assert caught.value.line == 2 and "line 2" in str(caught.value)


def test_eval_min_recall_exit_1(repo, run, tmp_path: Path) -> None:
    hard = cases_file(tmp_path, {"query": "refund rounding", "expect": ["docs/not-there.md"]}, name="hard.jsonl")

    below = run("eval", str(hard), "--min-recall", "0.5")

    assert below.code == 1
    assert DECISION.match(below.lines[-1]), "the report is printed in full, decision line last"
    assert "below --min-recall" in below.err and below.err.count("\n") == 1

    easy = cases_file(tmp_path, KNOWN[0], KNOWN[2], name="easy.jsonl")
    assert run("eval", str(easy), "--min-recall", "1.0").code == 0
    assert run("eval", str(easy)).code == 0, "without --min-recall a low score is still exit 0"


# --- eval: the cloud leg -----------------------------------------------------------------------------------


class StubCloud:
    """A cloud leg that answers from a fixed list of paths (one chunk each, repeats allowed)."""

    def __init__(self, paths: list[str], note: str | None = None, *, leak: bool = False) -> None:
        self.paths, self.note, self.leak = paths, note, leak
        self.asked: list[tuple[str, int, int]] = []

    def hits(self, query, allowed, worktree, limit, doc_types=()):
        self.asked.append((query, len(allowed), limit))
        found = [Hit("doc", p, 1, 3, "text", legs=("cloud",)) for p in self.paths if self.leak or p in allowed]
        return found[:limit], self.note

    def status_lines(self, worktree):
        return ["cloud: stub"]


def eval_parts(repo, cloud=None, wait_s=60):
    """What `run_eval` takes, built the way the CLI builds it."""
    from doc_search.config import load_config
    from doc_search.corpus import Corpus
    from doc_search.docindex import DocIndex
    from doc_search.repo import RepoInfo
    from doc_search.searcher import Searcher

    cfg = load_config(repo.root, {})
    info = RepoInfo.from_cwd(repo.root)
    pool = IndexPool(cfg)
    corpora: dict[Path, Corpus] = {}

    def corpus_for(worktree: Path) -> Corpus:
        return corpora.setdefault(worktree, Corpus(worktree, cfg, DocIndex(worktree)))

    return cfg, info, pool, corpus_for, Searcher(cfg, info, pool, corpus_for, cloud=cloud, wait_s=wait_s)


def test_run_eval_scores_the_cloud_leg_alone(repo, tmp_path: Path) -> None:
    # six chunks in the cloud's answer: four of one file, one outside the corpus, then the spec
    cloud = StubCloud([SHIPPING_PATH] * 4 + ["docs/other.md", SPEC_PATH], leak=True)
    _, info, pool, corpus_for, searcher = eval_parts(repo, cloud)
    path = cases_file(tmp_path, {"query": "anything", "expect": [SPEC_PATH], "kind": "k"})

    report = run_eval(searcher, pool, path, 2, info.top, cloud=cloud, corpus_for=corpus_for)

    assert [leg.name for leg in report.legs] == ["docs", "code", "cloud", "all", "semble-single"]
    leg = next(leg for leg in report.legs if leg.name == "cloud")
    # asked for k x 3 = 6 chunks, collapsed per file, outside-the-corpus dropped: [shipping, spec]
    assert leg.overall.recall == 1.0 and leg.overall.mrr == 0.5
    assert leg.by_kind["k"].queries == 1
    assert ("anything", 2, 6) in cloud.asked, "asked directly with the allowed set and limit k x 3"


def test_run_eval_waits_for_the_builds_whatever_the_searcher_waits(repo, tmp_path: Path) -> None:
    """A cold pool and a searcher that would answer `index building` at once: the legs are still scored."""
    _, info, pool, _, searcher = eval_parts(repo, wait_s=0)
    path = cases_file(tmp_path, KNOWN[0])

    report = run_eval(searcher, pool, path, 10, info.top)

    assert all(leg.skipped is None for leg in report.legs), [(leg.name, leg.skipped) for leg in report.legs]
    assert report.recall("docs") == 1.0 and report.recall("all") == 1.0


def test_run_eval_single_leg_is_one_index_asked_for_three_times_k(repo, tmp_path: Path, monkeypatch) -> None:
    from types import SimpleNamespace

    asked: list[dict] = []
    built: list[dict] = []

    class OneIndex:
        def search(self, query, top_k=10, **kw):
            asked.append({"query": query, "top_k": top_k, **kw})
            chunks = ["a.md", "a.md", "a.md", "b.py", "a.md", "c.md", "c.md", "d.md"]  # chunk-level, repeats
            return [SimpleNamespace(chunk=SimpleNamespace(file_path=p)) for p in chunks[:top_k]]

    real = SembleIndex.from_path.__func__

    def from_path(cls, path, **kwargs):
        if [c.name for c in kwargs["content"]] != ["DOCS", "CODE"]:
            return real(cls, path, **kwargs)  # the pool's own indexes are real
        built.append({"path": path, **kwargs})
        return OneIndex()

    monkeypatch.setattr(SembleIndex, "from_path", classmethod(from_path))
    monkeypatch.setattr("doc_search.evaluate.save_index_to_cache", lambda index, path: None)
    cfg, info, pool, _, searcher = eval_parts(repo)
    path = cases_file(tmp_path, {"query": "q", "expect": ["c.md"]}, {"query": "q2", "expect": ["d.md"]})

    report = run_eval(searcher, pool, path, 2, info.top)

    single = next(leg for leg in report.legs if leg.name == "semble-single")
    assert [(b["path"], [c.name for c in b["content"]], b["model_path"]) for b in built] == [
        (str(info.top), ["DOCS", "CODE"], cfg.docs.model)
    ]
    assert [a["top_k"] for a in asked] == [6, 6]
    # collapsed per file in rank order: a.md, b.py, c.md: c.md is third, beyond k = 2
    assert single.overall.recall == 0.0 and single.overall.mrr == 0.0
    report = run_eval(searcher, pool, path, 3, info.top)
    single = next(leg for leg in report.legs if leg.name == "semble-single")
    assert [a["top_k"] for a in asked][-2:] == [9, 9]
    assert single.overall.recall == 0.5 and single.overall.mrr == pytest.approx(1 / 6), (  # c.md third; d.md is fourth
        "c.md is the third file of the first query, d.md the fourth of the second"
    )


class ScriptedCloud:
    """A cloud leg that answers each call from a script: an exception to raise, or (paths, note)."""

    def __init__(self, *script) -> None:
        self.script = list(script)

    def hits(self, query, allowed, worktree, limit, doc_types=()):
        step = self.script.pop(0)
        if isinstance(step, BaseException):
            raise step
        paths, note = step
        return [Hit("doc", p, 1, 3, "text", legs=("cloud",)) for p in paths], note

    def status_lines(self, worktree):
        return []


def test_cloud_leg_that_answers_no_query_is_skipped_not_scored_zero(repo, tmp_path: Path) -> None:
    _, info, pool, corpus_for, searcher = eval_parts(repo)  # the searcher has no cloud: only the leg alone asks it
    path = cases_file(tmp_path, KNOWN[0], KNOWN[2])
    no_stamp = "cloud skipped: no corpus stamp (corpus_meta/index)"
    for cloud, reason in (
        (ScriptedCloud(RuntimeError("boom"), RuntimeError("later")), "cloud leg failed (RuntimeError: boom)"),
        (DegradedLeg("no credentials"), "cloud failed: no credentials"),
        (ScriptedCloud(([], no_stamp), ([], no_stamp)), no_stamp),
    ):
        report = run_eval(searcher, pool, path, 10, info.top, cloud=cloud, corpus_for=corpus_for)

        leg = report.leg("cloud")
        assert leg.overall is None and leg.skipped == reason, reason
        assert re.search(rf"^cloud\s+skipped: {re.escape(reason)}$", report.render(), re.M)
        assert report.leg("all").overall is not None, "the other legs are scored as usual"


def test_cloud_leg_that_fails_some_queries_is_scored_with_a_note(repo, tmp_path: Path) -> None:
    _, info, pool, corpus_for, searcher = eval_parts(repo)
    path = cases_file(tmp_path, KNOWN[0], KNOWN[2])
    cloud = ScriptedCloud(RuntimeError("boom"), ([SHIPPING_PATH], None))

    report = run_eval(searcher, pool, path, 10, info.top, cloud=cloud, corpus_for=corpus_for)

    leg = report.leg("cloud")
    assert leg.skipped is None and (leg.overall.recall, leg.overall.mrr) == (0.5, 0.5)
    assert leg.notes == ["cloud leg failed (RuntimeError: boom)"]

    nothing = ScriptedCloud(([], None), ([], None))  # an empty answer with no note is an answer
    empty = run_eval(searcher, pool, path, 10, info.top, cloud=nothing, corpus_for=corpus_for).leg("cloud")
    assert empty.skipped is None and (empty.overall.recall, empty.overall.mrr) == (0.0, 0.0)


def test_eval_cloud_leg_that_cannot_answer_through_the_cli(git_repo, tiny_model: str, tmp_path, monkeypatch, run):
    made = git_repo()
    seed(made, tiny_model, cloud=CLOUD)
    monkeypatch.chdir(made.root)
    monkeypatch.setattr("doc_search.server.build_cloud_leg", lambda cfg, corpus_for=None: DegradedLeg("no creds"))

    done = run("eval", str(cases_file(tmp_path, KNOWN[0], KNOWN[2])))

    assert done.code == 0
    assert re.search(r"^cloud\s+skipped: cloud failed: no creds$", done.out, re.M)
    assert list(rows(done.out)) == ["docs", "code", "all", "semble-single"]


def test_eval_cloud_leg_through_the_cli(git_repo, tiny_model: str, tmp_path: Path, monkeypatch, run) -> None:
    made = git_repo()
    seed(made, tiny_model, cloud=CLOUD)
    monkeypatch.chdir(made.root)
    cloud = StubCloud([SHIPPING_PATH], note="cloud failed: no credentials")
    monkeypatch.setattr("doc_search.server.build_cloud_leg", lambda cfg, corpus_for=None: cloud)

    done = run("eval", str(cases_file(tmp_path, KNOWN[0], KNOWN[2])))

    assert done.code == 0
    scored = rows(done.out)
    assert list(scored) == ["docs", "code", "cloud", "all", "semble-single"]
    assert scored["cloud"][0] == pytest.approx(0.5)  # only the shipping case
    assert "note: cloud failed: no credentials (docs, cloud, all)" in done.lines, "one note, naming the legs"

    query = run("query", "shipping fee flat rate", "--scope", "docs", "--format", "json")
    assert json.loads(query.out)["header"]["cloud"] == "gemini-embedding-001"

    off = run("status", "--format", "json")
    assert json.loads(off.out)["cloud"] == {"configured": True, "lines": ["cloud: stub"]}
    assert build_threads() == [], "status starts no build"


def test_nothing_is_left_building(repo, run, tmp_path: Path) -> None:
    """The verbs that build return with their build threads finished (`status` builds nothing)."""
    for argv in (("index",), ("query", "refund"), ("eval", str(cases_file(tmp_path, KNOWN[0])))):
        assert run(*argv).code == 0
    assert build_threads() == []
