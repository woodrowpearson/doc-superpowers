"""The cloud write path's chunker (design section 8): heading-bounded sections cut to about 1,600 characters.

Stdlib only, and independent of semble (whose own chunks serve the local legs): this one exists so the
cloud corpus is chunked the same way whoever runs the indexer.

For markdown:
  - front matter is skipped, and every line number stays the line's number in the file;
  - a section runs from a heading of level <= `heading_level` (default 3) to the next one; headings in
    fenced blocks are not headings, and deeper headings stay inside their section;
  - a section under 25% of the target joins the section that follows it when that one is a sibling (the
    same level, so the same parent), and goes on joining while it is still that small;
  - a section over the target is cut at blank lines, then at lines, each chunk starting with the last
    lines of the one before it (about 15% of the target); a fenced block stays whole up to 6,000
    characters, over which it is cut like any other text;
  - a chunk's text is the file's own lines for its range, minus blank lines at its ends.
One exception keeps the size bounded: a single line over the target is cut into pieces that share its
line number.

`chunk_lines` is the same cut for text that is not markdown: windows of lines, nothing stripped.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import PurePosixPath

# The cloud stamp records this. A corpus stamped with another version was cut by other rules, so the next run
# rebuilds it whole. Bump it whenever a size below or a rule of the cut changes (a test pins them together).
CHUNKER_VERSION = 1

TARGET = 1600
HEADING_LEVEL = 3
MERGE_BELOW = 0.25  # a section under this share of the target joins its next sibling
OVERLAP = 0.15  # the share of the target repeated at the start of the next chunk
FENCE_CAP = 6000  # a fenced block up to this many characters is never cut
MAX_HEADING = 200  # a heading (or the title) in a path is cut to this: the path rides on every chunk under it

_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")
_CLOSING_HASHES = re.compile(r"(?:^|[ \t]+)#+$")


@dataclass(frozen=True)
class CloudChunk:
    """One chunk: `ordinal` counts from 0, lines are 1-based and inclusive, `heading_path` is the headings above."""

    ordinal: int
    start_line: int
    end_line: int
    heading_path: tuple[str, ...]
    text: str


# A piece of the file: lines [start, end) (0-based), or `text` alone for a cut line; `own` is where the
# chunk's own content starts (the lines before it are overlap), which decides its heading path.
@dataclass(frozen=True)
class _Piece:
    start: int
    end: int
    own: int
    text: str | None = None


@dataclass(frozen=True)
class _Unit:
    start: int
    end: int
    atomic: bool = False  # a fenced block that must not be cut


class _Doc:
    """The file's lines and the sums that make a range's size cheap."""

    def __init__(self, text: str) -> None:
        self.lines = split_lines(text)
        self._sums = [0]
        for line in self.lines:
            self._sums.append(self._sums[-1] + len(line) + 1)

    def size(self, start: int, end: int) -> int:
        """Characters of lines [start, end) joined with newlines."""
        return self._sums[end] - self._sums[start] - 1 if end > start else 0

    def blank(self, index: int) -> bool:
        return not self.lines[index].strip()

    def trimmed(self, start: int, end: int) -> tuple[int, int]:
        """[start, end) without blank lines at either end."""
        while start < end and self.blank(start):
            start += 1
        while end > start and self.blank(end - 1):
            end -= 1
        return start, end


def split_lines(text: str) -> list[str]:
    """Lines as an editor numbers them: split on LF, CR and a BOM dropped, no empty line after the last LF."""
    if text.startswith("﻿"):
        text = text[1:]
    lines = [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def _front_matter_end(lines: list[str]) -> int:
    """The index of the first line after a leading `---` block; 0 when there is none (or it never closes)."""
    if not lines or lines[0].rstrip() != "---":
        return 0
    for index in range(1, len(lines)):
        if lines[index].rstrip() in ("---", "..."):
            return index + 1
    return 0


def _short(text: str) -> str:
    return text if len(text) <= MAX_HEADING else text[: MAX_HEADING - 1] + "…"


def _heading(line: str) -> tuple[int, str] | None:
    found = _ATX.match(line)
    if not found:
        return None
    text = _CLOSING_HASHES.sub("", found.group(2) or "").strip()
    return (len(found.group(1)), _short(text)) if text else None


def _scan(lines: list[str], start: int) -> tuple[dict[int, tuple[int, str]], list[tuple[int, int]]]:
    """Headings outside fenced blocks (by line index) and the fenced blocks as inclusive (open, close) indexes."""
    headings: dict[int, tuple[int, str]] = {}
    fences: list[tuple[int, int]] = []
    fence: tuple[str, int, int] | None = None  # (character, length, line of the opening fence)
    for index in range(start, len(lines)):
        line = lines[index]
        found = _FENCE.match(line)
        if fence is None:
            if found and not (found.group(1)[0] == "`" and "`" in found.group(2)):
                fence = (found.group(1)[0], len(found.group(1)), index)
                continue
            heading = _heading(line)
            if heading:
                headings[index] = heading
        elif found and found.group(1)[0] == fence[0] and len(found.group(1)) >= fence[1] and not found.group(2).strip():
            fences.append((fence[2], index))
            fence = None
    if fence is not None:  # a fence never closed runs to the end of the file
        fences.append((fence[2], len(lines) - 1))
    return headings, fences


def _paths(doc: _Doc, start: int, headings: dict[int, tuple[int, str]], title: str) -> list[tuple[str, ...]]:
    """The heading path in force at each line; the title roots it unless the file's own H1 (or the title) does."""
    stack: list[tuple[int, str]] = []
    current: tuple[str, ...] = (title,) if title else ()
    paths: list[tuple[str, ...]] = [current] * len(doc.lines)
    for index in range(start, len(doc.lines)):
        found = headings.get(index)
        if found:
            while stack and stack[-1][0] >= found[0]:
                stack.pop()
            stack.append(found)
            rooted = stack[0][0] == 1 or stack[0][1] == title
            current = tuple(text for _, text in stack) if rooted or not title else (title, *(t for _, t in stack))
        paths[index] = current
    return paths


