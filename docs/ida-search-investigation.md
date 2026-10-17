# Original Foresight search investigation

Use REA with IDA Pro for further native reverse engineering, as requested by the user. Do not use Hopper.

## Evidence and current limits

The reference is `/Applications/Foresight.app/Contents/MacOS/Foresight`, SHA-256 `fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.

The existing static-string evidence identifies `handleGoogleSearch`, the `google_search` tool, `https://customsearch.googleapis.com/`, `customsearch/v1`, and the Dart Google APIs package. These identify a search implementation candidate, but do not establish the executed request path or how configuration is supplied.

The earlier assertion that users need a separate Google project configuration is unverified. Do not add that requirement to the product based on API documentation alone. Trace the original's client construction and configuration first, then reproduce its observed behavior.

## IDA session attempt

On October 16, 2026, the installed IDA Professional 9.3 library successfully initialized using an isolated Intel Python 3.13 environment under Rosetta. REA 6.3.0 was launched with an explicit `ida` provider and a headless IDA MCP registration. REA admitted the reference binary and returned its matching hash. The first `search_strings` request for `customsearch` timed out; it did not return search, xref, or decompilation evidence. Successful target admission alone does not establish successful IDA analysis.

Local diagnostic artifacts are `/tmp/foresight-ida-open.json`, `/tmp/foresight-ida-search.json`, and `/tmp/foresight-rea-ida-stderr.log`. The isolated registration is `/tmp/foresight-ida-registration.json`. These temporary files are not portable dependencies. The normal cleanup request was issued after the timeout; verify worker release before removing retained workspaces or retrying.

The execution service also intermittently refused to create commands with `Too many open files (os error 24)`. Resolve that execution limit and inspect the upstream worker diagnostics before repeating a large analysis.

The close request also timed out. A subsequent health request to the owned
loopback worker reported `status: busy`, `busy_tool: idb_open`; process sampling
showed continuing CPU use and a growing private database. The original REA
client and supervisor exited while that worker remained alive. Cleanup is
therefore unverified. Do not start duplicate analysis or remove its sidecars
before inspecting worker state. The retained workspace for this attempt is
`/private/var/folders/2c/mlyxj2757cb0mn64rs0xd65c0000gq/T/rea-ida-1NtJtI`.

## Bounded follow-up findings

The Mach-O symbol table retains these exact entry addresses for this hash:

| Symbol | Address |
| --- | --- |
| `SearchCallbacks.initialize` | `0x1008e568c` |
| `SearchCallbacks.handleGoogleSearch` | `0x1008e5a18` |
| `SearchCallbacks._summarizeLinkContent` | `0x1008e6494` |
| `SpeakerIdManager.getLabel` | `0x1006f6208` |
| `QueryDetectorOnDevice.detectQuery` | `0x1009f2a18` |
| `TextDeduplicator._normalizeText` | `0x1009f3a74` |
| Native `InputRecorder.setEchoCancellationEnabled` | `0x10038f7bc` |
| Native `InputRecorder.start` | `0x10038f918` |
| Native `InputRecorder.startInternal` | `0x10038fc20` |

These are symbol observations, not decompilation or execution evidence. Prefer
focused function requests at these addresses once IDA is ready. Addresses do
not apply to another executable hash.

A bounded byte-pattern scan also found two Google-key-shaped constants in the
shipped executable. Their values were redacted and were not copied into the
implementation. This makes bundled configuration a plausible explanation for
setup-free behavior, but does not establish which feature uses either constant.
No Custom Search identifier was found by the specific legacy numeric-colon
pattern used in that scan; this does not rule out other identifier formats.

## Next evidence required

1. Confirm the headless worker completes analysis and can return one known function.
2. Locate the search handler and follow client initialization, request construction, and response parsing through code and cross-references.
3. Determine whether configuration is bundled, derived, or supplied by another component; record the mechanism without exposing credentials.
4. Trace tool dispatch, result numbering, citation formatting, errors, and cancellation.
5. Implement and test those established behaviors. Mark remaining runtime questions explicitly.

## Analysis completed and focused function results

The retained worker subsequently reported `auto_analysis_ready: true` and
`hexrays_ready: true`. Both its private input and the installed executable were
rehashed and matched the reference SHA-256 above. Focused queries then completed
successfully through the upstream IDA MCP worker. REA process captures retained
those query results; these are **not** a successful response from the timed-out
REA native adapter. Raw redacted IDA responses and the exported REA evidence
bundle are under ignored `test-results/reference-functions/ida/`.

