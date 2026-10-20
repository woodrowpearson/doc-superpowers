"""The docs corpus: discovery, enrichment (type, status, title, headings) and tolerance of odd files."""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

import pytest

from doc_search.config import ConfigError, load_config
from doc_search.corpus import Corpus, is_terminal
from doc_search.docindex import DocIndex
from doc_search.types import DocMeta


def make_corpus(repo, config: dict | None = None) -> Corpus:
    """A Corpus over `repo` with docs/search/config.json set to `config` (defaults for `{}`)."""
    repo.write("docs/search/config.json", json.dumps(config or {}))
    cfg = load_config(repo.root, {})
    assert cfg is not None
    return Corpus(repo.root, cfg, DocIndex(repo.root))


def write_index(top: Path, docs: dict[str, dict]) -> Path:
    path = top / "docs" / ".doc-index.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 3, "docs": docs}), encoding="utf-8")
    return path


def meta_of(corpus: Corpus, path: str) -> DocMeta:
    meta = corpus.meta(path)
    assert meta is not None, f"{path} has no meta; skipped: {corpus.skipped()}"
    return meta


def doc_meta(path: str = "docs/a.md", status: str | None = None) -> DocMeta:
    return DocMeta(
        path=path, title="T", doc_type="other", status=status, code_refs=(), replaces=None, superseded_by=None
    )


# --- discovery -----------------------------------------------------------------------


def test_discovery_defaults(git_repo) -> None:
    repo = git_repo()
    repo.write(".gitignore", "docs/tmp.md\n")
    repo.write("docs/a.md", "# A\n")
    repo.write("README.md", "# Readme\n")
    repo.write("docs/archive/old.md", "# Old\n")
    repo.write("src/x.py", "x = 1\n")
    repo.commit("base")
    repo.write("docs/new.md", "# New\n")  # untracked, not ignored
    repo.write("docs/tmp.md", "# Ignored\n")  # untracked and gitignored

    corpus = make_corpus(repo)

    assert corpus.files() == ["README.md", "docs/a.md", "docs/new.md"]
    assert corpus.contains("docs/a.md")
    assert corpus.contains("./docs/new.md")
    assert not corpus.contains("docs/archive/old.md")
    assert not corpus.contains("docs/tmp.md")
    assert not corpus.contains("src/x.py")


def test_in_scope_is_the_globs_alone(git_repo) -> None:
    repo = git_repo()
    corpus = make_corpus(repo, {"docs": {"include": ["docs/**/*.md"], "exclude": ["docs/archive/**"]}})

    assert corpus.in_scope("docs/a.md") and corpus.in_scope("./docs/deep/er.md")
    assert not corpus.in_scope("docs/archive/a.md") and not corpus.in_scope("src/x.py")
    assert corpus.in_scope("docs/never/existed.md"), "the disk and git are not consulted"


def test_discovery_honours_include_and_exclude(git_repo) -> None:
    repo = git_repo()
    repo.write("README.md", "# Readme\n")
    repo.write("docs/x.md", "# X\n")
    repo.write("docs/internal/y.md", "# Y\n")
    repo.write("docs/internal/keep.md", "# Keep\n")
    repo.commit("base")
    corpus = make_corpus(
        repo,
        {"docs": {"include": ["docs/**/*.md"], "exclude": ["docs/internal/**", "!docs/internal/keep.md"]}},
    )
    assert corpus.files() == ["docs/internal/keep.md", "docs/x.md"]


