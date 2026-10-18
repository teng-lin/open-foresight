#!/usr/bin/env python3
"""Read the original weights-only query detector without executing the app.

This is a diagnostic loader, not a replacement model or a production backend.
Its GPU weight unpacking is checked against the asset's per-output sum_i values.
"""

from __future__ import annotations
from typing import Any

import argparse
import hashlib
import json
import mmap
from pathlib import Path
import struct

import numpy as np


class FlatBuffer:
    def __init__(self, data):
        self.data = data

    def unpack(self, kind, offset):
        size = struct.calcsize(kind)
        if offset < 0 or offset + size > len(self.data):
            raise ValueError("FlatBuffer read outside the model")
        return struct.unpack_from(kind, self.data, offset)[0]

    def field(self, table, index):
        vtable = table - self.unpack("<i", table)
        entry = vtable + 4 + index * 2
        if entry + 2 > vtable + self.unpack("<H", vtable):
            return 0
        offset = self.unpack("<H", entry)
        return table + offset if offset else 0

    def target(self, field):
        return field + self.unpack("<I", field) if field else 0

    def vector(self, field, tables=False):
        target = self.target(field)
        if not target:
            return []
        length = self.unpack("<I", target)
        if target + 4 + length * 4 > len(self.data):
            raise ValueError("FlatBuffer vector outside the model")
        entries = [target + 4 + i * 4 for i in range(length)]
        return [self.target(x) if tables else self.unpack("<i", x) for x in entries]

    def string(self, field):
        target = self.target(field)
        if not target:
            return ""
        length = self.unpack("<I", target)
        if target + 4 + length > len(self.data):
            raise ValueError("FlatBuffer string outside the model")
        return self.data[target + 4 : target + 4 + length].decode("utf-8")

    def buffer_region(self, table):
        target = self.target(self.field(table, 0))
        if target and self.unpack("<I", target):
            offset, size = target + 4, self.unpack("<I", target)
        else:
            offset_field, size_field = self.field(table, 1), self.field(table, 2)
            offset = self.unpack("<Q", offset_field) if offset_field else 0
            size = self.unpack("<Q", size_field) if size_field else 0
        if offset + size > len(self.data):
            raise ValueError("External tensor buffer outside the model")
        return offset, size