# --- cutting a range -------------------------------------------------------------------------------


def _units(doc: _Doc, start: int, end: int, atomic: dict[int, int]) -> list[_Unit]:
    """[start, end) as paragraphs (text and the blank lines after it) and whole fenced blocks, in order."""
    units: list[_Unit] = []
    pending = start
    seen_blank = False
    index = start
    while index < end:
        if index in atomic:
            if pending < index:
                units.append(_Unit(pending, index))
            stop = atomic[index] + 1
            while stop < end and doc.blank(stop):
                stop += 1
            units.append(_Unit(index, stop, atomic=True))
            index = pending = stop
            seen_blank = False
            continue
        if doc.blank(index):
            seen_blank = True
        elif seen_blank:
            units.append(_Unit(pending, index))
            pending, seen_blank = index, False
        index += 1
    if pending < end:
        units.append(_Unit(pending, end))
    return units


def _by_line(doc: _Doc, units: list[_Unit], target: int) -> list[_Unit]:
    """Units over the target that are not a kept fence, cut into one unit per line."""
    out: list[_Unit] = []
    for unit in units:
        if not unit.atomic and unit.end - unit.start > 1 and doc.size(unit.start, unit.end) > target:
            out.extend(_Unit(i, i + 1) for i in range(unit.start, unit.end))
        else:
            out.append(unit)
    return out


def _overlap_start(doc: _Doc, start: int, end: int, budget: int, inside: set[int]) -> int:
    """Where the chunk after [start, end) begins: its last lines within `budget` characters, else `end`.

    Never the whole chunk, never on a blank line, never inside a kept fence.
    """
    best = end
    for index in range(end - 1, start, -1):
        if doc.size(index, end) > budget:
            break
        if not doc.blank(index) and index not in inside:
            best = index
    return best


def _hard_split(line: str, target: int) -> list[str]:
    """`line` in pieces of at most `target` characters, cut after a space when one is in the second half."""
    pieces: list[str] = []
    rest = line
    while len(rest) > target:
        window = rest[:target]
        cut = max(window.rfind(" "), window.rfind("\t")) + 1
        if cut < target // 2:
            cut = target
        pieces.append(rest[:cut])
        rest = rest[cut:]
    if rest:
        pieces.append(rest)
    return pieces


