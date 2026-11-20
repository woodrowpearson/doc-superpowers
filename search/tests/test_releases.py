"""The security-release marker: a `## vX.Y.Z (date)` section holding a `### Security` heading."""

from __future__ import annotations

from pathlib import Path

from doc_search.releases import (
    MAX_NOTES_BYTES,
    Release,
    newest_security,
    parse_releases,
    read_notes,
)

FIXTURE = Path(__file__).parent / "fixtures" / "release-notes-security.md"

NOTES = "# Release Notes\n\n## v3.18.0 (2026-11-18)\nx\n### Security\n- y\n\n## v3.17.1 (2026-11-18)\n### Changed\n"


def test_marks_security_release() -> None:
    rs = parse_releases(NOTES)
    assert [(r.version, r.security) for r in rs] == [((3, 18, 0), True), ((3, 17, 1), False)]


def test_release_carries_its_date() -> None:
    assert parse_releases(NOTES)[0] == Release(version=(3, 18, 0), date="2026-11-18", security=True)


def test_newest_security() -> None:
    assert newest_security(parse_releases(NOTES)) == (3, 18, 0)


def test_fenced_headings_ignored() -> None:
    assert parse_releases("```\n## v9.9.9 (2026-01-01)\n### Security\n```\n") == []


def test_tilde_fence_ignored() -> None:
    assert parse_releases("~~~\n## v9.9.9 (2026-01-01)\n### Security\n~~~\n") == []


def test_a_shorter_fence_line_does_not_close_a_longer_fence() -> None:
    text = "## v1.0.0 (2026-01-01)\n````\n```\n### Security\n```\n````\n"
    assert [(r.version, r.security) for r in parse_releases(text)] == [((1, 0, 0), False)]


def test_a_fence_of_the_other_character_does_not_close() -> None:
    text = "## v1.0.0 (2026-01-01)\n```\n~~~\n### Security\n```\n"
    assert [(r.version, r.security) for r in parse_releases(text)] == [((1, 0, 0), False)]


def test_a_backtick_run_with_a_backtick_in_its_info_string_is_no_fence() -> None:
    # CommonMark, as _AWK_FENCE: "``` a`b" is inline code, so the heading after it counts
    text = "``` a`b\n## v1.0.0 (2026-01-01)\n### Security\n"
    assert newest_security(parse_releases(text)) == (1, 0, 0)


def test_an_indented_fence_of_up_to_three_spaces_counts() -> None:
    assert parse_releases("   ```\n## v9.9.9 (2026-01-01)\n   ```\n") == []


def test_an_unclosed_fence_hides_the_rest() -> None:
    text = "## v1.0.0 (2026-01-01)\n```\n## v2.0.0 (2026-01-02)\n### Security\n"
    assert [(r.version, r.security) for r in parse_releases(text)] == [((1, 0, 0), False)]


def test_security_after_a_non_release_heading_belongs_to_no_release() -> None:
    text = "## v1.0.0 (2026-01-01)\n### Fixed\n\n## Notes\n### Security\n"
    assert [(r.version, r.security) for r in parse_releases(text)] == [((1, 0, 0), False)]


def test_security_before_any_release_is_ignored() -> None:
    assert newest_security(parse_releases("### Security\n## v1.0.0 (2026-01-01)\n")) is None


def test_newest_first_by_version_not_file_order() -> None:
    text = "## v3.9.0 (2026-01-01)\n## v10.0.0 (2026-01-02)\n## v3.10.0 (2026-01-03)\n"
    assert [r.version for r in parse_releases(text)] == [(10, 0, 0), (3, 10, 0), (3, 9, 0)]


def test_newest_security_is_the_highest_security_version() -> None:
    text = (
        "## v3.20.0 (2026-01-03)\n### Changed\n"
        "## v3.9.0 (2026-01-01)\n### Security\n"
        "## v3.10.0 (2026-01-02)\n### Security\n"
    )
    assert newest_security(parse_releases(text)) == (3, 10, 0)


def test_headings_must_match_exactly() -> None:
    text = (
        "## v1.0 (2026-01-01)\n"
        "## v1.0.0-rc1 (2026-01-01)\n"
        "## v1.0.0\n"
        "## v1.0.0 (2026-1-1)\n"
        " ## v1.0.0 (2026-01-01)\n"
        "### v2.0.0 (2026-01-01)\n"
        "## v٣.0.0 (2026-01-01)\n"  # an Arabic-Indic digit is no ASCII digit
    )
    assert parse_releases(text) == []


