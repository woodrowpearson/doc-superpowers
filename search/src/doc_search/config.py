"""docs/search/config.json: the opt-in switch, the defaults, deep merge and validation.

Without the file doc-search is inert (`load_config` returns None). With it, `{}` is a
complete config: the file deep-merges over DEFAULTS (objects merge key by key, arrays and
scalars replace) and every value is checked, so a bad config fails loudly and names its key.
A key the defaults do not have, at any level, is an error too (`unknown key cloud.firestore.databse`):
a misspelled key must not silently keep its default.
"""

from __future__ import annotations

import json
import math
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .transformer import PREFIX, TransformerSpec, UnknownTransformer, parse_model

INERT_LINE = "doc-search: not enabled (no docs/search/config.json)"

CONFIG_REL = "docs/search/config.json"

CONTENT_VALUES = ("code", "config", "docs", "all")

MAX_LIMIT = 50  # `search.default_limit`'s ceiling: the tools clamp a limit to 1-50

MAX_THREADS = 256  # `docs.threads`'s ceiling

# `cloud.timeout_s`: the longest any one call to Vertex or Firestore may take. 20 s because a flat
# (unindexed) nearest-neighbour query over a large collection measured 3 to 14 s. The cloud leg of a
# search is cut off DEADLINE_GRACE_S after that: a credential refresh has no timeout of ours.
DEFAULT_TIMEOUT_S = 20.0
DEADLINE_GRACE_S = 5.0

DEFAULTS: dict[str, Any] = {
    "docs": {
        "include": ["docs/**/*.md", "*.md"],
        "exclude": ["docs/archive/**", "docs/.doc-index.json"],
        "types": [],
        "model": None,
        "threads": None,
    },
    "code": {"enabled": True, "content": ["code"], "model": None},
    "cloud": None,
    "search": {
        "default_limit": 10,
        "terminal_statuses": ["deprecated", "superseded", "archived"],
        "rescan_seconds": 5,
    },
    "required": False,  # true: doc-search is a gate in this repository (it must be ready)
    "requires": None,  # ">=X.Y.Z": the version floor for the plugin and the committed launcher copy
}

_VERSION = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)")

# `requires`'s one form: a floor, `>=` and a version.
_REQUIRES_PREFIX = ">="

# What `cloud` merges over when the config gives an object.
CLOUD_DEFAULTS: dict[str, Any] = {
    "timeout_s": DEFAULT_TIMEOUT_S,
    "vertex": {
        "project": None,
        "location": "us-central1",
        "model": "gemini-embedding-001",
        "dimensions": 768,
    },
    "firestore": {
        "project": None,
        "database": "(default)",
        "collection": "doc_chunks",
        "meta_collection": "corpus_meta",
        "base_ref": None,
    },
}


class ConfigError(ValueError):
    """The config exists but is invalid. The message names the offending key."""


def parse_version(text: str) -> tuple[int, int, int] | None:
    """`X.Y.Z` (three runs of ASCII digits, nothing around them) as a tuple; None for anything else."""
    match = _VERSION.fullmatch(text)
    if match is None:
        return None
    major, minor, patch = (int(part) for part in match.groups())
    return (major, minor, patch)


@dataclass(frozen=True)
class DocsCfg:
    include: tuple[str, ...]
    exclude: tuple[str, ...]
    types: tuple[tuple[str, str], ...]
    model: str | None
    threads: int | None  # encoder threads for a transformer model; None = by core count
    transformer: TransformerSpec | None  # the registry entry `model` names, when it is `transformer:<name>`


@dataclass(frozen=True)
class CodeCfg:
    enabled: bool
    content: tuple[str, ...]
    model: str | None


@dataclass(frozen=True)
class VertexCfg:
    project: str | None
    location: str
    model: str
    dimensions: int


@dataclass(frozen=True)
class FirestoreCfg:
    project: str | None
    database: str
    collection: str
    meta_collection: str
    base_ref: str | None


@dataclass(frozen=True)
class CloudCfg:
    vertex: VertexCfg
    firestore: FirestoreCfg
    timeout_s: float = DEFAULT_TIMEOUT_S  # per call to Vertex or Firestore; none is retried by the library

    @property
    def deadline_s(self) -> float:
        """How long a search waits for the whole cloud leg: one call's timeout, and a grace for what has none."""
        return self.timeout_s + DEADLINE_GRACE_S


