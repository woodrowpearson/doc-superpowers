#!/usr/bin/env python3
"""The writing lint: whole files, and what a branch wrote.

Three faults make Markdown hard to read in one pass, and this lint reports them. A code, such as
a record number, appears with nothing to explain it. A sentence runs past the word limit of its
register. A list item runs past the register's limit on words or on sentences. It also prints,
for information only, how many backtick spans a file has per 100 of its words. It cannot tell
whether the words beside a code describe it, whether a brief sentence says anything, whether
plain words hide jargon, or whether the main point comes first.

    lint.py check [--profile terse|full] [--github] [--format text|json] [--name LABEL] FILE...|-
    lint.py range [--format text|json] BASE...HEAD
    lint.py ceilings [--file PATH] [--base REF] [--update]
    lint.py counts [--format text|json] [PATH...]

``check`` reads whole files, or standard input for ``-``. A register sets the limits. Without
``--profile`` each file's register comes from the project's configuration, by its doc-index type
and then its path (``config.register_for``), the path being taken from the top of the repository.
A file with no register is named on standard error and is not a finding; a name that does not
exist, or is a folder, is an error. Standard input has no path, so it needs ``--profile``;
``--name`` is only the label its findings carry.

``range`` judges a branch by the text it wrote. It takes the merge base of BASE and HEAD and
compares it with the committed HEAD, never with the working tree. A sentence is the branch's own
when a line the diff adds holds it and neither the old copy of the file (under its old name, for a
rename) nor the Markdown files the branch removes have a sentence like it, so text that merely
moved counts as old. Digits, link targets and line breaks do not set two sentences apart. When a
new sentence rewrites an older one (the difflib ratio of their words is 0.6 or more), only the harm
the rewrite did is reported: a code that was not bare before, more words in the sentence, more
words or sentences in the item. BASE alone means BASE...HEAD; the head is always HEAD. Each file's
register is looked up in the configuration and the doc-index as committed at HEAD. Records are
linted, ``docs/archive/`` never is, and a file with no register is passed over without a word. The
output is that of ``check``, with one more line for each file that has new sentences: its density,
counted over the whole file.

``ceilings`` reads ``docs/writing/ceilings.json`` (or ``--file``), which lists paths, each naming
a Markdown file or a folder of them, with the number of findings that path holds in the committed
HEAD. Each file is read whole and judged in its own register. A folder passes over records and
files with no register, and a ceiling that names a record is itself a finding. The file reads
``{"counting_version": N, "paths": {PATH: COUNT}}``; a file with no version is one from before
versions, and reads as version 0. A count over its ceiling fails, and so does one under it. A
ceiling may fall but never rise, and no path may leave the file, unless the range from the merge
base of BASE (default ``origin/HEAD``, else ``origin/main``, looked up only when HEAD has a
ceilings file) to HEAD changes ``docs/writing/config.json`` or sets ``counting_version`` to
``COUNTING_VERSION``. A file recorded with another version is not compared at all: run
``ceilings --update``, which counts the working tree for each listed path and rewrites the file
with the engine's version. ``counts`` prints the findings of the working tree for each folder and
register, passing over records and files with no register, for the audit to show; a path that
matches no file is an error.

The exit status is 0 for a clean run and 1 when there are findings, each printed as
``path:line: rule: message``; for ``ceilings``, a count over or under its ceiling, a ceiling that
rose, a path that left the file, a stale version or a ceiling on a record. It is 2 when the
command line is wrong (for ``range``, also a head other than HEAD), an input cannot be opened or
decoded, git cannot resolve the base, the configuration or the ceilings file is unusable, or the
lint itself crashes. With ``--format json`` the findings are printed instead as one list of
objects, one per ``Finding``, with all its fields.

``Config`` (``config.py``, ``defaults.json``) supplies the limits, the shape of a code, the words
that are not codes, the line prefixes to leave alone and the headers of the blocks to leave alone
(the ``Implementation:`` list a tool writes into a decision record); ``markdown.py`` does the
reading. Its ``enabled`` switch is for callers that run the lint unasked (the audit, the review,
the hooks): an explicit ``check``, ``range``, ``ceilings`` or ``counts`` always runs.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import posixpath
import re
import shlex
import stat
import subprocess
import sys
from collections.abc import Callable, Iterable, Iterator, Mapping
from contextlib import contextmanager
from difflib import SequenceMatcher
from pathlib import Path, PurePosixPath
from typing import Any, NamedTuple

# An isolated interpreter (-I) leaves this script's folder off the path, and the modules import
# each other by name.
_HERE = str(Path(__file__).resolve().parent)
if sys.path[:1] != [_HERE]:
    sys.path.insert(0, _HERE)

# A module that is missing or broken beside this script ends the run with status 2, as every
# other fault of the engine does: an uncaught import error would exit 1, which reads as findings.
try:
    from config import (CONFIG, REGISTERS, Config, Limits, Malformed,  # noqa: E402
                        is_record, load, read_index, register_for)
    from markdown import (HEADING, LINK_TARGET, LIST_ITEM, TABLE_ROW,  # noqa: E402
                          Codes, bare_spans, blank_link_targets, paragraphs, path_spans,
                          prose_lines, unquote)
except Exception as _error:  # a defect in the installation, not a finding
    print(f"writing: cannot load the engine: {type(_error).__name__}: "
          + " ".join(str(_error).split()), file=sys.stderr)
    sys.exit(2)


class Finding(NamedTuple):
    path: str
    line: int
    rule: str
    message: str
    # Where the finding's paragraph starts and ends, as line numbers.
    paragraph_first_line: int
    paragraph_last_line: int


class Base(NamedTuple):
    """The old sentence behind a new one that rewrites it, as range mode remembers it: the number
    of its words, the codes bare in it (digits kept, so KX7 and KX8 differ) and the size of its
    paragraph in words and in sentences. A finding counts as the rewrite's own only when it goes
    beyond these."""

    words: int
    bare: frozenset[str]
    paragraph_words: int
    paragraph_sentences: int


class Unreadable(ValueError):
    """A base, a file or an answer from git that range mode cannot use. The command prints it
    and exits with status 2."""


# Words whose closing full stop never ends a sentence.
ABBREVIATIONS = frozenset({"e.g.", "i.e.", "cf.", "vs."})
OPENERS = "\"'‘“([`*_"  # may stand before a word without being part of it

LINK_TEXT = re.compile(r"\[([^\[\]]*)\]\(")
ITEM = re.compile(r"^[ \t]*-(?:[ \t]|$)")  # a "- " list item, at any indent
INDENTED = re.compile(r"^[ \t]+\S")  # a line that is indented and not blank
TASK_BOX = re.compile(r"\[[ xX]\]\s+")
BOLD_LABEL = re.compile(r"^\*\*([^*]+)\*\*")
BACKTICK_SPAN = re.compile(r"`[^`\n]+`")
# A sentence mark, perhaps followed by closing quotes, brackets or emphasis, before whitespace.
SENTENCE_END = re.compile(r"[.!?]+[\"'’”)\]*_`]*(?=\s)")
LETTER = re.compile(r"[^\W\d_]")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", re.MULTILINE)
NUMBER = re.compile(r"[0-9]+")
# The lowest word-level difflib ratio at which a new sentence is taken for a rewrite of an old one.
# A change of one word in ten scores 0.9; replacing two words in three scores far below this.
SIMILAR = 0.6

# Plan tasks written by `spec-inject` hold template wording rather than the author's own, hence
# the skip. It goes once the templates follow the rule themselves.
TASK = re.compile(r"^#{2,4}\s+Task\s+([0-9]+[a-z]?)\s*:\s*(.+?)\s*$")
INJECTED = re.compile(
    r"^(Update governing specs|Land the spec amendment|Claims gate|Final claims gate"
    r"|Ledger notices|Finalize all governing specs)", re.IGNORECASE)

STDIN = "<stdin>"

# A finding as (rule, message, start, end); the offsets locate the flagged span in the paragraph.
Found = tuple[str, str, int, int]


def _clean(text: str) -> str:
    """Normalize ``text`` for linting: drop a leading byte-order mark and turn CRLF or CR into
    LF, so a Windows copy of a file yields what its Unix copy does."""
    return text.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")


def _words(text: str) -> int:
    """Count the whitespace-separated tokens left after link targets are removed; the link
    ``[the ferry rota](docs/rota.md)`` is three words. A code span whose URL was blanked is one
    word, as it would be with any other word in it."""
    text = BACKTICK_SPAN.sub(lambda span: span.group() if span.group().strip("` \t") else "`x`",
                             LINK_TARGET.sub("", text))
    return len(text.split())


def _count(number: int, noun: str) -> str:
    return f"{number} {noun}" + ("" if number == 1 else "s")


# ---------------------------------------------------------------------------------------------
# Sentences


def _continues(text: str, end: int) -> bool:
    """Say whether the sentence mark ending at ``end`` fails to end its sentence: the text stops
    there, a lower-case letter comes next, or the word before the mark is a known abbreviation."""
    after = end
    while after < len(text) and text[after].isspace():
        after += 1
    if after == len(text) or text[after].islower():
        return True
    begin = end
    while begin > 0 and not text[begin - 1].isspace():
        begin -= 1
    return text[begin:end].lstrip(OPENERS).lower() in ABBREVIATIONS


def _sentence_spans(text: str) -> list[tuple[int, int]]:
    """Offsets (start, end) of the sentences of ``text``. A mark closes a sentence only when
    whitespace and then anything but a lower-case letter follow; abbreviations and file names
    such as ``rota_sync.py`` are not cut."""
    cuts: list[tuple[int, int]] = []
    start = 0
    for match in SENTENCE_END.finditer(text):
        if not _continues(text, match.end()):
            cuts.append((start, match.end()))
            start = match.end()
    cuts.append((start, len(text)))
    spans = []
    for begin, end in cuts:
        piece = text[begin:end]
        if piece.strip():
            lead = len(piece) - len(piece.lstrip())
            spans.append((begin + lead, begin + len(piece.rstrip())))
    return spans


def sentences(text: str) -> list[str]:
    """Cut a paragraph, its lines already joined by spaces, into sentences."""
    return [text[start:end] for start, end in _sentence_spans(text)]


def _body_start(text: str) -> int:
    """Offset of a list item's first word, past its bullet or number and any task box, which is
    no part of the item's words. 0 when ``text`` is no list item."""
    marker = LIST_ITEM.match(text)
    if not marker:
        return 0
    box = TASK_BOX.match(text, marker.end())
    return box.end() if box else marker.end()


