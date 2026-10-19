"""Tiny synthetic metadata/weights exercise the diagnostic CPU reader offline.

Tokenizer construction is the optional external boundary. No original model
asset is opened and these checks make no inference-parity claim.
"""

import importlib.util
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import numpy as np
import pytest
from tools import legacy_query_weights as weights


@pytest.fixture
def executor_module(monkeypatch):
    tokenizer = SimpleNamespace(
        encode=Mock(return_value=[1]),
        decode=lambda ids: " ".join(map(str, ids)),
        eos_id=lambda: 3,
    )
    monkeypatch.setitem(
        sys.modules,
        "sentencepiece",
        SimpleNamespace(SentencePieceProcessor=Mock(return_value=tokenizer)),
    )
    monkeypatch.syspath_prepend(str(Path(weights.__file__).parent))
    spec = importlib.util.spec_from_file_location(
        "diagnostic_executor_under_test",
        Path(weights.__file__).with_name("legacy_query_executor.py"),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, tokenizer


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def proto(fields):
    return b"".join(
        varint(
            number << 3
            | (0 if isinstance(value, int) else 5 if isinstance(value, float) else 2)
        )
        + (
            varint(value)
            if isinstance(value, int)
            else struct.pack("<f", value)
            if isinstance(value, float)
            else varint(len(value)) + value
        )
        for number, value in fields.items()
    )


@pytest.mark.parametrize(
    "data,message",
    [
        (b"\x80", "Truncated"),
        (b"\x80" * 10, "varint"),
        (b"\0\0", "tag"),
        (b"\x0b", "wire type"),
        (b"\x0a\x05a", "field"),
        (b"\x09x", "field"),
    ],
)
def test_metadata_parser_rejects_truncation_invalid_tags_and_wire_types(
    executor_module, data, message
):
    module, _ = executor_module
    with pytest.raises(ValueError, match=message):
        list(module.proto_fields(data))


def test_metadata_parser_supports_each_owned_wire_type(executor_module):
    module, _ = executor_module
    assert list(module.proto_fields(b"\x08\x96\x01\x12\x02ab\x19abcdefgh\x25abcd")) == [
        (1, 150),
        (2, b"ab"),
        (3, b"abcdefgh"),
        (4, b"abcd"),
    ]
    x = np.array([[3, 4]], dtype=np.float32)
    np.testing.assert_allclose(
        module.rms_norm(x, np.zeros(2)), x / np.sqrt(12.5 + 1e-6)
    )
    np.testing.assert_array_equal(
        module.rope(x[:, None, :], np.array([0]), 10000), x[:, None, :]
    )


@pytest.mark.parametrize(
    "failure", [None, "transformer", "vocabulary", "attention", "feed-forward", "srq"]
)
def test_executor_constructor_validates_architecture_before_loading_weights(
    executor_module, monkeypatch, failure
):
    module, tokenizer = executor_module
    transformer = {
        1: 1,
        3: 1024,
        4: 2048,
        5: 256,
        6: 4,
        7: 18,
        9: 1,
        13: 2,
        14: 2,
        15: 2,
        18: 1,
        19: 5,
        25: 16.0,
        32: 1000000.0,
    }
    attention = {1: 1, 2: 1, 3: 1, 5: 4, 6: 512, 7: 1}
    feed_forward = {1: 1, 2: 1, 3: 2, 4: 2}
    if failure == "transformer":
        transformer[7] = 17
    if failure == "attention":
        attention[6] = 1024
    if failure == "feed-forward":
        feed_forward[4] = 1
    if failure == "srq":
        transformer[41] = 1
    transformer[16], transformer[11] = proto(attention), proto(feed_forward)
    metadata = {
        1: proto(transformer),
        2: 10 if failure == "vocabulary" else 16384,
        4: 2,
    }
    model = Mock()
    model.__enter__ = Mock(return_value=model)
    model.__exit__ = Mock(return_value=False)
    model.metadata = {
        "odml.infra.proto.LlmParameters": proto(metadata),
        "spm_vocab_model": b"tokenizer bytes",
    }
    embedding = np.ones((4, 1024), dtype=np.float32)
    model.matrix_shapes.return_value = [("params.lm.softmax.logits_ffn.w", 4, 1024)]
    model.matrix.return_value = embedding
    model.vector.side_effect = lambda name, size: np.zeros(size, dtype=np.float32)
    monkeypatch.setattr(module, "LegacyQueryWeights", Mock(return_value=model))
    if failure:
        with pytest.raises(ValueError):
            module.LegacyQueryExecutor("fixture")
        model.matrix.assert_not_called()
    else:
        instance = module.LegacyQueryExecutor("fixture")
        assert instance.embedding is embedding
        assert instance.query_scale == 16 / 256
        assert instance.global_wavelength == 1000000
        assert len(instance.norms) == 108
        assert instance.tokenizer is tokenizer
        assert instance.cache == [None] * 18
    model.__exit__.assert_called_once()


@pytest.mark.parametrize("qk_scale", [False, True])
def test_forward_retains_f16_cache_and_batch_incremental_agreement(
    executor_module, qk_scale
):
    module, _ = executor_module
    instance = object.__new__(module.LegacyQueryExecutor)
    instance.embedding = np.arange(4 * 1024, dtype=np.float32).reshape(4, 1024) / 4096
    instance.global_wavelength, instance.query_scale, instance.qk_has_scale = (
        1000000,
        1 / 16,
        qk_scale,
    )
    instance.cache, instance.norms, instance.weights = [None] * 18, {}, {}
    instance.final_norm = np.zeros(1024, dtype=np.float32)
    shapes = [
        ("self_attention.q", 1024, 1024),
        ("self_attention.k", 256, 1024),
        ("self_attention.v", 256, 1024),
        ("self_attention.post", 1024, 1024),
        ("ff_layer.ffn_layer1_gate", 4, 1024),
        ("ff_layer.ffn_layer1", 4, 1024),
        ("ff_layer.ffn_layer2", 1024, 4),
    ]
    for layer in range(18):
        prefix = f"params.lm.transformer.x_layers_{layer}."
        for suffix, outputs, inputs in shapes:
            instance.weights[prefix + suffix + ".w"] = np.zeros(
                (outputs, inputs), dtype=np.float32
            )
        for suffix, size in [
            ("pre_layer_norm", 1024),
            ("post_layer_norm", 1024),
            ("ff_layer.pre_layer_norm", 1024),
            ("ff_layer.post_layer_norm", 1024),
            ("self_attention.q_norm", 256),
            ("self_attention.k_norm", 256),
        ]:
            instance.norms[prefix + suffix + ".scale"] = np.zeros(
                size, dtype=np.float32
            )
    batch = instance.forward([1, 2], 0)
    instance.cache = [None] * 18
    instance.forward([1], 0)
    previous = [(k.copy(), v.copy()) for k, v in instance.cache]
    incremental = instance.forward([2], 1)
    np.testing.assert_allclose(batch, incremental, atol=1e-3)
    for old, (key, value) in zip(previous, instance.cache, strict=True):
        assert key.shape == value.shape == (2, 256)
        assert key.dtype == value.dtype == np.float16
        np.testing.assert_array_equal(key[:1], old[0])
        np.testing.assert_array_equal(value[:1], old[1])
    for ids, start in (([], 0), ([1, 2], 511)):
        with pytest.raises(ValueError, match="capacity"):
            instance.forward(ids, start)
    instance.embedding[:] = np.nan
    with np.errstate(invalid="ignore"), pytest.raises(ValueError, match="Non-finite"):
        instance.forward([1], 0)


@pytest.mark.parametrize(
    "finish,encoded,limit,tokens",
    [
        ("eos", [1], 8, [0, 3]),
        ("output_limit", [1], 1, [0]),
        ("context_limit", [1] * 510, 8, [0]),
    ],
)
def test_generate_enforces_limits_and_reports_actual_finish_reason(
    executor_module, finish, encoded, limit, tokens
):
    module, tokenizer = executor_module
    instance = object.__new__(module.LegacyQueryExecutor)
    instance.tokenizer = tokenizer
    tokenizer.encode.return_value = encoded
    logits = [np.eye(4)[token] for token in tokens]
    instance.forward = Mock(side_effect=logits)
    result = instance.generate("question\0ignored", limit)
    assert result["prompt"] == " <ctrl1>question"
    assert result["finish_reason"] == finish
    assert result["output_token_ids"] == [0]
    assert result["original_gpu_parity_verified"] is False
    assert result["cache_storage"] == "float16"
    for invalid in (0, 513):
        with pytest.raises(ValueError, match="Output limit"):
            instance.generate("x", invalid)
    tokenizer.encode.return_value = [1] * 512
    with pytest.raises(ValueError, match="Prompt exceeds"):
        instance.generate("x")


class FlatFixture:
    """Minimal forward-offset FlatBuffer writer, independent of the reader."""

    def __init__(self):
        self.data = bytearray(b"\0" * 4 + b"TFL3")

    def append(self, data):
        offset = len(self.data)
        self.data.extend(data)
        return offset

    def table(self, fields):
        vtable = self.append(
            struct.pack("<HH", 4 + 2 * fields, 4 + 8 * fields)
            + b"".join(struct.pack("<H", 4 + 8 * i) for i in range(fields))
        )
        table = self.append(struct.pack("<i", 4 + 2 * fields) + b"\0" * (fields * 8))
        assert table - vtable == 4 + 2 * fields
        return [table + 4 + i * 8 for i in range(fields)], table

    def point(self, field, target):
        struct.pack_into("<I", self.data, field, target - field)

    def string(self, field, text):
        raw = text.encode()
        self.point(field, self.append(struct.pack("<I", len(raw)) + raw + b"\0"))

    def vector(self, field, length):
        offset = self.append(struct.pack("<I", length) + b"\0" * (length * 4))
        self.point(field, offset)
        return [offset + 4 + 4 * i for i in range(length)]


def model_bytes(problem=None):
    f = FlatFixture()
    model, root = f.table(7)
    struct.pack_into("<I", f.data, 0, root)
    struct.pack_into("<I", f.data, model[0], 2 if problem == "version" else 3)
    subgraph_ref = f.vector(model[2], 1)[0]
    subgraph, target = f.table(5)
    f.point(subgraph_ref, target)
    f.string(subgraph[4], "other" if problem == "subgraph" else "GEMMA4_200M")
    f.vector(subgraph[3], 1 if problem == "operators" else 0)
    tensors = f.vector(subgraph[0], 2 if problem == "duplicate" else 1)
    for reference in tensors:
        tensor, target = f.table(4)
        f.point(reference, target)
        f.string(tensor[3], "weight")
        struct.pack_into(
            "<I", f.data, tensor[2], 99 if problem == "tensor-index" else 0
        )
    buffers = f.vector(model[4], 1)
    buffer, target = f.table(3)
    f.point(buffers[0], target)
    payload = f.append(struct.pack("<I", 3) + b"gpu")
    f.point(buffer[0], payload)
    metadata = f.vector(model[6], 2)
    for reference, name, value in zip(
        metadata,
        ["odml.infra.LlmModelType", "backend"],
        [0 if problem == "type" else 35, 0],
        strict=True,
    ):
        entry, target = f.table(2)
        f.point(reference, target)
        f.string(entry[0], name)
        struct.pack_into("<I", f.data, entry[1], value)
    if problem == "backend":
        f.data[payload + 4 : payload + 7] = b"cpu"
    return bytes(f.data)


@pytest.mark.parametrize(
    "problem",
    [
        None,
        "digest",
        "magic",
        "version",
        "subgraph",
        "operators",
        "duplicate",
        "tensor-index",
        "type",
        "backend",
    ],
)
def test_weight_container_validates_structure_and_closes_failed_mmaps(
    tmp_path, problem
):
    data = model_bytes(problem)
    if problem == "magic":
        data = data[:4] + b"BAD!" + data[8:]
    path = tmp_path / "weights.tflite"
    path.write_bytes(data)
    if problem:
        with pytest.raises(ValueError):
            weights.LegacyQueryWeights(path, verify_digest=problem == "digest")
    else:
        with weights.LegacyQueryWeights(path, verify_digest=False) as model:
            assert model.raw("weight") == b"gpu"
            assert model.metadata["backend"] == b"gpu"
            assert model.metadata["odml.infra.LlmModelType"] == 35
        assert model.file.closed
        assert model.data.closed
    path.unlink()  # Failed constructor also releases the file/mapping.


def test_weight_vectors_quantization_and_inventory_are_checked():
    model = object.__new__(weights.LegacyQueryWeights)
    model.tensors = {"x": 0}
    model.regions = [(0, 16)]
    model.data = np.array([1, 2, 3, 4], dtype="<f4").tobytes()
    np.testing.assert_array_equal(model.vector("x", 4), [1, 2, 3, 4])
    for index in (-1, 1):
        with pytest.raises(ValueError, match="buffer index"):
            model.read_region(index)
    with pytest.raises(ValueError, match="float vector"):
        model.vector("x", 3)
    model.data = np.array([np.inf] * 4, dtype="<f4").tobytes()
    with pytest.raises(ValueError, match="float vector"):
        model.vector("x", 4)
    model.quantized_matrix = Mock(return_value=np.ones((4, 4), dtype=np.int8))
    model.vector = Mock(return_value=np.arange(1, 5, dtype=np.float32))
    np.testing.assert_array_equal(
        model.matrix("x", 4, 4), np.arange(1, 5)[:, None] * np.ones((4, 4))
    )
    model.matrix_shapes = lambda: [("x", 4, 4)]
    report = model.verify()
    assert report["matrices_verified"] == 1
    assert report["quantized_parameters"] == 16
    assert len(list(weights.LegacyQueryWeights.matrix_shapes())) == 127
    model.vector.return_value = np.zeros(4)
    with pytest.raises(ValueError, match="quantized scales"):
        model.matrix("x", 4, 4)
    with pytest.raises(ValueError, match="quantized scales"):
        model.verify()


def test_flatbuffer_absent_and_external_regions():
    reader = weights.FlatBuffer(b"\0" * 12)
    assert reader.target(0) == 0
    assert reader.string(0) == ""
    assert reader.vector(0) == []
    f = FlatFixture()
    fields, table = f.table(3)
    # A zero-length inline buffer selects the external offset/size fields.
    f.point(fields[0], f.append(struct.pack("<I", 0)))
    external = f.append(b"abcdef")
    struct.pack_into("<Q", f.data, fields[1], external)
    struct.pack_into("<Q", f.data, fields[2], 6)
    assert weights.FlatBuffer(f.data).buffer_region(table) == (external, 6)
    struct.pack_into("<Q", f.data, fields[2], 9999)
    with pytest.raises(ValueError, match="External tensor"):
        weights.FlatBuffer(f.data).buffer_region(table)