- `SearchService.initialize` (`0x1008e56dc`) constructs an API-key client and a
  Google `CustomSearchApi`. `clientViaApiKey` (`0x1008e57d0`) loads the key input
  directly from a compiled Dart object-pool entry before URL-encoding it. This
  establishes bundled configuration for this path, rather than a user project
  setup flow. REA capture: `ev_7a571db3a78cb623eb3156f4cf4724de8be52a6d021d638024018406e457dead`.
- `SearchService.search` (`0x1008e7a8c`) lazily initializes the API, calls
  `CseResource.list`, and applies a timeout. The specialized list method requests
  ten results. `handleGoogleSearch` takes the first three, summarizes their links
  concurrently, and falls back to snippets for results without a summary. Exact
  timeout values and result formatting still require resolving object-pool data.
  Captures: `ev_8de4f4662e2faa1432f4c63285f4fe4af1246d7b507b81905e15b833ed05b8e2`,
  `ev_2f71552ecb979639ca7ec840cd81d4e5d7b1387f24a3d7d72df8122f051ce616`,
  `ev_3fd40fb57eab3993b299ca5b163296bdbbb337b7e26f8db81b0741c53eaac1e1`.
- `SpeakerIdManager.getLabel` assembly branches on unboxed IDs zero and one,
  with a third label for all other values. Its UI-transcript caller is
  `0x1006f6174`. This is a three-way channel-label lookup; it does not establish
  individual-speaker diarization. The reconstructed labels and generation rules
  are Microphone, Remote, and Unknown. Capture:
  `ev_8de4f4662e2faa1432f4c63285f4fe4af1246d7b507b81905e15b833ed05b8e2`.
- `InputRecorder.startInternal` enables AVAudioEngine voice processing, disables
  AGC, unmutes input, and sets advanced ducking with the minimum ducking level.
  It retries unavailable formats five times at 150 ms and voice-processing
  engine starts three times at 50 ms. `start` cleans up the failed engine and
  creates a fresh standard engine on voice-processing failure. The toggle uses
  voice-processing bypass on an already-enabled node. Both inspected native
  defaults return false. Capture:
  `ev_8cce28a06d9cbd8c329a9c3b713e97c84691e1119691b36f2a4b7cc57e5ae91e`.

Speaker-label implementation verification at that checkpoint: core suite 49 passed (one opt-in
skip); both analyzers clean; two meeting-workspace widget tests passed. The
expanded workflow checks all three displayed labels, derived API speaker IDs,
preservation of original route values, and speaker-attribution instructions in
note generation. Native AEC implementation and its subsequent tests are tracked
in [the implementation ledger](missing-functions-investigation.md). Web search
and the remaining reference/runtime comparisons are still outstanding.

The ready IDA worker later exited on its idle timeout and left a saved `.i64`.
Reopening the retained original-input path reused that database and returned
analysis/decompiler readiness without repeating the long initial analysis.
After the focused query-pipeline investigation, `idb_save` returned `ok: true`.
The worker then shut down normally on SIGINT and reported `All sessions closed`;
its unified-exec session completed with exit code zero. The saved analysis is
retained intentionally for the ongoing reconstruction, rather than deleted.

## Recovered search protocol and first implementation

The focused snapshot reader now resolves the public request/format constants:

- GET `https://customsearch.googleapis.com/customsearch/v1`, with `cx` equal to
  `67f1d2112dbb54ce4`, `num=10`, and `q` equal to the untrimmed input.
- The handler's argument key is `query`. Null/empty produces
  `Error: Search query was not provided.`; null/empty result items produce
  `No results found.`.
- Pool entry 11620 is a Duration with unboxed microseconds 5,000,000 at raw
  offset +8. Both search and each page-summary future use this five-second
  timeout. The layout probe checks the class unboxed-field bitmap.
- The first three ranks are selected before filtering missing links. Summaries
  run concurrently. Null links are excluded from output; empty links remain in
  output but are not summarized. Null title/snippet becomes an empty string.
- Output is exactly `title: <title>\nsummary: <summary>` for nonempty summary,
  otherwise `title: <title>\nsnippet: <snippet>`. Whitespace is not trimmed.
- Sources are positional `(title, URL)` records. The instructions at
  0x1008e603c–0x1008e6044 pass title in X2 and link in X3 to AllocateRecord2.
  Results/sources preserve rank. Duplicate URLs are not deduplicated: each gets
  a summary task and the last completed nonempty summary wins in the shared map.