def test_discovery_is_the_working_tree(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.write("docs/gone.md", "# Gone\n")
    outside = tmp_path / "outside.md"
    outside.write_text("# Secret title\n")
    (repo.root / "docs" / "alias.md").symlink_to("a.md")
    (repo.root / "docs" / "leak.md").symlink_to(outside)
    (repo.root / "docs" / "dangling.md").symlink_to("nowhere.md")
    repo.commit("base")
    (repo.root / "docs" / "gone.md").unlink()  # tracked, deleted in the working tree, not committed

    corpus = make_corpus(repo)

    assert corpus.files() == ["docs/a.md", "docs/alias.md"]
    # a symlink out of the worktree is never read for its title
    assert corpus.meta("docs/leak.md") is None
    assert meta_of(corpus, "docs/alias.md").title == "A"


def test_files_cached_for_rescan_seconds(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.commit("base")
    slow = make_corpus(repo, {"search": {"rescan_seconds": 3600}})
    fast = make_corpus(repo, {"search": {"rescan_seconds": 0}})
    assert slow.files() == fast.files() == ["docs/a.md"]

    repo.write("docs/b.md", "# B\n")

    assert slow.files() == ["docs/a.md"]
    assert slow.contains("docs/b.md") is False
    assert fast.files() == ["docs/a.md", "docs/b.md"]
    assert fast.contains("docs/b.md") is True


def test_files_returns_a_copy(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.commit("base")
    corpus = make_corpus(repo)
    corpus.files().append("docs/mutated.md")
    assert corpus.files() == ["docs/a.md"]


def test_invalid_glob_is_a_config_error(git_repo) -> None:
    repo = git_repo()
    with pytest.raises(ConfigError, match=r"docs\.include"):
        make_corpus(repo, {"docs": {"include": ["!"]}})
    with pytest.raises(ConfigError, match=r"docs\.exclude"):
        make_corpus(repo, {"docs": {"exclude": ["\\"]}})
    with pytest.raises(ConfigError, match=r"docs\.types\[0\]"):
        make_corpus(repo, {"docs": {"types": [{"glob": "!", "type": "x"}]}})


def test_regex_failure_in_a_glob_is_a_config_error(git_repo) -> None:
    """pathspec turns some globs into a bad regex (`[z-a]`): that is `re.error`, not `ValueError`."""
    repo = git_repo()
    with pytest.raises(ConfigError, match=r"docs\.include .*z-a"):
        make_corpus(repo, {"docs": {"include": ["[z-a]"]}})
    with pytest.raises(ConfigError, match=r"docs\.exclude"):
        make_corpus(repo, {"docs": {"exclude": ["[z-a]"]}})
    with pytest.raises(ConfigError, match=r"docs\.types\[0\]"):
        make_corpus(repo, {"docs": {"types": [{"glob": "[z-a]", "type": "x"}]}})


# --- doc_type -------------------------------------------------------------------------


def test_doc_type_resolution_order(git_repo) -> None:
    repo = git_repo()
    # tier 1: the doc-index entry beats front matter and every path rule
    repo.write("docs/adr/0001-index.md", "---\ndoc_type: guide\n---\n# One\n")
    # tier 2: front matter, `doc_type` before `type`, both beating the built-in path rule
    repo.write("docs/adr/0002-fm.md", "---\ntype: fm-type\ndoc_type: fm-doc-type\n---\n# Two\n")
    repo.write("docs/adr/0003-fm-type.md", "---\ntype: fm-type\n---\n# Three\n")
    # tier 3: docs.types rules, in order, beating the built-in path rule
    repo.write("docs/plans/roadmap.md", "# Roadmap\n")
    repo.write("docs/rfcs/0001.md", "# Rfc\n")
    # tier 4: the built-in rules
    repo.write("docs/adr/0004-builtin.md", "# Four\n")
    # tier 5: nothing answers
    repo.write("docs/misc/note.md", "# Note\n")
    repo.write("README.md", "# Readme\n")
    write_index(repo.root, {"docs/adr/0001-index.md": {"doc_type": "from-index"}})
    repo.commit("base")

    corpus = make_corpus(
        repo,
        {
            "docs": {
                "types": [
                    {"glob": "docs/plans/**", "type": "roadmap"},
                    {"glob": "docs/rfcs/", "type": "rfc"},
                    {"glob": "docs/rfcs/0*.md", "type": "never-reached"},
                ]
            }
        },
    )

    assert {path: meta_of(corpus, path).doc_type for path in corpus.files()} == {
        "README.md": "other",
        "docs/adr/0001-index.md": "from-index",
        "docs/adr/0002-fm.md": "fm-doc-type",
        "docs/adr/0003-fm-type.md": "fm-type",
        "docs/adr/0004-builtin.md": "adr",
        "docs/misc/note.md": "other",
        "docs/plans/roadmap.md": "roadmap",
        "docs/rfcs/0001.md": "rfc",
    }


@pytest.mark.parametrize(
    ("rel", "doc_type"),
    [
        ("docs/superpowers/specs/s.md", "design-spec"),
        ("docs/adr/a.md", "adr"),
        ("docs/specs/s.md", "spec"),
        ("docs/plans/p.md", "plan"),
        ("docs/issues/i.md", "issue"),
        ("docs/architecture/c.md", "architecture"),
        ("docs/workflows/w.md", "workflows"),
        ("docs/guides/g.md", "guide"),
        ("docs/adr-notes.md", "other"),
        ("docs/specs.md", "other"),
    ],
)
def test_builtin_doc_type_rules(git_repo, rel: str, doc_type: str) -> None:
    repo = git_repo()
    repo.write(rel, "# Doc\n")
    repo.commit("base")
    assert meta_of(make_corpus(repo), rel).doc_type == doc_type


# --- status, title, code_refs ---------------------------------------------------------


def test_status_sources(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/dep.md", "---\nstatus: accepted\n---\n# Dep\n")
    repo.write("docs/sup.md", "---\nstatus: draft\n---\n# Sup\n")
    repo.write("docs/fm.md", "---\nstatus: Accepted\n---\n# Fm\n")
    repo.write("docs/quoted.md", '---\nstatus: "Rejected"   # why\n---\n# Quoted\n')
    repo.write("docs/bold.md", "# Bold\n\n**Status:** Draft — 2026-10-19\n")
    repo.write("docs/both.md", "---\nstatus: proposed\n---\n# Both\n\n**Status:** Draft\n")
    repo.write("docs/none.md", "# None\n\nNo status anywhere.\n")
    repo.write("docs/line20.md", "".join(f"filler {n}\n" for n in range(1, 20)) + "**Status:** Accepted\n")
    repo.write("docs/line21.md", "".join(f"filler {n}\n" for n in range(1, 21)) + "**Status:** Accepted\n")
    repo.write("docs/after-fm.md", "---\n" + "k: v\n" * 30 + "---\n# After\n**Status:** Accepted\n")
    repo.write("docs/fenced.md", "# Fenced\n\n```md\n**Status:** Accepted\n```\n")
    write_index(
        repo.root,
        {
            "docs/dep.md": {"status": "deprecated", "superseded_by": "docs/new.md"},
            "docs/sup.md": {"superseded_by": "docs/new.md"},
            "docs/none.md": {"superseded_by": None, "replaces": None},
        },
    )
    repo.commit("base")

    corpus = make_corpus(repo)
    statuses = {path: meta_of(corpus, path).status for path in corpus.files()}

    assert statuses == {
        "docs/after-fm.md": "accepted",  # the first 20 lines are counted from the body, past the front matter
        "docs/bold.md": "draft",
        "docs/both.md": "proposed",
        "docs/dep.md": "deprecated",
        "docs/fenced.md": None,
        "docs/fm.md": "accepted",
        "docs/line20.md": "accepted",
        "docs/line21.md": None,
        "docs/none.md": None,
        "docs/quoted.md": "rejected",
        "docs/sup.md": "superseded",
    }


def test_front_matter_status_is_its_first_word(git_repo) -> None:
    """MADR's `status: superseded by ADR-0005` is `superseded` (terminal), as the `**Status:**` line already reads."""
    repo = git_repo()
    repo.write("docs/madr.md", "---\nstatus: superseded by ADR-0005\n---\n# Madr\n")
    repo.write("docs/dated.md", "---\nstatus: Accepted (2026-10-19)\n---\n# Dated\n")
    repo.write("docs/marked.md", "---\nstatus: '`Deprecated`: see ADR-9'\n---\n# Marked\n")
    repo.write("docs/dash.md", "---\nstatus: in-progress since May\n---\n# Dash\n")
    repo.write("docs/wordless.md", "---\nstatus: '2026'\n---\n# Wordless\n\n**Status:** Draft\n")
    repo.commit("base")

    corpus = make_corpus(repo)
    statuses = {path: meta_of(corpus, path).status for path in corpus.files()}

    assert statuses == {
        "docs/dash.md": "in-progress",
        "docs/dated.md": "accepted",
        "docs/madr.md": "superseded",
        "docs/marked.md": "deprecated",
        "docs/wordless.md": "draft",  # no word in the front matter: the `**Status:**` line answers
    }
    assert is_terminal(meta_of(corpus, "docs/madr.md"), corpus._cfg)
    assert "docs/madr.md" not in corpus.allowed((), None, include_terminal=False)


def test_meta_title_and_index_fields(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/h1.md", "---\ntitle: Front Title\n---\n\n# Real Heading #\n\n## Sub\n")
    repo.write("docs/fm-title.md", "---\n# a comment\ntitle: 'Only Front Title'\n---\n\nbody\n")
    repo.write("docs/stem-name.md", "just text\n\n## Only a sub\n")
    repo.write("docs/fenced.md", "```sh\n# shell comment\n```\n")
    repo.write("docs/late-h1.md", "intro\n\n## Sub first\n\n# Late H1\n")
    repo.write("docs/ref.md", "# Ref\n")
    write_index(
        repo.root,
        {
            "docs/ref.md": {
                "doc_type": "guide",
                "code_refs": ["src/", "lib/a.py", 7],
                "replaces": "docs/old.md",
                "superseded_by": "docs/newer.md",
            }
        },
    )
    repo.commit("base")

    corpus = make_corpus(repo)

    assert meta_of(corpus, "docs/h1.md").title == "Real Heading"
    assert meta_of(corpus, "docs/fm-title.md").title == "Only Front Title"
    assert meta_of(corpus, "docs/stem-name.md").title == "stem-name"
    assert meta_of(corpus, "docs/fenced.md").title == "fenced"
    assert meta_of(corpus, "docs/late-h1.md").title == "Late H1"
    ref = meta_of(corpus, "docs/ref.md")
    assert ref == DocMeta(
        path="docs/ref.md",
        title="Ref",
        doc_type="guide",
        status="superseded",
        code_refs=("src/", "lib/a.py"),
        replaces="docs/old.md",
        superseded_by="docs/newer.md",
    )
    # no index entry: empty refs, nothing replaced
    plain = meta_of(corpus, "docs/h1.md")
    assert (plain.code_refs, plain.replaces, plain.superseded_by) == ((), None, None)


def test_front_matter_edge_cases(git_repo) -> None:
    repo = git_repo()
    windows = "﻿---\r\ntype: spec\r\nstatus: Draft\r\n---\r\n# Windows\r\n\r\n## Part\r\n"
    repo.write("docs/windows.md", "")
    (repo.root / "docs" / "windows.md").write_bytes(windows.encode("utf-8"))
    repo.write("docs/unterminated.md", "---\ntitle: Not front matter\n# Heading\n")
    repo.write("docs/dots.md", "---\ntype: guide\n...\n# Dots\n")
    repo.write("docs/lists.md", "---\ntype: [a, b]\nstatus: |\n  multi\n---\n# Lists\n")
    repo.commit("base")

    corpus = make_corpus(repo)

    windows_meta = meta_of(corpus, "docs/windows.md")
    assert (windows_meta.title, windows_meta.doc_type, windows_meta.status) == ("Windows", "spec", "draft")
    assert corpus.heading_path_at("docs/windows.md", 7) == ("Windows", "Part")
    unterminated = meta_of(corpus, "docs/unterminated.md")
    assert (unterminated.title, unterminated.doc_type) == ("Heading", "other")
    assert meta_of(corpus, "docs/dots.md").doc_type == "guide"
    lists = meta_of(corpus, "docs/lists.md")
    assert (lists.doc_type, lists.status) == ("other", None)


def test_is_terminal(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/search/config.json", "{}")
    cfg = load_config(repo.root, {})
    assert cfg is not None

    for status in ("deprecated", "superseded", "archived", "Deprecated"):
        assert is_terminal(doc_meta(status=status), cfg), status
    for status in (None, "accepted", "draft"):
        assert not is_terminal(doc_meta(status=status), cfg), status
    # under docs/archive/ is terminal whatever the status says
    assert is_terminal(doc_meta("docs/archive/x.md"), cfg)
    assert is_terminal(doc_meta("docs/archive/x.md", status="accepted"), cfg)
    assert not is_terminal(doc_meta("docs/archives.md"), cfg)

    repo.write("docs/search/config.json", json.dumps({"search": {"terminal_statuses": ["rejected"]}}))
    custom = load_config(repo.root, {})
    assert custom is not None
    assert is_terminal(doc_meta(status="Rejected"), custom)
    assert not is_terminal(doc_meta(status="deprecated"), custom)


# --- caches ---------------------------------------------------------------------------


def test_meta_follows_the_doc_index_without_the_file_changing(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.commit("base")
    corpus = make_corpus(repo)
    before = meta_of(corpus, "docs/a.md")
    assert (before.doc_type, before.status) == ("other", None)

    index = write_index(repo.root, {"docs/a.md": {"doc_type": "guide", "status": "deprecated", "code_refs": ["src/"]}})
    after = meta_of(corpus, "docs/a.md")
    assert (after.doc_type, after.status, after.code_refs) == ("guide", "deprecated", ("src/",))

    write_index(repo.root, {})
    st = index.stat()
    os.utime(index, ns=(st.st_atime_ns, st.st_mtime_ns + 5_000_000_000))
    assert meta_of(corpus, "docs/a.md") == before


def test_meta_cached_by_size_and_mtime(git_repo) -> None:
    repo = git_repo()
    path = repo.write("docs/a.md", "# Old title\n")
    repo.commit("base")
    corpus = make_corpus(repo)
    st = path.stat()
    assert meta_of(corpus, "docs/a.md").title == "Old title"

    # same size and same mtime_ns: the cached parse is reused
    path.write_text("# New title\n", encoding="utf-8")
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert meta_of(corpus, "docs/a.md").title == "Old title"

    # a changed mtime_ns is a changed file
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    assert meta_of(corpus, "docs/a.md").title == "New title"

    # and so is a changed size
    path.write_text("# A longer new title\n", encoding="utf-8")
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    assert meta_of(corpus, "docs/a.md").title == "A longer new title"


# --- headings -------------------------------------------------------------------------

NESTED = """\
---
title: Front title
---
Preamble before any heading.
# Guide
Intro text.
## Setup
Setup text.
### Install
```sh
# not a heading, a shell comment
```
Install text.
## Usage
Usage text.
# Appendix
Appendix text.
"""


def test_heading_path_at(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/guide.md", NESTED)
    repo.commit("base")
    corpus = make_corpus(repo)

    expected = {
        0: ("Guide",),
        1: ("Guide",),
        4: ("Guide",),  # before any heading: just the title
        5: ("Guide",),  # the H1 itself is the title, not a second entry
        6: ("Guide",),
        7: ("Guide", "Setup"),  # a heading line is inside its own section
        8: ("Guide", "Setup"),
        9: ("Guide", "Setup", "Install"),
        11: ("Guide", "Setup", "Install"),  # the fenced `#` line is not a heading
        13: ("Guide", "Setup", "Install"),
        14: ("Guide", "Usage"),
        15: ("Guide", "Usage"),
        16: ("Guide", "Appendix"),  # a later H1 replaces the sections, under the title
        17: ("Guide", "Appendix"),
        999: ("Guide", "Appendix"),
    }
    assert {line: corpus.heading_path_at("docs/guide.md", line) for line in expected} == expected


def test_heading_path_at_title_sources_and_skipped_levels(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/fm.md", "---\ntitle: Front\n---\n\n## One\n\nbody\n\n### Deep\n\n## Two\n\nbody\n")
    repo.write("docs/stem.md", "intro\n\n## One\n")
    repo.write("docs/skip.md", "# T\n\n### Deep\n\ntext\n\n## Mid\n\ntext\n")
    corpus = make_corpus(repo)

    assert corpus.heading_path_at("docs/fm.md", 4) == ("Front",)
    assert corpus.heading_path_at("docs/fm.md", 7) == ("Front", "One")
    assert corpus.heading_path_at("docs/fm.md", 9) == ("Front", "One", "Deep")
    assert corpus.heading_path_at("docs/fm.md", 12) == ("Front", "Two")
    assert corpus.heading_path_at("docs/stem.md", 1) == ("stem",)
    assert corpus.heading_path_at("docs/stem.md", 3) == ("stem", "One")
    assert corpus.heading_path_at("docs/skip.md", 5) == ("T", "Deep")
    assert corpus.heading_path_at("docs/skip.md", 9) == ("T", "Mid")


def test_heading_path_at_beyond_the_head_window(git_repo) -> None:
    repo = git_repo()
    filler = "filler line of text\n" * 5000  # about 100 KiB: past the 64 KiB the metadata reads
    repo.write("docs/long.md", f"# Long\n\n## Early\n\n{filler}\n## Late\n\nafter late\n")
    corpus = make_corpus(repo)
    last = 4 + 5000 + 4
    assert corpus.heading_path_at("docs/long.md", 4 + 5000) == ("Long", "Early")
    assert corpus.heading_path_at("docs/long.md", last) == ("Long", "Late")
    assert meta_of(corpus, "docs/long.md").title == "Long"


def test_heading_path_at_for_unreadable_paths_is_empty(git_repo) -> None:
    repo = git_repo()
    (repo.root / "docs").mkdir()
    (repo.root / "docs" / "latin1.md").write_bytes("# Caf\xe9\n".encode("latin-1"))
    corpus = make_corpus(repo)
    assert corpus.heading_path_at("docs/latin1.md", 1) == ()
    assert corpus.heading_path_at("docs/missing.md", 1) == ()
    assert corpus.heading_path_at("../outside.md", 1) == ()


# --- allowed --------------------------------------------------------------------------


def test_allowed_filters(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/adr/0001.md", "# One\n")
    repo.write("docs/adr/0002.md", "---\nstatus: Deprecated\n---\n# Two\n")
    repo.write("docs/guides/g.md", "# Guide\n")
    repo.write("docs/specs/s.md", "# Spec\n")
    repo.write("docs/plans/p.md", "# Plan\n")
    repo.write("docs/archive/old.md", "# Old\n")
    repo.write("README.md", "# Readme\n")
    write_index(repo.root, {"docs/specs/s.md": {"superseded_by": "docs/specs/s2.md"}})
    repo.commit("base")
    corpus = make_corpus(repo, {"docs": {"exclude": []}})  # keep docs/archive in the corpus

    everything = [
        "README.md",
        "docs/adr/0001.md",
        "docs/adr/0002.md",
        "docs/archive/old.md",
        "docs/guides/g.md",
        "docs/plans/p.md",
        "docs/specs/s.md",
    ]
    live = ["README.md", "docs/adr/0001.md", "docs/guides/g.md", "docs/plans/p.md"]
    assert corpus.files() == everything
    assert corpus.allowed((), None, True) == everything
    # terminal: deprecated (front matter), superseded (index), and under docs/archive/
    assert corpus.allowed((), None, False) == live

    assert corpus.allowed(("adr",), None, False) == ["docs/adr/0001.md"]
    assert corpus.allowed(("adr",), None, True) == ["docs/adr/0001.md", "docs/adr/0002.md"]
    assert corpus.allowed(("ADR", "guide"), None, False) == ["docs/adr/0001.md", "docs/guides/g.md"]
    assert corpus.allowed(("other",), None, True) == ["README.md", "docs/archive/old.md"]
    assert corpus.allowed(("nope",), None, True) == []

    assert corpus.allowed((), "docs/guides/", False) == ["docs/guides/g.md"]
    assert corpus.allowed((), "./docs/adr", True) == ["docs/adr/0001.md", "docs/adr/0002.md"]
    assert corpus.allowed((), "docs/adr", False) == ["docs/adr/0001.md"]
    assert corpus.allowed(("plan",), "docs/adr", True) == []
    assert corpus.allowed(("adr", "plan"), "docs/", False) == ["docs/adr/0001.md", "docs/plans/p.md"]
    assert corpus.allowed((), "", False) == live


# --- odd files ------------------------------------------------------------------------


def test_enrichment_tolerates_bad_files(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/good.md", "# Good\n")
    (repo.root / "docs" / "latin1.md").write_bytes("# Caf\xe9 au lait\n".encode("latin-1"))
    (repo.root / "docs" / "huge.md").write_bytes(b"# Huge\n" + b"filler line\n" * 190_000)  # about 2.2 MiB
    (repo.root / "docs" / "binary.md").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00")
    repo.write("docs/gone.md", "# Gone\n")
    repo.commit("base")
    corpus = make_corpus(repo)
    assert (repo.root / "docs" / "huge.md").stat().st_size > 2 * 1024 * 1024

    listed = corpus.files()
    assert "docs/gone.md" in listed
    (repo.root / "docs" / "gone.md").unlink()  # removed after discovery

    for bad in ("docs/latin1.md", "docs/huge.md", "docs/binary.md", "docs/gone.md"):
        assert corpus.meta(bad) is None, bad
        assert corpus.heading_path_at(bad, 1) == (), bad
    assert meta_of(corpus, "docs/good.md").title == "Good"

    assert corpus.skipped() == {
        "docs/binary.md": "not-utf8",
        "docs/gone.md": "vanished",
        "docs/huge.md": "too-large",
        "docs/latin1.md": "not-utf8",
    }
    assert corpus.allowed((), None, True) == ["docs/good.md"]


def test_nul_bytes_make_a_file_binary(git_repo) -> None:
    repo = git_repo()
    (repo.root / "docs").mkdir()
    (repo.root / "docs" / "nul.md").write_bytes(b"# Looks like text\n\x00\x00 but is not\n")
    corpus = make_corpus(repo)
    assert corpus.meta("docs/nul.md") is None
    assert corpus.skipped() == {"docs/nul.md": "not-utf8"}


def test_skipped_covers_files_nobody_asked_about(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/good.md", "# Good\n")
    (repo.root / "docs" / "latin1.md").write_bytes("# Caf\xe9\n".encode("latin-1"))
    corpus = make_corpus(repo)
    assert corpus.skipped() == {"docs/latin1.md": "not-utf8"}


def test_skip_clears_when_the_file_is_fixed(git_repo) -> None:
    repo = git_repo()
    path = repo.root / "docs" / "doc.md"
    path.parent.mkdir()
    path.write_bytes("# Caf\xe9\n".encode("latin-1"))
    corpus = make_corpus(repo)
    assert corpus.meta("docs/doc.md") is None
    assert corpus.skipped() == {"docs/doc.md": "not-utf8"}

    path.write_text("# Cafe, in UTF-8 now\n", encoding="utf-8")
    assert meta_of(corpus, "docs/doc.md").title == "Cafe, in UTF-8 now"
    assert corpus.skipped() == {}


def test_skipped_forgets_files_that_leave_the_corpus(git_repo) -> None:
    repo = git_repo()
    path = repo.root / "docs" / "doc.md"
    path.parent.mkdir()
    path.write_bytes("# Caf\xe9\n".encode("latin-1"))
    corpus = make_corpus(repo, {"search": {"rescan_seconds": 0}})
    assert corpus.skipped() == {"docs/doc.md": "not-utf8"}

    path.unlink()
    assert corpus.files() == []  # the rescan notices
    assert corpus.skipped() == {}


def test_head_window_may_cut_a_multibyte_character(git_repo) -> None:
    repo = git_repo()
    head = "# Title\n"
    # byte 65535 begins an e-acute (two bytes) that the 64 KiB read cuts in half
    body = "a" * (64 * 1024 - len(head) - 1) + "é" + "\nmore text after the cut\n"
    repo.write("docs/cut.md", head + body)
    data = (repo.root / "docs" / "cut.md").read_bytes()
    assert data[64 * 1024 - 1 : 64 * 1024 + 1] == "é".encode()
    corpus = make_corpus(repo)

    assert meta_of(corpus, "docs/cut.md").title == "Title"
    assert corpus.skipped() == {}


def test_directory_named_like_a_doc_is_not_a_file(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/dir.md/inner.txt", "x\n")
    repo.write("docs/a.md", "# A\n")
    corpus = make_corpus(repo)
    assert "docs/dir.md" not in corpus.files()
    assert corpus.meta("docs/dir.md") is None
    # only corpus files are reported, not whatever a caller asked about
    assert corpus.meta("docs/nope.md") is None
    assert corpus.skipped() == {}


# --- a parent directory swapped for a symlink ------------------------------------------


def _swap_docs_for_symlink(repo, target: Path) -> None:
    """Replace the tracked `docs/` with a symlink to `target`; the index still lists docs/a.md."""
    shutil.rmtree(repo.root / "docs")
    (repo.root / "docs").symlink_to(target)


def _outside_docs(tmp_path: Path) -> Path:
    outside = tmp_path / "outside-docs"
    outside.mkdir()
    (outside / "a.md").write_text("# Outside title\n\n**Status:** Accepted\n\n## Outside section\n", encoding="utf-8")
    return outside


def test_parent_symlinked_out_of_the_worktree_is_not_listed(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# Inside title\n")
    repo.write("README.md", "# Readme\n")
    repo.commit("base")
    corpus = make_corpus(repo, {"search": {"rescan_seconds": 0}})
    assert corpus.files() == ["README.md", "docs/a.md"]

    _swap_docs_for_symlink(repo, _outside_docs(tmp_path))

    # `git ls-files --cached` still names docs/a.md; the working tree no longer has it
    assert corpus.files() == ["README.md"]
    assert corpus.meta("docs/a.md") is None
    assert corpus.heading_path_at("docs/a.md", 5) == ()
    assert corpus.allowed((), None, True) == ["README.md"]


def test_parent_swapped_for_a_symlink_after_listing_is_refused(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# Inside title\n")
    repo.commit("base")
    corpus = make_corpus(repo, {"search": {"rescan_seconds": 3600}})
    assert corpus.files() == ["docs/a.md"]
    assert meta_of(corpus, "docs/a.md").title == "Inside title"

    _swap_docs_for_symlink(repo, _outside_docs(tmp_path))

    # the listing is stale, but nothing is read through the symlink
    assert corpus.files() == ["docs/a.md"]
    assert corpus.meta("docs/a.md") is None
    assert corpus.heading_path_at("docs/a.md", 5) == ()
    assert corpus.allowed((), None, True) == []
    assert corpus.skipped() == {"docs/a.md": "vanished"}


def test_parent_symlinked_inside_the_worktree_is_read_through(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# Inside title\n\n## Part\n")
    repo.commit("base")
    corpus = make_corpus(repo, {"search": {"rescan_seconds": 0}})
    (repo.root / "docs").rename(repo.root / "docs-real")
    (repo.root / "docs").symlink_to("docs-real")

    assert corpus.files() == ["docs-real/a.md", "docs/a.md"]
    assert meta_of(corpus, "docs/a.md").title == "Inside title"
    assert corpus.heading_path_at("docs/a.md", 3) == ("Inside title", "Part")


def test_front_matter_scalars_from_the_cached_head(git_repo) -> None:
    repo = git_repo()
    repo.write(
        "docs/a.md",
        "---\nKey: chat-70\nstatus: 'Accepted'  # note\ntags: [x, y]\nnested:\n  inner: 1\nowner: \"w\"\n---\n# T\n",
    )
    repo.write("docs/plain.md", "# No front matter\n")
    repo.write("docs/bin.md", "\x00\x01 not text")
    repo.commit("base")
    corpus = make_corpus(repo)

    assert corpus.front_matter("docs/a.md") == {"key": "chat-70", "status": "Accepted", "owner": "w"}
    assert corpus.front_matter("./docs/a.md") == corpus.front_matter("docs/a.md")
    assert corpus.front_matter("docs/plain.md") == {}
    assert corpus.front_matter("docs/bin.md") == {}
    assert corpus.front_matter("docs/missing.md") == {}
    # a caller cannot change the cached parse
    corpus.front_matter("docs/a.md")["key"] = "changed"
    assert corpus.front_matter("docs/a.md")["key"] == "chat-70"


def test_title_and_front_matter_in_one_read(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "---\nkey: chat-70\n---\n# The Title\n\n## Part\n")
    repo.write("docs/plain.md", "no heading at all\n")
    repo.write("docs/bin.md", "\x00\x01 not text")
    repo.commit("base")
    corpus = make_corpus(repo)

    assert corpus.title_and_front_matter("docs/a.md") == ("The Title", {"key": "chat-70"})
    assert corpus.title_and_front_matter("./docs/a.md") == ("The Title", {"key": "chat-70"})
    assert corpus.title_and_front_matter("docs/plain.md") == ("plain", {})  # no H1: the file name, as for meta
    assert corpus.title_and_front_matter("docs/bin.md") is None
    assert corpus.title_and_front_matter("docs/missing.md") is None
    assert corpus.title_and_front_matter("docs/a.md")[0] == meta_of(corpus, "docs/a.md").title
    title, fields = corpus.title_and_front_matter("docs/a.md")
    fields["key"] = "changed"
    assert corpus.title_and_front_matter("docs/a.md")[1] == {"key": "chat-70"}
