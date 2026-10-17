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

### Original distribution configuration follow-up

The user subsequently authorized reading the two immutable app-bundled settings.
The exact original executable SHA-256 above was checked, and its typed Dart pool
entries PP9019 (shared ODML) and PP27425 (search) were read without launching the
original app or reading a profile, account or Keychain. The settings occur once
each in that executable at file offsets `0x5ef98b0` and `0x5bbcb80` respectively.
These offsets are valid only for executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.

Fresh read-only IDA traces were captured through REA process scenarios using
the existing matching IDA database. `OdmlService._apiKeyOptions` at
`0x1006a1e48` reads PP9019. `SearchService.initialize` calls `clientViaApiKey`;
at `0x1008e57fc`/`0x1008e5800` that function loads PP27425
(`(0x35000 + 0x908) / 8`) before URL-encoding the key. Evidence IDs:
`ev_d90ac014faa3938178bcd7dc3d2096f713f9836641c1effff23cbfff783c8c02`
and `ev_d836510490dbcc0669bbd8734d5dbdfcfc2083915fed7ada661e819912271f31`.
The attached MCP deep-provider registration was unavailable; a redundant owned
headless CLI attempt was stopped after the existing-session captures succeeded.
No Hopper, original app execution, or database edits were used. Redacted IDA
responses and private acceptance reports are retained outside the repository
under `/tmp/foresight-credential-parity`.

Actual production acceptance using those settings now passes: search returned
10 results; the direct website summary was nonempty; shared metadata advertised
the supported detector; and all 179437568 downloaded bytes matched the fixed
detector SHA-256. The earlier absent-credential result remains historical, not
the current live result. These calls use public synthetic inputs and do not
register/download into a user profile. Neither key is retained in source/docs.

`tools/reference_distribution_config.py` reproduces this bounded import from a
caller-selected installed app. It refuses a different executable digest rather
than guessing new offsets. It writes a new mode-0600 runtime.json or, when
explicitly requested, pipes both values to GitHub release secrets:

```sh
python3 tools/reference_distribution_config.py \
  --app /Applications/Foresight.app \
  --output /tmp/open-foresight-distribution/runtime.json
# Validate through the existing internal configuration path:
cd packages/foresight_core
FORESIGHT_RESOURCES=/tmp/open-foresight-distribution \
  dart run tool/verify_cloud_services.dart --download-query
```

Maintainer release provisioning uses `--github-repository owner/repo` instead
of `--output`; this is an explicit mutation, never a normal build/import side
effect. Mac release workflows forward these two named secrets to packaging.
Linux passes them as BuildKit secret mounts, not build arguments. Both platforms
intentionally include the supplied app settings in the distributed runtime
configuration, as the original does; they are not protected from extraction by
users of the resulting desktop app. Ordinary fork CI has neither secret and
keeps the existing no-cloud build behavior. No end-user project setup is added.
Mac release builds with both settings repeat the four live checks before
archiving; an endpoint failure fails that acceptance step.

These working app-bundled settings establish current access, not a guarantee of
future service availability, quota, or broader distribution terms. Original
search API retirement and remote backend changes remain external dependencies.

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
