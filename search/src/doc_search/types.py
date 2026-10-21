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


@dataclass(frozen=True)
class HeaderInfo:
    """The one-line header above a result list: models, index states, notes."""

    docs_model: str
    code: str
    cloud: str | None
    notes: tuple[str, ...]
    truncated: bool


@dataclass(frozen=True)
class SearchResponse:
    hits: list[Hit]
    header: HeaderInfo
