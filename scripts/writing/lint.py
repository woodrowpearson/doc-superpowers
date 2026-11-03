#!/usr/bin/env python3
"""The writing lint, whole-file check.

Three faults make Markdown hard to read in one pass, and this lint reports them. A code, such as
a record number, appears with nothing to explain it. A sentence runs past the word limit of its
register. A list item runs past the register's limit on words or on sentences. It also prints,
for information only, how many backtick spans a file has per 100 of its words. It cannot tell
whether the words beside a code describe it, whether a brief sentence says anything, whether
plain words hide jargon, or whether the main point comes first.

    lint.py check [--profile terse|full] [--github] [--format text|json] [--name LABEL] FILE...|-

``check`` reads whole files, or standard input for ``-``. A register sets the limits. Without
``--profile`` each file's register comes from the project's configuration, by its doc-index type
and then its path (``config.register_for``), the path being taken from the top of the repository.
A file with no register is named on standard error and is not a finding. Standard input has no
path, so it needs ``--profile``; ``--name`` is only the label its findings carry.

The exit status is 0 for a clean run and 1 when there are findings, each printed as
``path:line: rule: message``. It is 2 when the command line is wrong, an input cannot be opened
or decoded, the configuration is unusable, or the lint itself crashes. With ``--format json`` the
findings are printed instead as one list of objects, one per ``Finding``, with all its fields.

``Config`` (``config.py``, ``defaults.json``) supplies the limits, the shape of a code, the words
that are not codes, the line prefixes to leave alone and the headers of the blocks to leave alone
(the ``Implementation:`` list a tool writes into a decision record); ``markdown.py`` does the
reading. Its ``enabled`` switch is for callers that run the lint unasked (the audit, the review,
the hooks): an explicit ``check`` always runs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import NamedTuple

# An isolated interpreter (-I) leaves this script's folder off the path, and the modules import
# each other by name.
_HERE = str(Path(__file__).resolve().parent)
if sys.path[:1] != [_HERE]:
    sys.path.insert(0, _HERE)

from config import (REGISTERS, Config, Limits, Malformed, load,  # noqa: E402
                    read_index, register_for)
from markdown import (HEADING, LINK_TARGET, LIST_ITEM, TABLE_ROW, Codes,  # noqa: E402
                      bare_spans, blank_link_targets, paragraphs, path_spans, prose_lines,
                      unquote)


class Finding(NamedTuple):
    path: str
    line: int
    rule: str
    message: str
    # Where the finding's paragraph starts and ends, as line numbers.
    paragraph_first_line: int
    paragraph_last_line: int


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
    ``[the ferry rota](docs/rota.md)`` is three words."""
    return len(LINK_TARGET.sub("", text).split())


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
    words on the project's allowed list are dropped. ``bare_spans`` picks its codes from these."""
    matches = sorted(((match.start(), match.end()) for pattern in codes.patterns
                      for match in pattern.finditer(text)), key=lambda span: (span[0], -span[1]))
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


def lint_text(text: str, path: str, register: str, config: Config, *,
              github: bool = False) -> list[Finding]:
    """Lint one Markdown text and return its findings sorted by line. ``register`` is
    ``"terse"`` or ``"full"``; ``config`` gives the limits, the code patterns and the prefixes to
    skip; ``path`` only labels the findings. Pass ``github=True`` for text GitHub renders, where
    ``#N`` is linked already."""
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
        for rule, message, start, _ in _text_findings(
                joined, register, limits, config.codes, item=bool(LIST_ITEM.match(joined)),
                defined=defined, github=github, glossed=glossed):
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


def _relative(file: Path, root: Path) -> str | None:
    """``file`` as a path from ``root``, with "/" between the names; ``None`` for a file that is
    not under it. Links in the folders are followed, but the file's own name is not resolved."""
    absolute = Path(os.path.abspath(str(file)))
    real = Path(os.path.realpath(str(absolute.parent))) / absolute.name
    try:
        return real.relative_to(os.path.realpath(str(root))).as_posix()
    except ValueError:
        return None


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
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the command in ``argv`` (default: the process's arguments) and return its exit
    code. A configuration that cannot be used is reported, not raised."""
    args = _parser().parse_args(argv)
    try:
        return args.handler(args)
    except Malformed as error:
        print(f"writing: {error}", file=sys.stderr)
        return 2


def entry(argv: list[str] | None = None) -> int:
    """``main``, except that a crash exits 2 with the error on standard error. An uncaught
    exception would exit 1 and read as findings."""
    try:
        return main(argv)
    except Exception as error:  # a bug, not a finding
        print(f"writing: internal error: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(entry())
