# Production model and packaged runtime acceptance

This work exercises the public assets selected by application setup, rather than
the tiny LiteRT SDK test model. The production probes use Gemma 4 E2B
(`181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`)
and EmbeddingGemma 2
(`e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c`).
These public conversions are not asserted byte-identical to the original
Foresight service's encrypted assets. No original credentials or user profile
are used.

## Failures found in actual artifacts

Fresh macOS package assembly rejected the helper because its load commands
required macOS 26, while the application declares macOS 15 support. Setting
`CMAKE_OSX_DEPLOYMENT_TARGET` after `project()` had preserved CMake's already
initialized host default. The common initialization now supplies the supported
environment fallback before compiler initialization. Explicit cache, environment
and toolchain targets retain precedence. Six fresh CMake configurations verify
the default and overrides, including a toolchain that specifies no OS target.

The linked Linux x86-64 worker loaded the actual Gemma 4 E2B production model,
but its capability probe reported `native_stop_token_sequences: false`. This
was the stock checksum-pinned 0.18.0 library selected by the release Dockerfile.
Actual EmbeddingGemma document/query inference also produced finite normalized
768-dimensional vectors. The package acceptance then correctly failed the
missing note-enhancement capability. Release SDK assembly now builds the pinned
source extension, retains the passing native regression log and wheel, and
passes their verified manifest and library to the application packager. The SDK
cache identity includes both the extension builder and source patch.

The first source-built macOS package hung before embedding model loading.
An owned process sample showed protobuf descriptor initialization blocked in
Abseil's shutdown mutex during `dlopen`. Importing the Python modules alone did
not reproduce it. Constructing a real SentencePiece processor before loading
the C API did; loading the C API first did not. The upstream macOS shared-library
link exported statically linked protobuf/Abseil dependency symbols. The source
patch now restricts its exported symbols to the public `litert_lm_*` C API;
Linux retains its existing internal `-Bsymbolic` binding. This fixes the native
library boundary rather than depending on a particular adapter import order.
The package capability probe now initializes a tiny real SentencePiece model
before loading the C API, with a native 15-second alarm. The previous package
fails this automated regression with SIGALRM rather than hanging indefinitely.
`tools/test_packaged_sentencepiece_coload.py` checks both initialization orders
in separate minimal-environment processes. The extension builder also audits
the actual macOS exported symbol inventory and retains it with the manifest.

The first GPU probe after the export fix reached native engine initialization
and exposed another packaging defect: the source wheel omitted the Dawn
dependency of the WebGPU accelerator, and the Metal accelerator and sampler
were absent. The dependency audit had also accepted a nonexistent `@rpath`
candidate under `/usr/lib/swift` as a system library. Source wheels and verified
manifests now include five Linux or seven macOS vendor libraries, and the audit
rejects missing runtime candidates.

After that closure correction, actual GPU embedding exposed a C++ callback ABI
mismatch: the vendor caller expected an Abseil `Status` in the return register;
the source callee expected indirect return storage and wrote into executable
memory. A real cross-DSO regression reproduced SIGBUS with the old headers and
passed with the exact private patched headers. A separate macOS arm64 patch
enables Clang's trivial ABI consistently across source-built Abseil translation
units. Its hash and the passing actual-header ABI report are retained separately
from the common Linux source patch. The final production GPU probe below passed
after the coherent rebuild. See [GPU closure and ABI evidence](reference-gpu-runtime-closure.md).

## Observed artifact results

The final complete macOS development bundle is
`/tmp/foresight-production-package-abi-aligned/Open Foresight.app`, with package
source revision `29345c1` and helper build stamp `ee4053d`. Dart/helper product
sources are unchanged across those later SDK/tooling commits. Its source SDK
uses the common patch `ec332aa6a6d2a48a3ef71f73778b39421f2a66acef779e378a1e3d6688c0a2ab`
and macOS ABI patch `dfee6ea34d3df727686d23d266d17d58469a45180b07fd4e4ec2750608e02f66`.

| Verified artifact | Observed result | Primary evidence |
| --- | --- | --- |
| Final macOS GPU workers | Actual document/query embeddings are finite, normalized and 768-dimensional; two retained-worker Gemma requests answer 4; native stop capability and clean graceful exits pass. | Integration worktree: `macos-gpu-abi-aligned/report.json` |
| Final macOS CPU workers | The same production model, embedding, protocol and shutdown checks pass independently on CPU. | Integration worktree: `macos-cpu-abi-aligned/report.json` |
| Final macOS initialization and source SDK | Both SentencePiece/C API load orders exit zero with clean stderr. Native config-copy test, actual-header cross-DSO callback and C API-only export audit pass. | Integration worktree: `macos-coload-abi-aligned/report.json`, `macos-extension-abi-aligned/build-manifest.json` |
| Final all-GPU packaged Application | Real AOT MCP/service, helper GPU embedding/tokenizer and GPU generation save Tuesday then Friday notes after an exact saved transcript correction, without forced regeneration. | Runtime-validation worktree: `macos-application-all-gpu-abi-aligned/report.json` |
| Linux x86-64 native runtime subset on Ubuntu 24.04 | Actual CPU document/query embeddings and two Gemma requests pass, native stop capability is true, and all workers exit gracefully. All 11 staged ELF files pass glibc 2.39/GLIBCXX 3.4.33 limits. | Runtime-validation worktree: `linux/ubuntu24-cpu-final/report.json`, `linux/final-abi.json`, `linux/extensions-final/build-manifest.json` |