# ---------------------------------------------------------------------------------------------
# Codes


def _code_spans(text: str, codes: Codes) -> list[tuple[int, int]]:
    """Every code in ``text`` as (start, end), left to right. Of overlapping matches the one
    starting first wins, then the longest, which is the rule ``markdown.bare_spans`` applies;
    words on the project's allowed list are dropped, and so is an empty match (a pattern such as
    ``[A-Z]*`` finds one everywhere). ``bare_spans`` picks its codes from these."""
    matches = sorted(((match.start(), match.end()) for pattern in codes.patterns
                      for match in pattern.finditer(text) if match.end() > match.start()),
                     key=lambda span: (span[0], -span[1]))
    kept: list[tuple[int, int]] = []
    for start, end in matches:
        if not kept or start >= kept[-1][1]:
            kept.append((start, end))
    return [(start, end) for start, end in kept if text[start:end] not in codes.allowed]


def _codes(text: str, codes: Codes) -> list[str]:
    return [text[start:end] for start, end in _code_spans(text, codes)]


def _has_words(text: str, codes: Codes) -> bool:
    """True when ``text`` still has a letter once its codes are cut out."""
    kept, last = [], 0
    for start, end in _code_spans(text, codes):
        kept.append(text[last:start])
        last = end
    kept.append(text[last:])
    return LETTER.search("".join(kept)) is not None


def _front_matter_end(text: str) -> int:
    """The line number that ends a YAML block starting on line 1 (``---`` to the next ``---``),
    as in a ledger item. 0 when there is no block or it never ends."""
    lines = text.splitlines()
    if not lines or lines[0].rstrip() != "---":
        return 0
    return next((number for number, line in enumerate(lines[1:], start=2)
                 if line.rstrip() == "---"), 0)


def _body_lines(text: str) -> list[tuple[int, str]]:
    """The prose lines after any front matter, which is data and not prose."""
    end = _front_matter_end(text)
    return [(number, line) for number, line in prose_lines(text) if number > end]


def defined_codes(text: str, codes: Codes) -> frozenset[str]:
    """The codes the text defines for itself. A heading defines the codes in it when it also has
    words (``### W5. Handover``). So does a bold label that starts a line or list item with words
    after it (``**W5.1** The note names the owner``); a ``## Key`` entry is one, so a keyed code
    is explained throughout. Codes alone in a heading or label define nothing, nor does a bold
    sentence that nothing follows."""
    defined: set[str] = set()
    for _, raw in _body_lines(text):
        line = unquote(raw)[1]
        heading = HEADING.match(line)
        if heading:
            if _has_words(heading.group(2), codes):
                defined.update(_codes(heading.group(2), codes))
            continue
        item = LIST_ITEM.match(line)
        opening = line[item.end():] if item else line.lstrip()
        label = BOLD_LABEL.match(opening)
        if label and _has_words(opening[label.end():], codes):
            defined.update(_codes(label.group(1), codes))
    return frozenset(defined)


# ---------------------------------------------------------------------------------------------
# One paragraph


