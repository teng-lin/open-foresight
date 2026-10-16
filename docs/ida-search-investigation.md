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

Speaker-label implementation verification: core suite 49 passed (one opt-in
skip); both analyzers clean; two meeting-workspace widget tests passed. The
expanded workflow checks all three displayed labels, derived API speaker IDs,
preservation of original route values, and speaker-attribution instructions in
note generation. Native AEC and web-search implementation remain outstanding.
