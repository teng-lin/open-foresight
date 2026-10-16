# Native inference replacement validation

The implementation replaces distributed Python inference with a compiled C++
worker. Python remains available to developers for builds, model provisioning
and independent regression oracles. Runtime/model provisioning and migration
commands are documented in [native inference](../services/inference/README.md).

## Verified behavior

- Four CTest targets pass: helper contract, compiled model-worker ownership,
  native grounding, and the generation/speech/capture FFI lifecycle.
- Six Dart core tests and static analysis pass.
- 132 Flutter tests pass; nine environment-dependent tests are skipped in the
  ordinary suite. Flutter static analysis and the Linux release build pass.
- All eleven application-service/MCP subprocess tests pass, including the
  dedicated headless native desktop/MCP integration.
- Fifteen Python regression tests and nine subtests pass. Retired inference
  implementations are test-only reference oracles under `tests/reference`.
- The opt-in Gemma E2B desktop acceptance passes native loading, factual answers,
  detailed three-step procedures, numeric/date/dose/range fidelity, independent
  support checks, insufficient context, cancellation and subsequent reuse.
- Seventeen-request native/Python embedding comparisons cover encoding,
  decoding, empty input, Unicode and long inputs across raw/query/document
  tasks. Public EmbeddingGemma CPU/GPU and the checksum-specific reference
  bundle GPU have zero observed vector difference. MiniLM ONNX CPU differs by
  at most 1.92e-7 per component; tested tokenizer outputs and identities match.
- Real service/MCP generation, indexing and restart restoration pass with a
  PATH containing only bash, dirname, chmod, stat and id. Python and python3
  are unavailable to the application. Obsolete registered Python generation
  paths restore through the bundled native worker.
- A bundle relocated to a path containing spaces, launched from `/`, passes
  desktop startup, linkage, helper readiness, same-profile desktop/MCP ownership
  and independent headless MCP startup. It contains no Python files or
  interpreter linkage; the native runtime probe passes.

Local reports are generated under ignored `test-results/`: `ctest.log`,
`flutter-tests.log`, `service-tests.log`, `native-flutter-gemma.json`,
`native-*-parity.json`, `native-service-mcp-no-python.json` and
`relocated-bundle.json`. Synthetic profiles and a dedicated headless compositor
were used; no user profile or account data was used by these checks.

## Compatibility and limits

LiteRT-LM 0.18.0 and ONNX Runtime 1.31.0 Linux x86_64 libraries are provisioned
with pinned archive and extracted-library hashes. Package assembly validates
those hashes and includes native dependencies and license notices.

The inspected Gemma E2B and embedding models were already local. This does not
establish E4B/12B fit, every GPU backend, equivalence to encrypted Mac weights,
or behavior on an independent clean machine. Directory-model compatibility is
uncased BERT WordPiece plus mean pooling with an ONNX export; arbitrary Python
SentenceTransformers architectures are not supported. Existing MiniLM users
provision the pinned export and re-register once, causing an atomic index
rebuild. Existing `.litertlm` model files retain their preprocessing identities.

The detailed procedural fixture also exposed an uncited completeness conclusion
in the former Python pipeline. The native prompt/repair instructions explicitly
require citations for limitations and prohibit unsupported completeness claims;
strict validation and attributed fallback remain enabled.

## Integration review against macOS platform support

After incorporating main's macOS process/ownership and resource configuration:

- Linux: six native CTest targets, sixteen core tests, 135 Flutter tests (ten
  opt-in skips), all eleven service/MCP tests (including the isolated native
  desktop integration), and static analysis pass. Real GPU generation, a
  sixteen-token output budget, structured JSON,
  cited answers and seventeen embedding/tokenizer requests pass through the
  portable descriptor protocol.
- Apple Silicon Mac: `foresight-model` and `libforesight_native.dylib` compile;
  native grounding, protocol and helper-worker lifetime/parent-death/launch-race
  tests pass.
  An unconfigured worker emits valid error JSON without `/proc`. This does not
  validate real-model Mac inference or distribution packaging.
- Review fixes preserve Mac supervisor ownership and launch serialization, use
  portable executable/library paths and protocol descriptors, propagate native
  library configuration from Finder resources, retain compiled fixture PID
  reporting, and make repeated helper shutdown share one termination future.
  Unknown citations are rejected even in headings and citation-only blocks;
  oversized complete evidence falls back to attributed excerpts without losing
  rows or numeric ranges. Small output budgets use a proportional safety margin,
  and packaging checks for both native runtime files before hashing them.

Review reports are under `test-results/merge-*`; the Mac source/build was
isolated in `/tmp/foresight-pr1-native-review`, with no changes to another checkout.
