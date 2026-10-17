# Cloud transport acceptance and ownership

The production search, Foresight website-summary RPC, shared-config RPC and
ranged model downloader already implement the recovered original protocols.
This follow-up closes an ownership gap and makes their remaining live acceptance
executable. It does not add another end-user project or credential screen.

## Owned summary calls

`WebContentService.close()` now cancels every RPC created by that service,
including multiple simultaneous candidate fetches, before shutting down an owned
channel. An injected channel remains caller-owned. Completed/failed calls leave
the active set in `finally`; operations after close are rejected. This matches
the port's existing model-config ownership policy. It is a port teardown policy,
not a claim that original Foresight exposes the same close API.

A loopback gRPC regression starts two unfinished fetches, observes cancellation
for both, and proves a second service on the same channel completes an existing
request and can make another request. Late fixture replies cannot revive the
closed service's requests. Existing candidate ranking, snippet fallback,
postprocessing and exact wire requests remain unchanged.

## Explicit live acceptance

From `packages/foresight_core`, run:

```sh
dart run tool/verify_cloud_services.dart
# Optional: also download and authenticate the advertised 179437568-byte detector.
dart run tool/verify_cloud_services.dart --download-query
```

The command reads only the port's existing runtime configuration, including
`FORESIGHT_SEARCH_API_KEY` and `FORESIGHT_WEB_CONTENT_API_KEY`. Existing
`FORESIGHT_RESOURCES` resolution can select the port bundle's runtime.json.
It uses the recovered production endpoints, a synthetic public search query,
and `https://example.com/`; it never launches the original application, reads its
keys, writes a profile, registers a model or changes a Keychain entry.

The checks independently require nonempty search results, a direct nonempty
remote website summary, and metadata advertising the supported detector size.
The direct summary call deliberately does not treat snippet fallback as live
summary success. The optional blob check verifies the fixed size and SHA-256
before reporting success and retains no downloaded file. This does not replace
worker readiness, encrypted installation or signed release acceptance.

Reports contain classifications/counts, never keys, response text, raw exception
messages, authenticated URLs or stack traces. Exit 0 means requested checks
passed, 1 means a requested check failed, 2 means distribution configuration was
missing, and 64 means invalid arguments. A blob check blocked by a failed metadata
check remains explicitly blocked; independent endpoint failures do not suppress
later metadata checks. Fixtures label their report endpoint mode `controlled`;
the command labels its mode `production`.

On this development host neither distribution key is present in the port process
environment or either inspected port development bundle. The actual production
command with `--download-query` therefore exited **2**, reporting all four checks
blocked before transport. No live Google/ODML success is claimed. Provisioning
these existing distribution-owned values and running this command remains the
specific live acceptance dependency; a user Google project is not required.

Four controlled acceptance tests exercise the real HTTP/gRPC clients against
loopback peers: all three endpoint checks pass together, independent failures
remain redacted and do not skip metadata, absent configuration constructs no
client, and incompatible advertised size blocks blob allocation/transport.
Together with the existing acquisition/search/summary fixtures and new teardown
regression and malformed-configuration CLI redaction check, **41 focused tests
passed**. Changed Dart files analyze cleanly.

## Runtime model settings: bounded evidence

The existing workers already use temperature 0.4, top-K 40, disabled thinking and
KV-cache channel-content filtering for ordinary chat. Those values agree with
the three inspected public bundled model configurations; grounded note requests
retain their distinct intentionally constrained sampling path.

Additional direct IDA Pro inspection of the pinned original confirms:

- `_LiteRtLmService.initialize` at `0x10065c2a8` accepts optional `audioBackend`,
  `cacheDir`, `enableSpeculativeDecoding`, `maxVisionTokensPerImage` and
  `visionBackend`. `EngineConfig.toJson` at `0x10065cc1c` emits those only when
  nonnull, alongside maximum tokens, GPU backend and automatic GPU priority.
- `ChatService.initialize` at `0x10091eff4`–`0x10091f21c` takes conversation
  settings from the selected model configuration first, then a global fallback.
  Its conversation construction carries temperature and top-K along with
  thinking, thinking budget and KV filtering. `ConversationConfig.toJson` at
  `0x100661978` identifies those fields; this call does not serialize top-P or
  repetition penalty, even though the public bundled JSON contains them.

The public scalar-only reader decoded PP12759–12768, PP12776–12780 and
PP12917–PP12925; credential pools PP9019/PP27425 and private configuration maps
were excluded. Raw direct IDA and reader results are retained under ignored
`test-results/reference-functions/ida/cloud-*`. These are static analysis
results, not new successful REA process-capture records or live original output.

The vision/model lifecycle change owns backend and vision-budget integration.
Alternative server/distribution model configurations and their selected-model
versus fallback effects still require actual runtime comparison. No arbitrary
cloud-model override UI or configuration file is inferred from this trace.
The cloud summary model remains the recovered fixed Foresight model ID,
independent of the user's local chat model selection.
