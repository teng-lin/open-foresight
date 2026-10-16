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
