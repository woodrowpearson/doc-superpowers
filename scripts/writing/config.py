"""The writing configuration: the defaults, a project's file merged over them, and the register
each Markdown file is written in.

``load`` reads ``defaults.json`` beside this module, then the project's optional
``docs/writing/config.json``, from the working tree or from a git revision, and returns one
``Config``. JSON has no comments, so what the defaults file means is written down here.

The project's file has six top-level keys, all optional, and any other key is an error::

    enabled          true or false: the switch a caller reads
    registers        doc_types (a doc-index type to a register) and paths (a list of rules)
    limits           per register: sentence, item and item_sentences, each a whole number or null
    codes            patterns (regular expressions), allowed (words that are not codes) and
                     gloss_chars (characters that let a bracket explain what stands before it)
    skip_prefixes    line prefixes the lint leaves alone, such as a commit trailer
    skip_blocks      headers that open a block of list items the lint leaves alone, such as the
                     ``Implementation:`` block a tool writes

A register is ``terse`` or ``full``. Each has its own limits; ``full`` sets no limit on a list
item. A file with no register is not linted.

How the project's file combines with the defaults:

- An object merges key by key. A scalar, including ``null``, replaces the default: ``{"limits":
  {"full": {"sentence": 30}}}`` leaves the terse limits and the full item limit alone, and
  ``{"limits": {"terse": {"item": null}}}`` removes the terse item limit.
- A list adds to the default list, so a project states only what it adds and never has to repeat
  a default. Duplicates are dropped. The one list where order matters is ``registers.paths``:
  the project's rules come first, so a rule of its own wins over a default one.

How a file gets its register (``register_for``):

1. A file that is not Markdown (its name does not end in ``.md``) gets none, and neither does
   one under ``docs/archive/``, whatever its doc-index type says. Archived docs are never linted.
2. Its doc-index entry's ``doc_type``, when the entry has one: the register ``registers.doc_types``
   names, and ``full`` for a type it does not name.
3. The first path rule that matches: the path starts with the rule's ``prefix`` and ends with its
   ``suffix`` (an empty one matches anything). The suffix is tested against ``/`` plus the path,
   so ``/AGENTS.md`` names that file in any folder, the repository root included, and no file
   whose name merely ends in ``AGENTS.md``. A rule whose register is ``null`` stops the search:
   the file is not linted.
4. Otherwise none.

The work ledger adds to this when ``docs/ledger/config.json`` exists. Its registry
(``docs/ledger/ledgers.json``) names the ledgers, and each ledger's key is a code (``orbit-14``),
so one more code pattern is built from the names. Its ``items.globs`` say where the item files
live; the folder each names (the directories before its first wildcard) becomes a terse path rule,
placed after the project's own rules and before the defaults. A glob with a wildcard in a
directory name, such as ``docs/w*rk/*.md``, names no one folder and adds no rule.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any, NamedTuple

from markdown import Codes

DEFAULTS = Path(__file__).with_name("defaults.json")
CONFIG = "docs/writing/config.json"
INDEX = "docs/.doc-index.json"
LEDGER_CONFIG = "docs/ledger/config.json"
LEDGER_REGISTRY = "docs/ledger/ledgers.json"
ARCHIVE = "docs/archive/"

REGISTERS = ("terse", "full")
RECORD_TYPES = frozenset({"plan", "issue", "audit", "design-spec"})
TOP_KEYS = ("enabled", "registers", "limits", "codes", "skip_prefixes", "skip_blocks")
LIMIT_KEYS = ("sentence", "item", "item_sentences")
GLOB_CHARS = re.compile(r"[*?{}\\]")

_ABSENT = object()  # a file that is not there, as opposed to a JSON ``null``


class Limits(NamedTuple):
    """What a register allows: words in a sentence, words in a list item, sentences in a list
    item. ``None`` means no limit."""

    sentence: int
    item: int | None
    item_sentences: int | None


class PathRule(NamedTuple):
    """A path rule: a path that starts with ``prefix`` and ends with ``suffix`` is in
    ``register`` (``None``: not linted). The suffix is tested against ``/`` plus the path."""

    prefix: str
    suffix: str
    register: str | None


class Config(NamedTuple):
    """The merged configuration. ``doc_types`` maps a doc-index type to its register and
    ``paths`` is the ordered rule list, first match wins."""

    enabled: bool
    codes: Codes
    limits: dict[str, Limits]
    skip_prefixes: tuple[str, ...]
    skip_blocks: tuple[str, ...]
    doc_types: dict[str, str]
    paths: tuple[PathRule, ...]


class Malformed(ValueError):
    """A file the lint reads cannot be used. The message names the file, and the key when one is
    at fault: a caller prints it and exits with status 2."""


# ---------------------------------------------------------------------------------------------
# Reading files


def _label(rel: str, rev: str | None) -> str:
    return rel if rev is None else f"{rel} at {rev}"


def _read(root: Path, rel: str, rev: str | None) -> bytes | None:
    """The bytes of ``rel`` in the working tree (``rev`` is ``None``) or in revision ``rev``;
    ``None`` when the file is not there."""
    label = _label(rel, rev)
    if rev is None:
        try:
            return (root / rel).read_bytes()
        except (FileNotFoundError, NotADirectoryError):
            return None
        except OSError as exc:
            raise Malformed(f"{label}: cannot read it ({exc.strerror or exc})") from None
    if rev.startswith("-"):
        raise Malformed(f"{label}: git cannot resolve {rev}")
    try:
        tree = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{tree}}"],
                              cwd=str(root), capture_output=True)
        if tree.returncode != 0:
            raise Malformed(f"{label}: git cannot resolve {rev} in {root}")
        blob = subprocess.run(["git", "cat-file", "blob", f"{rev}:{rel}"],
                              cwd=str(root), capture_output=True)
    except OSError as exc:
        raise Malformed(f"{label}: cannot run git ({exc.strerror or exc})") from None
    return blob.stdout if blob.returncode == 0 else None


def _parse(raw: bytes, label: str) -> Any:
    """Decode UTF-8 (a byte-order mark is not part of the text) and parse JSON."""
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise Malformed(f"{label}: not UTF-8") from None
    try:
        return json.loads(text)
    except (ValueError, RecursionError) as exc:
        raise Malformed(f"{label}: not valid JSON ({exc})") from None


def _json(root: Path, rel: str, rev: str | None) -> Any:
    """The parsed JSON of ``rel``, or ``_ABSENT`` when the file is not there."""
    raw = _read(root, rel, rev)
    return _ABSENT if raw is None else _parse(raw, _label(rel, rev))


def _object(value: Any, label: str, key: str) -> dict:
    if not isinstance(value, dict):
        raise _bad(label, key, "must be an object")
    return value


def _bad(label: str, key: str, problem: str) -> Malformed:
    return Malformed(f'{label}: key "{key}": {problem}')


# ---------------------------------------------------------------------------------------------
# Checking one configuration file


def _only(obj: dict, known: tuple[str, ...], label: str, prefix: str) -> None:
    for name in obj:
        if name not in known:
            raise _bad(label, prefix + name, "unknown key; the known keys are "
                       + ", ".join(known))


def _count(value: Any, label: str, key: str, nullable: bool) -> int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise _bad(label, key, "must be a whole number of at least 1"
                   + (" or null" if nullable else ""))
    return value


def _register(value: Any, label: str, key: str, nullable: bool) -> str | None:
    if value is None and nullable:
        return None
    if value not in REGISTERS:
        raise _bad(label, key, "must be " + " or ".join(f'"{name}"' for name in REGISTERS)
                   + (" or null" if nullable else ""))
    return value


def _strings(value: Any, label: str, key: str, length: int | None = None) -> list[str]:
    """A list of non-empty strings, each of ``length`` characters when that is given."""
    if not isinstance(value, list):
        raise _bad(label, key, "must be a list")
    for number, item in enumerate(value):
        if not isinstance(item, str) or not item or (length is not None and len(item) != length):
            raise _bad(label, f"{key}[{number}]", "must be a non-empty string"
                       if length is None else f"must be a string of {length} character")
    return list(value)


def _patterns(value: Any, label: str, key: str) -> list[str]:
    patterns = _strings(value, label, key)
    for number, pattern in enumerate(patterns):
        try:
            re.compile(pattern)
        except (re.error, OverflowError, RecursionError) as exc:
            raise _bad(label, f"{key}[{number}]", f"does not compile ({exc})") from None
    return patterns


def _rules(value: Any, label: str, key: str) -> list[PathRule]:
    if not isinstance(value, list):
        raise _bad(label, key, "must be a list")
    rules = []
    for number, rule in enumerate(value):
        where = f"{key}[{number}]"
        rule = _object(rule, label, where)
        _only(rule, ("prefix", "suffix", "register"), label, where + ".")
        if "register" not in rule:
            raise _bad(label, where + ".register", 'is required: "terse", "full" or null')
        ends = []
        for name in ("prefix", "suffix"):
            if not isinstance(rule.get(name, ""), str):
                raise _bad(label, f"{where}.{name}", "must be a string")
            ends.append(rule.get(name, ""))
        rules.append(PathRule(ends[0], ends[1],
                              _register(rule["register"], label, where + ".register", True)))
    return rules


def _layer(raw: Any, label: str) -> dict:
    """Check one file's content and return what it sets, in a plain form: any of ``enabled``,
    ``doc_types``, ``paths``, ``limits``, ``patterns``, ``allowed``, ``gloss_chars``,
    ``skip_prefixes`` and ``skip_blocks``."""
    if not isinstance(raw, dict):
        raise Malformed(f"{label}: the top level must be an object")
    _only(raw, TOP_KEYS, label, "")
    layer: dict[str, Any] = {}
    if "enabled" in raw:
        if not isinstance(raw["enabled"], bool):
            raise _bad(label, "enabled", "must be true or false")
        layer["enabled"] = raw["enabled"]
    if "registers" in raw:
        registers = _object(raw["registers"], label, "registers")
        _only(registers, ("doc_types", "paths"), label, "registers.")
        if "doc_types" in registers:
            types = _object(registers["doc_types"], label, "registers.doc_types")
            layer["doc_types"] = {
                name: _register(register, label, f"registers.doc_types.{name}", False)
                for name, register in types.items()}
        if "paths" in registers:
            layer["paths"] = _rules(registers["paths"], label, "registers.paths")
    if "limits" in raw:
        limits = _object(raw["limits"], label, "limits")
        _only(limits, REGISTERS, label, "limits.")
        layer["limits"] = {}
        for register, values in limits.items():
            where = f"limits.{register}"
            values = _object(values, label, where)
            _only(values, LIMIT_KEYS, label, where + ".")
            layer["limits"][register] = {
                name: _count(value, label, f"{where}.{name}", name != "sentence")
                for name, value in values.items()}
    if "codes" in raw:
        codes = _object(raw["codes"], label, "codes")
        _only(codes, ("patterns", "allowed", "gloss_chars"), label, "codes.")
        if "patterns" in codes:
            layer["patterns"] = _patterns(codes["patterns"], label, "codes.patterns")
        if "allowed" in codes:
            layer["allowed"] = _strings(codes["allowed"], label, "codes.allowed")
        if "gloss_chars" in codes:
            layer["gloss_chars"] = _strings(codes["gloss_chars"], label, "codes.gloss_chars", 1)
    if "skip_prefixes" in raw:
        layer["skip_prefixes"] = _strings(raw["skip_prefixes"], label, "skip_prefixes")
    if "skip_blocks" in raw:
        layer["skip_blocks"] = _strings(raw["skip_blocks"], label, "skip_blocks")
    return layer


# ---------------------------------------------------------------------------------------------
# What the work ledger adds


def _ledger_pattern(root: Path, rev: str | None) -> list[str]:
    """One pattern for the ledger keys the registry names, or none."""
    registry = _json(root, LEDGER_REGISTRY, rev)
    if registry is _ABSENT:
        return []
    label = _label(LEDGER_REGISTRY, rev)
    if not isinstance(registry, dict):
        raise Malformed(f"{label}: the top level must be an object")
    entries = registry.get("ledgers", [])
    if not isinstance(entries, list):
        raise _bad(label, "ledgers", "must be a list")
    names: list[str] = []
    for number, entry in enumerate(entries):
        entry = _object(entry, label, f"ledgers[{number}]")
        name = entry.get("id")
        if not isinstance(name, str) or not name:
            raise _bad(label, f"ledgers[{number}].id", "must be a non-empty string")
        if name not in names:
            names.append(name)
    if not names:
        return []
    return ["(?<![A-Za-z0-9_])(?:" + "|".join(re.escape(name) for name in names)
            + ")-[1-9][0-9]*(?![A-Za-z0-9_])"]


def _glob_rule(glob: str) -> PathRule | None:
    """The terse path rule for the folder an ``items.globs`` entry names, or ``None`` when it
    names no one folder: a glob that starts with a wildcard, or has one in a directory name."""
    parts = glob.split("/")
    if "" in parts:
        return None
    if not GLOB_CHARS.search(glob):
        return PathRule(glob, "", "terse")  # no wildcard: the glob names one file
    folder = []
    for part in parts[:-1]:
        if part == "**":
            break
        if GLOB_CHARS.search(part):
            return None
        folder.append(part)
    return PathRule("/".join(folder) + "/", "", "terse") if folder else None


def _item_rules(settings: dict) -> list[PathRule]:
    items = settings.get("items")
    globs = items.get("globs") if isinstance(items, dict) else None
    rules: list[PathRule] = []
    for glob in globs if isinstance(globs, list) else []:
        rule = _glob_rule(glob) if isinstance(glob, str) else None
        if rule is not None and rule not in rules:
            rules.append(rule)
    return rules


def _ledger(root: Path, rev: str | None) -> tuple[list[str], list[PathRule]]:
    """The code patterns and path rules the work ledger adds, when it is switched on."""
    settings = _json(root, LEDGER_CONFIG, rev)
    if settings is _ABSENT:
        return [], []
    if not isinstance(settings, dict):
        raise Malformed(f"{_label(LEDGER_CONFIG, rev)}: the top level must be an object")
    return _ledger_pattern(root, rev), _item_rules(settings)


# ---------------------------------------------------------------------------------------------
# Loading


def _extend(first: list, then: list) -> list:
    return first + [item for item in then if item not in first]


def _defaults() -> dict:
    try:
        raw = DEFAULTS.read_bytes()
    except OSError as exc:
        raise Malformed(f"{DEFAULTS.name}: cannot read it ({exc.strerror or exc})") from None
    return _layer(_parse(raw, DEFAULTS.name), DEFAULTS.name)


def load(root: Path, rev: str | None = None) -> Config:
    """The configuration for the repository at ``root``: the defaults, the work ledger's
    additions and the project's ``docs/writing/config.json``, read from the working tree or, with
    ``rev``, from that git revision. A file that exists but cannot be used raises ``Malformed``."""
    root = Path(root)
    base = _defaults()
    raw = _json(root, CONFIG, rev)
    mine = {} if raw is _ABSENT else _layer(raw, _label(CONFIG, rev))
    ledger_patterns, ledger_rules = _ledger(root, rev)

    limits = {}
    for register in REGISTERS:
        values = {**base.get("limits", {}).get(register, {}),
                  **mine.get("limits", {}).get(register, {})}
        if "sentence" not in values:
            raise _bad(DEFAULTS.name, f"limits.{register}.sentence", "is required")
        limits[register] = Limits(values["sentence"], values.get("item"),
                                  values.get("item_sentences"))
    patterns = _extend(_extend(base.get("patterns", []), ledger_patterns),
                       mine.get("patterns", []))
    return Config(
        enabled=mine.get("enabled", base.get("enabled", True)),
        codes=Codes(
            patterns=tuple(re.compile(pattern) for pattern in patterns),
            allowed=frozenset(base.get("allowed", [])) | frozenset(mine.get("allowed", [])),
            gloss_chars=(frozenset(base.get("gloss_chars", []))
                         | frozenset(mine.get("gloss_chars", [])))),
        limits=limits,
        skip_prefixes=tuple(_extend(base.get("skip_prefixes", []), mine.get("skip_prefixes", []))),
        skip_blocks=tuple(_extend(base.get("skip_blocks", []), mine.get("skip_blocks", []))),
        doc_types={**base.get("doc_types", {}), **mine.get("doc_types", {})},
        paths=tuple(_extend(_extend(mine.get("paths", []), ledger_rules), base.get("paths", []))))


def read_index(root: Path, rev: str | None) -> dict | None:
    """The ``docs`` object of ``docs/.doc-index.json`` (each doc's path to its entry), read from
    the working tree or from ``rev``; ``None`` when there is no index or it has no ``docs``."""
    data = _json(Path(root), INDEX, rev)
    if data is _ABSENT:
        return None
    label = _label(INDEX, rev)
    if not isinstance(data, dict):
        raise Malformed(f"{label}: the top level must be an object")
    docs = data.get("docs")
    if docs is None:
        return None
    return _object(docs, label, "docs")


# ---------------------------------------------------------------------------------------------
# Registers


def _clean(path: str) -> str:
    while path.startswith("./"):
        path = path[2:]
    return path


def _doc_type(path: str, index: dict | None) -> str | None:
    entry = index.get(path) if index else None
    doc_type = entry.get("doc_type") if isinstance(entry, dict) else None
    return doc_type if isinstance(doc_type, str) and doc_type else None


def register_for(path: str, config: Config, index: dict | None) -> str | None:
    """The register of the Markdown file at ``path`` (relative to the top level, with ``/``):
    ``"terse"`` or ``"full"``, or ``None`` when it is not linted. ``index`` is ``read_index``'s
    answer, or ``None``. A file that is not Markdown, or is under ``docs/archive/``, is never
    linted. For any other the doc-index type decides first, then the path rules."""
    path = _clean(path)
    if not path.lower().endswith(".md") or path.startswith(ARCHIVE):
        return None
    doc_type = _doc_type(path, index)
    if doc_type is not None:
        return config.doc_types.get(doc_type, "full")
    for rule in config.paths:
        if path.startswith(rule.prefix) and ("/" + path).endswith(rule.suffix):
            return rule.register
    return None


def is_record(path: str, index: dict | None) -> bool:
    """Whether the file is a record of a moment, as the freshness check sees it: a plan, an
    issue, an audit or a design spec, or anything under ``docs/archive/``."""
    path = _clean(path)
    return path.startswith(ARCHIVE) or _doc_type(path, index) in RECORD_TYPES