def _pack(doc: _Doc, units: list[_Unit], target: int, inside: set[int]) -> list[_Piece]:
    """Units packed into chunks of at most `target` characters, with the overlap between neighbours."""
    budget = int(target * OVERLAP)
    out: list[_Piece] = []
    cur: _Piece | None = None
    for unit in units:
        if not unit.atomic and doc.size(unit.start, unit.end) > target:  # one line over the target
            if cur:
                out.append(cur)
                cur = None
            out.extend(
                _Piece(unit.start, unit.start + 1, unit.start, text)
                for text in _hard_split(doc.lines[unit.start], target)
            )
            continue
        if cur is None:
            cur = _Piece(unit.start, unit.end, unit.start)
        elif doc.size(cur.start, unit.end) <= target:
            cur = _Piece(cur.start, unit.end, cur.own)
        else:
            out.append(cur)
            begin = _overlap_start(doc, cur.start, cur.end, budget, inside)
            if begin < cur.end and doc.size(begin, unit.end) <= target:
                cur = _Piece(begin, unit.end, unit.start)
            else:
                cur = _Piece(unit.start, unit.end, unit.start)
    if cur:
        out.append(cur)
    return out


def _chunks(doc: _Doc, pieces: list[_Piece], paths: list[tuple[str, ...]] | None, title: str) -> list[CloudChunk]:
    chunks: list[CloudChunk] = []
    for piece in pieces:
        if piece.text is not None:
            text, start, end = piece.text, piece.start, piece.end
        else:
            start, end = doc.trimmed(piece.start, piece.end)
            if start == end:
                continue
            text = "\n".join(doc.lines[start:end])
        own = max(piece.own, start)
        path = paths[own] if paths is not None else ((title,) if title else ())
        chunks.append(CloudChunk(len(chunks), start + 1, end, path, text))
    return chunks


# --- public ----------------------------------------------------------------------------------------


def chunk_markdown(
    path: str, text: str, title: str, heading_level: int = HEADING_LEVEL, target: int = TARGET
) -> list[CloudChunk]:
    """The chunks of one markdown file (see the module docstring). `title` roots the heading path; without
    one the file's stem does."""
    title = _short(title or PurePosixPath(path).stem)
    doc = _Doc(text)
    body = _front_matter_end(doc.lines)
    headings, fences = _scan(doc.lines, body)
    atomic = {a: b for a, b in fences if doc.size(a, b + 1) <= FENCE_CAP}
    inside = {i for a, b in atomic.items() for i in range(a + 1, b + 1)}

    # sections: [start, end, level]; level 0 is the text before the first heading
    bounds = [(i, level) for i, (level, _) in sorted(headings.items()) if level <= heading_level]
    starts = [(body, 0), *bounds] if not bounds or bounds[0][0] != body else bounds
    sections = [
        (start, starts[n + 1][0] if n + 1 < len(starts) else len(doc.lines), level)
        for n, (start, level) in enumerate(starts)
    ]
    sections = [s for s in sections if doc.trimmed(s[0], s[1])[0] < doc.trimmed(s[0], s[1])[1]]  # not all blank

    small = int(target * MERGE_BELOW)
    merged: list[tuple[int, int]] = []
    n = 0
    while n < len(sections):
        start, end, level = sections[n]
        n += 1
        while (
            level > 0
            and doc.size(*doc.trimmed(start, end)) < small
            and n < len(sections)
            and sections[n][2] == level
            and sections[n][0] == end
        ):
            end = sections[n][1]
            n += 1
        merged.append((start, end))

    paths = _paths(doc, body, headings, title)
    pieces: list[_Piece] = []
    for start, end in merged:
        first, last = doc.trimmed(start, end)
        if doc.size(first, last) <= target:
            pieces.append(_Piece(first, last, first))
        else:
            units = _by_line(doc, _units(doc, first, last, atomic), target)
            pieces.extend(_pack(doc, units, target, inside))
    return _chunks(doc, pieces, paths, title)


def chunk_lines(path: str, text: str, title: str, target: int = TARGET) -> list[CloudChunk]:
    """The chunks of a file that is not markdown: windows of lines of about `target` characters, nothing stripped."""
    title = _short(title or PurePosixPath(path).stem)
    doc = _Doc(text)
    units = [_Unit(i, i + 1) for i in range(len(doc.lines))]
    return _chunks(doc, _pack(doc, units, target, set()), None, title)
