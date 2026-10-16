# Dedicated detector model and raw-session implementation

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
REA captures use IDA Pro, the matching snapshot reader and bounded parsing of
public protobuf descriptors embedded in that executable. No model key or API
credential was extracted, and no original model was decrypted or downloaded.

## Recovered contract

| Layer | Observed selection |
| --- | --- |
| App model kind | 4, MODEL_TYPE_QUERY_DETECTOR |
| Native architecture | 35, LLM_MODEL_TYPE_GEMMA4_200M |
| Local persistence policy | Encrypt type 4; the downloaded bytes pass through the encryption service before persistence |
| Native options | model path; model type 35; empty LoRA path, rank 0; temperature 0; top_k 1; max_tokens 512 |
| Native sampler | TOP_K, k at least 1, temperature falls back to 0.3 when nonpositive |
| Prompt components | Empty system/context; $CONTEXT$ and $USER_INPUT$ placeholders |
| Prepared input | Literal ` <ctrl1>` followed directly by the prepared transcript |

These app-kind and native-architecture enums are separate. The embedded
TextCacheEngineOptions descriptor explicitly names model_type as
`.odml.infra.proto.LlmModelType`; enum value 35 names GEMMA4_200M.
The descriptor is at file offset 0x6590f9d; the enum starts at 0x6593fc7.
SamplerParameters at 0x658edd0 binds type 1 to TOP_K, 2 to TOP_P and 3 to GREEDY.

The matching snapshot's PP[11905] is the model encryption map. It maps type 4
to true, alongside ASR and word extraction; embedding and the listed Gemma chat
models map to false. The downloader defaults an absent kind to true. PP[25010]
is `CreateTextCacheTask`, binding the Dart `_CreateTextGenerator` wrapper to
the native text-cache C API at 0x1001fe03c.

TextCacheTaskImpl::Create (0x1001fe1fc) copies the 64-byte C options into typed
engine and prompt components. CreateLlmEngine (0x101b79ac0) copies model_type
into an optional settings field and sets its presence flag. **That flag is not
a CPU selector.** The original executor backend is resolved later through
settings/model metadata and remains unbound by this trace.

TryInitialize (0x101b7a1e4) creates the base session and optional system context.
PerformInference (0x101b7a9d8) can update cached context, clones the base session
(vtable offset 120), substitutes prompt components, adds the user prompt with
AddQueryChunk (offset 24), and predicts (offset 72). The detector's context is
empty, so its base does not contain earlier detector inputs. The original C
input uses strlen on UTF-8 strings. This establishes raw text-cache generation,
separately from the app's selected chat conversation.

## Implemented worker primitive

Both inference workers now accept `--query-detector`. They use a raw public
LiteRT session, disable the chat template, omit system/history/tools/schema,
and use the fixed 512-token setting. Input is already prepared by the caller;
the mode adds no prefix. C API objects are freed on success and failures. Empty
text is accepted; missing candidates and failed prefill/decode propagate.

This mode currently forces CPU as a **port testing choice**, independently of
the chat backend. It is not a claim about the original backend. The original
architecture-35 override is also not exposed by the pinned public engine API;
that API relies on compatible model metadata. Compatibility with the decrypted
original TFLite asset has not been demonstrated.

LiteRT 0.18 declares TOP_K in its public header but the installed runtime rejects
it at decode with `UNIMPLEMENTED: Sampler type: 1 not implemented yet.` The port
uses supported TOP_P with k=1 and p=1, retaining one candidate, and temperature
0.3. This is an explicit public-runtime adaptation; original-model comparison,
including tie behavior, is still required.

The Application detector callback remains unchanged and still uses the generic
chat path. This worker primitive does not complete production detector parity.
Required next work: acquire a usable dedicated asset, bind the original executor
selection/legacy model settings, verify raw generation against the original,
and connect the dedicated runtime to the existing ReferenceQueryDetector.

## Validation and limitations

13 Python runner tests pass, including raw input/Unicode/NUL handling, sampler
settings, empty and missing candidates, prefill failure and native-resource
cleanup. The native raw probe compiles on macOS against the pinned C declarations.
Four native CTest groups pass. Full Linux inference compilation remains separate.

A real-library diagnostic ran both raw implementations with the installed E2B
model and returned identical ` Paris.` completions on CPU. Its engine context
was explicitly 4096. The same E2B diagnostic at 512 failed while preparing the
model's prefill tensor shapes; the production detector setting was not enlarged.
This E2B run validates the raw API path only, not detector semantics, dedicated
model compatibility or original output parity. Reports retain that distinction.

Reproduce a raw runtime comparison with a compatible local asset:

```sh
python3 tests/inference/test_raw_query_model.py \
  --model MODEL --native-probe BUILD/native_raw_query_probe \
  --python LITERT_PYTHON --library LITERT_LIBRARY --report REPORT.json
```

The default diagnostic context is 512. `--context` allows testing a different
model's runtime requirements and does not change the production mode.

## Retained evidence

Raw JSON, logs and the REA session bundle are retained under ignored
`test-results/reference-functions/ida`; runtime reports are under
`test-results/reference-functions/query-runtime`.

- `ev_b50a02724c871b41b31463667ae81c75d257fe4655741c2db50c06d98461edc2`:
  type-4 encryption policy and native symbol binding.
- `ev_bb6ef6120e4b5bae290921dfe5416f77d2ac080568be245fb0d2ccebfb1cd876`:
  embedded model-type enum, including value 35.
- `ev_fd19fda1b2e597201ab1394c681995f8863b1047c4ce36e2d6dc213a5ae83f9b`:
  typed TextCacheEngineOptions descriptor.
- `ev_4371b89156f6b35f0a848d6b431a0d017b6129c46478316af8469fc54fec0ece`:
  original and public sampler enum descriptors.
- `ev_42c3bdf73f02797691296950641644b1fcaa25bc2940e77bc539e57707002597`:
  native C options transfer, engine settings and downloader save arguments.
- `ev_2f634341b90502c4e2fc975ef92ba97e28ffa26b7d5255c3562a0edf065f4386`:
  initialization, generation input and initial inference page.
- `ev_4a9405bbcc61a65592602efa80ee55ae7b30fab2c6cac51b280c477715e9b45b`:
  subsequent engine-factory pages; backend resolution still needs focused tracing.

A supplementary capture produced the remaining inference page and common session
config, but REA reported incomplete process-ownership verification at cleanup.
Its retained files were read without repeating the analysis. The dispatcher log
reported IDA closed 0/all sessions closed, and an independent process inventory
found no corresponding IDA worker. This does not override REA's wider cleanup
uncertainty. No unrelated process was terminated.
