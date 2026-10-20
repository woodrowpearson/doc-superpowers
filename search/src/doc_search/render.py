"""Markdown text for a search response (design section 6).

    doc-search · docs: semble <model> [(+cloud: <model>)] · code: semble <version>|off · <n> hits
    note: <header note>
    1. [doc] path:start-end · Heading › Path · type · status (+N more in this file)
       <snippet, at most 6 lines>
       code: a, b, c (+N)
    2. [code] path:start-end
       <snippet>
       documented by: x, y, z (+N)

Everything in a hit comes from repository content, so each field is kept on its own line: a
newline in a path or heading never starts a line of its own. The text is at most `cap` characters,
cut between hits, never inside one; a cut ends with `(truncated at <cap> chars)`.
"""

from __future__ import annotations

from collections.abc import Sequence

from .types import Hit, SearchResponse

SNIPPET_LINES = 6
SNIPPET_LINE_CHARS = 240  # a minified file's single line must not eat the whole response
LINK_LIMIT = 3
DEFAULT_CAP = 8000
SEP = " · "
INDENT = "   "


def render_search(resp: SearchResponse, cap: int = DEFAULT_CAP) -> str:
    """The response as text of at most `cap` characters."""
    blocks = [_block(n, hit) for n, hit in enumerate(resp.hits, start=1)]
    return fit_to_cap(_head(resp), blocks, cap, truncated=resp.header.truncated)


def render_hits(hits: Sequence[Hit]) -> list[str]:
    """One numbered block per hit, as `render_search` writes them (for the other tools' lists)."""
    return [_block(n, hit) for n, hit in enumerate(hits, start=1)]


def fit_to_cap(head: str, blocks: Sequence[str], cap: int = DEFAULT_CAP, *, truncated: bool = False) -> str:
    """`head` then the blocks, one per line break, in at most `cap` characters.

    The cut falls between blocks, never inside one, and ends with `(truncated at <cap> chars)`.
    `truncated` forces the notice (a caller that already dropped blocks).
    """
    whole = "\n".join([head, *blocks])
    if len(whole) <= cap and not truncated:
        return whole

    notice = f"(truncated at {cap} chars)"
    room = cap - len(notice) - 1  # the newline before the notice
    if room < 0:
        return notice[:cap]
    kept = head[:room]
    used = len(kept)
    parts = [kept]
    if kept == head:
        for block in blocks:
            if used + 1 + len(block) > room:
                break
            parts.append(block)
            used += 1 + len(block)
    parts.append(notice)
    return "\n".join(parts)


def _head(resp: SearchResponse) -> str:
    info = resp.header
    docs = f"docs: semble {flat(info.docs_model)}"
    if info.cloud:
        docs += f" (+cloud: {flat(info.cloud)})"
    code = "code: off" if info.code == "off" else f"code: semble {flat(info.code)}"
    lines = [SEP.join(["doc-search", docs, code, f"{len(resp.hits)} hits"])]
    lines += [f"note: {flat(note)}" for note in info.notes]
    return "\n".join(lines)


def _block(number: int, hit: Hit) -> str:
    title = f"{number}. [{hit.kind}] {flat(hit.path)}:{hit.start_line}-{hit.end_line}"
    if hit.heading_path:
        title += SEP + " › ".join(flat(part) for part in hit.heading_path)
    if hit.doc_type:
        title += SEP + flat(hit.doc_type)
    if hit.status:
        title += SEP + flat(hit.status)
    if hit.more_in_file:
        title += f" (+{hit.more_in_file} more in this file)"
    lines = [title, *_snippet(hit.snippet)]
    if hit.links:
        label = "code" if hit.kind == "doc" else "documented by"
        shown = ", ".join(flat(link) for link in hit.links[:LINK_LIMIT])
        extra = len(hit.links) - LINK_LIMIT
        lines.append(f"{INDENT}{label}: {shown}" + (f" (+{extra})" if extra > 0 else ""))
    return "\n".join(lines)


def _snippet(text: str) -> list[str]:
    """At most SNIPPET_LINES lines, without blank lines at either end, indented, no trailing spaces."""
    lines = text.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    out = []
    for line in lines[:SNIPPET_LINES]:
        line = line.rstrip()
        if len(line) > SNIPPET_LINE_CHARS:
            line = line[: SNIPPET_LINE_CHARS - 1] + "…"
        out.append(INDENT + line if line else "")
    return out


def flat(text: object) -> str:
    """`text` on one line: line breaks of any kind become a space."""
    text = str(text)
    return " ".join(text.splitlines()) if text else text