def _text_findings(text: str, register: str, limits: Limits, codes: Codes, *, item: bool,
                   defined: frozenset[str], github: bool, glossed: set[str]) -> list[Found]:
    """What the lint finds in a paragraph once its lines are joined by spaces and its link
    targets are blank. In the full register a code explained or linked earlier may stand bare
    afterwards, so the caller hands the same ``glossed`` set to each of its paragraphs in
    reading order; the terse register wants an explanation at every use."""
    body = _body_start(text) if item else 0
    spans = [(body + start, body + end) for start, end in _sentence_spans(text[body:])]
    found: list[Found] = []

    links = [(match.start(1), match.end(1)) for match in LINK_TEXT.finditer(text)]
    paths = path_spans(text)
    bare = set(bare_spans(text, codes))
    for start, end in _code_spans(text, codes):
        code = text[start:end]
        if (start, end) not in bare or any(open_ <= start and end <= close
                                           for open_, close in links):
            if register == "full":
                glossed.add(code)
            continue
        if (code in defined or code in glossed or (github and code.startswith("#"))
                or any(open_ <= start and end <= close for open_, close in paths)):
            continue
        found.append(("bare-code", f'"{code}" has no words explaining it; name the record, then '
                      "give the code in brackets after those words, link it, or define it under "
                      "## Key", start, end))

    for start, end in spans:
        count = _words(text[start:end])
        if count > limits.sentence:
            found.append(("long-sentence", f"a sentence of {count} words is over the {register} "
                          f"limit of {limits.sentence}", start, end))

    if item:
        count = _words(text[body:])
        too_long = limits.item is not None and count > limits.item
        too_many = limits.item_sentences is not None and len(spans) > limits.item_sentences
        if too_long or too_many:
            allowed = " and ".join(
                _count(number, noun) for number, noun in
                ((limits.item, "word"), (limits.item_sentences, "sentence"))
                if number is not None)
            found.append(("long-item", f"a list item of {_count(count, 'word')} and "
                          f"{_count(len(spans), 'sentence')} is over the {register} limit of "
                          f"{allowed}; keep one idea in an item", 0, len(text)))
    return found


def _outside_injected(lines: list[tuple[int, str]]) -> list[tuple[int, str]]:
    """Drop the injected plan tasks from ``lines``. A task starts at its heading and stops before
    the next heading at its level or above."""
    kept: list[tuple[int, str]] = []
    level = 0  # depth of the heading that opened the skipped task; 0 outside one
    for number, line in lines:
        heading = HEADING.match(line)
        if heading:
            depth = len(heading.group(1))
            if level and depth <= level:
                level = 0
            task = TASK.match(line)
            if not level and task and INJECTED.match(task.group(2)):
                level = depth
        if not level:
            kept.append((number, line))
    return kept


def _outside_block(lines: list[tuple[int, str]],
                   headers: tuple[str, ...]) -> list[tuple[int, str]]:
    """Drop the block a tool writes after one of ``headers`` (``Implementation:``) from ``lines``,
    which hold every line outside a fence, blanks included. The block is the header line, each
    ``- `` item at any indent, and the indented lines that follow an item or the header. It ends
    at a blank line, at a fence (the numbering skips it), or at an unindented line that is not an
    item. Only the first header opens a block, and it must stand alone on its line, or be
    followed by ``[]``, which makes it a block of one line. This is the grammar of
    ``doc-tools.sh``, which writes and reads the block."""
    kept: list[tuple[int, str]] = []
    state = "before"  # before the header, inside the block, or after it
    last = 0  # the number of the block's last line
    for number, line in lines:
        if state == "inside":
            if number == last + 1 and (ITEM.match(line) or INDENTED.match(line)):
                last = number
                continue
            state = "after"
        header = next((head for head in headers if line.startswith(head)), None)
        if state == "before" and header is not None:
            rest = "".join(line[len(header):].split())
            if rest == "":
                state, last = "inside", number
                continue
            if rest == "[]":
                state = "after"
                continue
        kept.append((number, line))
    return kept


def _lint_paragraphs(text: str, skip_prefixes: tuple[str, ...], skip_blocks: tuple[str, ...]
                     ) -> Iterator[list[tuple[int, str]]]:
    """Yield the paragraphs worth linting. Front matter, a tool-written block, blockquotes and
    the tasks `spec-inject` wrote are cut first, and a quote then splits its paragraph in two.
    Headings and table rows are never linted, nor is a paragraph that opens with one of
    ``skip_prefixes``."""
    # The lines have blank link targets, so the prefixes and headers must too: they may hold one.
    prefixes = tuple(blank_link_targets(prefix) for prefix in skip_prefixes)
    headers = tuple(blank_link_targets(header) for header in skip_blocks)
    lines = _outside_injected([(number, line) for number, line
                               in _outside_block(_body_lines(text), headers)
                               if unquote(line)[0] == 0])
    for paragraph in paragraphs(lines):
        first = paragraph[0][1]
        if HEADING.match(first) or TABLE_ROW.match(first):
            continue
        item = LIST_ITEM.match(first)
        opening = first[item.end():] if item else first.lstrip()
        if opening.startswith(prefixes) or first.lstrip().startswith(prefixes):
            continue
        yield paragraph


def _join(paragraph: list[tuple[int, str]]) -> tuple[str, list[tuple[int, int]]]:
    """Join a paragraph's lines with single spaces. Also return, for each line, its start offset
    in the joined text and its line number."""
    starts, offset = [], 0
    for number, line in paragraph:
        starts.append((offset, number))
        offset += len(line) + 1
    return " ".join(line for _, line in paragraph), starts


def _line_at(starts: list[tuple[int, int]], offset: int) -> int:
    return next(number for begin, number in reversed(starts) if begin <= offset)


# ---------------------------------------------------------------------------------------------
# A whole text


def lint_text(text: str, path: str, register: str, config: Config, *, github: bool = False,
              new: Mapping[str, Base | None] | None = None) -> list[Finding]:
    """Lint one Markdown text and return its findings sorted by line. ``register`` is
    ``"terse"`` or ``"full"``; ``config`` gives the limits, the code patterns and the prefixes to
    skip; ``path`` only labels the findings. Pass ``github=True`` for text GitHub renders, where
    ``#N`` is linked already. Range mode passes ``new``, a map from each new sentence (normalized)
    to the old sentence it rewrites, or to ``None`` when it rewrites none. A finding then survives
    only if it lies in a new sentence and the branch itself caused it (``_edit_adds``): an old
    sentence beside new ones, or a fault the rewritten sentence had before, stays quiet."""
    if register not in config.limits:
        raise ValueError(f"unknown register {register!r}; expected one of "
                         + ", ".join(config.limits))
    text = _clean(text)
    limits = config.limits[register]
    defined = defined_codes(text, config.codes)
    glossed: set[str] = set()
    findings: list[Finding] = []
    for paragraph in _lint_paragraphs(text, config.skip_prefixes, config.skip_blocks):
        joined, starts = _join(paragraph)
        found = _text_findings(
            joined, register, limits, config.codes, item=bool(LIST_ITEM.match(joined)),
            defined=defined, github=github, glossed=glossed)
        if new is not None:
            found = _added_by_edit(found, joined, new)
        for rule, message, start, _ in found:
            findings.append(Finding(path, _line_at(starts, start), rule, message,
                                    paragraph[0][0], paragraph[-1][0]))
    return sorted(findings, key=lambda finding: finding.line)


def identifier_density(text: str, skip_prefixes: tuple[str, ...] = (),
                       skip_blocks: tuple[str, ...] = ()) -> float:
    """Backtick spans per 100 words in the prose that gets linted; 0.0 when it has no words."""
    words = spans = 0
    for paragraph in _lint_paragraphs(_clean(text), skip_prefixes, skip_blocks):
        joined, _ = _join(paragraph)
        words += _words(joined)
        spans += len(BACKTICK_SPAN.findall(joined))
    return spans * 100 / words if words else 0.0