@dataclass(frozen=True)
class SearchCfg:
    default_limit: int
    terminal_statuses: tuple[str, ...]
    rescan_seconds: float


@dataclass(frozen=True)
class Config:
    docs: DocsCfg
    code: CodeCfg
    cloud: CloudCfg | None
    search: SearchCfg
    required: bool  # doc-search is a gate in this repository
    requires: tuple[int, int, int] | None  # the version floor, from `">=X.Y.Z"`


def load_config(top: Path, env: Mapping[str, str] = os.environ) -> Config | None:
    """Load `<top>/docs/search/config.json`.

    Returns None when the file is absent (doc-search is inert), the merged and validated
    Config otherwise. Raises ConfigError when the file is unreadable or invalid.

    `DOC_SEARCH_CLOUD=0` turns the cloud leg off. No environment variable turns it on:
    only the config file can ask for it.
    """
    path = Path(top) / CONFIG_REL
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as err:
        raise ConfigError(f"{CONFIG_REL}: cannot read: {err}") from err
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as err:
        raise ConfigError(f"{CONFIG_REL}: malformed JSON: {err}") from err
    if not isinstance(raw, dict):
        raise ConfigError(f"{CONFIG_REL}: the top level must be an object")

    _reject_unknown(raw, DEFAULTS, "")
    merged = _merge(DEFAULTS, raw)
    docs = _docs(_section(merged, "docs"))
    code = _code(_section(merged, "code"))
    search = _search(_section(merged, "search"))
    cloud = _cloud(merged["cloud"], env.get("GOOGLE_CLOUD_PROJECT") or None)
    if env.get("DOC_SEARCH_CLOUD", "").strip() == "0":
        cloud = None
    required = merged["required"]
    if not isinstance(required, bool):
        raise ConfigError("required must be true or false")
    return Config(
        docs=docs, code=code, cloud=cloud, search=search, required=required, requires=_requires(merged["requires"])
    )