All evidence paths in the table are beneath the respective worktree's ignored
`test-results/production-runtime` directory. The final macOS C API SHA-256 is
`913afbad6070e6ce272ead4695e14da37f7fa4cd3337fb0f1306db53f827a19d`;
its wheel SHA-256 is
`78b6faf8b542b659f454179d0b22627660625493266050b52df896f6093993d3`.
The final Linux C API SHA-256 is
`936a2ed8fbc28ce92d6d5677a0e2f51c713e7a43483f0446779e89623eb9256b`;
its wheel SHA-256 is
`ecc7b7e6cc91875140192d23a91c28bd00fbc2ad8816be1224330e0ce4253006`.
Manifests retain the individual vendor hashes and passing native regression log.

The all-GPU Application's accepted primary bullet changes from “Mira will send
the draft on Tuesday” to “Mira will send the final draft on Friday, as this is
the final deadline.” Artifact IDs and input revisions advance from 1 to 2, and
the exact correction is present in the saved transcript. The helper reports a
ready GPU pipeline and tokenizer. The service stops gracefully, and all processes
from that bundle are verified absent. A preceding mixed CPU-embedding/GPU-generation
scenario also passed on artifact `08c3bfe`; it is retained as separate evidence.

The Linux subset uses the actual repository CMake inference target with pinned
SentencePiece/FlatBuffers, private ICU/ONNX and the verified five-vendor SDK
closure. It was compiled using GCC 14 in Debian under Rosetta, then executed in a
separate minimal Ubuntu 24.04 container with GLIBC `2.39-0ubuntu8.9`. It is not a
complete GUI/deb/rpm/Arch artifact. Native regression and wheel both exit zero;
Linux `--force_pic` lets those stages use the same PIC runtime objects.

An earlier, distinct development artifact (`b3df3d3`, before the ABI rebuild)
passed `macos-smoke-fixed.json`: relocation into a path containing spaces,
two AOT MCP clients sharing one owner, restart persistence, stale graph rejection,
PDF/RTF extraction, verified stop, idle atomic upgrade, rollback and maintenance
exclusion. That smoke does not load models; the final worker and Application
reports above supply production inference evidence.

## Repeatable acceptance

`tools/test_packaged_model_runtime.py` requires the exact production model hashes
and package-owned executable paths. It runs the package's embedding and generation
workers with a disposable home/cache, a working directory containing poisoned
Python modules, and an environment without checkout/SDK paths. It checks:

- Real document and query embeddings with finite normalized 768-dimensional vectors.
- The actual loaded model's native ordered-stop capability.
- Two successful generation requests in one retained worker process, with native
  stop configuration accepted and arithmetic answer content checked.
- Protocol-only stdout, terminal acknowledgements and verified graceful exits.
- Failure stage, stderr and shutdown evidence, preserving the primary failure
  even if cleanup also fails.

For example, after moving the assembled application to the desired test path:

```sh
python3 tools/test_packaged_model_runtime.py \
  --bundle '/path with spaces/Open Foresight.app' \
  --generation /path/to/gemma-4-E2B-it.litertlm \
  --embedding /path/to/embeddinggemma-2-740m.litertlm \
  --backend gpu --output test-results/production-runtime/macos-gpu
```

Use `--backend cpu` separately; pass the portable bundle directory on Linux.
The probe checks that ordered-stop configuration is accepted. It does not claim
to observe a matching sequence terminating production decoding. The native
config-copy regression verifies that configured sequences survive the engine's
conversation configuration copy.

`tools/test_packaged_note_enhancement.py` additionally drives the actual AOT MCP
and Application service with a disposable synthetic profile. It configures the
production models through existing RPCs, requires embedding and tokenizer
readiness, and manually enhances a draft deadline from Tuesday to Friday after
a saved transcript correction. It checks the actual persisted output and newer
artifact input revision without forcing regeneration. Automatic live enhancement
is disabled in that profile so a timer cannot race the manual requests. Reports
retain both inputs, outputs and authenticated service shutdown evidence. This
is one explicit content scenario, not a general model-quality score.

## Verification boundary

The Linux CPU runtime subset has passed actual Ubuntu 24.04 execution and the
minimum-ABI audit. The complete GUI and deb/rpm/Arch installation matrix remains
an independent release CI gate.
The Linux GCC/prebuilt GPU callback boundary has not been exercised. The
macOS-only Status ABI fix does not establish Linux GPU ABI compatibility, and
no equivalent Linux defect is claimed from the macOS failure.

The locally assembled macOS artifact includes the standalone Python prefix and
verified source-built extension. At this acceptance checkpoint, CI archived a
native-only app, so these historical local results did not validate that CI
artifact. The subsequent complete-runtime CI path is described in
[macOS support](macos-support.md): it supplies Python/LiteRT and Whisper, checks
the packaged closure, and adds real CPU model acceptance before release archiving.
Its run results remain separate from this retained local artifact evidence.

The tested macOS artifact is an ad-hoc development package. A successful local model
probe does not establish Developer ID signing, notarization, quarantine behavior,
physical capture permissions, a clean-user install, macOS 15 runtime execution,
or the larger E4B/12B model variants. Those remain separate release gates.
Vision startup/model refresh remains deferred and is not changed here.

Raw reports, model-worker stderr, process samples, native build logs and package
audit output are retained outside sealed bundles under the ignored
`test-results/production-runtime` tree and `/tmp/foresight-production-assets`.
Raw generation can retain model `<turn|>` markers; these probes do not establish
polished general answer rendering or matching-sequence production termination.
All acceptance workers exited before teardown. The owned Linux build JVM ended
as a zero-RSS zombie; its shutdown client reported 36 because container PID 1 did
not reap it. That cleanup status is retained separately from passing inference.
Both disposable containers were then stopped after copying evidence, preserving
their filesystems, images and build cache. No whole-app parity completion is claimed.
