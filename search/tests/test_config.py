"""Config loading: the inert contract, the section 9 defaults, deep merge, validation."""

from __future__ import annotations

import json
import subprocess
import sys
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
    parse_version,
)
from doc_search.transformer import REGISTRY, spec_for_path


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
    assert cfg.docs.threads is None
    assert cfg.docs.transformer is None
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


def test_docs_model_transformer(tmp_path: Path) -> None:
    cfg = load(tmp_path, {"docs": {"model": "transformer:gte-modernbert-base"}})
    assert cfg.docs.model == "transformer:gte-modernbert-base"
    assert cfg.docs.transformer is not None
    assert cfg.docs.transformer.name == "gte-modernbert-base"
    assert cfg.docs.transformer.dim == 768
    assert cfg.docs.transformer.max_tokens == 1024
    assert cfg.docs.transformer.onnx_file == "onnx/model_int8.onnx"
    assert cfg.docs.transformer.model_path == "transformer:gte-modernbert-base@e7f32e3c00f9"


def test_docs_model_unknown_transformer(tmp_path: Path) -> None:
    write_config(tmp_path, {"docs": {"model": "transformer:nope"}})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "docs.model" in str(err.value) and "gte-modernbert-base" in str(err.value)


@pytest.mark.parametrize("model", ["minishlab/potion-base-8M", None])
def test_docs_model_static_has_no_transformer(tmp_path: Path, model: str | None) -> None:
    cfg = load(tmp_path, {"docs": {"model": model}})
    assert cfg.docs.model == model
    assert cfg.docs.transformer is None


def test_code_model_refuses_transformer(tmp_path: Path) -> None:
    write_config(tmp_path, {"code": {"model": "transformer:gte-modernbert-base"}})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "code.model" in str(err.value)


def test_spec_for_path_round_trips_the_registry() -> None:
    for spec in REGISTRY.values():
        assert spec_for_path(spec.model_path) is spec
    with pytest.raises(ValueError, match="not a current transformer model path"):
        spec_for_path("transformer:gte-modernbert-base@000000000000")  # a retired revision


def test_config_does_not_import_onnxruntime() -> None:
    """config.py imports the registry: the encoder's heavy imports must stay out of that module's top level."""
    code = "import sys, doc_search.config; sys.exit('onnxruntime' in sys.modules)"
    assert subprocess.run([sys.executable, "-c", code], check=False).returncode == 0


def test_docs_threads(tmp_path: Path) -> None:
    assert load(tmp_path, {}).docs.threads is None
    assert load(tmp_path, {"docs": {"threads": 4}}).docs.threads == 4
    assert load(tmp_path, {"docs": {"threads": 256}}).docs.threads == 256
    for bad in (0, 257, True, "4", 2.5):
        write_config(tmp_path, {"docs": {"threads": bad}})
        with pytest.raises(ConfigError) as err:
            load_config(tmp_path, {})
        assert "docs.threads" in str(err.value)


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


def test_cloud_timeout_defaults_to_twenty_seconds_and_is_a_lever(tmp_path: Path) -> None:
    assert load(tmp_path, {"cloud": {}}).cloud.timeout_s == 20.0
    assert load(tmp_path, {"cloud": {"timeout_s": 45}}).cloud.timeout_s == 45.0
    assert load(tmp_path, {"cloud": {"timeout_s": 2.5}}).cloud.timeout_s == 2.5
    # the other cloud keys are untouched by it
    cfg = load(tmp_path, {"cloud": {"timeout_s": 7, "vertex": {"project": "p"}}}).cloud
    assert cfg.timeout_s == 7.0 and cfg.vertex.project == "p" and cfg.firestore.collection == "doc_chunks"
    # the read leg's wall-clock deadline is the timeout and five seconds more
    assert cfg.deadline_s == 12.0
    assert CloudCfg(vertex=cfg.vertex, firestore=cfg.firestore).timeout_s == 20.0, "a CloudCfg built by hand too"


@pytest.mark.parametrize("bad", [0, -1, -0.5, float("nan"), float("inf"), "x", "20", True, None, [20], {"s": 20}])
def test_cloud_timeout_must_be_a_positive_finite_number(tmp_path: Path, bad: object) -> None:
    write_config(tmp_path, {"cloud": {"timeout_s": bad}})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "cloud.timeout_s" in str(err.value)


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


@pytest.mark.parametrize(
    ("value", "dotted"),
    [
        ({"serach": {}}, "serach"),
        ({"docs": {"inclde": ["docs/**/*.md"]}}, "docs.inclde"),
        ({"docs": {"types": [{"glob": "x/**", "type": "spec", "tpye": "adr"}]}}, "docs.types[0].tpye"),
        ({"code": {"enable": False}}, "code.enable"),
        ({"search": {"default_limt": 5}}, "search.default_limt"),
        ({"cloud": {"timeout": 5}}, "cloud.timeout"),
        ({"cloud": {"vertx": {}}}, "cloud.vertx"),
        ({"cloud": {"vertex": {"dimension": 768}}}, "cloud.vertex.dimension"),
        ({"cloud": {"firestore": {"databse": "corpus"}}}, "cloud.firestore.databse"),
    ],
)
def test_unknown_keys_are_rejected_at_every_level(tmp_path: Path, value: object, dotted: str) -> None:
    """A misspelled key is an error naming it, never a silent default (a typo'd database would write to `(default)`)."""
    write_config(tmp_path, value)
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert str(err.value) == f"unknown key {dotted}"