def test_crlf_lines_parse() -> None:
    assert newest_security(parse_releases(NOTES.replace("\n", "\r\n"))) == (3, 18, 0)


def test_security_heading_allows_trailing_whitespace_only() -> None:
    assert newest_security(parse_releases("## v1.0.0 (2026-01-01)\n### Security  \n")) == (1, 0, 0)
    assert newest_security(parse_releases("## v1.0.0 (2026-01-01)\n### Security fixes\n")) is None


def test_huge_version_numbers_never_raise() -> None:
    text = "## v99999.0.0 (2026-01-01)\n### Security\n## v" + "9" * 5000 + ".0.0 (2026-01-01)\n### Security\n"
    assert newest_security(parse_releases(text)) == (99999, 0, 0)


def test_oversized_input_truncated_not_raised() -> None:
    assert parse_releases(NOTES + "z" * (MAX_NOTES_BYTES + 10))[0].version == (3, 18, 0)


def test_a_heading_past_the_cap_is_not_read() -> None:
    text = NOTES + "z" * MAX_NOTES_BYTES + "\n## v9.0.0 (2026-01-01)\n### Security\n"
    assert newest_security(parse_releases(text)) == (3, 18, 0)


def test_hostile_bytes_never_raise() -> None:
    text = "\x00\x1b[31m## v1.0.0 (2026-01-01)\n\ud800\n## v2.0.0 (2026-01-01)\x00\n### Security\n"
    assert parse_releases(text) == []


def test_not_a_string_gives_nothing() -> None:
    assert parse_releases(None) == []  # type: ignore[arg-type]


def test_no_headings() -> None:
    assert parse_releases("hello") == [] and newest_security([]) is None


def test_the_shared_fixture() -> None:
    rs = parse_releases(FIXTURE.read_text(encoding="utf-8"))
    assert [(r.version, r.security) for r in rs] == [
        ((3, 19, 0), True),
        ((3, 18, 0), True),
        ((3, 17, 1), False),
        ((3, 17, 0), False),
    ]
    assert newest_security(rs) == (3, 19, 0)


def test_read_notes_reads_a_file() -> None:
    assert read_notes(FIXTURE) == FIXTURE.read_text(encoding="utf-8")


def test_read_notes_missing_file_gives_none(tmp_path: Path) -> None:
    assert read_notes(tmp_path / "absent.md") is None
    assert read_notes(tmp_path) is None  # a directory


def test_read_notes_caps_and_cuts_on_a_line_boundary(tmp_path: Path) -> None:
    path = tmp_path / "big.md"
    head = NOTES.encode()
    path.write_bytes(head + b"z" * (MAX_NOTES_BYTES - len(head) - 3) + b"\nab" + b"c" * 100 + b"\n")
    text = read_notes(path)
    assert text is not None
    assert len(text.encode()) <= MAX_NOTES_BYTES
    assert text.endswith("\n") and "ab" not in text
    assert newest_security(parse_releases(text)) == (3, 18, 0)


def test_read_notes_reads_at_most_the_cap_plus_one(tmp_path: Path, monkeypatch) -> None:
    path = tmp_path / "big.md"
    path.write_bytes(b"x\n" * (MAX_NOTES_BYTES * 2))
    sizes: list[int] = []
    real_open = Path.open

    class Spy:
        def __init__(self, handle) -> None:
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *exc) -> None:
            self.handle.close()

        def read(self, size: int = -1) -> bytes:
            sizes.append(size)
            return self.handle.read(size)

    def spy_open(self, *args, **kwargs):
        return Spy(real_open(self, *args, **kwargs))

    monkeypatch.setattr(Path, "open", spy_open)
    read_notes(path)
    assert sizes == [MAX_NOTES_BYTES + 1]


def test_read_notes_invalid_utf8_is_replaced(tmp_path: Path) -> None:
    path = tmp_path / "bad.md"
    path.write_bytes(b"## v1.0.0 (2026-01-01)\n\xff\xfe\n### Security\n")
    text = read_notes(path)
    assert text is not None and newest_security(parse_releases(text)) == (1, 0, 0)
