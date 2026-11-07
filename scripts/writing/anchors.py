#!/usr/bin/env python3
"""The anchor check: did a rewrite keep the landmarks a reader navigates by?

A landmark, called an anchor here, is anything a reader can search for or follow: an identifier
set in backticks, a code such as a record number, a number, or the target of a link. A rewrite may
reword and reorder freely, but it may not lose one. For each named file this reads two copies, the
one a base commit holds and the one in the working tree, extracts the anchors of both by a single
routine, and reports every anchor that the new copy mentions less often than the old.

    anchors.py --base REF [--format text|json] FILE...

How each kind is counted:

- Identifier: a span between single backticks. Prose is read a paragraph at a time, joined the way
  the lint joins it, so a span may wrap over several lines; its whitespace collapses to one space
  apiece. A lone backtick that never pairs makes nothing. Within a fenced block every line stands
  alone.
- Code: whatever the project's code patterns match, anywhere on a line (``config.load`` of the
  repository's top, as the working tree has it). Link text and link targets take part, which is
  why a code that moves into a link still counts.
- Number: found on every line, fences, table rows and headings included. The digits of a code, of
  an identifier, of an inline link's target or of an ordered list marker do not count as numbers;
  the destination of a reference definition is not set aside, so digits in it do. A decimal point
  or a thousands separator belongs to the number (``3.5``, ``1,120``).
- Link target: the destination of an inline link or image, or of a reference definition
  (``[label]: destination``). A footnote definition (``[^1]: words``) names no destination.

Out of reach: whether a statement got stronger, weaker or ended up in the wrong place, and whether
a link leads where the author meant. The reader holding both texts judges those. An anchor lost in
one spot and gained in another nets out to nothing here.

A second rule covers links. Each relative destination that the new copy adds, other than inside
code, must point at something that exists on disk, whether file or folder, counted from the folder
the file lives in. A fragment (``#part``) and a query (``?x=1``) are cut off, and percent escapes
decoded, before the lookup. Never looked up: a destination with a scheme (a URL), a bare fragment,
one that starts with a slash, and one that the base copy held already.

The base commit stands against the working tree, never HEAD, which lets a rewrite be vetted ahead
of its commit. A file missing from the base has nothing to lose, though its links are still looked
up. Only the working-tree copy has to be UTF-8: undecodable bytes in the base copy are replaced, so
such a file is still compared and a loss in it exits 1, not 2.

Exit status: 0 when nothing was lost and no added link leads nowhere; 1 when an anchor was lost or
an added link leads nowhere; 2 for a wrong command line, an unreadable or undecodable file, a base
that git cannot resolve, an unusable configuration, or a crash in the check itself (reported as
``writing: internal error: TYPE: MESSAGE``).

Output. Text mode prints a line per finding, lost anchors first, then each added link that leads
nowhere, as ``FILE:LINE: MESSAGE``. For a lost anchor, MESSAGE gives its kind and text and says
either that it is gone or how many uses remain against how many the base had, and LINE is the
first line of the base copy that used it. For an added link, MESSAGE says the destination names no
file, and LINE is in the new copy. ``--format json`` prints one JSON list instead, an object per
finding in the same order, and nothing else on standard output. Every object has ``path`` (FILE
as given), ``line``, ``kind`` (identifier, code, number or link-target), ``anchor``, ``rule``
(``lost-anchor`` or ``unresolved-target``) and ``message`` (the text line without its
``FILE:LINE:`` prefix). A ``lost-anchor`` object has three more: ``before`` (uses in the base
copy), ``after`` (uses in the new copy) and ``base_lines`` (the lines of the base copy that used
it, ascending).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import NamedTuple
from urllib.parse import unquote as percent_decode

# An isolated interpreter (-I) keeps this script's folder off the path, yet the modules import one
# another by name.
_HERE = str(Path(__file__).resolve().parent)
if sys.path[:1] != [_HERE]:
    sys.path.insert(0, _HERE)

# The lint module owns the git helpers, the code finder and the paragraph joiner. They are shared.
# A module that is missing or broken beside this script ends the run with status 2: an uncaught
# import error would exit 1, which reads as a lost anchor.
try:
    from config import Malformed, load  # noqa: E402
    from lint import (BACKTICK_SPAN, Unreadable, _code_spans, _join,  # noqa: E402
                      _line_at, _relative, _repo_root, _run_git, _text_at,
                      closed_pipe_proof)
    from markdown import REFERENCE, Codes, paragraphs, prose_lines  # noqa: E402
except Exception as _error:  # a defect in the installation, not a finding
    print(f"writing: cannot load the engine: {type(_error).__name__}: "
          + " ".join(str(_error).split()), file=sys.stderr)
    sys.exit(2)

# The destination of an inline link or image; a title after it and angle brackets are left out.
TARGET = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+[^)]*)?\)")
# Digits kept whole around an inner decimal point or thousands separator.
NUMBER = re.compile(r"(?<![0-9A-Za-z_.,])[0-9]+(?:[.,][0-9]+)*(?![0-9A-Za-z_])")
ORDERED_MARKER = re.compile(r"^\s*[0-9]+[.)](?=\s)")
# URLs and mail links open with a scheme, so the repository does not hold them.
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
KINDS = ("identifier", "code", "number", "link-target")


class Anchor(NamedTuple):
    line: int
    kind: str
    text: str


class Loss(NamedTuple):
    """An anchor lost in part or whole: the anchor at the first line that used it in the base copy,
    the uses that remain in the new copy, and each line of the base copy that used it."""

    anchor: Anchor
    kept: int
    lines: tuple[int, ...]


def _blank(text: str, spans: list[tuple[int, int]]) -> str:
    """``text`` with every span overwritten by spaces, so the columns stay put."""
    chars = list(text)
    for start, end in spans:
        chars[start:end] = " " * (end - start)
    return "".join(chars)


def _fold(span: str) -> str:
    """``span`` with each stretch of whitespace squeezed to a single space."""
    return re.sub(r"\s+", " ", span)


def _targets(line: str) -> list[str]:
    return [match.group(1) for pattern in (TARGET, REFERENCE) for match in pattern.finditer(line)]


def _identifiers(text: str) -> tuple[list[tuple[int, str]], dict[int, list[tuple[int, int]]]]:
    """Each backtick span of ``text`` as (its opening line, its text), plus, for every line, the
    column ranges that spans take up. Fenced lines are read one by one and everything else by
    paragraph, so that a span may wrap."""
    lines = text.splitlines()
    prose = {number for number, _ in prose_lines(text)}
    spans: list[tuple[int, str]] = []
    covered: dict[int, list[tuple[int, int]]] = defaultdict(list)
    for number, line in enumerate(lines, start=1):
        if number not in prose:
            for match in BACKTICK_SPAN.finditer(line):
                spans.append((number, _fold(match.group()[1:-1])))
                covered[number].append(match.span())
    for paragraph in paragraphs([(number, lines[number - 1]) for number in sorted(prose)]):
        joined, starts = _join(paragraph)
        for match in BACKTICK_SPAN.finditer(joined):
            start, end = match.span()
            spans.append((_line_at(starts, start), _fold(match.group()[1:-1])))
            for (offset, number), (_, unquoted) in zip(starts, paragraph):
                low, high = max(start, offset), min(end, offset + len(unquoted))
                if low < high:
                    # Quote markers were cut from the joined lines; add their width back.
                    shift = len(lines[number - 1]) - len(unquoted)
                    covered[number].append((low - offset + shift, high - offset + shift))
    return spans, covered


def uses(text: str, codes: Codes) -> dict[tuple[str, str], list[int]]:
    """For each (kind, anchor) of ``text``, the ascending line numbers of its uses. The old copy
    and the new copy of a rewrite go through this same routine."""
    found: dict[tuple[str, str], list[int]] = defaultdict(list)
    spans, covered = _identifiers(text)
    for number, value in spans:
        found[("identifier", value)].append(number)
    for number, line in enumerate(text.splitlines(), start=1):
        targets = [match.span() for match in TARGET.finditer(line)]
        code_spans = _code_spans(line, codes)
        marker = ORDERED_MARKER.match(line)
        bare = _blank(line, [(start + 1, end) for start, end in targets] + covered[number]
                      + code_spans + ([marker.span()] if marker else []))
        for kind, values in (("code", [line[start:end] for start, end in code_spans]),
                             ("number", NUMBER.findall(bare)),
                             ("link-target", _targets(line))):
            for value in values:
                found[(kind, value)].append(number)
    return {key: sorted(lines) for key, lines in found.items()}


def _order(anchor: Anchor) -> tuple[int, int, str]:
    return anchor.line, KINDS.index(anchor.kind), anchor.text


def anchors(text: str, codes: Codes) -> list[Anchor]:
    """The anchors of ``text``, one entry apiece at its first line, in reading order."""
    return sorted((Anchor(lines[0], kind, value) for (kind, value), lines in
                   uses(text, codes).items()), key=_order)


def missing(before: str, after: str, codes: Codes) -> list[Loss]:
    """Anchors with fewer uses in ``after`` than in ``before``, counted for ``codes``."""
    now = uses(after, codes)
    lost = [Loss(Anchor(lines[0], kind, value), len(now.get((kind, value), [])), tuple(lines))
            for (kind, value), lines in uses(before, codes).items()
            if len(now.get((kind, value), [])) < len(lines)]
    return sorted(lost, key=lambda loss: _order(loss.anchor))


def _times(count: int) -> str:
    return f"{count} time" if count == 1 else f"{count} times"


def _describe(loss: Loss) -> str:
    anchor = loss.anchor
    if not loss.kept:
        return f'{anchor.kind}: "{anchor.text}" is not in the file'
    lines = sorted(set(loss.lines))
    where = f"line {lines[0]}" if len(lines) == 1 else "lines " + ", ".join(map(str, lines))
    return (f'{anchor.kind}: "{anchor.text}" is used {_times(loss.kept)}, {len(loss.lines)} at '
            f"the base ({where})")


def _linked(text: str) -> list[Anchor]:
    """The destinations in ``text`` that really are links. Link syntax inside a backtick span or
    within a fence only illustrates the syntax, and is left out."""
    prose = {number for number, _ in prose_lines(text)}
    _, covered = _identifiers(text)
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        if number in prose:
            bare = _blank(line, covered[number])
            found += [Anchor(number, "link-target", target) for target in _targets(bare)]
    return found


def _exists(path: Path) -> bool:
    try:
        return path.exists()
    except OSError:  # a name the file system rejects cannot be a file it holds
        return False


def unresolved(before: str, after: str, folder: Path) -> list[Anchor]:
    """Relative destinations added by ``after``, outside code, that lead nowhere from ``folder``
    (the folder holding the file) once any ``#fragment`` or ``?query`` is cut off and percent
    escapes are decoded. One that ``before`` already had is skipped, as are URLs, a bare fragment
    and a root-relative destination. A destination is listed once, at its earliest line."""
    held = {target for line in before.splitlines() for target in _targets(line)}
    found = []
    for anchor in _linked(after):
        target = anchor.text
        if target in held or SCHEME.match(target) or target.startswith(("#", "/")):
            continue
        held.add(target)
        path = percent_decode(target.split("#")[0].split("?")[0])
        if path and not _exists(folder / path):
            found.append(anchor)
    return found


# ---------------------------------------------------------------------------------------------
# The command line


def _resolve(root: Path, base: str) -> str:
    """The commit id that ``base`` stands for."""
    if base.startswith("-"):
        raise Unreadable(f"base {base!r}: a base cannot start with -")
    done = _run_git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if done.returncode:
        raise Unreadable(f"base {base!r}: git cannot resolve it to a commit")
    return os.fsdecode(done.stdout).strip()


def _base_text(root: Path, commit: str, path: str) -> str | None:
    """The text of ``path`` in ``commit``, or ``None`` if the commit has no file at that path."""
    kind = _run_git(root, "cat-file", "-t", f"{commit}:{path}")
    if kind.returncode or kind.stdout.strip() != b"blob":
        return None
    return _text_at(root, commit, path, head=False)


def _lost_record(label: str, loss: Loss) -> dict:
    return {"path": label, "line": loss.anchor.line, "kind": loss.anchor.kind,
            "anchor": loss.anchor.text, "rule": "lost-anchor", "message": _describe(loss),
            "before": len(loss.lines), "after": loss.kept,
            "base_lines": sorted(set(loss.lines))}


def _target_record(label: str, anchor: Anchor) -> dict:
    return {"path": label, "line": anchor.line, "kind": anchor.kind, "anchor": anchor.text,
            "rule": "unresolved-target",
            "message": f'{anchor.kind}: "{anchor.text}" names no file'}


def _check(args: argparse.Namespace) -> int:
    root = _repo_root()
    commit = _resolve(root, args.base)
    settings = load(root)
    status = 0
    records: list[dict] = []
    for label in args.files:
        try:
            path = _relative(Path(label), root)
            if path is None:
                raise Unreadable("not inside the repository")
            raw = Path(label).read_bytes()
            try:
                after = raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                raise Unreadable("not UTF-8") from None
            before = _base_text(root, commit, path)
        except OSError as error:
            print(f"writing: cannot read {label}: {error.strerror or error}", file=sys.stderr)
            status = 2
            continue
        except Unreadable as error:
            print(f"writing: cannot read {label}: {error}", file=sys.stderr)
            status = 2
            continue
        lost = missing(before, after, settings.codes) if before is not None else []
        added = unresolved(before or "", after, (root / path).parent)
        records += [_lost_record(label, loss) for loss in lost]
        records += [_target_record(label, anchor) for anchor in added]
        status = max(status, 1 if lost or added else 0)
    if args.format == "json":
        print(json.dumps(records, indent=2))
    else:
        for record in records:
            print(f"{record['path']}:{record['line']}: {record['message']}")
    return status


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="anchors", description=(__doc__ or "").split("\n\n")[0],
        epilog="Exit status: 0 nothing lost, 1 an anchor lost or an added link leading nowhere, "
        "2 a wrong command line, an unusable file, base or configuration, or a crash.")
    parser.add_argument("--base", required=True, metavar="REF",
                        help="the commit that the rewrite began with")
    parser.add_argument("--format", choices=("text", "json"), default="text",
                        help="json: a single list holding one object per finding (default text)")
    parser.add_argument("files", nargs="+", metavar="FILE",
                        help="a Markdown file in the working tree")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the check on ``argv`` (default: the process's arguments) and return the exit status. A
    configuration or a base that fails to resolve is reported on standard error, not raised."""
    args = _parser().parse_args(argv)
    try:
        return _check(args)
    except (Malformed, Unreadable) as error:
        print(f"writing: {error}", file=sys.stderr)
        return 2


def entry(argv: list[str] | None = None) -> int:
    """``main``, except that a crash exits 2 and prints the error on standard error. Left alone,
    an exception would exit 1, which a caller takes for a lost anchor. A reader that closes the
    pipe early changes nothing: the run returns the status it would have."""
    try:
        with closed_pipe_proof():
            return main(argv)
    except Exception as error:  # a defect in the check, not a finding
        print(f"writing: internal error: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(entry())
