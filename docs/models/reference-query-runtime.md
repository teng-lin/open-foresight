# Dedicated detector model and raw-session implementation

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
REA captures use IDA Pro, the matching snapshot reader and bounded parsing of
public protobuf descriptors embedded in that executable. The installed detector was authenticated and decrypted locally using only its
exact model-key entry, without prompts or keychain changes. No API credential
was accessed; key material was never logged or persisted.

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
settings/model metadata. The recovered legacy asset declares `backend=gpu`;
the metadata resolver maps that string to legacy backend 2. The port worker
selection now follows that GPU setting.

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

This mode selects GPU from the recovered dedicated asset contract, independently
of the chat backend. The architecture-35 override is not exposed by the pinned
public engine API. Both public workers reject the original legacy TFLite asset
with `INVALID_ARGUMENT: Unsupported file format`; they cannot yet execute it.

LiteRT 0.18 declares TOP_K in its public header but the installed runtime rejects
it at decode with `UNIMPLEMENTED: Sampler type: 1 not implemented yet.` The port
uses supported TOP_P with k=1 and p=1, retaining one candidate, and temperature
0.3. This is an explicit public-runtime adaptation; original-model comparison,
including tie behavior, is still required.

This public-SDK primitive was an intermediate diagnostic. Production now uses
the reconstructed legacy worker through ReferenceQueryDetector, as described
below; the generic chat detector path has been removed.

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
  --python LITERT_PYTHON --library LITERT_LIBRARY --backend gpu --report REPORT.json
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

## Authenticated installed asset and legacy loader boundary

The public app configuration lookup selects `prod`, then only
`encryption_keychain_service_name`, giving
`com.google.AIEdgeForesight.encryption`. Native code retrieves account
`dataEncryptionKey` as a generic-password item and deserializes a binary Tink
keyset. It creates AES-256-GCM keys only when no key exists; the diagnostic never
calls that creation path.

`tools/decrypt_reference_detector.swift` reads only that exact existing entry
with interaction disabled. Its controlled self-test verifies successful
authentication and rejection of corrupted ciphertext. On the installed asset,
authentication succeeded and yielded 179,437,568 bytes with TFL3 at offset 4,
SHA-256 `889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f`.
The diagnostic writes only a new mode-0600 model file under ignored evidence
output; it never writes keys or changes the installed asset. Its wire parser
follows the public [Tink keyset schema](https://github.com/tink-crypto/tink/blob/master/proto/tink.proto)
and [AES-GCM schema](https://github.com/tink-crypto/tink/blob/master/proto/aes_gcm.proto).

The model is a legacy weights container: model version 3, one `GEMMA4_200M`
subgraph, 490 tensors, no operator codes and no operators. Metadata includes
`odml.infra.proto.LlmParameters`, `spm_vocab_model`,
`odml.infra.LlmModelType` and `backend`. Its external buffers contain 116 bytes
of LlmParameters, 550,461 bytes of SentencePiece vocabulary, and the literal
`gpu` backend. Reading only the inline buffer vector gives empty values; the
external offset/size fields must also be followed. The empty inline-buffer
observation was superseded by this checked external-buffer read.

GetFileFormatFromFileContents (0x102c664b8) identifies TFL3 as format 0, ZIP as 1
and LITERTLM as 2. Consequently the modern formats' default-CPU branch does not
establish the legacy detector's backend. DeriveLlmModelSettingsStruct
(0x102c46788), recovered across three pages, reads legacy ModelData metadata;
`gpu` selects backend 2 at 0x102c47a94. This corrects the earlier diagnostic CPU
choice. Static metadata and dispatch establish selection. Later controlled oracle runs
observed the original Metal F16 runtime; see the legacy execution follow-up.

Both raw workers were attempted on CPU and GPU with the decrypted asset and the
unchanged 512-token context. Both fail at engine construction with unsupported format,
before prefill or inference. Reports and stderr are retained as
`query-runtime/original-query-raw-runtime.json*` and
`query-runtime/original-query-gpu-runtime.json*`. This is a verified loader gap,
not successful detector inference or output parity. The previous E2B CPU probe
remains a diagnostic of the raw API only.

Additional REA evidence:

- `ev_e27a217feab7e3fd5b571abea5528089d37469d04c67a300938343851bd2c345`: narrowly selected public model-key service configuration.
- `ev_89454a142daa64ae0d4e9d737d56aca2cd9a15da92f69fc8aa97f09122ace315`: controlled crypto/keyset self-test.
- `ev_480484654ea97b468f376bf61fab83b25af852db85e2c06f062bc9bdb7ea8dda`: authenticated dedicated asset and digest.
- `ev_b09a0cfa9881d9c3db87f8f4e65bbeabd84bef34203d45087edef8ef3416df3f`: bounded model structure.
- `ev_0ce3a5b0e0072c56684d2a8140e7b7bd4a8b8d488cb6bd7c41d37acf5fb48364`: external metadata buffers and GPU selection.
- `ev_5b977e6af4dea5b4117b1194c11aeb80e6229e2cbacf033d61239281750f1fcd`: both public raw workers reject the original legacy format.

## Legacy execution follow-up

An isolated original-weight CPU evaluator now executes this asset; see
[legacy detector execution](reference-legacy-detector-runtime.md). All 127 packed
matrices match their stored row checksums. A question-bearing transcript yields
a rewritten question, and a statement-only transcript yields empty/EOS. This
resolves the ability to execute the dedicated weights outside the original app.
Dependency packaging and production integration are now implemented through the
reconstructed dedicated CPU worker. Nine controlled parsed outputs agree with
the original Metal runtime. Original GPU arithmetic, complete detector output
parity and supported acquisition remain open. The public LiteRT workers still
reject this legacy container.


## Supported local import and acquisition boundary

The existing Local models screen now offers Automatic questions. It accepts an
already-decrypted dedicated asset and uses the bundled interpreter/worker without
a new project configuration. Setup checks the fixed 179,437,568-byte size and
SHA-256 above before starting the worker. The worker then authenticates/loads the
asset and completes a fixed harmless fixture before the existing model registry
is replaced. Failed verification or runtime startup preserves the previous
registration. The service's existing `models.register` operation routes
`kind=query-detection` through the same checks, with `backend=legacy_query_cpu`;
a caller-supplied digest cannot authorize a different model. Existing explicit
installed-model manifests may optionally include the same kind. This manifest is
not required for interactive import.

Automatic acquisition is now connected to this existing setup flow when the
distribution provides its shared web-content credential. It follows recovered
metadata selection, blob basename, range/retry and type-4 encryption policies,
then authenticates the supported model before registration. Encrypted models
reopen through owned private leases, retained until their worker exits. See
[acquisition implementation and verification limits](reference-model-acquisition.md).
Live service access, signed-app Keychain behavior and the original refresh/cleanup
policy remain unverified; local import remains available without a credential.
