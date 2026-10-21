"""The doc-index reader: entries, cross-link lookup, absent and changing files."""

from __future__ import annotations

import json
import os
from pathlib import Path

from doc_search.docindex import DocIndex


def write_index(top: Path, docs: dict[str, dict]) -> Path:
    path = top / "docs" / ".doc-index.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 3, "docs": docs}), encoding="utf-8")
    return path


def bump_mtime(path: Path, seconds: int = 10) -> None:
    st = path.stat()
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + seconds * 1_000_000_000))


def test_docs_covering_specificity(tmp_path: Path) -> None:
    write_index(
        tmp_path,
        {
            "docs/root.md": {"code_refs": ["."]},
            "docs/dir.md": {"code_refs": ["src/"]},
            "docs/file.md": {"code_refs": ["src/a.py"]},
            "docs/other.md": {"code_refs": ["lib/"]},
        },
    )
    index = DocIndex(tmp_path)
    assert index.docs_covering("src/a.py") == ["docs/file.md", "docs/dir.md", "docs/root.md"]
    # a sibling file: the directory and the root cover it, the file doc does not
    assert index.docs_covering("src/b.py") == ["docs/dir.md", "docs/root.md"]
    assert index.docs_covering("lib/x/y.py") == ["docs/other.md", "docs/root.md"]
    assert index.docs_covering("elsewhere.py") == ["docs/root.md"]


def test_docs_covering_ties_sort_by_path_and_best_ref_wins(tmp_path: Path) -> None:
    write_index(
        tmp_path,
        {
            "docs/z.md": {"code_refs": ["src/"]},
            "docs/a.md": {"code_refs": ["src"]},
            "docs/m.md": {"code_refs": [".", "src/deep/", "./src/deep/f.py"]},
        },
    )
    index = DocIndex(tmp_path)
    # m.md names the file itself (via ./), so it outranks the two directory docs, which tie on path
    assert index.docs_covering("src/deep/f.py") == ["docs/m.md", "docs/a.md", "docs/z.md"]
    # a ./ spelling of the code path gives the same list, each doc once
    assert index.docs_covering("./src/deep/f.py") == ["docs/m.md", "docs/a.md", "docs/z.md"]


def test_docs_covering_matches_whole_path_components(tmp_path: Path) -> None:
    write_index(tmp_path, {"docs/src.md": {"code_refs": ["src"]}, "docs/exact.md": {"code_refs": ["src/a.py"]}})
    index = DocIndex(tmp_path)
    assert index.docs_covering("src2/a.py") == []
    assert index.docs_covering("src/a.py.bak") == ["docs/src.md"]
    assert index.docs_covering("src") == ["docs/src.md"]


def test_entry_and_present(tmp_path: Path) -> None:
    write_index(
        tmp_path,
        {"docs/a.md": {"doc_type": "guide", "code_refs": ["src/"], "status": "deprecated"}, "docs/bad.md": "oops"},
    )
    index = DocIndex(tmp_path)
    assert index.present
    assert index.error is None
    entry = index.entry("docs/a.md")
    assert entry is not None and entry["doc_type"] == "guide"
    assert index.entry("./docs/a.md") == entry
    assert index.entry("docs/missing.md") is None
    assert index.entry("docs/bad.md") is None


def test_absent_index(tmp_path: Path) -> None:
    index = DocIndex(tmp_path)
    assert index.present is False
    assert index.error is None
    assert index.entry("docs/a.md") is None
    assert index.docs_covering("src/a.py") == []


def test_unusable_index_is_absent_with_a_reason(tmp_path: Path) -> None:
    path = write_index(tmp_path, {})
    path.write_text("{ not json", encoding="utf-8")
    index = DocIndex(tmp_path)
    assert index.present is False
    assert index.error is not None and "doc-index.json" in index.error
    assert index.docs_covering("src/a.py") == []

    path.write_text(json.dumps({"docs": ["not", "a", "mapping"]}), encoding="utf-8")
    bump_mtime(path)
    assert index.present is False
    assert index.error is not None

    path.write_text(json.dumps([1, 2]), encoding="utf-8")
    bump_mtime(path, 20)
    assert index.present is False


def test_malformed_refs_are_ignored(tmp_path: Path) -> None:
    write_index(
        tmp_path,
        {
            "docs/a.md": {"code_refs": "src/"},
            "docs/b.md": {"code_refs": [None, 3, "", "/abs", "src/ok.py"]},
            "docs/c.md": {},
        },
    )
    index = DocIndex(tmp_path)
    assert index.docs_covering("src/ok.py") == ["docs/b.md"]


def test_reload_on_mtime(tmp_path: Path) -> None:
    path = write_index(tmp_path, {"docs/a.md": {"doc_type": "guide", "code_refs": ["src/"]}})
    index = DocIndex(tmp_path)
    entry = index.entry("docs/a.md")
    assert entry is not None and entry["doc_type"] == "guide"
    assert index.docs_covering("src/a.py") == ["docs/a.md"]

    write_index(tmp_path, {"docs/a.md": {"doc_type": "adr", "code_refs": ["lib/"]}, "docs/b.md": {"code_refs": ["."]}})
    bump_mtime(path)
    entry = index.entry("docs/a.md")
    assert entry is not None and entry["doc_type"] == "adr"
    assert index.entry("docs/b.md") is not None
    assert index.docs_covering("src/a.py") == ["docs/b.md"]

    path.unlink()
    assert index.present is False
    assert index.entry("docs/a.md") is None

    write_index(tmp_path, {"docs/c.md": {}})
    assert index.present is True
    assert index.entry("docs/c.md") == {}
