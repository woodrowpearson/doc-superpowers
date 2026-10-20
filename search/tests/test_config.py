"""Config loading: the inert contract, the section 9 defaults, deep merge, validation."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from doc_search.config import (
    INERT_LINE,
    CloudCfg,
    Config,
    ConfigError,
    FirestoreCfg,
    VertexCfg,
    load_config,
)


def write_config(top: Path, value: object) -> None:
    """Write `value` as docs/search/config.json (str is written verbatim)."""
    path = top / "docs" / "search" / "config.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")


def load(top: Path, value: object, env: dict[str, str] | None = None) -> Config:
    write_config(top, value)
    cfg = load_config(top, env or {})
    assert cfg is not None
    return cfg


def test_inert_line_is_exact() -> None:
    assert INERT_LINE == "doc-search: not enabled (no docs/search/config.json)"


def test_absent_config_is_inert(tmp_path: Path) -> None:
    assert load_config(tmp_path, {}) is None


def test_empty_object_gets_defaults(tmp_path: Path) -> None:
    cfg = load(tmp_path, {})
    assert cfg.docs.include == ("docs/**/*.md", "*.md")
    assert cfg.docs.exclude == ("docs/archive/**", "docs/.doc-index.json")
    assert cfg.docs.types == ()
    assert cfg.docs.model is None
    assert cfg.code.enabled is True
    assert cfg.code.content == ("code",)
    assert cfg.code.model is None
    assert cfg.cloud is None
    assert cfg.search.default_limit == 10
    assert cfg.search.terminal_statuses == ("deprecated", "superseded", "archived")
    assert cfg.search.rescan_seconds == 5


def test_arrays_replace_objects_merge(tmp_path: Path) -> None:
    cfg = load(
        tmp_path,
        {
            "docs": {
                "include": ["specs/**/*.md"],
                "types": [{"glob": "specs/**", "type": "design-spec"}],
            },
            "search": {"default_limit": 20},
            "code": {"content": ["code", "config"]},
        },
    )
    # arrays replace: no trace of the default include globs
    assert cfg.docs.include == ("specs/**/*.md",)
    assert cfg.docs.types == (("specs/**", "design-spec"),)
    assert cfg.code.content == ("code", "config")
    # objects merge: sibling keys keep their defaults
    assert cfg.docs.exclude == ("docs/archive/**", "docs/.doc-index.json")
    assert cfg.docs.model is None
    assert cfg.code.enabled is True
    assert cfg.search.default_limit == 20
    assert cfg.search.terminal_statuses == ("deprecated", "superseded", "archived")
    assert cfg.search.rescan_seconds == 5


def test_scalars_replace(tmp_path: Path) -> None:
    cfg = load(
        tmp_path,
        {"docs": {"model": "some/model"}, "code": {"enabled": False}, "search": {"rescan_seconds": 30}},
    )
    assert cfg.docs.model == "some/model"
    assert cfg.code.enabled is False
    assert cfg.search.rescan_seconds == 30


def test_cloud_defaults_fill(tmp_path: Path) -> None:
    cfg = load(tmp_path, {"cloud": {"vertex": {"project": "p"}, "firestore": {}}})
    assert cfg.cloud == CloudCfg(
        vertex=VertexCfg(project="p", location="us-central1", model="gemini-embedding-001", dimensions=768),
        firestore=FirestoreCfg(
            project=None,
            database="(default)",
            collection="doc_chunks",
            meta_collection="corpus_meta",
            base_ref=None,
        ),
    )


def test_cloud_object_may_omit_both_sections(tmp_path: Path) -> None:
    cfg = load(tmp_path, {"cloud": {}}, {"GOOGLE_CLOUD_PROJECT": "envp"})
    assert cfg.cloud is not None
    assert cfg.cloud.vertex.location == "us-central1"
    assert cfg.cloud.firestore.database == "(default)"


def test_cloud_null_is_off(tmp_path: Path) -> None:
    assert load(tmp_path, {"cloud": None}).cloud is None


def test_cloud_disabled_by_env(tmp_path: Path) -> None:
    value = {"cloud": {"vertex": {"project": "p"}, "firestore": {"project": "p"}}}
    assert load(tmp_path, value).cloud is not None
    assert load(tmp_path, value, {"DOC_SEARCH_CLOUD": "0"}).cloud is None


def test_env_cannot_enable_cloud(tmp_path: Path) -> None:
    assert load(tmp_path, {}, {"DOC_SEARCH_CLOUD": "1"}).cloud is None
    assert load(tmp_path, {"cloud": None}, {"DOC_SEARCH_CLOUD": "1", "GOOGLE_CLOUD_PROJECT": "p"}).cloud is None


def test_google_cloud_project_fallback(tmp_path: Path) -> None:
    value = {"cloud": {"vertex": {"project": None}, "firestore": {"project": None}}}
    cfg = load(tmp_path, value, {"GOOGLE_CLOUD_PROJECT": "envp"})
    assert cfg.cloud is not None
    assert cfg.cloud.vertex.project == "envp"
    assert cfg.cloud.firestore.project == "envp"
    # an explicit project is never overridden by the environment
    cfg = load(
        tmp_path,
        {"cloud": {"vertex": {"project": "explicit"}, "firestore": {"project": None}}},
        {"GOOGLE_CLOUD_PROJECT": "envp"},
    )
    assert cfg.cloud is not None
    assert cfg.cloud.vertex.project == "explicit"
    assert cfg.cloud.firestore.project == "envp"
    # no environment variable and no config project: stays None (the cloud leg reports it)
    cfg = load(tmp_path, {"cloud": {}}, {})
    assert cfg.cloud is not None
    assert cfg.cloud.vertex.project is None


def test_config_is_frozen(tmp_path: Path) -> None:
    cfg = load(tmp_path, {})
    with pytest.raises(AttributeError):
        cfg.search = cfg.search  # type: ignore[misc]


@pytest.mark.parametrize(
    ("value", "key"),
    [
        ({"code": {"content": ["code", "bogus"]}}, "code.content"),
        ({"code": {"content": "code"}}, "code.content"),
        ({"code": {"content": []}}, "code.content"),
        ({"code": {"enabled": "yes"}}, "code.enabled"),
        ({"search": {"default_limit": "ten"}}, "search.default_limit"),
        ({"search": {"default_limit": 2.5}}, "search.default_limit"),
        ({"search": {"default_limit": True}}, "search.default_limit"),
        ({"search": {"default_limit": 0}}, "search.default_limit"),
        ({"search": {"rescan_seconds": "5"}}, "search.rescan_seconds"),
        ({"search": {"terminal_statuses": "archived"}}, "search.terminal_statuses"),
        ({"cloud": "on"}, "cloud"),
        ({"cloud": ["vertex"]}, "cloud"),
        ({"cloud": {"vertex": {"dimensions": "768"}}}, "cloud.vertex.dimensions"),
        ({"cloud": {"firestore": "(default)"}}, "cloud.firestore"),
        ({"docs": {"types": [{"glob": "x/**"}]}}, "docs.types"),
        ({"docs": {"types": ["x/**"]}}, "docs.types"),
        ({"docs": {"types": [{"glob": "x/**", "type": 7}]}}, "docs.types"),
        ({"docs": {"include": "docs/**/*.md"}}, "docs.include"),
        ({"docs": "docs"}, "docs"),
        ({"docs": {"model": 3}}, "docs.model"),
        ([], "top level"),
        ("[1, 2]", "top level"),
        ("{not json", "malformed JSON"),
    ],
)
def test_invalid_values_raise(tmp_path: Path, value: object, key: str) -> None:
    write_config(tmp_path, value)
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert key in str(err.value)


def test_unreadable_config_raises(tmp_path: Path) -> None:
    (tmp_path / "docs" / "search" / "config.json").mkdir(parents=True)
    with pytest.raises(ConfigError):
        load_config(tmp_path, {})
