"""The local-transformer docs embedder: the model registry (and, in later tasks, the ONNX encoder).

`docs.model: "transformer:<name>"` names an entry of REGISTRY. config.py imports this module, so it
must stay light: nothing heavy (onnxruntime, tokenizers, numpy) is imported at module level.
"""

from __future__ import annotations

from dataclasses import dataclass

PREFIX = "transformer:"


@dataclass(frozen=True)
class TransformerSpec:
    """One pinned model: where its files come from, which of them to run, and what it produces."""

    name: str
    source: str  # a Hugging Face repo id, or a local directory (tests)
    revision: str
    onnx_file: str
    variant: str
    tokenizer_file: str
    dim: int
    max_tokens: int
    pooling: str = "cls"

    @property
    def model_path(self) -> str:
        """What semble records as the index's model path: a new revision here invalidates saved indexes."""
        return f"{PREFIX}{self.name}@{self.revision[:12]}"

    @property
    def model_id(self) -> str:
        return f"{self.source}@{self.revision}"


REGISTRY: dict[str, TransformerSpec] = {
    "gte-modernbert-base": TransformerSpec(
        "gte-modernbert-base",
        "Alibaba-NLP/gte-modernbert-base",
        "e7f32e3c00f91d699e8c43b53106206bcc72bb22",
        "onnx/model_int8.onnx",
        "int8",
        "tokenizer.json",
        768,
        1024,
    ),
}


class UnknownTransformer(ValueError):
    """A `transformer:<name>` value whose name is not in REGISTRY. The message lists the known names."""


def parse_model(value: str | None) -> TransformerSpec | None:
    """The spec a `docs.model` value names; None for null or any value without the `transformer:` prefix."""
    if value is None or not value.startswith(PREFIX):
        return None
    name = value[len(PREFIX) :]
    spec = REGISTRY.get(name)
    if spec is None:
        raise UnknownTransformer(f"unknown transformer model {name!r} (known: {', '.join(REGISTRY)})")
    return spec


def spec_for_path(model_path: str) -> TransformerSpec:
    """The spec behind a semble model path (`spec.model_path`). ValueError when no current registry entry has it."""
    for spec in REGISTRY.values():
        if spec.model_path == model_path:
            return spec
    raise ValueError(f"not a current transformer model path: {model_path!r}")