# ---------------------------------------------------------------------------------------------
# Range mode


class Added(NamedTuple):
    """A changed file that has new sentences: its path, its register, its text at HEAD and its
    new sentences, normalized, each with the old sentence it edits (``None`` for none)."""

    path: str
    register: str
    text: str
    new: dict[str, Base | None]


def _normal(sentence: str) -> str:
    """``sentence`` reduced to what range mode compares: every run of digits becomes a single 0
    and the whitespace is collapsed (link targets arrive blank). Two sentences that differ in a
    number, a link target or a line break compare equal."""
    return " ".join(NUMBER.sub("0", sentence).split())


def _edit_adds(rule: str, now: str | int | tuple[int, int], base: Base | None) -> bool:
    """Decide whether a finding belongs to the branch. A sentence with no old sentence behind it
    always does. A rewritten one does when the rewrite brought in a code that was not bare in the
    old sentence, has more words than the old sentence, or belongs to an item longer in words, or
    in sentences, than the old paragraph was. ``now`` holds the flagged code, the flagged
    sentence's word count, or a (words, sentences) pair for the item."""
    if base is None:
        return True
    if rule == "bare-code":
        return now not in base.bare
    if rule == "long-sentence":
        return isinstance(now, int) and now > base.words
    return (isinstance(now, tuple)
            and (now[0] > base.paragraph_words or now[1] > base.paragraph_sentences))


def _added_by_edit(found: list[Found], joined: str, new: Mapping[str, Base | None]
                   ) -> list[Found]:
    """The findings of ``found``, a paragraph's, that sit in a new sentence and that the edit
    added (``_edit_adds``). For a ``long-item`` any new sentence of the item will do."""
    body = _body_start(joined)
    spans = [(body + begin, body + finish, _normal(joined[body + begin:body + finish]))
             for begin, finish in _sentence_spans(joined[body:])]
    kept: list[Found] = []
    for rule, message, start, end in found:
        about = [normal for begin, finish, normal in spans
                 if rule == "long-item" or begin <= start < finish]
        now: str | int | tuple[int, int]
        if rule == "bare-code":
            now = joined[start:end]
        elif rule == "long-sentence":
            now = _words(joined[start:end])
        else:
            now = (_words(joined[body:]), len(spans))
        if any(_edit_adds(rule, now, new[normal]) for normal in about if normal in new):
            kept.append((rule, message, start, end))
    return kept


def _bare_codes(sentence: str, config: Config) -> frozenset[str]:
    """The codes bare in a sentence taken alone, as written: neither the document's definitions
    nor earlier glosses help. Digits stay, unlike in ``_normal``, so a further code of a series
    the sentence already carries bare still counts as the branch's."""
    return frozenset(sentence[start:end] for rule, _, start, end in
                     _text_findings(sentence, "terse", config.limits["terse"], config.codes,
                                    item=False, defined=frozenset(), github=False, glossed=set())
                     if rule == "bare-code")


def _base_sentences(text: str, config: Config) -> list[tuple[str, Base]]:
    """The sentences of an old text, in normal form, each paired with its ``Base``."""
    found = []
    for paragraph in _lint_paragraphs(text, config.skip_prefixes, config.skip_blocks):
        joined, _ = _join(paragraph)
        body = _body_start(joined)
        spans = _sentence_spans(joined[body:])
        words = _words(joined[body:])
        for start, end in spans:
            piece = joined[body + start:body + end]
            found.append((_normal(piece), Base(_words(piece), _bare_codes(piece, config), words,
                                               len(spans))))
    return found


def _closest(normal: str, candidates: list[tuple[list[str], Base]]) -> Base | None:
    """The candidate whose words come closest to ``normal`` (difflib's ratio), provided one
    reaches ``SIMILAR``."""
    matcher = SequenceMatcher(None, autojunk=False)
    matcher.set_seq2(normal.split())
    best, found = SIMILAR, None
    for words, base in candidates:
        matcher.set_seq1(words)
        if matcher.real_quick_ratio() < best or matcher.quick_ratio() < best:
            continue
        if (ratio := matcher.ratio()) >= best:
            best, found = ratio, base
    return found


def _sentence_lines(paragraph: list[tuple[int, str]]) -> Iterator[tuple[str, range]]:
    """Each sentence of ``paragraph`` as ``lint_text`` cuts it, plus the lines it covers."""
    joined, starts = _join(paragraph)
    body = _body_start(joined)
    for start, end in _sentence_spans(joined[body:]):
        yield (joined[body + start:body + end],
               range(_line_at(starts, body + start), _line_at(starts, body + end - 1) + 1))


