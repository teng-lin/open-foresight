# Original dedicated detector: legacy execution

The authenticated original detector now executes through an isolated CPU
diagnostic using its own weights and vocabulary. This does not establish
numerical parity with the original GPU executor. Automatic Q&A now uses this
reconstructed dedicated runtime when its authenticated model and worker are
registered. An absent dedicated model produces a visible not-ready error and
does not substitute chat inference.

The exact asset SHA-256 is
`889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f`.
The loader rejects a different asset. The product worker contains reconstructed
code; it neither loads the original application binary nor acquires model weights.

## Public runtime evidence

The installed LiteRT-LM 0.18 CPU and GPU engine paths already reject this
weights-only container before inference; see [the runtime trace](reference-query-runtime.md).
Adding a modern container header cannot supply its missing compute graph:
there are 490 tensors but no TFLite operators or operator codes.

Primary upstream source provides a viable reconstruction path:

- [MediaPipe ModelData at cad7f3ab](https://github.com/google-ai-edge/mediapipe/blob/cad7f3ab99ebf175947e40c5252c642612aae927/mediapipe/tasks/cc/genai/inference/utils/llm_utils/model_data.cc)
  reads legacy external buffer offsets/sizes. `odml.infra.LlmModelType` stores
  the enum directly in `metadata.buffer`, unlike ordinary metadata buffers.
- [The public XNN model factory](https://github.com/google-ai-edge/mediapipe/blob/cad7f3ab99ebf175947e40c5252c642612aae927/mediapipe/tasks/cc/genai/inference/utils/xnn_utils/llm_builder_factory.cc)
  supports older Gemma variants but has no architecture-35 branch. Building it
  unchanged would not implement this detector.
- [The legacy graph builder](https://github.com/google-ai-edge/mediapipe/blob/cad7f3ab99ebf175947e40c5252c642612aae927/mediapipe/tasks/cc/genai/inference/utils/xnn_utils/graph_builder.cc)
  established **1 + stored scale**, which matters because the detector's
  post-normalization and Q/K scale tensors contain zeros. Its clamped RMS
  denominator was used initially and has now been corrected from the original
  GPU trace below.
- [The LLM graph](https://github.com/google-ai-edge/mediapipe/blob/cad7f3ab99ebf175947e40c5252c642612aae927/mediapipe/tasks/cc/genai/inference/utils/xnn_utils/llm.cc)
  supplies tied token/output weights, embedding scaling, residual paths, GELU
  gating and query scaling. [The RoPE helper](https://github.com/google-ai-edge/mediapipe/blob/cad7f3ab99ebf175947e40c5252c642612aae927/mediapipe/tasks/cc/genai/inference/utils/xnn_utils/utils.cc)
  supplies the local 10,000 wavelength and split-half cosine/sine convention.

Only selected source files and repository inventories were fetched. No large
dependency or source build was started. The current LiteRT-LM source inventory
was pinned to `776cdb6b3a9e871108ec1c72df73ed05dd77bf44` for investigation;
the selected legacy execution source above is pinned separately.

## Weights and architecture

`tools/legacy_query_weights.py` follows external buffers with bounds checks and
recovers all **127 int8 matrices / 177,209,344 quantized parameters**. Matrix
bytes encode unsigned values with zero point 128. Their layout is
`[input/4, output/4, 4 inputs, 4 outputs]`; unpacking transposes this into the
logical output/input matrix. Every output-row sum matches the original `sum_i`
tensor across all 127 matrices. Ordinary row-major decoding does not match.
Per-output positive float32 scales produce diagnostic float32 matrices.

The model has 18 layers, width 1,024, feed-forward width 2,048, four query heads,
one KV head, head width 256 and a 16,384-piece SentencePiece vocabulary. Its
embedded parameters select Q/K normalization, causal attention, a 512-token
window, five local layers per global layer, global RoPE wavelength 1,000,000,
and query rescale factor 32. BOS is token 2. The literal prefix ` <ctrl1>` encodes
to token 16,004 before the transcript. The vocabulary's recognized EOS is token
1 (`</s>`).

The original protobuf descriptors retained by the parent investigation bind
previously unavailable fields: `num_local_layers_per_global`,
`sliding_window_size`, `qk_norm`, `qk_norm_has_scale`, `global_rope_wavelength`
and `apply_srq`. REA evidence is
`ev_15e94f2dccf3bfdc69fe8ce4af9e445c0b249e75b7fa3f18cb91d1090d645065`
and `ev_841f9af297687fb5337738be2bf87cc711beb64ed96d8ed5be9f1f165680a98d`.

## Original GPU normalization and rotary trace

`odml_byom::CreateTransformerBuilder` at `0x1027f0f54` selects the ordinary
`ml_drift::TransformerBuilder` for model type 35. Only types 5, 8 and 11 select
specialized builders in that switch. The generic GPU builder is therefore the
relevant implementation for this detector.

`MakeNormalization` at `0x102833e6c` explicitly passes a scale shift of **1.0**.
`MakeRMSNormalizationWithBuilder` at `0x10280ed0c` adds that shift to the learned
scale and passes epsilon **1e-6**. The actual original GPU shader generator
`GetRMSNormalizationCode` at `0x1028cba2c` computes the inverse square root of
**mean square plus epsilon**. The CPU diagnostic now uses that denominator,
replacing the older XNN clamp behavior. A tiny-activation regression distinguishes
these formulas; the existing original-weight positive/negative and cache tests
still pass.

The primary [ml-drift RMS kernel source](https://github.com/google-ai-edge/ml-drift/blob/e420a73d95ce069b528b214499e28c69127f296f/ml_drift/common/kernels/mean_stddev_normalization.cc)
matches the recovered GPU expression. Its [RoPE kernel](https://github.com/google-ai-edge/ml-drift/blob/e420a73d95ce069b528b214499e28c69127f296f/ml_drift/common/kernels/rope.cc)
uses split halves and geometric timescales. Original `MakeRotaryEmbedding` at
`0x102822970` forwards its three floats to `SplitRoPEConcat` with planar mode.
Original `QKVRoPE` at `0x10285f434` selects minimum timescale 1, local maximum
10,000, the metadata global maximum 1,000,000, and proportion 1 when no partial
proportion is configured.

`CreateStackedTransformerModel` binds the global-layer schedule at
`0x102836564–0x102836620`: it compares the zero-based layer index modulo
`num_local_layers_per_global + 1` with the configured global-layer offset,
falling back to `num_local_layers_per_global` when that optional offset is
absent. The original asset therefore selects global layers **5, 11 and 17**
(zero-based). The same comparison selects the full attention mask and is
forwarded to the layer builder. This agrees with the diagnostic's existing
`(layer + 1) % 6 == 0` schedule.

The original GPU scalar is now bound directly. `PerDimScale` at `0x10281d148`
reads attention-scale enum 4 from builder offset 140 and multiplies Q by the
rescale factor at offset 144 divided by head width at offset 24
(`0x10281d25c`). For the original asset this is **32 / 256 = 0.125**.
`MakeSelfAttention` calls this immediately after `QKVRoPE`, before the QK
matrix product. The diagnostic now applies the scalar at that same stage.
This confirms the scalar previously derived from the public XNN branch.

The full fused-builder body and shader, including their retained tails,
establish that `MakeTransformQKVRmsNormApplyRoPE` applies Q/K RMS with epsilon
1e-6, optional learned gamma, and RoPE, then writes Q without an additional
attention scalar. This agrees with scaling in the outer attention caller.
`MakeLayer` constructs a nonempty `.self_attention` weight prefix and forwards
it through virtual slot 32 (`0x10282def0`). The ordinary `MakeSelfAttention`
passes that prefix to `QKVRoPE` with normalization shift 1.0, so this fused V1
path loads the Q/K scale vectors. All 36 original Q/K scale vectors contain
only zeros, verified from the authenticated asset: adding 1 gives the same
identity scale as the diagnostic's metadata-selected no-gamma path.

The outer `LlmWebGpu::InitModel` dispatch at `0x101e2bc80` rejects V2
for this asset because the extra embedding-configuration optionals required by
that branch are absent. Its fallback at `0x101e2c174–0x101e2c188` selects the
ordinary V1 call at `0x101e2c2cc` when the optional global-head configuration
flag at builder offset 40 is false. `CreateTransformerConfig` leaves that flag
false unless the protobuf integer at offset 244 is positive.
`IsModelv3` at `0x1027fa940` returns false for this
model's absent/default configuration fields, excluding the V3 builder path.

Retained IDA evidence files include `detector-gpu-model-builder.json`,
`detector-gpu-normalization-default.json`, `detector-gpu-rms-builder.json`,
`detector-gpu-rms-kernel.json`, `detector-gpu-qkv-rotary.json`,
`detector-gpu-transformer-config.json`, `detector-gpu-query-scale-dispatch.json`,
`detector-gpu-self-attention.json`, `detector-gpu-stacked-v1-final.json`,
`detector-gpu-make-layer.json`, `detector-gpu-init-model-dispatch-final.json`,
and `detector-gpu-v1-fallback-dispatch.json` under `test-results/reference-functions/ida/`.

## Isolated execution and results

`tools/legacy_query_executor.py` runs the authenticated weights through a NumPy
float32 transformer. It uses the original control prefix and BOS, tied weights,
Q/K normalization, four layer norms, local/global RoPE, causal attention,
incremental KV caches, the 512-token context limit, and greedy selection matching
the original top-k=1 candidate set. It adds no chat template or alternate model.

Example, with NumPy and SentencePiece 0.2.1 installed:

```sh
VECLIB_MAXIMUM_THREADS=2 python tools/legacy_query_executor.py \
  test-results/reference-functions/query-runtime/original-query-detector.tflite \
  --transcript 'The launch is scheduled for Friday. What risks could delay it?' \
  --max-output-tokens 64
```

Observed original-weight output is `What risks could delay the launch?`, followed
by EOS. Statement-only `The meeting starts at three.` returns empty output/EOS.
Several other standalone questions also returned empty output; the retained
reports preserve those results rather than presenting universal detection.

Reports are retained under ignored `query-runtime/` evidence output:
`original-query-weight-checksums.json`, `original-query-numpy-first.json` and
`original-query-numpy-cases.json`. Those initial inference reports retain the
older XNN denominator; `original-query-numpy-gpu-norm-cases.json` records fresh
execution with the corrected GPU normalization formula. The subsequent
`original-query-numpy-gpu-norm-scale-cases.json` also applies the binary-proven
Q scaling before the dot product. Every inference report explicitly sets
`original_gpu_parity_verified: false`.

Ten tests pass in the isolated environment, including all original matrix
checksums, independent packing fixtures, malformed metadata/bounds rejection,
norm/RoPE math, original-weight positive/negative output, and agreement between
batch prefill and incremental cached execution. Real-model tests require the
explicit `FORESIGHT_ORIGINAL_QUERY_MODEL` environment variable. The tested
environment uses NumPy 2.5.1 and SentencePiece 0.2.1. The packaging dependency
locks now include both dependencies.

## Selected cache precision

The logged `int8_kv_cache: true` option does **not** quantize this model's cache.
The original cache descriptor selects uint8 only when
`(apply_srq && int8_kv_cache) || force_int8_kv_cache`. The selected model logs
`apply_srq: false` and `force_int8_kv_cache: false`, so that predicate is false.
The original configuration printer binds those flags to offsets 408, 410 and
411; the recovered protobuf serializer also binds offset 225 to field 41,
`apply_srq`. This rules out adding speculative int8 cache quantization.

The false branch uses builder offset 3024, initialized by
`DeduceDataTypeFromPrecision`. That function maps F32 to float32 and the other
calculation precisions to float16. The retained original run explicitly selects
`CalculationsPrecision::F16`. Selected V1 `AddValuesToCache` performs typed
reads and linear cache writes, with no extra quantization operation. The CPU
executor now stores K/V as **float16**, then lifts them to float32 for its
remaining attention calculations. Reports explicitly include
`cache_storage: "float16"`; this does not claim all operations run in float16.

Canonical traces include `detector-gpu-v1-add-values-cache.json`, the K/V cache
descriptor files, `detector-cache-runtime-flag-print.json`,
`detector-cache-calculation-dtype-binding.json`, and
`detector-cache-dtype-from-precision.json`. The original run's retained `run.stderr`
contains the actual flags and F16 calculation choice. Earlier float32-cache
reports remain unchanged. Fresh `original-query-float16-cache-paired-cases.json`
re-executes the corrected CPU model against nine retained original outputs;
all nine agree after the recovered output trimming. Both raw outputs remain in
the report, including the original decoder's leading spaces.

The cache regression checks float16 storage in all 18 layers, exact retention of
old cache rows while new tokens append, agreement of the greedy choice, and
bounded prefill/incremental logit differences. Float16 storage can amplify tiny
BLAS grouping differences across a rounding boundary, so those logits are not
expected to be bit-identical. Fourteen Python tests pass with original-weight
execution enabled, including these cache checks and the worker protocol tests.

## Application worker and registration

`tools/legacy_query_worker.py` loads the SHA-identified asset once and accepts
serial JSON-line requests. Each generation resets the KV cache. Requests carry
an owned ID, the already-prefixed raw prompt, and an output limit up to 512;
the executor also enforces the original 512-token context. Frames are bounded
to 1 MiB. Its ready/result frames identify the float32 CPU backend and explicitly
leave original GPU parity unverified.

`DedicatedQueryRuntime` owns a separate worker process. Cancellation and timeout
terminate only that owned process, including during model loading. Idle close
sends EOF with a bounded shutdown deadline; active close kills and reaps the
worker. Canceled workers cannot deliver responses or decoder errors to a later
worker. The application passes decoded output unchanged to the existing
`ReferenceQueryDetector`, whose recovered parser sanitizes and trims individual
questions. The worker does not fabricate the original decoder's leading spaces.

Use the existing `models.register` service operation with kind
`query-detection`, backend `legacy_query_cpu`, the authenticated local model
`path`, and Python interpreter/launcher `runtime`. The packaged resource map
supplies `FORESIGHT_QUERY_WORKER`; it uses the same resource configuration and
model database as other runtimes. No separate project configuration is needed.
Registering the dedicated interpreter records package ownership for relocation.
The model itself is not shipped or automatically acquired by this integration.

Four Python protocol tests cover exact prefix/output handling, malformed and
oversized frames, output bounds, and recovery after context failure. The actual
isolated `-I -B` worker was also run with the original weights and produced
`What risks could delay the launch?` followed by EOS. Six Dart process tests
cover reuse, exact whitespace, request ownership, cancel/restart, malformed and
unterminated oversized output, timeout, active close and graceful idle EOF;
PID liveness checks confirm no owned process remains after cancellation/close.
Application tests cover the dedicated answer pipeline and missing-model failure
without chat substitution or cursor advancement.

## Remaining fidelity work

Float32 CPU execution changes the original packed-int8 GPU arithmetic. The
original Metal runtime uses F16 calculations and cache storage; this worker
now matches the cache storage type while its other operations remain float32.
Matching selected question outputs does not establish numerical parity. GPU
operation precision, reduction/rounding, GELU implementation,
and broader tokenizer/session/output comparisons remain relevant.

Dedicated model acquisition and persistence still need a supported installation
path. A native XNN or Metal port can reuse the verified matrix loader and
topology, but requires additional execution work; building an older public
factory unchanged or wrapping the zero-operator file does not supply that graph.
