"""Security releases, read from release notes.

A release is a security release when its `## vX.Y.Z (YYYY-MM-DD)` section holds a `### Security` heading
before the next `## ` heading. Nothing else marks one: no manifest field and no separate file.

Release notes may come from the network (`install.sh upgrade` caches the newest tag's `RELEASE-NOTES.md`), so
the text is untrusted data. Only the two anchored regexes below read it; nothing in it runs. The parser caps its
input at `MAX_NOTES_BYTES`, ignores everything inside a code fence, returns what it can, and never raises.

The fence rule is the one `doc-tools.sh`'s `_AWK_FENCE` applies, so the Python and shell readers agree: a fence
line is a run of three or more backticks or tildes after at most three spaces. A backtick run whose info string
holds a backtick is no fence (CommonMark's inline-code rule). A fence closes on a run of the same character, at
least as long, with only whitespace after it; an unclosed fence runs to the end of the text.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

MAX_NOTES_BYTES = 2_000_000
"""The most of a release-notes text that is read; the rest is ignored. Real notes are well under 1 MB."""

_HEADING = re.compile(r"## v([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9}) \(([0-9]{4}-[0-9]{2}-[0-9]{2})\)")
"""One whole release heading (match it with `fullmatch`). The digit runs are bounded so `int()` stays cheap and
can never refuse a hostile run of digits; a version past nine digits is no heading."""

_SECURITY = re.compile(r"### Security[ \t]*")
"""One whole `### Security` heading (match it with `fullmatch`), trailing blanks allowed."""

Version = tuple[int, int, int]


@dataclass(frozen=True)
class Release:
    version: Version
    date: str
    security: bool


def read_notes(path: Path) -> str | None:
    """At most `MAX_NOTES_BYTES` of `path`, cut on a line boundary, as text; None when it cannot be read.

    It reads `MAX_NOTES_BYTES + 1` bytes and no more, so a huge file costs no more than a capped one. When the
    file is longer than the cap, the partial last line is dropped. Bytes that are not UTF-8 are replaced.
    """
    try:
        with path.open("rb") as handle:
            data = handle.read(MAX_NOTES_BYTES + 1)
    except OSError:
        return None
    if len(data) > MAX_NOTES_BYTES:
        data = data[: data.rfind(b"\n", 0, MAX_NOTES_BYTES) + 1]
    return data.decode("utf-8", errors="replace")


def _cap(text: str) -> str:
    """`text` cut to at most `MAX_NOTES_BYTES` UTF-8 bytes (the cap `read_notes` and `install.sh` apply), on a
    line boundary when it was longer. The cut is made at a newline byte, so no character is split; a lone
    surrogate (text decoded with `surrogateescape`, say) passes through instead of raising."""
    data = text.encode("utf-8", errors="surrogatepass")
    if len(data) <= MAX_NOTES_BYTES:
        return text
    return data[: data.rfind(b"\n", 0, MAX_NOTES_BYTES) + 1].decode("utf-8", errors="surrogatepass")


class _Fence:
    """The open fence, if any: `_AWK_FENCE`'s `blk_fence`, line by line."""

    def __init__(self) -> None:
        self.char = ""
        self.length = 0

    @property
    def open(self) -> bool:
        return self.char != ""

    def step(self, line: str) -> bool:
        """Is `line` a fence line? Opens or closes the fence as a side effect."""
        text = line
        for _ in range(3):
            if not text.startswith(" "):
                break
            text = text[1:]
        char = text[:1]
        if char not in ("`", "~"):
            return False
        length = len(text) - len(text.lstrip(char))
        if length < 3:
            return False
        rest = text[length:]
        if not self.open:
            if char == "`" and "`" in rest:
                return False
            self.char, self.length = char, length
            return True
        if char == self.char and length >= self.length and rest.strip(" \t\r\f\v") == "":
            self.char, self.length = "", 0
            return True
        return False


def parse_releases(text: str | None) -> list[Release]:
    """Every release heading outside code fences, newest first by version (file order breaks ties); none for
    None or any other non-text value (an unreadable cache, a caller's JSON)."""
    if not isinstance(text, str):
        return []
    fence = _Fence()
    found: list[tuple[Version, str]] = []
    security: list[bool] = []
    current = -1  # index into `found` of the open release section; -1 outside one
    for raw in _cap(text).split("\n"):
        line = raw[:-1] if raw.endswith("\r") else raw
        if fence.step(line) or fence.open:
            continue
        if line == "##" or line.startswith("## "):
            match = _HEADING.fullmatch(line)
            if match is None:
                current = -1
                continue
            major, minor, patch, date = match.groups()
            found.append(((int(major), int(minor), int(patch)), date))
            security.append(False)
            current = len(found) - 1
        elif current >= 0 and _SECURITY.fullmatch(line):
            security[current] = True
    releases = [Release(version=v, date=d, security=s) for (v, d), s in zip(found, security, strict=True)]
    return sorted(releases, key=lambda r: r.version, reverse=True)


def newest_security(releases: Sequence[Release]) -> Version | None:
    """The highest version among the security releases; None when there is none."""
    versions = [r.version for r in releases if r.security]
    return max(versions) if versions else None