def _run_git(root: Path, *args: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    except OSError as error:
        raise Unreadable(f"cannot run git ({error.strerror or error})") from None


def _git(root: Path, *args: str) -> bytes:
    """What ``git`` prints on standard output for ``args``, undecoded."""
    done = _run_git(root, *args)
    if done.returncode:
        detail = os.fsdecode(done.stderr).strip() or f"exit status {done.returncode}"
        raise Unreadable(f"git {' '.join(args)}: {detail}")
    return done.stdout


def _text_at(root: Path, rev: str, path: str, *, head: bool) -> str:
    """The text of ``path`` in revision ``rev``, minus any byte-order mark. The copy at HEAD must
    be UTF-8. An old copy is only what the branch is compared with, so a byte it cannot decode is
    replaced rather than refused. Line endings are left alone: ``lint_text`` and the paragraph
    reader treat CRLF and CR as LF themselves."""
    raw = _git(root, "cat-file", "blob", f"{rev}:{path}")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        if head:
            raise Unreadable(f"cannot read {path}: not UTF-8") from None
        return raw.decode("utf-8-sig", errors="replace")


def _merge_base(root: Path, base: str) -> str:
    if base.startswith("-"):
        raise Unreadable(f"base {base!r}: a base cannot start with -")
    done = _run_git(root, "merge-base", base, "HEAD")
    if done.returncode == 0:
        return os.fsdecode(done.stdout).strip()
    # Git stays silent when both tips exist and no commit it holds is common to them.
    detail = (os.fsdecode(done.stderr).strip()
              or "no merge base with HEAD (a shallow clone may have cut the history short)")
    raise Unreadable(f"base {base!r}: {detail}")


def _changes(root: Path, merge_base: str) -> tuple[list[tuple[str, str | None]], list[str]]:
    """Which files the branch adds, edits or renames, each paired with the path it had in the
    merge-base commit (``None`` for a new file), and, in a list of its own, which it deletes.
    Renames come from ``git diff -M``. The names are read with ``-z`` so one holding a space, a
    quote or a non-ASCII letter stays whole."""
    fields = [os.fsdecode(field) for field in
              _git(root, "diff", "--name-status", "-z", "-M", "--diff-filter=AMRD", merge_base,
                   "HEAD", "--").split(b"\0")]
    changed: list[tuple[str, str | None]] = []
    deleted: list[str] = []
    index = 0
    while index < len(fields) and fields[index]:
        status = fields[index]
        if status.startswith("R"):
            changed.append((fields[index + 2], fields[index + 1]))
            index += 3
            continue
        path = fields[index + 1]
        if status == "D":
            deleted.append(path)
        else:
            changed.append((path, path if status == "M" else None))
        index += 2
    return changed, deleted


def _moved_from(root: Path, merge_base: str, deleted: list[str], config: Config
                ) -> list[tuple[str, Base]]:
    """The sentences that the Markdown files the branch deletes held at the merge base: text
    carried from a deleted file into another one is not new."""
    return [sentence for path in deleted if path.lower().endswith(".md")
            for sentence in _base_sentences(_text_at(root, merge_base, path, head=False), config)]


def _new_in_head(root: Path, merge_base: str, path: str, source: str | None,
                 moved: list[tuple[str, Base]], config: Config
                 ) -> tuple[str, list[tuple[str, Base | None]]]:
    """Read ``path`` at HEAD and find what the branch wrote in it: the text, and each new
    sentence, normalized, beside the old sentence it rewrites (``None`` if it rewrites none). A
    line the diff adds must hold the sentence, and neither ``source`` (the name the file had in
    the merge-base commit) nor ``moved`` may hold one that normalizes the same. The old
    sentence is the closest one (``_closest``) among those HEAD no longer contains, because a
    rewrite replaces the old words. Only commits count: the working tree is never read."""
    text = _text_at(root, "HEAD", path, head=True)
    added: set[int] | None = None  # None: the file is new, so every line counts
    old = ""
    if source is not None:
        diff = _git(root, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--text",
                    "--unified=0", f"{merge_base}:{source}", f"HEAD:{path}")
        added = set()
        for match in HUNK.finditer(diff.decode("utf-8", errors="replace")):
            first, count = int(match.group(1)), int(match.group(2) or 1)
            added.update(range(first, first + count))
        if not added:
            return text, []
        old = _text_at(root, merge_base, source, head=False)
    base = [*_base_sentences(old, config), *moved]
    known = {normal for normal, _ in base}
    now = [(_normal(sentence), span)
           for paragraph in _lint_paragraphs(text, config.skip_prefixes, config.skip_blocks)
           for sentence, span in _sentence_lines(paragraph)]
    present = {normal for normal, _ in now}
    candidates = [(normal.split(), info) for normal, info in base if normal not in present]
    return text, [(normal, _closest(normal, candidates)) for normal, span in now
                  if (added is None or added.intersection(span)) and normal not in known]


def new_sentences(root: Path, base: str, path: str, config: Config) -> dict[str, Base | None]:
    """The new sentences of ``path`` at HEAD, normalized, each beside the old sentence it
    rewrites: the map ``lint_text(new=...)`` takes. A file the branch leaves alone gives an empty
    dict."""
    merge_base = _merge_base(root, base)
    changed, deleted = _changes(root, merge_base)
    sources = dict(changed)
    if path not in sources:
        return {}
    moved = _moved_from(root, merge_base, deleted, config)
    return dict(_new_in_head(root, merge_base, path, sources[path], moved, config)[1])


def _range_files(root: Path, base: str, config: Config) -> list[Added]:
    """Every Markdown file that a commit of the branch adds, edits or renames, when it has a
    register and at least one new sentence. Registers come from the configuration and the
    doc-index at HEAD: the caller loads the first as ``config``, and this reads the second."""
    merge_base = _merge_base(root, base)
    index = read_index(root, "HEAD")
    changed, deleted = _changes(root, merge_base)
    moved = _moved_from(root, merge_base, deleted, config)
    files = []
    for path, source in changed:
        register = register_for(path, config, index)
        if register is None:
            continue
        text, new = _new_in_head(root, merge_base, path, source, moved, config)
        if new:
            files.append(Added(path, register, text, dict(new)))
    return files


def _lint_files(files: list[Added], config: Config) -> list[Finding]:
    return [finding for file in files
            for finding in lint_text(file.text, file.path, file.register, config, new=file.new)]


def lint_range(root: Path, base: str, config: Config) -> list[Finding]:
    """Lint what HEAD has gained over the merge base of ``base`` and HEAD, in the repository at
    ``root``. ``config`` should be ``load(root, "HEAD")``. Raises ``Unreadable`` when git cannot
    resolve ``base`` or a file at HEAD cannot be decoded, and ``config.Malformed`` for a doc-index
    at HEAD that cannot be used."""
    return _lint_files(_range_files(root, base, config), config)


# ---------------------------------------------------------------------------------------------
# Ceilings and counts

# The number of this engine's way of counting findings. It is not the release number: most
# releases leave it alone. Any change that moves the findings of a text that has not changed (a
# limit, a default code pattern, a rule of the parser or of the lint) raises it by one, and adds
# an entry for the new version to ``EXPECTED`` in ``tests/test_ceilings.py``, which fails until
# then. A ceilings file records the version its counts were made with and is never compared with
# counts made by another.
COUNTING_VERSION = 1
CEILINGS = "docs/writing/ceilings.json"


class Ceilings(NamedTuple):
    """A ceilings file: the counting version its counts were made with, and the ceiling of each
    path it lists."""

    version: int
    paths: dict[str, int]


class Ceiling(NamedTuple):
    """One printed line of a ceilings run, whether it fails, and, for a path over its ceiling
    only, the findings listed beneath it, which show where to look."""

    line: str
    failed: bool
    findings: tuple[Finding, ...] = ()


class Folder(NamedTuple):
    """The Markdown files of one register in one folder, and the findings they hold."""

    folder: str
    register: str
    files: int
    findings: int


def _whole(value: object) -> bool:
    """True for a JSON whole number, 0 or more. A boolean is not one."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise Malformed(f"{key!r} is listed twice")
        seen.add(key)
    return dict(pairs)


def parse_ceilings(text: str) -> Ceilings:
    """Read the text of a ceilings file. Raises ``Malformed`` unless the top level holds
    ``paths`` and, if it has one, ``counting_version`` and nothing else, the version is a whole
    number, and every path is listed once, from the top of the repository, in normal form (it does
    not start with ``/`` or ``./``, hold ``..`` or end with ``/``), beside a whole-number ceiling.
    A file with no ``counting_version`` is one from before versions: its version is 0."""
    try:
        data = json.loads(text, object_pairs_hook=_unique_keys)
    except Malformed:
        raise
    except (ValueError, RecursionError) as error:
        raise Malformed(f"not JSON: {error}") from None
    if (not isinstance(data, dict) or not {"paths"} <= set(data) <= {"counting_version", "paths"}
            or not isinstance(data["paths"], dict)):
        raise Malformed('expected {"counting_version": <whole number>, "paths": '
                        '{"<file or folder>": <whole number>}}')
    version = data.get("counting_version", 0)
    if not _whole(version):
        raise Malformed("counting_version must be a whole number, 0 or more; "
                        f"{json.dumps(version)} is not")
    paths: dict[str, int] = {}
    for path, ceiling in data["paths"].items():
        posix = PurePosixPath(path)
        if not posix.parts or posix.is_absolute() or ".." in posix.parts or str(posix) != path:
            raise Malformed(f"{path!r} is not a path in normal form: it may not start with / "
                            "or ./, hold .. or end with /")
        if not _whole(ceiling):
            raise Malformed(f"{path}: a ceiling is a whole number, 0 or more, and "
                            f"{json.dumps(ceiling)} is not")
        paths[path] = ceiling
    return Ceilings(version, paths)


def _parse_labelled(text: str, file: str, where: str) -> Ceilings:
    try:
        return parse_ceilings(text)
    except Malformed as error:
        raise Malformed(f"{file} at {where}: {error}") from None


def _ceilings_at(root: Path, rev: str, file: str, where: str) -> Ceilings | None:
    """The ceilings file as committed at ``rev``; ``None`` when ``rev`` has none."""
    if _run_git(root, "cat-file", "-e", f"{rev}:{file}").returncode:
        return None
    return _parse_labelled(_text_at(root, rev, file, head=True), file, where)


class Tree:
    """The Markdown files of one tree, the register of each, and what the lint finds in them,
    read once. ``files`` are the regular files of the tree as paths from its top, and ``read``
    gives a file's text. Records and files with no register are left out of every count."""

    def __init__(self, files: Iterable[str], read: Callable[[str], str], settings: Config,
                 index: dict | None) -> None:
        self._read = read
        self._settings = settings
        self._found: dict[str, list[Finding]] = {}
        self.registers: dict[str, str] = {}
        records = set()
        for file in sorted(files):
            if not file.lower().endswith(".md"):
                continue
            if is_record(file, index):
                records.add(file)
                continue
            register = register_for(file, settings, index)
            if register is not None:
                self.registers[file] = register
        self.records: frozenset[str] = frozenset(records)

    def is_record(self, path: str) -> bool:
        """True when ``path`` is itself a Markdown file that is a record."""
        return path in self.records

    def findings_of(self, file: str) -> list[Finding]:
        if file not in self._found:
            self._found[file] = lint_text(self._read(file), file, self.registers[file],
                                          self._settings)
        return self._found[file]

    def findings(self, path: str) -> list[Finding] | None:
        """The findings in the files the lint reads under ``path``, which names one Markdown file
        or the folder holding several. ``None`` when it names no such file."""
        named = [file for file in self.registers if file == path or file.startswith(path + "/")]
        if not named:
            return None
        return [finding for file in named for finding in self.findings_of(file)]


def _head_files(root: Path) -> list[str]:
    """The regular files of the committed HEAD. Links and submodules are not read."""
    files = []
    for entry in os.fsdecode(_git(root, "ls-tree", "-r", "-z", "HEAD")).split("\0"):
        meta, _, name = entry.partition("\t")
        fields = meta.split()
        if name and len(fields) == 3 and fields[1] == "blob" and fields[0] != "120000":
            files.append(name)
    return files


def _working_files(root: Path, paths: list[str]) -> list[str]:
    """The regular files of the working tree that git knows or does not ignore, as paths from the
    top of the repository. ``paths`` are git pathspecs from the working directory; none means the
    whole repository."""
    names = os.fsdecode(_git(Path.cwd(), "ls-files", "-co", "--exclude-standard", "-z",
                             "--full-name", "--", *(paths or [":/"])))
    found = []
    for name in dict.fromkeys(names.split("\0")):
        try:
            if name and stat.S_ISREG(os.lstat(root / name).st_mode):
                found.append(name)
        except OSError:
            pass  # tracked, and deleted from the working tree
    return found


def _disk_reader(root: Path) -> Callable[[str], str]:
    def read(file: str) -> str:
        try:
            return (root / file).read_bytes().decode("utf-8-sig")
        except UnicodeDecodeError:
            raise Unreadable(f"cannot read {file}: not UTF-8") from None
        except OSError as error:
            raise Unreadable(f"cannot read {file}: {error.strerror or error}") from None
    return read


def _update_command(file: str) -> str:
    named = "" if file == CEILINGS else f" --file {shlex.quote(file)}"
    return "writing ceilings --update" + named


def check_ceilings(root: Path, file: str, base: str | None) -> list[Ceiling]:
    """Check the ceilings file committed at HEAD against the files committed there, and against
    the file as it stood where the branch left ``base``. A path is counted over whole files, and
    each gets a line. A ceiling that rose since then, or a path the earlier file listed and this
    one does not, fails unless the range edits the project's writing configuration or moves
    ``counting_version`` to this engine's; the line names which. A file recorded with another
    version gets one failing line and no counts. ``base`` of ``None`` means the default base
    (``_default_base``), looked up only when there is a file at HEAD to compare: with none, the run
    has nothing to check and passes. ``Malformed`` is raised for a file that is not valid,
    ``Unreadable`` when git cannot resolve ``base`` or read a file."""
    head = _ceilings_at(root, "HEAD", file, "HEAD")
    if head is None and base is None:  # no file and no base named: nothing to check against
        return [Ceiling(f"{file}: {_count(0, 'path')} checked at HEAD", False)]
    merge_base = _merge_base(root, base or _default_base(root))
    before = _ceilings_at(root, merge_base, file, "the base")
    if head is not None and head.version != COUNTING_VERSION:
        return [Ceiling(f"writing ceilings: counted with version {head.version}; this "
                        f"engine counts with {COUNTING_VERSION}: run {_update_command(file)}",
                        True)]
    listed = head.paths if head else {}
    earlier = before.paths if before else {}
    summary = Ceiling(f"{file}: {_count(len(listed), 'path')} checked at HEAD", False)
    if head is None and before is None:
        return [summary]

    names = os.fsdecode(_git(root, "diff", "--name-only", "--no-renames", "-z", merge_base,
                             "HEAD", "--")).split("\0")
    changes = [CONFIG] if CONFIG in names else []
    if head is not None and before is not None and before.version < head.version:
        changes.append(f"counting_version from {before.version} to {head.version}")
    allowed = f"; allowed: the range changes {' and '.join(changes)}" if changes else ""

    tree = Tree(_head_files(root), lambda name: _text_at(root, "HEAD", name, head=True),
                load(root, "HEAD"), read_index(root, "HEAD"))
    results: list[Ceiling] = []
    for path, ceiling in sorted(listed.items()):
        if tree.is_record(path):
            results.append(Ceiling(f"{path} is a record; records take no ceiling", True))
            continue
        found = tree.findings(path)
        if found is None and path not in earlier:
            results.append(Ceiling(f"{path}: names no Markdown file the lint reads at HEAD", True))
            continue
        if path in earlier and ceiling > earlier[path]:
            results.append(Ceiling(f"{path}: the ceiling rose from {earlier[path]} to {ceiling} "
                                   f"against the base{allowed}", not changes))
        count = len(found or [])
        if count > ceiling:
            results.append(Ceiling(f"{path}: {_count(count, 'finding')}, above its ceiling of "
                                   f"{ceiling}", True, tuple(found or [])))
        elif count < ceiling:
            results.append(Ceiling(f"{path}: {_count(count, 'finding')}, below its ceiling of "
                                   f"{ceiling}; set the ceiling to {count}", True))
        else:
            results.append(Ceiling(f"{path}: {_count(count, 'finding')}, at its ceiling of "
                                   f"{ceiling}", False))
    results.extend(Ceiling(f"{path}: dropped from {file}; the base holds it at {ceiling}"
                           f"{allowed}", not changes)
                   for path, ceiling in sorted(earlier.items()) if path not in listed)
    return [*results, summary]


def update_ceilings(root: Path, file: str) -> list[Ceiling]:
    """Count the working tree for each path the working copy of the ceilings file lists, and
    rewrite the file with those counts and ``COUNTING_VERSION``. It adds no path and removes none.
    A path that names a record is a failing line, and the file is left as it was."""
    try:
        text = (root / file).read_bytes().decode("utf-8-sig")
    except FileNotFoundError:
        example = f'{{"counting_version": {COUNTING_VERSION}, "paths": {{"<file or folder>": 0}}}}'
        raise Unreadable(f"cannot update {file}: it does not exist; create it as {example} and "
                         "run this again") from None
    except UnicodeDecodeError:
        raise Unreadable(f"cannot read {file}: not UTF-8") from None
    except OSError as error:
        raise Unreadable(f"cannot read {file}: {error.strerror or error}") from None
    listed = _parse_labelled(text, file, "the working tree").paths
    tree = Tree(_working_files(root, []), _disk_reader(root), load(root), read_index(root, None))
    records = [Ceiling(f"{path} is a record; records take no ceiling", True)
               for path in sorted(listed) if tree.is_record(path)]
    if records:
        return records
    counts = {path: len(tree.findings(path) or []) for path in sorted(listed)}
    written = json.dumps({"counting_version": COUNTING_VERSION, "paths": counts}, indent=2,
                         ensure_ascii=False) + "\n"
    try:
        (root / file).write_bytes(written.encode("utf-8"))
    except OSError as error:
        raise Unreadable(f"cannot write {file}: {error.strerror or error}") from None
    return [*(Ceiling(f"{path}: {_count(count, 'finding')}", False)
              for path, count in counts.items()),
            Ceiling(f"{file}: recorded {_count(len(counts), 'path')} at counting version "
                    f"{COUNTING_VERSION}", False)]


def count_folders(tree: Tree) -> list[Folder]:
    """The files and findings of the tree for each folder and register, sorted by folder and then
    register. A file at the top of the repository is in the folder ``.``."""
    groups: dict[tuple[str, str], list[int]] = {}
    for file, register in tree.registers.items():
        group = groups.setdefault((posixpath.dirname(file) or ".", register), [0, 0])
        group[0] += 1
        group[1] += len(tree.findings_of(file))
    return [Folder(folder, register, files, found)
            for (folder, register), (files, found) in sorted(groups.items())]


# ---------------------------------------------------------------------------------------------
# The command line


def _print_findings(findings: list[Finding]) -> None:
    for finding in findings:
        print(f"{finding.path}:{finding.line}: {finding.rule}: {finding.message}")


def _top_level() -> Path:
    """The top of the repository around the working directory; the directory itself when it is
    in no repository, or git cannot run."""
    try:
        done = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True)
    except OSError:
        return Path.cwd()
    top = os.fsdecode(done.stdout).strip()
    return Path(top) if done.returncode == 0 and top else Path.cwd()


