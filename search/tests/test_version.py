"""The plugin's own version and the launcher stamp: what `check` compares with `requires`."""

from __future__ import annotations

import json
from pathlib import Path

from doc_search.version import STAMP_RE, launcher_stamp, plugin_root, plugin_version


def write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="utf-8")
    return path


def test_the_stamp_is_parsed(tmp_path: Path) -> None:
    path = write(
        tmp_path / "launch.sh",
        "#!/bin/sh\n# doc-search launcher v3.10.2\n# the header\n",
    )
    assert launcher_stamp(path) == (3, 10, 2)


def test_the_first_stamp_within_five_lines_wins(tmp_path: Path) -> None:
    path = write(
        tmp_path / "launch.sh",
        "#!/bin/sh\n# header\n# doc-search launcher v1.2.3\n# doc-search launcher v9.9.9\n",
    )
    assert launcher_stamp(path) == (1, 2, 3)


def test_a_file_without_a_stamp_gives_none(tmp_path: Path) -> None:
    assert launcher_stamp(write(tmp_path / "plain.sh", "#!/bin/sh\necho hi\n")) is None
    assert launcher_stamp(write(tmp_path / "empty.sh", "")) is None


def test_a_stamp_after_line_five_gives_none(tmp_path: Path) -> None:
    path = write(
        tmp_path / "late.sh", "#!/bin/sh\n#\n#\n#\n#\n# doc-search launcher v1.0.0\n"
    )
    assert launcher_stamp(path) is None


def test_a_malformed_stamp_gives_none(tmp_path: Path) -> None:
    for line in (
        "# doc-search launcher v1.0",
        "# doc-search launcher v1.0.0-rc1",
        "# doc-search launcher v1.0.0 ",
        " # doc-search launcher v1.0.0",
        "# doc-search launcher 1.0.0",
    ):
        path = write(tmp_path / "bad.sh", f"#!/bin/sh\n{line}\n")
        assert launcher_stamp(path) is None, line
        assert STAMP_RE.fullmatch(line) is None, line


def test_a_missing_file_gives_none(tmp_path: Path) -> None:
    assert launcher_stamp(tmp_path / "absent.sh") is None


def test_plugin_root_is_this_repository() -> None:
    root = plugin_root()
    assert (root / "search" / "pyproject.toml").is_file()
    assert (root / "scripts" / "search" / "launch.sh").is_file()


def test_plugin_version_is_package_json() -> None:
    root = plugin_root()
    declared = json.loads((root / "package.json").read_text(encoding="utf-8"))[
        "version"
    ]
    expected = tuple(int(part) for part in declared.split("."))
    assert plugin_version(root) == expected


def test_plugin_version_without_a_package_json_gives_none(tmp_path: Path) -> None:
    assert plugin_version(tmp_path) is None
    write(tmp_path / "package.json", "not json")
    assert plugin_version(tmp_path) is None
    write(tmp_path / "package.json", json.dumps({"version": "3.9"}))
    assert plugin_version(tmp_path) is None
    write(tmp_path / "package.json", json.dumps(["3.9.0"]))
    assert plugin_version(tmp_path) is None


def test_the_shipped_launcher_carries_the_plugin_version() -> None:
    root = plugin_root()
    assert launcher_stamp(root / "scripts" / "search" / "launch.sh") == plugin_version(
        root
    )
