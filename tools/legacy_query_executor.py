#!/usr/bin/env python3
"""Isolated CPU diagnostic for the original dedicated detector weights.

No chat model is substituted. Float32 NumPy execution does not establish
numerical parity with the original packed-int8 GPU executor.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import struct
import time

import numpy as np
import sentencepiece as spm

from legacy_query_weights import LegacyQueryWeights


def proto_fields(data):
    position = 0

    def varint():
        nonlocal position
        result = 0
        for shift in range(0, 70, 7):
            if position >= len(data):
                raise ValueError('Truncated model metadata')
            value = data[position]
            position += 1
            result |= (value & 127) << shift
            if not value & 128:
                return result
        raise ValueError('Invalid model metadata varint')

    while position < len(data):
        tag = varint()
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError('Invalid model metadata tag')
        if wire == 0:
            value = varint()
        elif wire == 2:
            size = varint()
            value = data[position:position + size]
            position += size
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = data[position:position + size]
            position += size
        else:
            raise ValueError('Unsupported model metadata wire type')
        if position > len(data):
            raise ValueError('Truncated model metadata field')
        yield number, value


def rms_norm(x, scale=None):
    # Original GPU MakeNormalization adds 1 to learned scales; its RMS kernel
    # computes rsqrt(mean_sq + 1e-6). GPU reduction/rounding remains unverified.
    divisor = np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + np.float32(1e-6))
    result = x / divisor
    return result if scale is None else result * (np.float32(1) + scale)


def rope(x, positions, wavelength):
    half = x.shape[-1] // 2
    frequencies = np.power(wavelength, -np.arange(half, dtype=np.float32) / half)
    angle = positions[:, None] * frequencies[None, :]
    cosine, sine = np.cos(angle)[:, None, :], np.sin(angle)[:, None, :]
    first, second = x[..., :half], x[..., half:]
    return np.concatenate((first * cosine - second * sine,
                           second * cosine + first * sine), axis=-1)


_erf = np.vectorize(math.erf, otypes=[np.float32])


class LegacyQueryExecutor:
    cache_storage = 'float16'

    def __init__(self, model_path):
        with LegacyQueryWeights(model_path) as model:
            metadata = dict(proto_fields(model.metadata['odml.infra.proto.LlmParameters']))
            transformer = dict(proto_fields(metadata[1]))
            attention = dict(proto_fields(transformer[16]))
            feed_forward = dict(proto_fields(transformer[11]))
            expected_transformer = {1: 1, 3: 1024, 4: 2048, 5: 256, 6: 4,
                                    7: 18, 9: 1, 13: 2, 14: 2, 15: 2,
                                    18: 1, 19: 5}
            if any(transformer.get(k) != v for k, v in expected_transformer.items()):
                raise ValueError('Unsupported original transformer configuration')
            if metadata.get(2) != 16384 or metadata.get(4) != 2:
                raise ValueError('Unsupported vocabulary or BOS configuration')
            if any(attention.get(k) != v for k, v in {1: 1, 2: 1, 3: 1, 5: 4, 6: 512, 7: 1}.items()):
                raise ValueError('Unsupported attention configuration')
            if any(feed_forward.get(k) != v for k, v in {1: 1, 2: 1, 3: 2, 4: 2}.items()):
                raise ValueError('Unsupported feed-forward configuration')
            # Original GPU PerDimScale case 4: rescale factor / head width.
            self.query_scale = struct.unpack('<f', transformer[25])[0] / 256
            self.global_wavelength = struct.unpack('<f', transformer[32])[0]
            self.qk_has_scale = bool(attention.get(8, False))
            if transformer.get(41, 0):
                raise ValueError('SRQ execution is not implemented')
            self.tokenizer = spm.SentencePieceProcessor(model_proto=model.metadata['spm_vocab_model'])
            self.weights = {name: model.matrix(name, outputs, inputs)
                            for name, outputs, inputs in model.matrix_shapes()}
            self.norms = {}
            for layer in range(18):
                prefix = f'params.lm.transformer.x_layers_{layer}.'
                for suffix, dimension in [
                    ('pre_layer_norm.scale', 1024), ('post_layer_norm.scale', 1024),
                    ('ff_layer.pre_layer_norm.scale', 1024),
                    ('ff_layer.post_layer_norm.scale', 1024),
                    ('self_attention.q_norm.scale', 256),
                    ('self_attention.k_norm.scale', 256),
                ]:
                    self.norms[prefix + suffix] = model.vector(prefix + suffix, dimension)
            self.final_norm = model.vector('params.lm.final_ln.scale', 1024)
        self.embedding = self.weights['params.lm.softmax.logits_ffn.w']
        self.cache = [None] * 18

    def forward(self, ids, start):
        if not ids or start + len(ids) > 512:
            raise ValueError('Original 512-token context capacity exceeded')
        x = self.embedding[ids] * np.float32(32)
        positions = np.arange(start, start + len(ids), dtype=np.float32)
        for layer in range(18):
            prefix = f'params.lm.transformer.x_layers_{layer}.'

            def linear(value, suffix):
                return value @ self.weights[prefix + suffix + '.w'].T

            def norm(value, suffix):
                return rms_norm(value, self.norms[prefix + suffix + '.scale'])

            before = norm(x, 'pre_layer_norm')
            query = linear(before, 'self_attention.q').reshape(-1, 4, 256)
            key = linear(before, 'self_attention.k').reshape(-1, 1, 256)
            value = linear(before, 'self_attention.v')
            query = rms_norm(query, self.norms[prefix + 'self_attention.q_norm.scale']
                             if self.qk_has_scale else None)
            key = rms_norm(key, self.norms[prefix + 'self_attention.k_norm.scale']
                           if self.qk_has_scale else None)
            global_layer = (layer + 1) % 6 == 0
            wavelength = self.global_wavelength if global_layer else 10000.0
            # Original MakeSelfAttention scales Q after QKVRoPE, before QK^T.
            query = rope(query, positions, wavelength) * np.float32(self.query_scale)
            key = rope(key, positions, wavelength)[:, 0, :]
            # Selected original V1 caches use the calculation dtype (F16).
            # Keep storage rounding separate from the remaining float32 math.
            key = key.astype(np.float16)
            value = value.astype(np.float16)
            previous = self.cache[layer]
            if previous is not None:
                key = np.concatenate((previous[0], key))
                value = np.concatenate((previous[1], value))
            self.cache[layer] = key, value
            score = query.transpose(1, 0, 2) @ key.astype(np.float32).T
            columns = np.arange(len(key))[None, :]
            allowed = columns <= positions[:, None]
            if not global_layer:
                allowed &= columns > positions[:, None] - 512
            score = np.where(allowed[None, :, :], score, -np.inf)
            probability = np.exp(score - np.max(score, axis=-1, keepdims=True))
            probability /= np.sum(probability, axis=-1, keepdims=True)
            mixed = (probability @ value.astype(np.float32)).transpose(1, 0, 2).reshape(-1, 1024)
            after = linear(mixed, 'self_attention.post')
            x = x + norm(after, 'post_layer_norm')
            before = norm(x, 'ff_layer.pre_layer_norm')
            gate = linear(before, 'ff_layer.ffn_layer1_gate')
            gate = gate * np.float32(.5) * (1 + _erf(gate / np.float32(math.sqrt(2))))
            hidden = gate * linear(before, 'ff_layer.ffn_layer1')
            after = linear(hidden, 'ff_layer.ffn_layer2')
            x = x + norm(after, 'ff_layer.post_layer_norm')
        logits = rms_norm(x[-1], self.final_norm) @ self.embedding.T
        if not np.isfinite(logits).all():
            raise ValueError('Non-finite detector logits')
        return logits

    def generate(self, transcript, max_output_tokens=64):
        if not 1 <= max_output_tokens <= 512:
            raise ValueError('Output limit must be between 1 and 512')
        prompt = (' <ctrl1>' + transcript).split('\0', 1)[0]
        ids = [2] + self.tokenizer.encode(prompt)
        if len(ids) > 512:
            raise ValueError('Prompt exceeds the original 512-token context')
        self.cache = [None] * 18
        logits = self.forward(ids, 0)
        generated = []
        finish = 'output_limit'
        for _ in range(max_output_tokens):
            token = int(np.argmax(logits))  # Original top-k=1 has one candidate.
            if token == self.tokenizer.eos_id():
                finish = 'eos'
                break
            generated.append(token)
            if len(ids) + len(generated) >= 512:
                finish = 'context_limit'
                break
            if len(generated) == max_output_tokens:
                break
            logits = self.forward([token], len(ids) + len(generated) - 1)
        return {'prompt': prompt, 'input_token_ids': ids,
                'output_token_ids': generated, 'text': self.tokenizer.decode(generated),
                'finish_reason': finish, 'model_sha256': LegacyQueryWeights.sha256,
                'original_weights_executed': True, 'original_gpu_parity_verified': False,
                'backend': 'numpy_float32_cpu_diagnostic', 'cache_storage': self.cache_storage}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', type=Path)
    parser.add_argument('--transcript', required=True)
    parser.add_argument('--max-output-tokens', type=int, default=64)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    start = time.monotonic()
    executor = LegacyQueryExecutor(args.model)
    loaded = time.monotonic()
    report = executor.generate(args.transcript, args.max_output_tokens)
    report['load_seconds'] = loaded - start
    report['inference_seconds'] = time.monotonic() - loaded
    encoded = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(encoded)
    print(encoded, end='')


if __name__ == '__main__':
    main()
