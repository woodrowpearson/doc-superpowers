"""Plain data types shared by the corpus, the search engine, the renderers and the server."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class Hit:
    """One search result: a docs chunk or a code chunk, with its doc metadata when a doc."""

    kind: Literal["doc", "code"]
    path: str
    start_line: int
    end_line: int
    snippet: str
    heading_path: tuple[str, ...] = ()
    doc_type: str | None = None
    status: str | None = None
    links: tuple[str, ...] = ()
    more_in_file: int = 0
    legs: tuple[str, ...] = ()


@dataclass(frozen=True)
class DocMeta:
    """What the corpus knows about one doc: front matter, doc-index and path rules, merged."""

    path: str
    title: str
    doc_type: str | None
    status: str | None
    code_refs: tuple[str, ...]
    replaces: str | None
    superseded_by: str | None


@dataclass(frozen=True)
class SearchRequest:
    query: str
    scope: Literal["all", "docs", "code"] = "all"
    limit: int = 10
    doc_type: tuple[str, ...] = ()
    path_prefix: str | None = None
    include_terminal: bool = False


# Why a kind's configured cloud leg did not contribute to a search (cloud-code design section 9): it failed (an
# error, no credentials, a missing extra), overran its deadline or is held back after an overrun, its corpus has
# no usable stamp, or (docs only) the docs index is still building, so the leg was not started.
LocalOnlyReason = Literal["failed", "timeout", "no-stamp", "building"]


@dataclass(frozen=True)
class HeaderInfo:
    """The one-line header above a result list: models, index states, notes.

    `local_only` holds a `(kind, reason)` pair, `docs` before `code`, for each kind whose configured cloud leg
    the search used did not contribute; nothing for a cloud that is off, not run for this request, or that
    answered with no hits. `code_cloud` is the code cloud leg's model, when there is one.
    """

    docs_model: str
    code: str
    cloud: str | None
    notes: tuple[str, ...]
    truncated: bool
    local_only: tuple[tuple[str, LocalOnlyReason], ...] = ()
    code_cloud: str | None = None


@dataclass(frozen=True)
class SearchResponse:
    hits: list[Hit]
    header: HeaderInfo