def unpack_gpu_matrix(raw, outputs, inputs, expected_sums):
    """Decode uint8-offset, I4/O4-interleaved GPU weights with row checksums."""
    if outputs % 4 or inputs % 4 or len(raw) != outputs * inputs:
        raise ValueError("Unexpected GPU matrix dimensions")
    packed = np.frombuffer(raw, dtype=np.uint8)
    packed_matrix = packed.reshape(inputs // 4, outputs // 4, 4, 4)
    matrix = packed_matrix.transpose(1, 3, 0, 2).reshape(outputs, inputs)
    signed = matrix.astype(np.int16) - 128
    if expected_sums.shape != (outputs,):
        raise ValueError("Unexpected GPU checksum dimensions")
    if not np.array_equal(signed.sum(axis=1), expected_sums):
        raise ValueError("GPU matrix row checksums do not match")
    return signed.astype(np.int8)


class LegacyQueryWeights:
    """Bounds-checked reader for the authenticated GEMMA4_200M container."""

    sha256 = "889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f"

    def __init__(self, path, *, verify_digest=True):
        self.file = Path(path).open("rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            if verify_digest and hashlib.sha256(self.data).hexdigest() != self.sha256:
                raise ValueError("Model is not the authenticated original detector")
            if self.data[4:8] != b"TFL3":
                raise ValueError("Expected a TFL3 weights container")
            f = self.flat = FlatBuffer(self.data)
            model = f.unpack("<I", 0)
            if f.unpack("<I", f.field(model, 0)) != 3:
                raise ValueError("Unexpected TFLite version")
            subgraphs = f.vector(f.field(model, 2), tables=True)
            if (
                len(subgraphs) != 1
                or f.string(f.field(subgraphs[0], 4)) != "GEMMA4_200M"
            ):
                raise ValueError("Expected the dedicated GEMMA4_200M subgraph")
            if f.vector(f.field(subgraphs[0], 3), tables=True):
                raise ValueError("Expected weights without TFLite operators")
            buffers = f.vector(f.field(model, 4), tables=True)
            self.regions = [f.buffer_region(x) for x in buffers]
            self.tensors: dict[str, Any] = {}
            for tensor in f.vector(f.field(subgraphs[0], 0), tables=True):
                name = f.string(f.field(tensor, 3))
                index = f.unpack("<I", f.field(tensor, 2))
                if not name or name in self.tensors or index >= len(buffers):
                    raise ValueError("Invalid or duplicate tensor")
                self.tensors[name] = index
            self.metadata = {}
            for entry in f.vector(f.field(model, 6), tables=True):
                name = f.string(f.field(entry, 0))
                value = f.unpack("<I", f.field(entry, 1))
                # ModelData stores this enum directly in metadata.buffer; it is
                # not a buffer index. See public MediaPipe model_data.cc.
                self.metadata[name] = (
                    value
                    if name == "odml.infra.LlmModelType"
                    else self.read_region(value)
                )
            if self.metadata.get("odml.infra.LlmModelType") != 35:
                raise ValueError("Expected original model type 35")
            if self.metadata.get("backend") != b"gpu":
                raise ValueError("Expected original GPU packing metadata")
        except BaseException:
            self.close()
            raise

    def close(self):
        self.data.close()
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def read_region(self, index):
        if not 0 <= index < len(self.regions):
            raise ValueError("Invalid model buffer index")
        offset, size = self.regions[index]
        return self.data[offset : offset + size]

    def raw(self, name):
        return self.read_region(self.tensors[name])

    def vector(self, name, length):
        result = np.frombuffer(self.raw(name), dtype="<f4")
        if result.shape != (length,) or not np.isfinite(result).all():
            raise ValueError(f"Invalid float vector: {name}")
        return result

    def quantized_matrix(self, name, outputs, inputs):
        sums = np.frombuffer(self.raw(name + ".sum_i"), dtype="<i4")
        return unpack_gpu_matrix(self.raw(name), outputs, inputs, sums)

    def matrix(self, name, outputs, inputs):
        quantized = self.quantized_matrix(name, outputs, inputs)
        scales = self.vector(name + "_quantized_scale", outputs)
        if (scales <= 0).any():
            raise ValueError(f"Invalid quantized scales: {name}")
        return quantized.astype(np.float32) * scales[:, None]

    def verify(self):
        matrices, parameters = 0, 0
        for name, outputs, inputs in self.matrix_shapes():
            self.quantized_matrix(name, outputs, inputs)
            if (self.vector(name + "_quantized_scale", outputs) <= 0).any():
                raise ValueError(f"Invalid quantized scales: {name}")
            matrices += 1
            parameters += outputs * inputs
        for layer in range(18):
            prefix = f"params.lm.transformer.x_layers_{layer}."
            for suffix, dimension in [
                ("pre_layer_norm.scale", 1024),
                ("post_layer_norm.scale", 1024),
                ("ff_layer.pre_layer_norm.scale", 1024),
                ("ff_layer.post_layer_norm.scale", 1024),
                ("self_attention.q_norm.scale", 256),
                ("self_attention.k_norm.scale", 256),
            ]:
                self.vector(prefix + suffix, dimension)
        self.vector("params.lm.final_ln.scale", 1024)
        return {
            "model_sha256": self.sha256,
            "matrices_verified": matrices,
            "quantized_parameters": parameters,
            "tensors": len(self.tensors),
            "architecture": {
                "layers": 18,
                "dimension": 1024,
                "hidden": 2048,
                "head_dimension": 256,
                "query_heads": 4,
                "kv_heads": 1,
                "vocabulary": 16384,
            },
            "backend_metadata": "gpu",
            "original_inference_verified": False,
        }

    @staticmethod
    def matrix_shapes():
        yield "params.lm.softmax.logits_ffn.w", 16384, 1024
        for layer in range(18):
            prefix = f"params.lm.transformer.x_layers_{layer}."
            for suffix, outputs, inputs in [
                ("self_attention.q.w", 1024, 1024),
                ("self_attention.k.w", 256, 1024),
                ("self_attention.v.w", 256, 1024),
                ("self_attention.post.w", 1024, 1024),
                ("ff_layer.ffn_layer1_gate.w", 2048, 1024),
                ("ff_layer.ffn_layer1.w", 2048, 1024),
                ("ff_layer.ffn_layer2.w", 1024, 2048),
            ]:
                yield prefix + suffix, outputs, inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    with LegacyQueryWeights(args.model) as model:
        report = model.verify()
    encoded = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
