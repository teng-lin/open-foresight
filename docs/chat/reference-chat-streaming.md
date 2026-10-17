# Original chat streaming and port transport

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
The retained IDA send pages show `sendMessageStream` at 0x10090a75c,
accumulation of text parts, provisional sanitation, then final message assembly
and history insertion. This extends [response cleanup](reference-chat-response.md).

## Original provisional text

The call at 0x10090a794 supplies PP4920 (`text`) to
`_buildJsonFieldRegex` (0x1009131f0). Its exact public suffix is PP30826.
For JSON-like output, the send loop selects the last matching text field, even
when the JSON string is unfinished. It does not expose analysis-only JSON.
Plain output passes through the existing sanitizer. Fenced JSON and partial
`json` fence headers have distinct handling; incomplete headers do not publish
an update. Only nonempty sanitized text reaches the callback at 0x10090b29c.

`_unescapeJsonStringLiteral` (0x100912ab0) removes an odd trailing backslash,
drops an incomplete final Unicode escape, escapes control characters and bare
quotes, then attempts JSON string decoding. Its exception handler decodes
Unicode and common escape sequences before removing remaining escape slashes.
Selected public constants and the fallback disassembly bind that order.
The port applies these rules to accumulated preview text without changing the
stored final response.

Retained analysis includes `chat-search-send-2000.json`,
`chat-search-send-2500.json`, `chat-stream-field-name.json`,
`chat-stream-unescape-*.json`, `chat-stream-incomplete-unicode.json` and
`chat-stream-fallback-group.json`. Several IDA batches closed normally but their
REA wrappers could not inspect unrelated process ownership. Those retained
results are static analysis; no successful process-capture ID is claimed for
those failed wrappers. Public escape constants and enum storage were captured
successfully as `ev_df9f8183d07203dae49c5b22313d69f43279ece1b808f20275aa3ec7989e1fc7`.

## Worker and native bridge

Both workers use the pinned LiteRT conversation streaming C API. A callback
contains a message delta, not the final response. Controlled SDK probes observed
several text deltas followed by an empty final callback; native tool calls
arrive complete with the default `stream_tool_calls=false` setting.

The workers emit `delta <JSON>` for each nonempty chunk, assemble the complete
structured response, then use the existing model/control/answer exchange.
Text parts merge only when their other metadata matches, channel text appends
by channel, and tool calls retain their argument representation. Start errors,
callback errors, and optional-argument cleanup are covered by fixtures. Callback
state survives until conversation teardown.

The native supervisor forwards deltas as `model_delta` without waiting for a
tool reply. Deltas after a final answer or while awaiting a control response are
protocol errors. Dart exposes cumulative `preview` events per model turn while
retaining one authoritative final `delta` with the complete response. Consumers
that only need completed content, including compression, do not append previews.
Domain sanitizes and publishes preview text, but stores only the final response
and performs final citation selection there. This avoids duplicating streamed
text or persisting an intermediate tool round.

## Verification and remaining work

A real Mac worker with the installed Gemma 4 E2B model emitted 21 deltas. The
first arrived at 3.571 seconds, before the final model/answer at 4.982 seconds.
Concatenated text exactly matched the final answer. Report:
`test-results/reference-functions/streaming/worker-report.json`.

The integrated real-model web test also passed: a controlled search result was
cited and saved, a follow-up replayed its code without another search, and a
compressed context retained its theme color. Its report is
`streaming/integrated-web-model.json`. The provider was controlled; this does
not verify live Google access or original-app runtime output.

Fixtures cover incremental Unicode previews, final response ownership, invalid
post-answer frames, JSON headers/partial escapes, and exclusion of preview text
from persisted history. Python streaming fixtures and the C++ aggregation target
pass. The changed full C++ inference source passes syntax compilation against
pinned headers; a linked Linux build remains unverified.

The native bridge now negotiates `worker_protocol: 1` and retains one owned
worker and model engine for tool conversations. Each request carries a monotonic
identifier; cancellation waits for clone teardown before acknowledging completion.
An unresponsive cancellation destroys the owned worker and the next request starts
a fresh worker. Custom runners without the capability retain their existing path.
One-shot generation shuts down the retained worker before loading another model.

For empty-history text conversations, the worker retains an unused base keyed by
system instruction, tool declarations and output budget, then clones it for each
request. Historical conversations start independently. Plain summary requests use
the retained engine without replacing the chat base. The SDK initializes the base
lazily: this implements conversation reuse without claiming eager KV prefill.

Native fixtures prove process reuse, cancellation acknowledgement, bounded fallback
termination, stale-frame rejection and shutdown. The real GPU report
`streaming/persistent-worker-report.json` proves clone isolation and reuse after
cancellation. `streaming/persistent-integrated-web-model.json` verifies search,
citation, replay and compression through the retained worker. The full core suite
passes 193 tests; the full desktop suite passes 175 tests, with optional tests
skipped. All four native test groups pass.

The original two-stage cleanup and date-specific empty-response fallback are
implemented; the pooled stream wrapper has no generic empty-text retry.
Malformed-JSON metadata reconstruction is implemented; see the response document.
Original runtime comparison and exhaustive lifecycle parity remain open.

## Cache failure and non-text boundary

A fresh REA/IDA pass confirms the send-path clone exception handler at
`0x10090a638`–`0x10090a6b8`: after warning about the clone failure, the original
uses its independently initialized request conversation. It does not evict the
untouched base or fail the send solely because cloning failed. Both workers now
create the configured request conversation when native cloning fails. Python
also handles a raised clone exception. Failure of the fallback creation still
propagates. A functional regression checks fallback isolation, subsequent reuse
of the same base, and exactly one close per owned conversation.

The flag checked at `0x10090a554` is the send argument `addToHistory`, not a
generic text-only predicate. The original initializer at `0x10091eda4`–
`0x10091ee60` additionally requires empty history, a live base, matching output
budget, and equality of cached/current configuration slots `+79/+159`,
`+87/+167`, and `+95/+239` before cloning. The preceding paths change vision
and audio configuration; the base is configuration-specific, rather than
unconditionally prohibited for every non-text request. This is static
control-flow evidence, not a live multimodal observation.

The port currently exposes string prompts with fixed text inference settings.
Its history path, including image/audio content parts, bypasses base cloning
and installs the full history unchanged; controlled runner fixtures verify
that admission policy without claiming that a real media encoder ran. Current
image/audio prompt transport and original multimodal engine/configuration
transitions are not implemented by this change. Those require a supported
transport before the remaining original configuration conditions can be
exercised; adding unused modality flags would not establish parity.

Evidence: `ev_b81a4d88ca1196b1ba3a9fbca444e8b6e79804b42f9dcb1b3962562e022dbe1a`
retains the ready matching IDA database and clone gate/handler;
`ev_927b42d21cc758a3869c52144d464507c94d527f0ebfa115962937799779eae4`
and `ev_ad56c721b915e4730a565f39b3e8acafbdad3da238bb79d0695d896c1507b8bb`
retain initialization/reuse/base replacement branches. The first capture has
complete raw output but truncated rendered terminal frames. Selected public
argument names `addToHistory`, `createHandle`, and `hasAudioQuery` are bound by
`ev_907d6cbe7a39e8029cf25cf00f16fe100ef944de1f7dc149484115aebfbf9fcc`.
Retained files are `ida/chat-cache-clone-gate.json` and
`ida/chat-cache-initialize{,-tail,-completion}.json`. The matching original
and IDA input both hash to the reference executable digest above.
