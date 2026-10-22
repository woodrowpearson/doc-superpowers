"""The semble seam: every private semble name and calling convention the local-transformer relies on.

doc-search puts its encoder in at `semble.index.dense._load_cached`, private API, and tells an
indexing call from a query by how semble calls the model: `embed_chunks` passes
`use_multiprocessing`, a search passes the query text alone. semble is pinned `<0.8` for this;
an upgrade that moves any of it fails here, by name, instead of building a docs index that is
silently static or uncached. Build progress relies on one more: semble embeds on the thread that
calls `from_path`, where `report_to` set the sink.
"""

from __future__ import annotations

import importlib.metadata
import json
import tomllib
from pathlib import Path

import pytest
import semble.index.dense as dense
import semble.index.types
import semble.search
from model2vec import StaticModel
from semble import ContentType, SembleIndex
from semble.cache import get_validated_cache, save_index_to_cache
from semble.index.types import PersistencePath

from doc_search import transformer
from doc_search.transformer import TransformerSpec
from fakes_transformer import fake_encoder

PYPROJECT = Path(__file__).resolve().parents[1] / "pyproject.toml"

DOCS = {
    "docs/refunds.md": "# Refunds\n\nA refund total is rounded half up to the nearest cent.\n",
    "docs/tax.md": "# Tax\n\nThe tax rate applies to each invoice line before the discount.\n",
    "README.md": "# Guide\n\nSee the payment policy for the default fee and the refund rule.\n",
}


class Sink:
    """A progress sink that records every `add`."""

    def __init__(self) -> None:
        self.adds: list[tuple[int, bool]] = []

    def add(self, n: int, *, cached: bool = False) -> None:
        self.adds.append((n, cached))


def docs_tree(root: Path) -> Path:
    for rel, text in DOCS.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    return root


def test_seam_pins(tmp_path: Path, fake_transformer: TransformerSpec) -> None:
    spec = fake_transformer
    for name in ("_load_cached", "load_model", "embed_chunks"):
        assert callable(getattr(dense, name, None)), f"semble.index.dense.{name} moved"
    assert callable(getattr(semble.search, "_search_semantic", None)), "semble.search._search_semantic moved"
    assert hasattr(semble.index.types, "PersistencePath"), "semble.index.types.PersistencePath moved"
    dependencies = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))["project"]["dependencies"]
    assert "semble>=0.7,<0.8" in dependencies
    assert importlib.metadata.version("semble").startswith("0.7.")

    transformer.install()
    tree = docs_tree(tmp_path / "tree")
    sink = Sink()
    with transformer.report_to(sink):  # thread-local: semble must embed on the thread that builds
        index = SembleIndex.from_path(tree, content=[ContentType.DOCS], model_path=spec.model_path)
    assert sum(n for n, _ in sink.adds) == len(index.chunks)
    encoder = fake_encoder(spec)
    assert index.model is encoder  # load_model reads _load_cached as a module global, at call time
    indexing = [texts for texts, kwargs in encoder.calls if "use_multiprocessing" in kwargs]
    assert indexing, f"embed_chunks no longer passes use_multiprocessing: {encoder.calls}"
    assert sum(map(len, indexing)) == len(index.chunks) > 0
    assert index._semantic_index.vectors.shape == (len(index.chunks), spec.dim)

    encoder.calls.clear()
    index.search("refund")
    assert encoder.calls == [(["refund"], {})]  # a query: one text, no keywords

    save_index_to_cache(index, str(tree))
    cache_path = get_validated_cache(str(tree), spec.model_path, (ContentType.DOCS,))
    assert cache_path is not None
    loaded = SembleIndex.load_from_disk(cache_path)
    assert loaded.model is encoder
    assert loaded._semantic_index.vectors.shape == (len(loaded.chunks), spec.dim)
    metadata = json.loads(PersistencePath.from_path(cache_path).metadata.read_text(encoding="utf-8"))
    assert metadata["model_path"] == spec.model_path
    assert metadata["files"] and all("count" in entry for entry in metadata["files"].values())
    assert sum(entry["count"] for entry in metadata["files"].values()) == len(index.chunks)


def test_other_models_pass_through(fake_transformer: TransformerSpec, tiny_model: str) -> None:
    transformer.install()
    transformer.install()  # idempotent: the loader never wraps itself
    model = dense._load_cached(tiny_model)
    assert isinstance(model, StaticModel)
    assert dense.load_model() == (model, tiny_model)  # semble's default model (SEMBLE_MODEL_NAME) is static too
    with pytest.raises(ValueError, match="not a current transformer model path"):
        dense._load_cached("transformer:gte-modernbert-base@000000000000")  # a retired revision
