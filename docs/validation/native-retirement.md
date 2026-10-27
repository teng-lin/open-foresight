# Native retirement ownership

This describes the C1 implementation checkpoint. Full application, model and
hardware acceptance remains pending the qualification listed below.

The application checks `fs_abi_version()==1` before resolving dependent native
symbols. Generation and recording separately require `fs_lifetime_version()==2`
and the complete lifetime symbol suite. Optional diagnostics have their own
capability negotiation. Audio capabilities, explicit consent, process identity
and environment setup require the base ABI without requiring lifetime or
logging extensions.

Each `NativeLibrary` retains the original `DynamicLibrary` mapping and shares
one lifetime observer/admission state with other users of that actual mapping.
Generation probe, event polling, operation status/release and retirement use that mapping.
Loading and close never reopen its pathname or transfer an engine/conversation
address to another Dart isolate. The service worker shares only immutable code
capabilities with its frontend. The native admission query pins the original
image before those capabilities are published; its first call can perform
loader work. The frontend retains the original quarantine callback before
acknowledging admission. Consent workers create and free their own
native results within their own isolate; they transfer only ordinary data.

## Requests and actual completion

Native engine, conversation, speech and capture owners are monotonically
increasing numeric IDs resolved only by that mapping, never native addresses.
Their control blocks are registered before publication. Retirement revokes
admission and requests cancellation synchronously, then submits preallocated native work. Native work
joins admitted calls, workers, children and overlapping polls before destruction.
A positive monotonic operation token survives loss of the Dart acknowledgement.
The registry admits at most4096 operation records, including unacknowledged
completion records. It refuses new admission at capacity instead of evicting
ownership or reusing identities. The executor publishes terminal state after
actual cleanup and retained resource release; secondary diagnostics are outside that mandatory publication.

`fs_operation_status` returns pending0, success1, completed operation failure2,
unconfirmed3 or unknown/released-1. Pending tokens cannot be released. Probe and
capture finish leave their handles owned; separate retirement destroys them. Unexpected
cleanup exceptions leave ownership unconfirmed and retained rather than turning
cancellation acknowledgement into completion. A token always belongs to its
original native mapping. An old numeric owner ID can never target an object
whose address was reused;
repeated Dart close joins the cached completion. Probe/join/finish results use
operation acknowledgement; retirement uses its separate owner acknowledgement.
An unconfirmed or lost completion latches new-admission refusal for all Dart
consumers sharing that mapping. Native atomic admission state and quarantine
exports make this refusal visible to replacement isolates too. Cleanup remains available, but the owner must
restart the service/application process; replacing an isolate cannot recover
lost owner state. Capacity refusal is surfaced without automatic retry loops.

The production worker waits for frontend admission before creating generation
or recording owners. After service close joins actual cleanup it confirms this
to the frontend and waits for acknowledgement before exiting. If it exits with
admitted ownership but without that confirmation, the frontend marks the pinned
mapping unconfirmed, including the gap before physical creation. New frontend
objects and replacement isolates then require process restart. A worker that
never requested native admission can still be replaced for SQL-only service.

`NativeRuntime.close()` and `Recording.dispose()` synchronously detach handles
and stop new work. Their `closed` futures join actual retirement. A generation
request's `finally` joins its own conversation retirement before its feature
reservation is released. Request-scoped `cancelAndDrain` also supports a paused
stream without waiting for the consumer to resume. Every continuation checks its
exact owner/epoch before another native call. Cancellation and timeout do not
adopt a later tool result: pending tool callbacks have separate tracked ownership,
keep generation busy and are joined by runtime/service close before Store release.

Capture finish joins acquisition before final PCM is drained; retirement follows
that drain. Speech reuse waits for `fs_speech_join_async` before the same handle
accepts another segment. A done event is not worker exit. Idle speech handles
retain the shared model worker between segments, and actual shutdown joins the
last model owner. Start failure, pause, stop, resume failure and dispose use these
same ownership barriers; original storage/producer errors remain primary.

`GenerationRuntimeSlot` owns candidates, installation and retiring generations.
Its six production transitions cover note discovery, registered note load,
note reset, startup discovery, startup registered load and successful model
configuration. New attempts revoke older candidates and join their producers;
installation waits for previous retirement and rechecks the epoch. Once model
registration commits, subscriber cancellation cannot discard that adoption;
workspace/slot epoch and service close still revoke it. A pending
candidate may supply loading status, but a stale candidate cannot replace the
installed owner. Application close revokes this slot before waiting for model or
generation producers. Domain drainage joins the slot before helper/Store release. A settled retirement
failure is separate from actual work-in-flight: it requires restart and refuses
new generation, but cannot permanently block idle process shutdown as busy.

## Retained synchronous consumers

The original synchronous C ABI remains available to serialized C++/Python
lifecycle owners. `fs_engine_destroy` still rejects referenced/busy engines;
conversation destroy still respects its drain flag; speech destroy and
synchronous probe still join their actual resources. Ready legacy Mac capture
finish/stop retains final PCM and synchronous cleanup; pending startup instead
uses the separate bounded quarantine described in native-retirement-protocol.md.
The remaining synchronous legacy calls remain blocking and are deliberately absent from the application's Dart
retirement path. Linked C++ root fixtures use the matching header/library; Python
loaders check ABI before binding dependent functions.

| Consumer family | Disposition |
| --- | --- |
| `native.dart`, model setup, Domain, ModelRegistry and native note adapter | Original mapping, native completion tokens and one generation slot; request/adapter close joins actual native cleanup. |
| `recording.dart`, RecordingController and meeting controls | Capture finish/retire and speech join/retire tokens; control RPCs await their owned physical transition. |
| Audio adapters, Helper process identity and platform environment setup | ABI first; no borrowed generation/media pointer or asynchronous destruction ownership. |
| `tools/evaluate_pipeline.py`, `tools/test_whisper_gpu.py`, `tools/test_capture_device_recovery.py` | ABI first; retain synchronous diagnostic/evaluation shutdown and original result/cleanup checks. |
| Native lifecycle/model-type/process Python fixtures and `tests/models/evaluate_native.py` | ABI first directly or through the common native loader; retain legacy synchronous semantics. Persistent-speech fixtures validate ABI in both of their direct loaders. |
| Root C++ probe/lifecycle/rollback/audio/owned-operation/export fixtures | Compile/link the matching source and preserve original sentinel, child reap, terminal/content and rollback assertions. |
| Core/desktop native fixtures and runtime fakes | Await real owner completion; fakes model epochs and explicitly declare their empty-resource completion contract. Remote/read-only facades gain no native ownership authority. |
| Dedicated query/model-vault and one-shot worker owners | Separate owners keep their existing worker-reap-before-lease-delete order. Generation has no implicit plaintext-vault lease. |

The source guard in `test_native_ffi_contract.py` requires the hardened shared
outer exception boundary for every public throwing native export. The only
unwrapped export is the constant lifetime capability. Allocation/standard/unknown
exceptions, reporter contention, unpublished-resource allocation rollback and
held worker/poll/API ownership have separate executable native controls.

## Qualification limits

Controlled native and Dart fixtures establish ownership/order and cancellation
behavior. They do not establish real-model quality, physical audio, GPU behavior,
installed signing/TCC, or the real-model latency target. Run the full root native
matrix on Linux and Mac, fresh-library/helper core and desktop coverage, compiled
service/MCP and isolated-display integration. Preserve failures and skip reasons.
Sanitizers, native-active real-model teardown and warmed100-sample RPC p95 require
their actual dedicated lanes; a done frame, cancelled Future, older binary or
narrow fixture never substitutes for those proofs.