def _merge(base: Mapping[str, Any], over: Mapping[str, Any]) -> dict[str, Any]:
    """Objects merge key by key; arrays, scalars and nulls in `over` replace."""
    out = dict(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


# The keys of one `docs.types` rule.
_TYPE_RULE_KEYS = {"glob": None, "type": None}


def _reject_unknown(given: Mapping[str, Any], known: Mapping[str, Any], prefix: str) -> None:
    """Raise ConfigError naming the first key of `given` (dotted from the top) that `known` does not have.

    Recurses into every object both sides have as an object; `cloud` (null in DEFAULTS) is checked
    against CLOUD_DEFAULTS, and each `docs.types` rule against its two keys. A value of the wrong type is
    left for the type checks, which name it.
    """
    for key, value in given.items():
        if key not in known:
            raise ConfigError(f"unknown key {prefix}{key}")
        dotted = f"{prefix}{key}"
        if dotted == "cloud" and isinstance(value, dict):
            _reject_unknown(value, CLOUD_DEFAULTS, "cloud.")
        elif dotted == "docs.types" and isinstance(value, list):
            for i, rule in enumerate(value):
                if isinstance(rule, dict):
                    _reject_unknown(rule, _TYPE_RULE_KEYS, f"docs.types[{i}].")
        elif isinstance(value, dict) and isinstance(known[key], dict):
            _reject_unknown(value, known[key], f"{dotted}.")


def _section(root: Mapping[str, Any], key: str, label: str | None = None) -> Mapping[str, Any]:
    value = root[key]
    if not isinstance(value, dict):
        raise ConfigError(f"{label or key} must be an object")
    return value


def _str(value: Any, key: str, *, nullable: bool = False) -> Any:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{key} must be {'a non-empty string or null' if nullable else 'a non-empty string'}")
    return value


def _str_list(value: Any, key: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise ConfigError(f"{key} must be an array of non-empty strings")
    return tuple(value)


def _int(value: Any, key: str, *, minimum: int, maximum: int | None = None) -> int:
    # bool is an int subclass, and `true` is not a limit
    wrong = isinstance(value, bool) or not isinstance(value, int)
    if wrong or value < minimum or (maximum is not None and value > maximum):
        bounds = f">= {minimum}" if maximum is None else f"from {minimum} to {maximum}"
        raise ConfigError(f"{key} must be an integer {bounds}")
    return value


def _seconds(value: Any, key: str, *, zero: bool = False) -> float:
    """A duration: a finite number above zero (or zero too, with `zero`).

    A bool is an int subclass, and `true` is not a duration.
    """
    message = f"{key} must be a number {'>=' if zero else '>'} 0 (seconds)"
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(message)
    try:
        seconds = float(value)  # an integer too large for a float overflows here
    except OverflowError:
        raise ConfigError(message) from None
    if not math.isfinite(seconds) or seconds < 0 or (seconds == 0 and not zero):
        raise ConfigError(message)
    return seconds


def _docs(section: Mapping[str, Any]) -> DocsCfg:
    types = section["types"]
    if not isinstance(types, list):
        raise ConfigError('docs.types must be an array of {"glob", "type"} objects')
    rules: list[tuple[str, str]] = []
    for i, entry in enumerate(types):
        glob = entry.get("glob") if isinstance(entry, dict) else None
        doc_type = entry.get("type") if isinstance(entry, dict) else None
        if not (isinstance(glob, str) and glob and isinstance(doc_type, str) and doc_type):
            raise ConfigError(f'docs.types[{i}] must be an object with a non-empty "glob" and "type"')
        rules.append((glob, doc_type))
    model = _str(section["model"], "docs.model", nullable=True)
    try:
        transformer = parse_model(model)
    except UnknownTransformer as err:
        raise ConfigError(f"docs.model: {err}") from err
    threads = section["threads"]
    return DocsCfg(
        include=_str_list(section["include"], "docs.include"),
        exclude=_str_list(section["exclude"], "docs.exclude"),
        types=tuple(rules),
        model=model,
        threads=None if threads is None else _int(threads, "docs.threads", minimum=1, maximum=MAX_THREADS),
        transformer=transformer,
    )


def _code(section: Mapping[str, Any]) -> CodeCfg:
    enabled = section["enabled"]
    if not isinstance(enabled, bool):
        raise ConfigError("code.enabled must be true or false")
    model = _str(section["model"], "code.model", nullable=True)
    if model is not None and model.startswith(PREFIX):
        raise ConfigError("code.model cannot be a transformer model (transformer:…): the code index stays static")
    content = _str_list(section["content"], "code.content")
    allowed = ", ".join(CONTENT_VALUES)
    if not content:
        raise ConfigError(f"code.content must not be empty (allowed: {allowed})")
    for value in content:
        if value not in CONTENT_VALUES:
            raise ConfigError(f"code.content has an unknown value {value!r} (allowed: {allowed})")
    return CodeCfg(enabled=enabled, content=content, model=model)


def _search(section: Mapping[str, Any]) -> SearchCfg:
    return SearchCfg(
        default_limit=_int(section["default_limit"], "search.default_limit", minimum=1, maximum=MAX_LIMIT),
        terminal_statuses=_str_list(section["terminal_statuses"], "search.terminal_statuses"),
        rescan_seconds=_seconds(section["rescan_seconds"], "search.rescan_seconds", zero=True),
    )


def _requires(value: Any) -> tuple[int, int, int] | None:
    if value is None:
        return None
    floor = None
    if isinstance(value, str) and value.startswith(_REQUIRES_PREFIX):
        floor = parse_version(value[len(_REQUIRES_PREFIX) :])
    if floor is None:
        raise ConfigError('requires must be ">=X.Y.Z" or null')
    return floor


def _cloud(value: Any, env_project: str | None) -> CloudCfg | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ConfigError("cloud must be an object or null")
    merged = _merge(CLOUD_DEFAULTS, value)
    vertex = _section(merged, "vertex", "cloud.vertex")
    firestore = _section(merged, "firestore", "cloud.firestore")
    return CloudCfg(
        vertex=VertexCfg(
            project=_str(vertex["project"], "cloud.vertex.project", nullable=True) or env_project,
            location=_str(vertex["location"], "cloud.vertex.location"),
            model=_str(vertex["model"], "cloud.vertex.model"),
            dimensions=_int(vertex["dimensions"], "cloud.vertex.dimensions", minimum=1),
        ),
        firestore=FirestoreCfg(
            project=_str(firestore["project"], "cloud.firestore.project", nullable=True) or env_project,
            database=_str(firestore["database"], "cloud.firestore.database"),
            collection=_str(firestore["collection"], "cloud.firestore.collection"),
            meta_collection=_str(firestore["meta_collection"], "cloud.firestore.meta_collection"),
            base_ref=_str(firestore["base_ref"], "cloud.firestore.base_ref", nullable=True),
        ),
        timeout_s=_seconds(merged["timeout_s"], "cloud.timeout_s"),
    )