def _repo_root() -> Path:
    """The top of the repository around the working directory. Unlike ``_top_level``, a directory
    outside any repository is an error here."""
    return Path(os.fsdecode(_git(Path.cwd(), "rev-parse", "--show-toplevel")).rstrip("\n"))


def _relative(file: Path, root: Path) -> str | None:
    """``file`` as a path from ``root``, with "/" between the names; ``None`` for a file that is
    not under it. Links in the folders are followed, but the file's own name is not resolved."""
    absolute = Path(os.path.abspath(str(file)))
    real = Path(os.path.realpath(str(absolute.parent))) / absolute.name
    try:
        return real.relative_to(os.path.realpath(str(root))).as_posix()
    except ValueError:
        return None


def _usable(name: str) -> None:
    """Raise ``OSError`` unless ``name`` is a file that can be read, so that a typo or a folder is
    an error even when no register would have the lint read it."""
    if stat.S_ISDIR(os.stat(name).st_mode):
        raise IsADirectoryError(errno.EISDIR, os.strerror(errno.EISDIR))


def _check(args: argparse.Namespace) -> int:
    reads_stdin = "-" in args.files
    if args.files.count("-") > 1:
        args.usage("standard input (-) may be named once")
    if reads_stdin and not args.profile:
        args.usage("standard input has no path to find a register by: give --profile")
    if args.name is not None and not reads_stdin:
        args.usage("--name labels standard input: use it with -")

    root = _top_level()
    settings = load(root)
    index = None if args.profile else read_index(root, None)
    status = 0
    every: list[Finding] = []
    for name in args.files:
        label = (args.name or STDIN) if name == "-" else name
        try:
            if name != "-":
                _usable(name)
        except OSError as error:
            print(f"writing: cannot read {label}: {error.strerror or error}", file=sys.stderr)
            status = 2
            continue
        if args.profile:
            register = args.profile
        else:
            path = _relative(Path(name), root)  # a file: standard input needs --profile
            register = None if path is None else register_for(path, settings, index)
        if register is None:
            print(f"{label}: not linted (no register)", file=sys.stderr)
            continue
        try:
            raw = sys.stdin.buffer.read() if name == "-" else Path(name).read_bytes()
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            print(f"writing: cannot read {label}: not UTF-8", file=sys.stderr)
            status = 2
            continue
        except OSError as error:
            print(f"writing: cannot read {label}: {error.strerror or error}", file=sys.stderr)
            status = 2
            continue
        findings = lint_text(text, label, register, settings, github=args.github)
        every += findings
        if args.format == "text":
            _print_findings(findings)
            density = identifier_density(text, settings.skip_prefixes, settings.skip_blocks)
            print(f"{label}: {density:.1f} backtick spans per 100 words")
        status = max(status, 1 if findings else 0)
    if args.format == "json":
        print(json.dumps([finding._asdict() for finding in every], indent=2))
    return status


