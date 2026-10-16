# Original dedicated detector: legacy execution

The authenticated original detector now executes through an isolated CPU
diagnostic using its own weights and vocabulary. This does not establish
numerical parity with the original GPU executor, and production automatic Q&A
has not been switched to this diagnostic.

The exact asset SHA-256 is
`889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f`.
The loader rejects a different asset. No model download, credentials, keychain
operation, original-app execution, or IDA session was performed for this work.

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
  normalizes by clamped RMS and multiplies by **1 + stored scale**. This matters:
  the detector's post-normalization and Q/K scale tensors contain zeros.
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
`original-query-numpy-cases.json`. Every inference report explicitly sets
`original_gpu_parity_verified: false`.

Eight tests pass in the isolated environment, including all original matrix
checksums, independent packing fixtures, malformed metadata/bounds rejection,
norm/RoPE math, original-weight positive/negative output, and agreement between
batch prefill and incremental cached execution. Real-model tests require the
explicit `FORESIGHT_ORIGINAL_QUERY_MODEL` environment variable. The tested
environment uses NumPy 2.5.1 and SentencePiece 0.2.1; the packaged runtime already
has SentencePiece but currently lacks NumPy.

## Remaining fidelity work

Float32 CPU execution changes the original packed-int8 GPU arithmetic. Original
GPU RMS epsilon/rounding, GELU implementation, local/global layer placement,
tokenizer/session boundaries and output behavior still require direct reference
comparison. Public legacy XNN math is an explicit diagnostic adaptation until
that comparison is established. The current successful CPU output proves the
weights can execute; it does not prove exact original GPU behavior.

Production integration also needs reproducible dependency packaging, cancellation
and worker ownership, dedicated model acquisition/persistence, and controlled
runtime/output comparisons. A native XNN or Metal port can reuse the verified
matrix loader and topology, but either requires additional execution work;
building an older public factory unchanged or wrapping the zero-operator file
does not solve those requirements.