def test_unknown_cloud_keys_are_rejected_even_when_the_env_turns_cloud_off(tmp_path: Path) -> None:
    write_config(tmp_path, {"cloud": {"firestore": {"databse": "corpus"}}})
    with pytest.raises(ConfigError, match=r"^unknown key cloud\.firestore\.databse$"):
        load_config(tmp_path, {"DOC_SEARCH_CLOUD": "0"})


def test_every_known_key_is_accepted(tmp_path: Path) -> None:
    """The full §9 key set, every key given: none is unknown."""
    full = {
        "docs": {
            "include": ["docs/**/*.md"],
            "exclude": [],
            "types": [{"glob": "a/**", "type": "spec"}],
            "model": None,
            "threads": 4,
        },
        "code": {"enabled": True, "content": ["code"], "model": None},
        "cloud": {
            "timeout_s": 20,
            "vertex": {"project": "p", "location": "us-central1", "model": "gemini-embedding-001", "dimensions": 768},
            "firestore": {
                "project": "p",
                "database": "corpus",
                "collection": "doc_chunks",
                "meta_collection": "corpus_meta",
                "base_ref": "origin/main",
            },
        },
        "search": {"default_limit": 50, "terminal_statuses": ["archived"], "rescan_seconds": 0},
        "required": True,
        "requires": ">=3.10.0",
    }
    cfg = load(tmp_path, full)
    assert cfg.cloud is not None and cfg.cloud.firestore.database == "corpus"
    assert cfg.search.default_limit == 50 and cfg.search.rescan_seconds == 0
    assert cfg.docs.threads == 4
    assert cfg.required is True and cfg.requires == (3, 10, 0)


@pytest.mark.parametrize("bad", [51, 1000])
def test_default_limit_is_capped_at_fifty(tmp_path: Path, bad: int) -> None:
    write_config(tmp_path, {"search": {"default_limit": bad}})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "search.default_limit" in str(err.value) and "50" in str(err.value)


@pytest.mark.parametrize(
    "bad",
    [-1, -0.5, float("nan"), float("inf"), float("-inf"), pytest.param(10**400, id="huge-int"), "5", True, None, [5]],
)
def test_rescan_seconds_must_be_finite_and_not_negative(tmp_path: Path, bad: object) -> None:
    # json.dumps writes NaN / Infinity, and json.loads reads them back: a config file can hold them
    write_config(tmp_path, {"search": {"rescan_seconds": bad}})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "search.rescan_seconds" in str(err.value)


@pytest.mark.parametrize("good", [0, 0.5, 5, 30])
def test_rescan_seconds_allows_zero(tmp_path: Path, good: float) -> None:
    assert load(tmp_path, {"search": {"rescan_seconds": good}}).search.rescan_seconds == good


def test_required_defaults_false_and_requires_none(tmp_path: Path) -> None:
    cfg = load(tmp_path, {})
    assert cfg.required is False
    assert cfg.requires is None


def test_required_and_requires_parse(tmp_path: Path) -> None:
    cfg = load(tmp_path, {"required": True, "requires": ">=3.10.0"})
    assert (cfg.required, cfg.requires) == (True, (3, 10, 0))


@pytest.mark.parametrize("bad", ["3.10.0", ">3.10.0", ">=3.10", ">=v3.10.0", 5])
def test_requires_rejects_other_forms(tmp_path: Path, bad: object) -> None:
    write_config(tmp_path, {"requires": bad})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert 'requires must be ">=X.Y.Z"' in str(err.value)


def test_required_must_be_bool(tmp_path: Path) -> None:
    write_config(tmp_path, {"required": "yes"})
    with pytest.raises(ConfigError) as err:
        load_config(tmp_path, {})
    assert "required must be true or false" in str(err.value)


@pytest.mark.parametrize(
    ("text", "parsed"),
    [
        ("3.10.0", (3, 10, 0)),
        ("0.0.0", (0, 0, 0)),
        ("12.345.6789", (12, 345, 6789)),
        ("3.10", None),
        ("3.10.0.1", None),
        ("v3.10.0", None),
        (">=3.10.0", None),
        ("3.10.0-rc1", None),
        (" 3.10.0", None),
        ("3.10.0\n", None),
        ("3.x.0", None),
        ("", None),
    ],
)
def test_parse_version(text: str, parsed: tuple[int, int, int] | None) -> None:
    assert parse_version(text) == parsed