def _range(args: argparse.Namespace) -> int:
    base, dots, head = args.range.partition("...")
    if not base or ".." in base or (dots and head != "HEAD"):
        args.usage("range takes BASE...HEAD, with three dots and HEAD, the committed tip, as "
                   "the head")
    root = _repo_root()
    settings = load(root, "HEAD")
    files = _range_files(root, base, settings)
    findings = _lint_files(files, settings)
    if args.format == "json":
        print(json.dumps([finding._asdict() for finding in findings], indent=2))
    else:
        _print_findings(findings)
        for file in files:
            density = identifier_density(file.text, settings.skip_prefixes, settings.skip_blocks)
            print(f"{file.path}: {density:.1f} backtick spans per 100 words (whole file)")
    return 1 if findings else 0


def _default_base(root: Path) -> str:
    """The base review-pr takes when none is named: what ``origin/HEAD`` points at, else
    ``origin/main``."""
    done = _run_git(root, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
    name = os.fsdecode(done.stdout).strip()
    return name if done.returncode == 0 and name else "origin/main"


def _ceilings(args: argparse.Namespace) -> int:
    if args.update and args.base is not None:
        args.usage("--update counts the working tree: it takes no --base")
    root = _repo_root()
    file = CEILINGS if args.file is None else _relative(Path(args.file), root)
    if file is None:
        raise Unreadable(f"{args.file} is not inside the repository")
    if args.update:
        results = update_ceilings(root, file)
    else:
        results = check_ceilings(root, file, args.base)
    for result in results:
        print(result.line)
        _print_findings(list(result.findings))
    return 1 if any(result.failed for result in results) else 0


def _named_files(root: Path, path: str | None) -> list[str]:
    """The working-tree files under the pathspec ``path`` (the whole repository for ``None``).
    A pathspec that matches no file is an error, which a typo would otherwise hide as a count of
    zero."""
    files = _working_files(root, [] if path is None else [path])
    if path is not None and not files:
        raise Unreadable(f"{path}: matches no file")
    return files


def _counts(args: argparse.Namespace) -> int:
    root = _repo_root()
    files = [file for path in args.paths or [None] for file in _named_files(root, path)]
    tree = Tree(list(dict.fromkeys(files)), _disk_reader(root), load(root), read_index(root, None))
    folders = count_folders(tree)
    if args.format == "json":
        print(json.dumps({"counting_version": COUNTING_VERSION,
                          "folders": [item._asdict() for item in folders],
                          "records_skipped": len(tree.records)}, indent=2))
        return 0
    for item in folders:
        print(f"{item.folder}: {item.register}, {_count(item.files, 'file')}, "
              f"{_count(item.findings, 'finding')}")
    print(f"counting version {COUNTING_VERSION}; {_count(len(tree.records), 'record')} skipped")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="writing", description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)
    check = commands.add_parser(
        "check", help="lint whole files, or standard input",
        description="Lint whole files, or standard input for -. Exit status: 0 clean, "
        "1 findings, 2 a wrong command line or an input that cannot be used.")
    check.add_argument("--profile", choices=REGISTERS,
                       help="the register of every input (default: look each file's up; "
                       "required for -)")
    check.add_argument("--github", action="store_true",
                       help="the text is rendered on GitHub, where #N is linked already")
    check.add_argument("--format", choices=("text", "json"), default="text",
                       help="json: a single list holding one object per finding (default text)")
    check.add_argument("--name", metavar="LABEL",
                       help="the label standard input carries in findings (with -)")
    check.add_argument("files", nargs="+", metavar="FILE",
                       help="a Markdown file, or - for standard input")
    check.set_defaults(handler=_check, usage=check.error)
    changes = commands.add_parser(
        "range", help="lint what a branch wrote",
        description="Lint the sentences the committed HEAD gained over the merge base of BASE and "
        "HEAD. Exit status: 0 clean, 1 findings, 2 a wrong command line, a base that git cannot "
        "resolve, or an unusable file.")
    changes.add_argument("--format", choices=("text", "json"), default="text",
                         help="json: a single list holding one object per finding (default text)")
    changes.add_argument("range", metavar="BASE...HEAD",
                         help="BASE is any commit-ish; the head is always HEAD, and BASE alone "
                         "means BASE...HEAD")
    changes.set_defaults(handler=_range, usage=changes.error)
    held = commands.add_parser(
        "ceilings", help="hold paths to the finding counts recorded for them",
        description="Check the counts recorded in the ceilings file against the committed HEAD, "
        "every Markdown file counted whole, or record them again with --update. Exit status: "
        "0 when all hold; 1 for a count over or under its ceiling, a ceiling that rose, a path "
        "that left the file, a stale counting version, or a record with a ceiling; 2 for a wrong "
        "command line, a base that git cannot resolve, or an unusable file.")
    held.add_argument("--file", metavar="PATH",
                      help=f"the ceilings file (default {CEILINGS} from the top of the "
                      "repository; a path you give is read from the working directory)")
    held.add_argument("--base", metavar="REF",
                      help="the commit whose copy of the file no ceiling may rise above "
                      "(default: the target of origin/HEAD, else origin/main)")
    held.add_argument("--update", action="store_true",
                      help="count the working tree for every listed path and rewrite the file "
                      "with this engine's counting version; no path is added or removed")
    held.set_defaults(handler=_ceilings, usage=held.error)
    totals = commands.add_parser(
        "counts", help="count findings per folder and register",
        description="Count the findings of the working tree for each folder and register, leaving "
        "out records and files with no register. Exit status: 0, or 2 for a file or path that "
        "cannot be used.")
    totals.add_argument("--format", choices=("text", "json"), default="text",
                        help="json: counting_version, folders and records_skipped (default text)")
    totals.add_argument("paths", nargs="*", metavar="PATH",
                        help="git pathspecs from the working directory (default: the whole "
                        "repository)")
    totals.set_defaults(handler=_counts, usage=totals.error)
    return parser


