"""A tiny ONNX model and tokenizer for the encoder tests: real onnxruntime, a model of a few kilobytes.

The graph is one `Gather(table, input_ids) -> last_hidden_state`: every token's hidden state is
its row of a seeded random table, so position 0 (where the encoder reads its CLS vector) holds
the first word's row, and a test knows the exact vector a text must encode to. The graph also
declares `attention_mask`, as a real BERT-style export does, without using it.

The protobuf is encoded by hand: the `onnx` package has no Intel-macOS wheels. The messages and
field numbers used (onnx.proto):

    ModelProto           ir_version = 1 (varint), graph = 7, opset_import = 8
    OperatorSetIdProto   domain = 1, version = 2 (varint)
    GraphProto           node = 1, name = 2, initializer = 5, input = 11, output = 12
    NodeProto            input = 1, output = 2, name = 3, op_type = 4
    TensorProto          dims = 1 (varint, unpacked), data_type = 2 (FLOAT = 1, INT64 = 7), name = 8, raw_data = 9
    ValueInfoProto       name = 1, type = 2
    TypeProto            tensor_type = 1
    TypeProto.Tensor     elem_type = 1, shape = 2
    TensorShapeProto     dim = 1
    Dimension            dim_value = 1 (varint), dim_param = 2

Every other field is a length-delimited message, string or bytes (wire type 2).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from doc_search.transformer import TransformerSpec

FLOAT = 1
INT64 = 7
IR_VERSION = 8
OPSET = 13
SPECIAL = ["[UNK]", "[PAD]"]


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _int(field: int, value: int) -> bytes:
    """A varint field (wire type 0)."""
    return _varint(field << 3) + _varint(value)


def _bytes(field: int, data: bytes) -> bytes:
    """A length-delimited field (wire type 2): a message, a string or raw bytes."""
    return _varint(field << 3 | 2) + _varint(len(data)) + data


def _str(field: int, text: str) -> bytes:
    return _bytes(field, text.encode("utf-8"))


def _value_info(name: str, elem_type: int, dims: list[int | str]) -> bytes:
    """A ValueInfoProto for a tensor: an int dim is a fixed size, a str one a symbolic (dynamic) size."""
    shape = b"".join(_bytes(1, _int(1, d) if isinstance(d, int) else _str(2, d)) for d in dims)
    tensor = _int(1, elem_type) + _bytes(2, shape)
    return _str(1, name) + _bytes(2, _bytes(1, tensor))


def vocabulary(words: list[str]) -> list[str]:
    """The tokenizer's vocabulary for `words`, in id order: the special tokens, then each word once."""
    return list(dict.fromkeys([*SPECIAL, *words]))


def write_tiny_model(dir: Path, words: list[str], dim: int, seed: int = 0) -> np.ndarray:
    """Write `model.onnx` and `tokenizer.json` into `dir`; return the embedding table (one row per token id)."""
    from tokenizers import Tokenizer, models, normalizers, pre_tokenizers

    vocab = vocabulary(words)
    table = np.random.default_rng(seed).standard_normal((len(vocab), dim)).astype(np.float32)

    initializer = _int(1, len(vocab)) + _int(1, dim) + _int(2, FLOAT) + _str(8, "table")
    initializer += _bytes(9, table.astype("<f4").tobytes())
    node = _str(1, "table") + _str(1, "input_ids") + _str(2, "last_hidden_state") + _str(3, "gather")
    node += _str(4, "Gather")
    graph = _bytes(1, node) + _str(2, "tiny") + _bytes(5, initializer)
    graph += _bytes(11, _value_info("input_ids", INT64, ["b", "s"]))
    graph += _bytes(11, _value_info("attention_mask", INT64, ["b", "s"]))
    graph += _bytes(12, _value_info("last_hidden_state", FLOAT, ["b", "s", dim]))
    model = _int(1, IR_VERSION) + _bytes(7, graph) + _bytes(8, _str(1, "") + _int(2, OPSET))

    dir.mkdir(parents=True, exist_ok=True)
    (dir / "model.onnx").write_bytes(model)
    tokenizer = Tokenizer(models.WordLevel({w: i for i, w in enumerate(vocab)}, unk_token="[UNK]"))
    tokenizer.normalizer = normalizers.Lowercase()
    tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
    tokenizer.save(str(dir / "tokenizer.json"))
    return table


def tiny_spec(dir: Path, dim: int) -> TransformerSpec:
    """A spec whose files are the ones `write_tiny_model` wrote into `dir` (a local source: no hub)."""
    return TransformerSpec(
        name="tiny",
        source=str(dir),
        revision="0" * 40,
        onnx_file="model.onnx",
        variant="fp32",
        tokenizer_file="tokenizer.json",
        dim=dim,
        max_tokens=32,
    )
