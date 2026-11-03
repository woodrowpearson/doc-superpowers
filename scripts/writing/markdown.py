"""A small Markdown reader for the writing lint.

It turns a document into prose lines and paragraphs, and finds the shorthand codes in them that
nothing explains. A code is a short label for a record, such as ORB-12, KX7, ``beacon-~a1c9`` or
#318. On its own it tells a reader nothing; in brackets after words that say what the record is,
it is a pointer. The module reads no file and loads no configuration: callers pass the text, and
a ``Codes`` that says what a code looks like.

Use the pieces in this order. ``prose_lines`` drops fenced code and blanks link targets.
``paragraphs`` regroups what is left, so a wrapped line keeps its brackets with their words.
``bare_spans`` finds the unexplained codes in a paragraph, and ``path_spans`` the file paths,
whose codes name a file.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import NamedTuple


class Codes(NamedTuple):
    """Describes a project's codes. ``patterns`` find them. ``allowed`` names matches that are
    really ordinary words, such as UTF-8. ``gloss_chars`` are extra characters that make a
    bracket explain its contents when one stands just ahead of it, as a letter or digit does (a
    closing quote, a backtick)."""

    patterns: tuple[re.Pattern, ...]
    allowed: frozenset[str]
    gloss_chars: frozenset[str]


PAIRS = {")": "(", "]": "["}

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")  # the marker may be indented, as it is in a nested list
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LINK_TARGET = re.compile(r"(?<=\])\(([^)]*)\)")
LIST_ITEM = re.compile(r"^(\s*)(?:[-*+]|\d+[.)]|\(?[a-z][.)])\s+")
TABLE_ROW = re.compile(r"^\s*\|")
QUOTE = re.compile(r"^[ \t]*>(?:[ \t]*>)*[ \t]?")

# A token is a file path when it contains "/" and, after the quotes, backticks, brackets and
# trailing punctuation are trimmed off, it ends in "/" or in an extension that may carry a line
# range (":12" or ":12-40"). Codes found in a path are just part of a filename. "K1/K2" lacks an
# extension, hence is no path.
TOKEN = re.compile(r"\S+")
TOKEN_OPENERS = "`\"'‘“([{<*_"
TOKEN_CLOSERS = "`\"'’”)]}>*_.,;:!?("
EXTENSION = re.compile(r"\.[A-Za-z][A-Za-z0-9]*(?::[0-9]+(?:-[0-9]+)?)?$")


def blank_link_targets(line: str) -> str:
    """``line`` with every Markdown link target replaced by as many spaces, so offsets hold and no
    target is read as prose."""
    return LINK_TARGET.sub(lambda match: "(" + " " * len(match.group(1)) + ")", line)


def unquote(line: str) -> tuple[int, str]:
    """Split off the leading ``>`` markers: (how many there are, the rest of the line)."""
    quote = QUOTE.match(line)
    return (quote.group().count(">"), line[quote.end():]) if quote else (0, line)


def prose_lines(text: str) -> Iterator[tuple[int, str]]:
    """Yield (line number, text) for each line of ``text`` outside a fenced code block.

    Line numbers start at 1, and each link target is replaced by spaces. A fence line may be
    indented. A fence that opens within a quote belongs to that quote: when the quote ends, so
    does the fence, and its closing marker must sit at the depth it opened, use the same character
    and be no shorter. Lines that are headings, table rows or list items come through as written;
    ``paragraphs`` keeps them apart."""
    fence, fence_depth = "", 0
    for number, line in enumerate(text.splitlines(), start=1):
        depth, unquoted = unquote(line)
        marker = FENCE.match(unquoted)
        if fence and depth < fence_depth:
            fence = ""
        if fence:
            if (marker and depth == fence_depth and marker.group(1)[0] == fence[0]
                    and len(marker.group(1)) >= len(fence)):
                fence = ""
            continue
        if marker:
            fence, fence_depth = marker.group(1), depth
            continue
        yield number, blank_link_targets(line)


def paragraphs(lines: list[tuple[int, str]]) -> Iterator[list[tuple[int, str]]]:
    """Join the lines of ``lines`` into paragraphs, stripping blockquote markers.

    A hard wrap can put a bracket on the line after the words it belongs to, so the lines of one
    paragraph are read together. Blank lines and bare ``>`` lines separate paragraphs, as does a
    gap in the numbering (a fence sat there) or a new quote depth. A heading or a table row forms
    a paragraph alone. Each list item starts a new paragraph, which only its indented lines
    extend."""
    current: list[tuple[int, str]] = []
    alone = in_item = False
    depth = 0
    for number, raw in lines:
        level, line = unquote(raw)
        starts_item = bool(LIST_ITEM.match(line))
        single = bool(HEADING.match(line) or TABLE_ROW.match(line))
        if current and (not line.strip() or number != current[-1][0] + 1 or level != depth
                        or alone or single or starts_item
                        or (in_item and not line[:1].isspace())):
            yield current
            current = []
        if not line.strip():
            continue
        if not current:
            in_item, depth = starts_item, level
        current.append((number, line))
        alone = single
    if current:
        yield current


def _glossed_brackets(line: str, spans: list[tuple[int, int]],
                      codes: Codes) -> list[tuple[int, int]]:
    """Index pairs (open, close) of the brackets in ``line`` that explain what is inside.

    A bracket explains its contents when words, or a gloss character, come just before it. Square
    brackets that are link text are judged differently: they explain their codes when other
    letters or digits sit beside them."""
    stack: list[tuple[str, int]] = []
    glossing: list[tuple[int, int]] = []
    for index, char in enumerate(line):
        if char in "([":
            stack.append((char, index))
        elif char in PAIRS and stack and stack[-1][0] == PAIRS[char]:
            _, start = stack.pop()
            if char == "]" and line[index + 1:index + 2] == "(":
                inside = list(line[start + 1:index])
                for code_start, code_end in spans:
                    if start < code_start and code_end <= index:
                        inside[code_start - start - 1:code_end - start - 1] = \
                            " " * (code_end - code_start)
                glosses = any(letter.isalnum() for letter in inside)
            else:
                before = line[:start].rstrip()
                glosses = bool(before) and (before[-1].isalnum() or before[-1] in codes.gloss_chars)
            if glosses:
                glossing.append((start, index))
    return glossing


def bare_spans(line: str, codes: Codes) -> list[tuple[int, int]]:
    """Positions (start, end) of the unexplained codes in ``line``, left to right.

    Where matches overlap, only one is kept: the earliest start, then the longest. Words listed in
    ``codes.allowed`` are not codes, and neither is anything inside a bracket that explains it.
    File paths are not considered here, so a code that lies in one is still returned;
    ``path_spans`` locates the paths."""
    matches = sorted(((match.start(), match.end()) for pattern in codes.patterns
                      for match in pattern.finditer(line)), key=lambda span: (span[0], -span[1]))
    kept: list[tuple[int, int]] = []
    for start, end in matches:
        if not kept or start >= kept[-1][1]:
            kept.append((start, end))
    glossed = _glossed_brackets(line, kept, codes)
    return [(start, end) for start, end in kept
            if line[start:end] not in codes.allowed
            and not any(open_ < start and end <= close for open_, close in glossed)]


def path_spans(text: str) -> list[tuple[int, int]]:
    """Positions (start, end) of the file paths among the whitespace-separated tokens of ``text``,
    for instance ``docs/guides/NAV-210-layout.md`` or ``tests/samples/ORB-12/``, whether or not
    backticks or link text surround them. This is the single path rule: a "/" in the token, and
    either a trailing "/" or an extension."""
    spans = []
    for match in TOKEN.finditer(text):
        core = match.group().lstrip(TOKEN_OPENERS).rstrip(TOKEN_CLOSERS)
        if "/" in core and (core.endswith("/") or EXTENSION.search(core.rsplit("/", 1)[1])):
            spans.append(match.span())
    return spans


def bare_codes(text: str, codes: Codes) -> list[str]:
    """List the unexplained codes of plain ``text`` in reading order. Link targets and file paths
    are skipped. Paragraphs are split on blank lines and on bare ``>`` lines; within a paragraph
    the lines are glued together with single spaces and the ``>`` markers removed, so a bracket
    can open on one line and close on a later one. Fences mean nothing in plain text: a fence
    line hides no code."""
    found: list[str] = []
    paragraph: list[str] = []
    for raw in [*text.splitlines(), ""]:
        line = unquote(blank_link_targets(raw))[1]
        if line.strip():
            paragraph.append(line)
        elif paragraph:
            joined = " ".join(paragraph)
            paths = path_spans(joined)
            found += [joined[start:end] for start, end in bare_spans(joined, codes)
                      if not any(open_ <= start and end <= close for open_, close in paths)]
            paragraph = []
    return found