- `_summarizeLinkContent` has no catch around its timeout/await. Summary failure
  propagates through Future.wait; a missing/empty summary uses the snippet.

REA evidence: `ev_771e591203ef243448bd334e7c4623df56fbfeed0ca15b5192247d1389703703`
(public constants/duration),
`ev_4f833cb59af9a76dfe1632317bb1827c5f7c7f926de025bc9a12aac31c11ef16`
(argument and HTTP-method constants), and
`ev_11537f3930a17d5c8e15d0040caaec0eac81eb508861bd0354859eeb6955d057`
(source-record assembly). Both focused IDA batch workers closed normally.
The reader explicitly excludes API-key entry 27425.

`packages/foresight_core/lib/src/web_search.dart` implements the search transport
and callback protocol, with an injectable summary backend. The transport owns
and releases one HTTP client per request, including timeout. Its status-only
HTTP error is a reconstruction choice; exact original HTTP error presentation
has not been established. No credential from the reference is redistributed.
The service accepts a distribution credential internally; no user project
configuration screen is introduced.

This is not yet an end-to-end web-answer feature. Production wiring, release
credential provisioning, native fetch/summarization, tool dispatch and cancellation still need completion. The subsequent [web-content reconstruction](reference-web-content.md) resolves
100 as words and corrects the default candidate count to one. It implements
the RPC, optional ranking and response postprocessing.

Verification: eleven focused tests pass, including a loopback HTTP server checking
encoded parameters, nullable items, errors and the response-body deadline;
callback fixtures check concurrency, order, duplicates, empty/null links,
whitespace, fallback, and exception propagation. Full core suite: 108 passed,
one opt-in skipped; analyzer clean. No real search or native model inference
was invoked by these fixtures.

### Tool-visible source numbering and fetch-error boundary

`InferencePipeline._ensureSearchCallbacksInitialized.<anonymous closure>` at
0x1008e5868 wraps each result with `[Source:<one-based index>] ` and two final
newlines. It returns the error string when the result list is empty. Its string
dispatch is an identity stub (0x100d1abac); there is no trimming step. Pool entry
3656 is exactly two LF units (000a 000a). `formatSearchToolResult` reproduces this
layer, including per-invocation numbering. This does not yet establish how the
application retains source URLs or presents clickable citations.

The native `_parallelizeTasks` scheduler attaches catchError to each fetch task;
its error closure at 0x1008e78d4 logs and returns null. This inner fetch-error
handling is distinct from the outer callback timeout, which still propagates.
The scheduler/native fetch implementation remains unfinished.

REA evidence: ev_2ac9b82ad85e5a91a198613e4d420f302e4b8f10acfcf7d53f1e5ef761efda97
(tool wrapper and scheduler),
ev_97521e2ed3c62903dfb4ab89a7c79a013d1fdda6e84bcdfccd70c104160e0546
(format constants),
ev_114663d726e7a2cc92e72bc1eb797f48f491532e149c263b82e97e63fe1d1f4d
(identity stub and fetch-error closure), and
ev_9f5d0d98fc8796ccf78591ff9800c42ba4f1855b59c41410122de61f63d7e42d
(separator UTF-16 units). IDA workers closed normally.

Final core validation: 108 passed, one opt-in skipped; analyzer clean. The first
full-suite rerun exposed an overly short 300 ms timeout in ordinary loopback
fixtures under concurrent load. Ordinary fixtures now use the production five
seconds; only the unfinished-body timeout fixture uses a short deadline.


### Remote summary service reconstruction

The web-content RPC, recovered protobuf subset and response processing are now
implemented. Earlier references to an unimplemented local/native summarizer and
always requesting three candidates are superseded by the
[web-content findings](reference-web-content.md). The original sends the URL to
odml.pa.googleapis.com with a fixed Gemini model ID, with ranking disabled by
default. Production wiring and distribution credentials remain unfinished.

Current core validation: **116 passed, one opt-in skipped**; analyzer clean.
Eight new wire/gRPC tests cover the reconstructed service without contacting
Google or invoking any remote/local model.


### Tool-generation bridge

The subsequent [tool-generation reconstruction](reference-tool-generation.md)
recovers and implements the schema, callback argument/error contract, concurrent
batch formatting, user-role response and 20-turn limit. A native bridge now
retains the model conversation while search callbacks run. Production Ask/meeting
activation, citation persistence, release credentials and live model/service
verification remain outstanding.
