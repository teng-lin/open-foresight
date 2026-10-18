# Native inference

`foresight-model` is a C++ worker shared by the retrieval helper and native
generation adapter. Linux and macOS build the same C++ worker for generation,
embedding and grounded citation checks through the LiteRT-LM C API. macOS
bundles native dylibs and the `foresight-query` dedicated legacy CPU detector;
no Python interpreter or inference scripts are included in the Mac application.
The optional Linux legacy query package can still use its explicitly supplied
Python diagnostic runtime.

- LiteRT-LM 0.18.0 uses Google's public C API for Gemma generation and
  EmbeddingGemma 2. Engine configuration, streaming, structured JSON, bounded
  output, citation checks, numeric fidelity, evidence selection, repair,
  independent support verification and attributed fallback run natively.
- SentencePiece and verified FlatBuffers metadata replace Python tokenization
  and model-header parsing. Embedding task prefixes, special tokens, 768-element
  L2 normalization, 512-token chunk averaging and the checksum-specific reference
  preprocessing convention are preserved.
- Embedding models must be `.litertlm` files. Other formats and model directories
  report an unsupported model format error.
- Generation keeps the existing separate-process boundary. The application
  service owns its process group, cancellation and timeout. Desktop and MCP
  continue using that same service. No model or runtime download happens inside
  the inference worker.

## Build and package

Build dependencies include OpenSSL and ICU development files. CMake fetches
pinned SentencePiece 0.2.1 and FlatBuffers sources; cached/offline sources can be
supplied with the standard `FETCHCONTENT_SOURCE_DIR_*` CMake options. Public
LiteRT headers/licenses are under `third_party`.

```sh
python3 tools/prepare_litert.py build/lib/liblitert-lm.so
./tools/build.sh
python3 tools/package.py --generation-backend gpu
```

Preparation verifies pinned archive and library SHA-256 hashes. LiteRT's Python
wheel is used only as a transport for its standalone C shared library. No Python
files are extracted. Packaging checks the native library hash, includes the
required native dependencies and licenses, and sets worker/library paths
relative to the bundle.

For source builds the worker also finds libraries under `build/lib`. Explicit
paths are available through `FORESIGHT_LITERT_LIBRARY` and `FORESIGHT_MODEL_WORKER`. `FORESIGHT_LITERT_RUNNER` overrides old registered
LiteRT runner paths when restoring a packaged profile.

## Existing installations

Stop the existing application service before launching an upgraded bundle, so
clients connect to the new owner. Existing `.litertlm` model files remain usable. LiteRT embeddings retain their
identity and preprocessing fingerprint; CPU/GPU identity boundaries remain
separate. Packaged generation restores through the bundled native worker even
when the profile contains an obsolete Python runner path.

Embedding model setup accepts `.litertlm` bundles on CPU and GPU.

## Verification

`native_grounding_test` replays the former grounding regression cases with a
controlled native generator. `helper_model_lifetime` uses a compiled fixture to
check creator-thread retirement, closed frontend stderr, worker death, forced
cleanup and parent death. Existing helper, FFI and service/MCP tests remain in
place.

`tools/test_native_inference.py` exercises real models with an empty executable
PATH, so inference cannot discover Python or shell commands. The native checker
also runs the shared adversarial corpus in `tests/inference/grounding_cases.json`.
Real-model reports go under ignored `test-results`.

Verified on the implementation host with CPU and GPU EmbeddingGemma bundles,
GPU Gemma E2B, service/MCP restoration and a relocated desktop
bundle. Other Gemma sizes and independent clean machines require their own
acceptance checks; the port does not establish new GPU/model compatibility.

## Platform integration review

The worker resolves executable paths through the shared Linux/macOS process
adapter and writes its protocol to an owned POSIX descriptor without `/proc`.
macOS library discovery uses `.dylib` names; explicit library paths also work.
Finder resource configuration selects the native runner and forwards LiteRT
library paths into native subprocess launches. macOS helper launch continues to
use the owned supervisor and close-on-exec safeguards from the application core.
Both release packagers select the verified source-built native library. Mac CI
checks the assembled application with an isolated environment. Real-model
acceptance remains a separate gate requiring explicit model fixtures.

## Conversation context admission

Chat/tool conversations reject input estimated above 4096 generation-model
tokens without reserving the full output allowance plus 256 tokens in advance.
The native engine context and output cap still apply. The helper tokenizer and
generation tokenizer serve different models. The separate grounded-generation
path retains its input/output reserve check. Exact original native accounting
remains unverified.

Experimental `--query-detector` mode uses a raw session with no chat template,
system instruction, tools or schema. Its fixed 512-token setting and single
candidate sampling follow the recovered detector options. CPU is currently a
port testing choice; dedicated-asset compatibility and production integration
remain unverified.

## Persistent tool worker

The shared generation worker advertises `{"worker_protocol":1}` from `--probe` and
accept `--serve --model MODEL`. They retain one engine until `shutdown` or input
EOF. The first protocol line is `ready 1`. Request IDs are positive monotonically
increasing integers, with one request active at a time:

```text
generate N {"prompt":"...","tools":{"tools":[],"system_message":"","delegate_tool_detection":true},"max_output_tokens":256}
reply N {"finish":true}
cancel N
shutdown
```

Plain, schema-constrained and grounded requests use the same worker with a `schema` field (or `null`) instead of `tools`. Their streamed chunks use `N text <JSON string>`; JSON strings preserve embedded newlines. Grounded answers emit only their final verified result. Grounded evidence selection and verification reuse that worker’s loaded engine.

Responses for tool conversations are `N delta|model|tool|answer <JSON>`, optionally
`N error <JSON string>`, followed by `N done completed|cancelled|failed`.
`model` remains the complete authoritative response used for delegated tool
parsing; `delta` carries unparsed structured partial model text. `reply` keeps
its existing delegated control or user-message payload. The sole input reader
routes replies by ID and cancels native generation while the request thread
waits for a stream or a tool result. Stale controls cannot reach another request.
Terminal `done` is emitted after closing the request conversation. EOF and
shutdown cancel the active request and release the retained base and engine.

The retained base follows the original empty-history clone path recovered at
`0x10091ee60` and `0x10091f3c4`; send closes its working clone at `0x10090b59c`.
A matching tool/system/output configuration reuses one untouched base by calling
`litert_lm_conversation_clone`. Requests with replayed history create a fresh
conversation. Plain empty-tool summaries also create a fresh conversation and
preserve the existing chat base. Generated turns and retrieved prompt context
are never promoted into that base.

LiteRT-LM 0.18 creates this configured base lazily: real probes observed zero
prefilled tokens until a message is sent. Retaining the engine and reproducing
base cloning therefore does not establish an initial-prefix KV speedup. A
separate already-prefilled fixture confirmed that the native clone API copies
KV state and isolates canceled/generated clones. No synthetic warmup message is
sent. Both platforms use the same typed C API clone function.

Validation includes routed-reply/cancellation/disconnect fixtures in
`tests/inference/tool_conversation.cpp`, base replacement/history/summary and
native cancellation fixtures in `tests/inference/tool_conversation.cpp`, and an
ignored real GPU report at
`test-results/reference-functions/streaming/persistent-worker-report.json`.
The real report used one worker for two isolated requests, canceled a third
request during streaming, and successfully generated a fourth before shutdown.
The C++ translation unit and protocol fixtures are checked on the Mac host;
full Linux model execution requires its own platform acceptance run.