class _Stdout:
    """Standard output that outlives its reader, as when a command is piped into ``head -1``. On
    the first ``BrokenPipeError`` it points the descriptor at the null device and carries on, so
    the run reaches its own return, and the flush the interpreter makes at exit finds nothing to
    fail on. Without it the run ends in a traceback and status 120."""

    def __init__(self, stream: Any) -> None:
        self._stream = stream
        self._live = True

    def __getattr__(self, name: str) -> Any:
        return getattr(self._stream, name)

    def write(self, text: str) -> int:
        self._try(self._stream.write, text)
        return len(text)

    def flush(self) -> None:
        self._try(self._stream.flush)

    def _try(self, call: Callable[..., object], *args: str) -> None:
        if not self._live:
            return
        try:
            call(*args)
        except BrokenPipeError:
            try:
                null = os.open(os.devnull, os.O_WRONLY)
                os.dup2(null, self._stream.fileno())
                os.close(null)
            except (OSError, ValueError):  # no descriptor to redirect: drop what comes
                self._live = False


@contextmanager
def closed_pipe_proof() -> Iterator[None]:
    """Within the block, standard output is a ``_Stdout``; what it holds is flushed on the way
    out, so a reader that left shows there and not at the interpreter's exit."""
    out = sys.stdout
    if out is None:  # ``>&-``: nothing to wrap, and print drops what it is given
        yield
        return
    sys.stdout = _Stdout(out)
    try:
        yield
    finally:
        sys.stdout.flush()
        sys.stdout = out


def main(argv: list[str] | None = None) -> int:
    """Run the command in ``argv`` (default: the process's arguments) and return its exit
    code. A configuration or a base that cannot be used is reported, not raised."""
    args = _parser().parse_args(argv)
    try:
        return args.handler(args)
    except (Malformed, Unreadable) as error:
        print(f"writing: {error}", file=sys.stderr)
        return 2


def entry(argv: list[str] | None = None) -> int:
    """``main``, except that a crash exits 2 with the error on standard error. An uncaught
    exception would exit 1 and read as findings. A reader that closes the pipe early changes
    nothing: the run returns the status it would have."""
    try:
        with closed_pipe_proof():
            return main(argv)
    except Exception as error:  # a bug, not a finding
        print(f"writing: internal error: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(entry())
