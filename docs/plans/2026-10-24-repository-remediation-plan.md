# Repository remediation and unified logging implementation plan

Revision 6, 2026-10-24. Status: combined plan; implementation has not started.
Source requirements: [consolidated review](../audit/2026-10-24-consolidated-repository-review.md),
F1–F25. Audit baseline: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`.
Planning checkout: `ae9170830ca115cb40a44ad7e9ade8714a170bec`.
Independent reviews and frozen revision hashes belong in the
[review record](2026-10-24-repository-remediation-reviews.md).

Implement the repository remediation and unified logging together in one
implementation PR, using ordered stages and commits. Repair recording privacy
and unbounded meeting work first, preserve the existing integrity and coverage
gates, and finish with distribution controls that require owner-provided
infrastructure. A source review or agreed plan is not implementation acceptance.

## Scope, baseline and delivery rules

The audit's exclusion remains in force: do not assess or change the sourcing or
packaging of release distribution credentials in `tools/reference_distribution_config.py`
or related code. Exempt that tool, its dedicated tests and its value-supply path
to `SearchService` from C/E's configuration, import, digest and helper rewrites.
Inventory those untouched paths as exclusions, outside completion denominators;
do not broaden their assessment through a mechanical cleanup.
Credential-file permissions and Google token storage in F21
remain in scope; they are separate from that excluded topic.

The checkout is one commit beyond the audit: #178 changes Google authentication,
provider switching, settings and associated contracts in 17 files. Revalidate
F18 OAuth documentation and F21 token handling against this head. Schema version
is still 19. At each implementation start, record the new head and re-check all
affected findings rather than copying stale line numbers or historical results.

This is the single active implementation plan. It combines remediation revision
4 (SHA-256 `7c8909f753ac32d507c3ab3ca9813f07b5c9af5e58150a8d1536482c66a352af`)
with converged logging revision 6
(`c5a480bc07d2eb78e550a3e9a9eab263e3bf34f63caea1942474137010392337`).
The full logging requirements and acceptance matrix are incorporated into stage
B below; execution does not depend on another plan or pending logging approval.
The [former logging plan](2026-10-24-unified-logging-plan.md) is a superseded
pointer, and its [review record](2026-10-24-unified-logging-reviews.md) retains
the six-round design history. Frozen input bytes are retained with the combined
plan's review evidence. Prior approvals establish the input baselines; the
combined revision needs its own complete-plan review.

The [native close follow-up](2026-10-21-native-close-follow-up.md) supplies F16
ownership requirements, which are included in C. Its old timing results and
earlier service/refactor execution records are historical, not new acceptance.

Before coding, open the substantial-behavior issue required by
[CONTRIBUTING](../../CONTRIBUTING.md), with F1–F25 and logging steps 0–4 as
its checklist. Track one implementation branch and one PR for the complete
scope. This planning task does not open issues, PRs, push, change repository
settings or publish. Include this plan/review record, the consolidated audit,
its two cited source reviews and the historical logging pointer/review record
in the first documentation commit on that implementation branch; do not create
a separate docs-only PR. Until then they are local planning inputs. Verify every
claim against tracked current source, never depend on an untracked audit at
runtime or silently omit a relative-link target from the eventual PR. The
subsequent execution goal authorizes the issue, implementation, local integration
and final GitHub delivery described below; the planning-only restriction above
describes preparation of this document, not a prohibition on that execution.

### One implementation PR with ordered stages

The user's instruction on 2026-10-24 explicitly lifts the approximately 100-file
limit for this combined work. This overrides that one AGENTS.md rule for this
execution; it does not waive owner review, coverage, tests, artifact trust,
publishing controls or any other repository requirement. There is no 90-file
budget, file-count split threshold or new file-count rejection gate. Keep
changed-file inventories for completeness, reviewer navigation and consumer/
generated-code coverage.

Default delivery is **one implementation PR** for A–F, including all five logging
steps. These are work stages and ordered commits, not PR boundaries. Keep tests,
generated outputs and topic documentation with their implementing commits.
Provide a review map by stage and shared file owner; do not open separate PRs
for diagnostic foundation, native integration, support docs, typing or each
audit finding.

| Stage | Cohesive outcome and findings | Ordering inside the implementation branch |
| --- | --- | --- |
| 0 | Freeze baseline, open execution issue, inventory consumers/output sites and external prerequisites | Before implementation. Logging step 0's syscall/exit proof precedes its storage code; it can progress alongside A. |
| A | Recording, storage/indexing and narrow resilience: F1–F3, F5–F9, F20 backup, F23 SQLite | Implement and qualify the microphone repair first, then migration/indexing and narrow fixes. |
| B | Full unified logging and support, plus safe RPC errors: F4/F19, related F18 | After A's shared runtime changes; logging steps 0 → 1 → 2 → 3 → 4 are commits in this stage. |
| C | Service/native ownership, desktop boundary and local security: F13–F16, F21, remaining F23, native F22 | After B's stable event/drain API and prior ABI/barrier checks. |
| D/E | Verification, release/dependency assurance, documentation and Python quality: F10–F12, F17/F18/F22/F24/F25 | Work on independent files may overlap A–C. Coordinate E's entrypoints/helpers before D's final workflow consumers; integrate and verify together. |
| F | Signed distribution, rollback instructions and update notice: remaining F20 | Backup code is already in A. Final release activation follows D's authority/receipts and provisioned signing prerequisites. |

Integrate shared runtime surfaces A → B → C on the same branch, testing each
stage checkpoint. A owns FIFO/speech-admission changes in
`foresight_native.cpp`; B owns diagnostic spawn/drain/FD wiring and
`services/helper/child_process.h`; B brings the shared nonthrowing error-reporter
hardening forward before exposing any new diagnostic C ABI. C then builds
spawn-result/PATH hardening, the remaining export/barrier conversion and
retirement on that result. C stops/joins B's native diagnostic
poller before any unload and preserves feature detection for optional symbols.
Assign one owner per shared file in the execution issue. Compile-time and helper
protocol/schema transitions keep each checkpoint buildable and compatible.

Split only for a concrete shipping dependency. If the qualified F1/F6/F9
error-path repair is ready while remaining work is blocked, ship that repair
promptly and keep the rest together in one successor PR. If signing identities,
platform protections or external acceptance cannot be provisioned in time,
prepare/test their code in the same PR where existing runtime/release behavior
can remain explicit and safe; record the activation and actual acceptance as
blocked, never passed. A code follow-up is needed only when that missing input
prevents a safe implementation or required owner review. Non-code owner actions
do not create a PR. Do not hide unresolved F-subitems to call one PR complete.
Any exception records the blocker and minimum additional delivery; size alone
never causes a split.

### Local worktrees, Mac qualification and final GitHub delivery

Execute the stages as locally reviewed work units on separate Git worktrees.
Launch native agent teams in parallel for independent surfaces; give each unit
a branch, owned files, acceptance requirements and a local review record.
Keep the shared runtime integration order A → B → C; logging foundation and D/E
may develop alongside A on nonoverlapping files. Do not create individual
GitHub PRs for these units. Review and qualify each implemented unit, coordinate
with HanSolo for the applicable Mac checks on its exact source, then merge it
into the local integration branch. Resolve local conflicts and requalify any
changed integration surface before accepting the next dependent unit.

After all implemented units are integrated, run the complete combined Linux/Mac
matrix and inspect every unresolved acceptance/owner prerequisite. Open one big
GitHub PR only when the integrated implementation is reviewable. Read review
threads and CI step output, fix verified findings and conflicts, and rerun the
required checks before each follow-up push. Obtain actual required owner review
for publishing/trust changes; do not treat agent approval as owner approval.
Merge the big PR only when required reviews and checks are satisfied. Verify
the merge reached repository main. The execution goal ends only after that
verified merge, not after a local merge or PR creation. External acceptance
that remains blocked must be disclosed and handled under explicit scoped policy;
it cannot be marked passed to make the final PR mergeable.

## Stage A: recording and data safety

### Capture owns teardown independently of persistence (F1/F6/F9)

Make the recording state machine explicitly distinguish capture, draining,
transcript persistence and indexing. Every exception after `active.start()` must
stop/dispose its capture owner, including a failure in the initial state write.
Stop, hide and visible-desktop disconnect unconditionally stop and drain capture
even when the first or final status update fails. Guard interruption callbacks
and their own database writes; cleanup errors must not replace the original
failure. Preserve committed transcript rows and report interrupted/failed
persistence truthfully rather than reporting successful completion.

Retain failed transcript segments in a bounded in-memory queue: proposed defaults
are at most 64 segments or 1 MiB of serialized text/metadata, whichever comes
first, with at most five attempts over 60 seconds per segment. Use ordered
idempotent retry; do not retain PCM for these retries. Exhaustion
stops capture and reports an interruption instead of dropping segments silently
or retaining unbounded PCM. This is recovery during the process lifetime, not a
claim that uncommitted text survives a crash. Define exactly what the UI reports
when storage remains unavailable.

Release recording ownership after physical capture/drain/owned speech work has
settled, before source indexing. A subsequent recording must start while the
previous meeting's indexing waits behind an unrelated import. Final indexing
gets a separate tracked background job with service-liveness ownership,
workspace/epoch/source-revision checks, error reporting and persisted restart
recovery; clearing recording cannot orphan the job or allow profile shutdown to
destroy its resources. Duplicate Stop shares one completion.

Look up imported source existence by indexed URI in SQL rather than loading all
document bodies per file; offload directory enumeration and bound its results.
Keep both speech queue-admission and execution deadlines finite. Start execution
timing only after native worker admission, signalled by the worker/owner, and
do not kill a sibling channel's active request when a queued request expires.
Measure remaining drain starvation before choosing a dedicated capture isolate;
any move must transfer ownership rather than share borrowed handles.

Acceptance: deterministic storage failures at initial, pre-stop, transcript and
final writes; SQLite rejecting triggers plus a real controlled quota/full/I/O
failure path; Start, Stop, hide and desktop disconnect; throwing interruption
callbacks; queue exhaustion/recovery; two-channel queued speech; repeated Stop;
next recording while the source queue is deliberately held. Assert actual capture
shutdown and child/resource cleanup, not only a state flag. Repeat the compiled
desktop/service/MCP boundary under the storage fault. OS physical audio acceptance
remains separate from controlled capture executables.

### Back up before migration, then bound history (F2/F20/F23)

Do not edit historical migration 18 or earlier closures. Add the next ordered
migration after v19. Before any migration, take a private, verified SQLite
`VACUUM INTO` snapshot outside the migration transaction with the service as the
exclusive migration owner and no active application writer. If the snapshot
cannot complete, retain the old profile and refuse migration with an actionable
storage error. Never begin deleting history to make room for its backup.

Use temporary-exclusive/no-follow creation and atomic completion publication;
only a verified complete snapshot is a restore candidate. Include WAL consistency,
schema/source identity, permission checks, interrupted backup, interrupted upgrade
and sufficient-space failure fixtures. Restore is offline, with all owners
stopped and schema compatibility checked; retain the newer profile separately
until the restored profile opens successfully. A SQLite backup does not promise
binary/helper-model rollback; document those version prerequisites.

Backups retain erased data. Use a bounded policy (at most two successful
pre-upgrade snapshots, seven days), require explicit confirmation of restore's
data-loss point, and include backups in clear/delete privacy maintenance. Persist
deletion intent when cleanup fails and do not advertise completed erasure while
a managed snapshot still contains the data. Snapshot creation, inspection and
cleanup cannot follow untrusted paths or depend on logging availability.

Replace the history triggers in the new migration to exclude system-generated
meeting transcript sources, without excluding imported/user-edited sources.
Measure generated live notes too, and classify generated versus user-edited
content explicitly. Prune existing generated revisions without touching current
content. Bound user history by both count and aggregate bytes per entity: proposed
defaults are 20 prior revisions, 32 MiB total and a 90-day maximum age. Preserve
current content even when a single old revision exceeds the history allowance;
show that revision's absence truthfully in restore UI. Apply the
policy to all five current `ContentHistory.entities`: sources, meeting notes,
notes, artifacts and `meeting_tasks`. Derive the retention entity inventory from
that authoritative set and guard against new history entities bypassing it.
Include repeated task replacement, manual-status changes and restore fixtures;
deletion/clear and backup erasure must cover every entity's history. Avoid a
retention job that repeatedly scans the whole database.
Set a finite SQLite busy timeout on each Dart connection; make `importText`'s
related statements transactional without blocking capture behind long retries.

Acceptance: supported historical-schema upgrades, untouched frozen fixtures,
crash/rollback/restore, current-content hashes, SQLite integrity, deletion and
backup erasure, conflicting writers, and long synthetic meetings including live
notes. Record row/byte growth and pruning cost. Do not qualify this migration
using only a standalone SQL simulation.

### Make live indexing incremental (F3)

Prefer stable transcript chunks keyed by meeting/channel/segment identity and
embedding generation. Append immutable chunks, re-embed only a bounded mutable
tail, and publish snapshots atomically. Retry is idempotent; amendments, deletes,
model replacement and interrupted indexing reconcile or rebuild the correct
generation. Preserve existing live-search/citation visibility and finalize with
one reconciliation job rather than a second unconditional full re-embed.
Coalesce note/proactive work so repeated segments do not create an unbounded
backlog; preserve their generation and cancellation ownership.

The helper has an independently versioned three-database set:
`agent_metadata.db`, `linux_state.db` and `rag_vector.db`, currently v1. Preserve
that frozen migration path and add ordered versions for incremental metadata,
chunk identity and journal changes. Preflight and migrate the whole attached
set with rollback-journal/crash fixtures, never treat application v20 as the
helper version. Keep authoritative application content backed up as above;
treat helper documents/vectors as derived data, invalidate their generation
and rebuild from the application store rather than copying content into another
backup. An interrupted rebuild keeps readiness false until a complete generation
is atomically published; no stale/deleted content may become visible.

Version the helper protocol for incompatible indexing semantics, regenerate
bindings/fixtures and keep exact protocol/build compatibility checks. Reject
an incompatible adopted or pre-upgrade helper before sending a new request;
replace it only through verified existing ownership/idle shutdown, or give an
explicit stop/restart refusal. Never signal an unknown PID. Older helpers refuse
newer schema members; deliberate downgrade uses a separately rebuilt compatible
index and a schema-compatible application backup, not in-place schema rewriting.
Include helper documents, journals, all vector generations and obsolete index
files in clear/erasure and restart acceptance, including failed rebuilds.

If the measured helper/protocol inventory makes this unsafe for the urgent PR,
use the audit's alternative only as an explicitly documented interim change:
coalesced final indexing, a stated live-search freshness limit and durable restart
work. A timer over full transcripts does not establish linear complexity or
close F3. Keep incremental indexing open until measured acceptance succeeds.

Acceptance: compare increasing-length meetings on the same pinned model/runtime;
count embedded tokens/chunks, full scans, DB/history bytes, pending jobs, CPU and
RPC/drain latency. Doubling appended segments must approximately double processed
content after fixed startup overhead: fix the workload before measuring and
require a processed-content ratio no greater than 2.5 for 2N versus N segments.
Report raw counts and the chosen N, excluding startup only by a documented
constant; do not tune the workload/threshold after seeing results. Also verify
citations, edits/deletes, restart recovery and final-index deduplication.

### Narrow transport and filesystem repairs (F5/F7/F8)

Reject duplicate active RPC IDs before allocating a producer or overwriting any
lease/subscription. Remove entries only if the completing owner still matches.
Raw-socket tests must hold an active producer, reuse its ID, cancel/disconnect,
and verify exact terminal/cleanup behavior and the 32-request admission limit.

Apply finite metadata RPC, connect, response-header and body-idle deadlines to
question-model acquisition, plus finite total attempt/retry budgets. Abort/close
the underlying transport when time expires; timeout futures alone are insufficient.
Stalling loopback fixtures cover every phase, cancellation, retry exhaustion,
reservation release, resumable/partial-file hygiene and retention of the previous
usable model. Preserve bounded retries when consolidating downloaders in C.

Honor a validated `TMPDIR` for capture FIFO allocation, with private modes,
bounded paths, safe fallback rules and owned cleanup. Move the install lock from
shared predictable `/tmp` into validated per-user runtime/cache storage. Update
Dart, `packaging/upgrade_lock.sh`, `packaging/package_linux.py` and its generated
Linux package scriptlets, plus `tools/install_macos.py`, together. Exercise
`tests/test_rpm_scriptlets.py`, `tests/test_linux_packages.py` and macOS installer
consumers as well as the service lock tests. Enumerate only
real user runtime locations, verify owner/type/mode/no-follow properties, and
define old/new service compatibility so upgrades cannot overlook an old lock.
Do not weaken the legitimate live-user lock's ability to refuse an unsafe root
upgrade. Test multi-user/profile cases, malicious pre-creation/symlinks, missing
runtime directories, fallback, concurrent install/service starts and upgrade
from the currently released lock protocol.

## Stage B: diagnostics and support (F4/F19)

Execute logging steps 0–4 as ordered commits in the single PR; retain
their complete acceptance matrix. Freeze the event/output inventory before
wiring it. Keep the common schema, generated diagnostic identities, byte-based
producer credits, private bounded storage, independent writer shutdown watchdog,
native capability negotiation and protocol separation. Do not persist arbitrary
exception strings, malformed RPC bodies, vendor stderr, file paths or content.
The audit's suggestion of raw stderr tails is superseded by the logging design's
safe parent-derived summaries and validated native event queue.

Preserve the reviewed logging lifecycle refinements: one bounded cross-isolate
ownership decision controls log role/protection; desktop forwarding enters a
quitting state that disables Retry/start; standalone entrypoints complete
intentional protocol/presentation output disposition before their final logger
deadline. Preserve operational lifecycle/exit semantics and test reordered
ownership/error/close messages, saturated credits and stalled writer shutdown.

F19 also covers client-facing RPC errors, separately from persisted logs.
Assign `RpcError.from` sanitization to B: unknown exceptions and unclassified
`StateError` become `internal` with a fixed message; `FormatException` and
`ArgumentError` use registered bounded validation messages that never echo
source/input. Helper/gRPC failures map status to safe messages instead of copying
arbitrary helper text. Preserve vetted actionable typed `RpcError` messages,
codes and reasons; convert legitimate guidance at its origin to an explicit
typed error rather than losing it through generic redaction. Validate wire error
maps and bound their fields. Product diagnostics never receive the unsafe text.

Test canary content through service dispatch, desktop serialization/presentation,
MCP tool error results and the helper-to-service error boundary; assert no raw
source/exception escapes and that typed retry/cancellation/upgrade guidance and
codes/reasons survive. Audit consumers that matched prose; preserve the error
envelope and code/reason compatibility and document intentional text changes in
CHANGELOG/protocol notes. Text-only corrections do not require a schema bump;
any semantic code/reason change needs C's explicit version/compatibility review.

The product RPC channel follows this safe-error policy. The routing table below
separates direct tool presentation from the registered errors exposed by RPC.
Classify dedicated-query detector, PDF/RTF extractor, audio-discovery and
open-URI failures at their origins as typed errors with a registered operation,
category and validated numeric exit/status code. Raw stderr tails, paths and
URIs are not vetted guidance. Add those specific canaries to dispatch, desktop
and MCP error tests. Preserve tool subprocess stdout framing, bounded stderr
handling, deadlines and cancellation, and intentional direct diagnostic-CLI
presentation; never copy that raw presentation into product RPC errors or logs.
The logging inventory also includes notification capability errors and Linux
sandbox/AppArmor failures: preserve their actionable guidance as registered typed
errors, and test canaries in helper JSON/stderr and ProcessException text.

Verify detached Linux and macOS startup, adopted helpers, startup before native
load, legacy libraries, slot exhaustion, log rotation, disk-full/read-only sinks,
closed stdio, stalled parents and natural process exit. Real-time audio callbacks
use preallocated counters, not formatting or disk writes. Logging cannot own a
service lifetime, replay operations or block recording on persistence failure.

Include the troubleshooting/log-location/redaction guide, safe health output,
open-log-folder action and issue form in the same stage. Logs stay local; support
export/upload is not added. Record every old diagnostic site's replacement or
explicit presentation-channel disposition. No raw failed test artifacts are
deleted by product log redaction.

The complete logging design below is part of this plan. The step table, output
routing, resource limits and acceptance matrix are binding alongside the common
verification contract; there is no separate logging delivery track.
Logging uses a common structured event contract and one isolated writer per
application process. It adds no database tables, network destination, service
lifetime authority or mandatory external collector.

### Scope and completion criteria

Cover production Dart, Flutter, application-owned C++/Swift entrypoints and their
child-process boundaries on Linux and macOS. Classify Python build/setup and
acceptance-tool output separately: those tools retain their existing full build
and test artifacts; runtime diagnostic subprocesses use the same safe event
contract where integrated. Do not mechanically rewrite intentional CLI results,
usage errors, progress, MCP messages, model tokens, transcripts, or PCM as logs.

Completion requires persistent startup and failure events for detached launches,
correlated service operations, useful native failure categories, bounded memory
and disk usage, safe behavior under sink failure, and documented access to logs.
All current diagnostic sites must be migrated or explicitly inventoried with a
reason and follow-up owner. Existing stderr statements cannot silently disappear.

Remote telemetry, automated uploading, crash dump capture, an interactive log
viewer, hot changes to verbosity, automatic stderr mirroring, and full distributed
tracing are out of scope. Version 1 uses persistent files and in-memory health;
developers can follow the files with ordinary console tools.
Native teardown, model policy, toolchain inputs and publishing controls are
handled by stages A/C/D/F under their own ownership and owner-review rules;
logging itself adds no new authority or network destination.

### Current boundaries

| Boundary | Current behavior | Required change |
| --- | --- | --- |
| Dart diagnostics | `service_diagnostics.dart` writes free text to stderr; trace opt-in caps characters, and `requestFailure` prints arbitrary exceptions and stacks | Typed events with byte limits and classified errors |
| Service transport | `service_frontend.dart` relays bytes to a Domain worker isolate; its lifecycle channels own readiness and shutdown | Independent bounded logging channel; preserve relay and lifecycle ownership |
| Invalid replies | `service_client.dart` traces decoded malformed frames | Validation category and byte count, without frame content |
| Detached startup | Linux uses detached process mode; macOS `open --stderr` appends `service-startup.log` in runtime storage | Initialize durable logs independently of inherited stdio; retire unbounded startup append |
| Helper | `helper.dart` drains stdout/stderr without retaining diagnostics | Drain continuously; retain validated control-state projections and safe summaries |
| Native child launch | `native/foresight_native.cpp::run` and `services/helper/child_process.h` discard stderr | Separate diagnostic drain with bounded buffering and cleanup |
| Inference | `services/inference/main.cpp` duplicates protocol stdout and redirects driver stdout to stderr | Keep protocol descriptor separate from every diagnostic path |
| Capture | PipeWire PCM uses an owned FIFO; Core Audio callbacks are realtime | Preserve media routing; callbacks publish only preallocated counters |
| Desktop errors | Framework and asynchronous failures have multiple handlers; read workers use isolates | Install process-wide handling and explicit producer initialization |

Revalidate these anchors at implementation start. Read `AGENTS.md`,
`CONTRIBUTING.md`, [native verification](../../native/README.md#verifying-native-changes),
and [service architecture](../architecture/application-service.md) on that head.
This baseline includes the #178 Google/Granola provider-switching and calendar
sign-in changes. Inventory those new flows too: log only action/provider enums,
validation outcomes and durations; never manual auth callback URLs, codes,
credentials, accounts, calendar/document data or client-configuration paths.

### Event contract and API

Create `lib/src/diagnostics/` in `foresight_core`, separating event definitions,
configuration, producer, writer, storage, native drain, and test sinks. Keep it
Flutter-independent. Expose only a narrow logger API through approved desktop
exports; file paths and sink administration stay in `desktop_bootstrap.dart`.
Existing desktop import/export guards remain authoritative.

Use versioned UTF-8 JSON Lines. Schema version 1 has these fields:

| Field | Meaning and constraints |
| --- | --- |
| `schema`, `timestamp`, `sequence` | Schema version, UTC ISO timestamp, and writer-assigned serialization sequence; neither wall clock nor serialization order proves causality across producers |
| `level`, `event`, `component` | Closed severity enum, registered event name, and closed component name |
| `version`, `revision` | Validated build identity, without arbitrary environment strings |
| `session`, `pid`, `producer` | Random process-session ID, actual OS PID, registered isolate/native producer |
| `connection`, `request`, `attempt`, `job` | Optional generated diagnostic identities, scoped and bounded as described below |
| `fields` | Event-specific allowlisted enum, boolean, and bounded numeric fields; no general arbitrary string/map escape hatch |

Use `error`, `warn`, `info`, `debug`, and `trace`; `off` disables emission.
Register events such as `service.starting`, `service.ready`, `rpc.completed`,
`rpc.failed`, `transport.invalid_frame`, `helper.exited`, `native.worker_failed`,
`capture.state_changed`, and `logging.records_dropped`. Give every event a field
definition, severity, description, and examples in an event catalog. Durations
use a monotonic clock. Expected cancellation and closing refusals are debug/info,
not error storms; internal failures remain error events with tracing disabled.

Producers check the level before creating diagnostic fields. Validate fields
before enqueueing and again at subprocess boundaries. Reject invalid records
with a bounded counter. Limit a serialized record to 16 KiB including newline;
omit optional fields or emit a small `logging.record_rejected` event instead of
cutting serialized JSON or splitting a UTF-8 character. Include a normalized,
bounded stack fingerprint/frames only through a dedicated safe encoder.

An in-memory test sink and injected clock/identity source allow deterministic
tests without persistent globals. Test reset closes writers, subscriptions and
ports; production code cannot silently replace an initialized session.

### Privacy and error classification

Persist lifecycle, status, operation enum, error category, numeric OS/backend
status, counts, byte sizes, retry attempt and duration. Native event strings
must also be registered constants. Unrecognized strings are never made safe by
JSON encoding, hashing, a regular-expression scrubber, or a debug level.

Never persist note/source/meeting titles or IDs, transcript/audio, prompts,
model output, file or model paths, URLs/query strings, auth callbacks, account
identifiers/email, credentials, headers, request/response bodies, raw malformed
frames, command lines, environment dumps, vendor stderr, or raw `error.toString()`.
Do not use hashes of personal content as correlation IDs. Exceptions become a
closed category plus validated numeric code. Strip exception messages and
normalize source paths in stack frames; unknown frames are omitted. Fingerprints
derive only from normalized code locations and category, not messages/content.

Apply this policy to JSONL, in-memory diagnostic health, native
queues, and support access. Existing user-facing CLI errors remain separately
reviewed presentation output and are never copied into product logs wholesale.
Retain raw failed test/subprocess artifacts privately as required by AGENTS;
product redaction must not erase acceptance evidence.

Workspace clear keeps bounded metadata-only diagnostic history, including its
own outcome, but no workspace identifiers or prior content. Document this policy
and test it. Logs are local; opening their folder never uploads them.

### Configuration and startup

Configuration is resolved once per process and inherited explicitly by isolates
and children. Add the following keys to the bundled runtime allowlist and macOS
private startup handoff, with typed parsing and no arbitrary destination paths:

| Setting | Default and behavior |
| --- | --- |
| `FORESIGHT_LOG_LEVEL` | `info`; accepts the five levels and `off`; invalid values use `info` and one constant warning |
| `FORESIGHT_SERVICE_TRACE` | Existing `1` enables trace for transport only when LOG_LEVEL is absent; explicit LOG_LEVEL, including off, takes precedence |

`off` creates no writer isolate, native polling timer, persistent slot or sink
subscription. Intentional CLI presentation and OS/runtime crash reporting remain
separate. Bootstrap fallbacks also obey `off` once configuration is resolved.

No stderr-mirroring or log-directory environment override in the first version:
logs follow the canonical selected profile. No settings, levels, or destinations
come from RPC arguments. Child processes receive validated effective values, never whole
environment dumps. Native runtime values must be installed before the first
native handle seals configuration; exact replay from fresh isolates remains
allowed and changed values after sealing remain rejected.

Before profile resolution succeeds, keep a small constant in-memory bootstrap
diagnostic; do not guess a shared path or print the failing input. Existing
intentional CLI/startup error presentation remains separate. Once a private
canonical profile exists, request a writer before service startup/desktop
connection. Bootstrap records use a bounded in-memory buffer until a sink is
available. File admission failure cannot prevent application startup.

Initialization is idempotent across desktop Retry, which resolves its profile
inside `DesktopStartup.start` after `runApp`. Keep one process session rather
than spawning a writer for each attempt. Hold desktop/MCP records in a bounded
bootstrap buffer and admit persistent storage only at the first warn/error,
five seconds of uptime, or 100 admitted records, whichever comes first. A service
candidate uses that same lazy policy and shared slots until
`acquireServiceProfileLock` returns successfully, including its launch-withdrawn
check. Only then promote it to the service role and admit reserved storage,
without awaiting logging on the ownership path. Replay the bounded bootstrap
events into that slot. `ServiceOwnershipContended` and `ServiceLaunchWithdrawn`
are info outcomes even when the CLI exits 1; neither can set failure protection.
Genuine pre-lock failures may use shared storage and existing startup status;
they cannot claim reserved owner slots. Repeated acquisition attempts do not
create new sessions or change the meaning of application ownership.
Admin commands (`--status`, `--stop`, `--stop-if-idle`) and desktop launches that
only forward an existing instance's command never claim a persistent slot, even
on failure; their intentional CLI output remains intact.

Acquisition happens in the Domain worker, not the entrypoint/frontend. Pass that
worker a dedicated diagnostics bootstrap port/configuration. Immediately after
`acquireServiceProfileLock` returns or throws, it sends one fixed-size typed
ownership decision: `acquired`, `contended`, `withdrawn`, or `failed_before_lock`.
The trusted producer permits at most one decision, exactly one on a controlled
return/throw. Reserve its control record/at most 256 bytes inside the session's
process budget. It bypasses
ordinary emission credits and level filters, never awaits a sink and is not
dropped for data-queue saturation while the writer is alive. This internal
diagnostic control decision is not emitted to JSONL when logging is off, grants
no application capability and never travels on the service lifecycle channel.
With logging off, bootstrap supplies a no-op control producer, creating no port,
writer or reserved buffer; lifecycle failure classification still works.

Register the parent's decision guard at entry to `IsolatedApplicationService.start`,
before `privateRuntime`, host/port setup, `retainLocalServiceOwner` or
`Isolate.spawn`. Enclose the entire method's potentially throwing setup, including
the runtime validation currently outside its try. Any parent-side throw before
successful spawn promptly finalizes `failed_before_lock` or unknown, with no
reserved owner slot/protection and no wait for nonexistent worker callbacks.
A session with no launch attempt/registered guard has no pending ownership
decision and closes as an unknown candidate without the timeout.
The worker enters
that guard before environment installation, profile construction or
`ApplicationService.start`; failures in installation-lock acquisition,
`retainLocalServiceOwner` and all other pre-profile-lock setup emit
`failed_before_lock` too. Thread the guard's no-op-or-bounded callback through
the internal `ApplicationService.start`/`_start` path so acquisition is reported
at the actual lock site, not delayed until `ready`. The outer catch/finally emits
the fallback only if no acquired/contended/withdrawn decision was already sent.
A logging failure cannot throw out of this guard or alter application cleanup.

The reserved decision belongs to the session, not the data-producer registration.
Producer credit reconciliation/unregister cannot discard an already queued
decision. A controlled worker completes its decision and completion barrier on
the same producer control port in order, within reserved bounded control metadata.
Register onError/onExit before spawning. If the worker never starts, crashes,
exits or unregisters with no decision, promptly finalize it as an unknown
candidate with no owner protection. Process queued session-owned control records
before acknowledging final close; producer completion must not invalidate them.
This terminal fallback does not wait out the logger deadline when the writer is
healthy and no ownership report will arrive.

Only the writer applies diagnostic role/protection. It holds unclassified errors
from any producer within the existing bounded bootstrap budget until this
decision arrives. Classification is independent of which producer's error arrives
first. A `close` message finalizes classification after processing the decision,
after the worker's terminal unknown fallback, or at the logging deadline if the
writer cannot make progress. A worker that dies before
reporting a decision stays an unknown candidate; never infer ownership/protection
from exitCode, a raw message or late `ready`. Logging still cannot guarantee an
event survives a dead writer or SIGKILL. If a candidate already has a shared slot,
an acquired decision may keep that slot and update its role/protection under the
admission lock; do not create a second session merely to prefer a reserved slot.

Replace the internal worker failure tuple's contention boolean with a closed
operational kind (`contended`, `withdrawn`, `other`) so frontend/entrypoint
diagnostics also retain classification. Keep this operational metadata separate
from log traffic; no raw exception message is an event field. Preserve existing
exit codes, startup-status state values, retry decisions and release ordering;
the new kind does not redefine the lifecycle protocol. Update worker/frontend
fixtures together. Kind `other` without an acquired decision is an unknown
candidate, never evidence of genuine owner failure. Required races include
post-lock failure before `ready`, frontend error before the ownership decision,
saturated ordinary credits, withdrawal, producer unregister before queued
decision processing, and close before decision delivery. Held installation locks,
environment installation and local-owner setup failures must retain current
presentation/exit code 1 and naturally exit with a healthy writer, without owner
protection or an unnecessary 500 ms timeout.
Inject runtime-directory and local-owner setup failures at the frontend's
pre-spawn sites (`service_frontend.dart`), not only their worker equivalents.

For macOS LaunchServices, replace unbounded `open --stderr` capture with this
bootstrap/persistent design and safe launch-failure presentation. Stop creating
new `service-startup.log` files; do not read, import, or automatically delete old
ones. Document their legacy status and manual removal. Failures before Dart
entrypoint execution, and VM/runtime fatal errors that bypass Dart handlers,
remain OS crash/launcher diagnostics, not guaranteed product logging. Preserve
`recordServiceStartupFailure` and its startup status file for actionable launch
failure presentation; macOS crash reports supply runtime-fatal evidence. Linux
detached launches require no inherited stderr to work.

Preserve intentional service-admin stdout/stderr and its actionable progress
contract (`service_stop_command_test.dart`). MCP stdout stays protocol-only.

### Writer ownership and bounded delivery

Every desktop, service, and MCP process may own one dedicated writer isolate.
It handles file I/O. A service frontend and its Domain worker
are producers to the same writer over separate ports, never the lifecycle
`_messages`/control channel. Explicitly register the desktop read worker and
long-lived native drain. Short-lived parsing/audio/setup isolates either receive
a bounded producer or return safe diagnostic outcomes to their owner; globals
do not propagate automatically. Cap registered producers at 16 per process;
extra producers report via their owner or receive a no-op producer.

The entrypoint owns a `LoggingSession` handle, including the writer isolate,
producer registration and an idempotent `close`. Close runs in an entrypoint
`finally` on normal service/MCP return, admin early return and failed startup.
Desktop startup/forward-quit retains a synchronous `VoidCallback` adapter that
starts one idempotent asynchronous close-and-exit operation, awaits at most the
logger deadline, then calls `exit(0)`. Existing normal GTK window close and macOS
menu/window termination remain native OS paths; they do not run Dart `finally`
or guarantee a final log flush. No new platform exit hook is added in version 1.
Recent queued/unflushed records may be lost on those paths; 250 ms is a healthy
flush scheduling target, not a guaranteed maximum loss window. No feature owns
the session handle. The startup widget sets an explicit `quitting` state before
invoking its quit callback. While quitting, render progress instead of the
startup-failure/Retry screen; `start`, queued Retry actions and repeated Quit
calls do nothing. Its `finally` must not clear quitting or enable binding
`commands.sock`. Test ordinary activation, quick-meeting and calendar-auth
forwarding with a deliberately stalled writer and queued Retry.
A watchdog outside the
writer implements the shutdown deadline; it stops credit grants and native
polling, closes producer ports/subscriptions and retries/timers, asks the writer
to close, then terminates the writer isolate at the deadline. A broken writer
cannot be required to acknowledge its own termination. Session health and a
safe constant crash summary remain available to the coordinator without it.

Use byte and record credits before `SendPort.send`: combined outstanding producer
and writer traffic is at most 512 KiB and 256 records per process, with one
quarter reserved for warn/error events. Account for message copies and encoding
scratch space in the memory acceptance measurement. Producer-side rejected/dropped
counters are fixed-size and saturating; return them on the next credit grant,
not as an unbounded stream of per-drop messages. Severity reservation does not
promise lossless fatal logging when its reserve is exhausted.

No caller awaits logging, sink flush, or disk locks on an application operation.
On a stuck writer, credits stop and producers drop. Reconcile credits when a
producer exits; a logger failure switches producers to bounded drops. Aggregate
rate limits repetitive events (including malformed traffic) per event/category
using a fixed-size table, preserving count and first/last times without retaining
payloads. Health reports need no database, RPC, timer in the service lifetime
owner, or retry thread that prevents exit.

Flush periodically, at most every 250 ms, and immediately schedule a flush for
error records. After real application shutdown has released authority/resources,
allow at most 500 ms for best-effort logger flush/close. Descriptor-anchored
segment operations are synchronous system-libc FFI on the writer isolate, never
on an application/coordinator isolate; do not describe them as cancellable
dart:io asynchronous writes. Native drain and lock attempts must return without
waiting. `Isolate.kill` requests shutdown and cannot interrupt arbitrary blocked
FFI. If the writer has not confirmed exit by the deadline, standalone service/MCP
entrypoints call `exit(exitCode)` after their existing ordered application/client/
child shutdown and intentional output flushing have completed; never do this while the application is active or
as a substitute for its cleanup. Natural return remains the normal path when the
writer stops. Verify the existing exit code is preserved. Direct process exit
bypasses pending asynchronous work and finally blocks, so all required non-logger
cleanup must precede it. See the [Dart exit contract](https://api.dart.dev/dart-io/exit.html)
and [isolate kill contract](https://api.dart.dev/dart-isolate/Isolate/kill.html).

Before entering that final logger deadline, await pending MCP transport writes
and the existing intentional `stdout.flush()`/`stderr.flush()` output in each
entrypoint's ordered teardown. Flush independently so one closed/broken sink
does not skip cleanup of the other; preserve existing broken-pipe/output error
policy and exit code. Never close or reopen a sink already owned/closed by its
transport merely to flush it. The explicit-exit fallback may run only after
successful completion or normal error disposition of those output flushes.
Existing presentation/protocol backpressure may wait for its reader, just as
natural termination does; it is outside the 500 ms logger-wait budget. Do not
turn an unflushed final MCP response or startup failure text into successful
shutdown. Test exact complete output bytes with a blocked file logger, plus
closed and stalled presentation sinks under their existing policies.
Test actual compiled process exit with a stalled writer, including ports/timers
and slot lease release, rather than only timing a Future.
The deadline bounds application waiting; uninterruptible kernel/filesystem I/O
is an infrastructure failure, not a guaranteed bounded operation or passing test.
Never delay socket/lock release, alter cancellation completion, or treat a flush
acknowledgement as operation completion. Crash/SIGKILL can lose queued events;
do not claim fsync or crash durability. Fatal signal handlers must not invoke
Dart/JSON/file logging.

The logger never writes to inherited fd 2, including bootstrap/fallback paths.
Do not change its shared open-file-description flags: duplicating fd 2 does not
provide independent `O_NONBLOCK` state. Polling for writability before writing
to a blocking descriptor does not eliminate another writer filling the pipe in
between. Version 1 therefore defers mirroring rather than claiming a nonblocking
console guarantee; a future console sink needs a separately reviewed transport.
Existing presentation/third-party writes remain outside logger guarantees.
Keep small health state/counters for developer and settings diagnostics; storage
failure records a closed reason in memory, never the failing exception/path.
Do not retry a broken sink on a hot path. Pipe behavior is described in the
[pipe contract](https://man7.org/linux/man-pages/man7/pipe.7.html).

### Storage admission and retention

Use `<canonical profile.data>/logs` and a finite slot layout to make a profile-wide
bound independent of repeated launches and arbitrary MCP process counts:

- Ten fixed session slots: three reserved for service owners, two for desktop,
  and five shared slots usable by any role. MCP may use only shared slots;
  service/desktop prefer their reserved slots. Each slot permits three segments
  of at most 2 MiB,
  including record framing. Managed payload is therefore at most 60 MiB per
  profile. Fixed lock/manifest files have explicit size limits; total managed
  metadata is at most 1 MiB. Extra active processes retain a
  `storage_unavailable` in-memory health reason; they do not block
  application startup or create extra sessions on disk.
- A writer holds a separate `flock(LOCK_EX | LOCK_NB)` lease on an independently
  opened descriptor for its slot until exit, on Linux and macOS. Do not use
  Dart `FileLock`/process-associated POSIX record locks: closing a same-process
  probe descriptor can release those locks. The
  permanent lock files are never unlinked or rotated. PID values are descriptive,
  not proof that a session is inactive. Slot leases never use application
  ownership locks or keep a service alive. All directory, lock and segment
  descriptors use CLOEXEC and are relocated to fd 10 or above, even when stdio
  is closed; children inherit no raw logging handles. Probes open
  independent flock descriptors and cannot release the active descriptor's lease.
- Under a separate short, nonblocking admission lock, choose an eligible empty
  slot, then an inactive expired slot, then an inactive session without warn/error
  records, then an inactive session with warn/error. Within each class choose
  oldest first. Protect the newest failed service session for seven days even
  under pressure; only a newer genuine failure after successful service ownership
  may replace that protection. Contended/withdrawn candidates never qualify. Use only
  safe bounded manifest fields for role/failure/timestamps, and publish failure
  protection before its first error-record flush. A corrupted manifest is not a
  free slot. Never remove files from a held slot or a protected failed session.
  If every eligible slot is active/protected, continue without file admission.
  Failed lock attempts cause deferred bounded retry on the writer and a no-file
  state in the meantime.
  Refuse further file creation if no slot is available. Clock rollback affects
  age cleanup only, not byte limits or liveness.
  Hold the candidate slot's lease through cleanup, reset and new-session
  publication; observing a free lease and releasing it before cleanup is unsafe.
  Expiration is opportunistic cleanup during admission, not timed erasure while
  no process requests storage.
- Only the admitted writer rotates its three segment names. Check the next
  record's encoded bytes before writing so a segment never exceeds its cap.
  Interrupted tails are recognized as incomplete records by readers; do not
  repair or append a new session to a stale partial record.

Create the root/slots as user-owned `0700`, files `0600` at creation. Use scoped
descriptor-based open/create/stat/rename/unlink primitives anchored to a validated
directory, with no-follow/exclusive semantics where appropriate. Validate regular
file type, effective UID, private permissions, link count, and bounded metadata;
reject symlinks, hardlinks, foreign/public files, device files and unexpected
entries. Do not merely chmod a pathname after opening it. Do not silently modify
the repository's general file writers to implement logging security.
Keep this bootstrap utility independent of `libforesight_native`: use the system
platform abstraction for scoped descriptor operations so a missing application
native library can itself be diagnosed. Logging step 0 must demonstrate the secure
open/write/close strategy and its shutdown behavior before storage implementation.

Only enable persistent slots on local filesystems whose open-file-description
`flock` semantics have been qualified on the supported platforms (initially the
Linux ext4/btrfs/XFS/overlay and macOS APFS test targets). Reject NFS/SMB/unknown
filesystem types for persistence with a safe health reason; application use of
the profile continues. Do not assume local flock semantics over network mounts.
Maintain one process-wide session registry and never probe its own active slot,
even on a qualified filesystem; second-isolate requests use that registry.

Do not infer exact errno from a later Dart FFI call: a failed lease attempt means
`storage_unavailable` with capped retry; a failed/short data write disables file
persistence for that session. Safety does not depend on differentiating EAGAIN,
ENOSPC, EDQUOT or EROFS. Omit an errno field unless it was captured reliably at
the syscall boundary; native producers may supply their own immediately captured
codes. Logging step 0's syscall/ABI table must cover open/openat/fcntl variadic bindings,
including separate empty/nonempty `VarArgs` signatures, and struct layouts/flags
on Linux x86-64 and macOS arm64. Verify them using the pinned toolchain and real
platform fixtures. The [Dart VarArgs contract](https://api.dart.dev/dart-ffi/VarArgs-class.html)
describes the required declaration shape. Fault-injection/real-ENOSPC evidence
identifies its external cause independently; product health may remain generic.

The fixed layout and slot leases apply to native and Dart writers alike, but
native children normally feed their owning parent and consume no separate slot.
Standalone native diagnostic CLIs emit safe stderr records without opening an
extra profile. Disk-full, read-only storage, partial writes, quota exhaustion and
unexpected entries disable file persistence safely and preserve prior segments.
Do not delete unrelated files to make space. A successful log write is not a
promise that the filesystem has durable or physically preallocated space.

### Request and background job correlation

Generate random diagnostic process/session and frontend bridge IDs. Add an
optional bounded diagnostic bridge ID to the existing authenticated first
`_frontend_peer` frame. Validate it only on a worker socket whose OS peer is the
service process. Public frames cannot set/replace it, and it conveys no capability.
The frontend continues relaying subsequent bytes without parsing each request.
Test older/missing metadata compatibility explicitly; no public RPC schema bump
is needed for this internal optional field.

The worker records bridge ID plus connection-local numeric envelope request ID
and the existing server-generated `rpc-$conversation-$id` identity from
`service_admission.dart`. Preserve its generation/cancellation semantics; do not
add a second business request identity. Never trust a caller's requestId, memory
addresses, or unrelated frontend/worker `identityHashCode` values as diagnostic
identities. Map background jobs to generated spans only for their live lifetime;
cap and erase mappings when the job completes. Request completion records include
operation enum, outcome category and duration.

Client logs correlate connection attempts with locally generated call IDs;
retries get an incremented attempt and record their wire ID. Correlation across
client and service is limited to the shared wire ID within its connection and
connection lifecycle evidence; no promise of a global cross-process trace ID.
Logging does not add retries, replay mutations, extend request leases, interpret
an unknown outcome as failure, or release generation reservations early.

### Native and subprocess integration

Use a bounded process-local native diagnostic queue and an additive C ABI drain
API. Native/shared-library producers emit registered event IDs plus fixed typed
fields; they never call Dart from foreign threads. Cap native queued bytes at
256 KiB, including bounded counters for dropped events. The owning process's
logging worker polls at a fixed cadence, validates records, and submits them
under the same writer credits. Draining accesses only this diagnostic queue,
not Domain/model/capture handles; it does not migrate native resource ownership.
Install native severity configuration through the sealed runtime configuration
before handles start; the drain API itself does not mutate the environment.
Start polling only after the normal native runtime owner has loaded the library;
logging must not load models or turn an unused native runtime into a startup
dependency. No poller may race library unload or continue beyond logger close.
Keep the fixed-capacity queue alive for the OS process lifetime without static
destructor teardown; do not race a final drain against destroyed synchronization
state or dynamically unload the library while a drain is registered.

The drain ABI uses caller-owned fixed-size record arrays with explicit ABI
version, structure size and capacity. A poll returns at most 64 records/16 KiB
plus saturating drop counters, never partial records, heap-owned pointers or
unbounded strings. Define invalid-argument/version results and a single consumer;
use bounded nonblocking operations, with no Domain/native-handle access. Update
both Dart `_nativeEnvironmentKeys` and the C++ `fs_set_runtime_environment`
allowlist for effective logging configuration, retaining seal/replay tests.

Negotiate native logging capability before adding logging-only keys to native
configuration. Logging step 2, old native libraries, and existing minimal native test
fixtures keep their pre-logging configuration path. An unsupported logging key
disables native logging configuration with one constant health reason and leaves
children on their existing defaults; it must not throw the application-startup
configuration error used for required runtime keys. Retain fail-closed behavior for non-logging
runtime keys and changed values after the configuration seal. Resolve effective
`LOG_LEVEL` and transport-only legacy tracing in Dart before negotiation; do not
accidentally promote the legacy transport flag to native trace verbosity.
For capable runtimes, overwrite the raw logging-level value in native `environ`
with the resolved canonical level before sealing, including explicit `info` when
the user supplied an invalid value. For legacy children, logging capability is
absent and the pre-logging behavior remains; do not promise normalized new
settings through an older library that cannot install them.
The Dart-launched helper receives a launch-specific environment override with
the resolved canonical level too; modifying native `environ` does not modify
`runtimeConfiguration.environment`. Carry the already-resolved logging
configuration explicitly into Dart isolates. Do not insert a synthetic explicit
LOG_LEVEL into their raw environment before evaluating legacy transport tracing,
which would accidentally suppress the alias's original precedence.

Treat all child diagnostic stdout/stderr bytes as untrusted mixed output.
Inference redirects vendor stdout to stderr, so even a line matching a registered
JSON event cannot prove which code emitted it. Do not parse or persist any shared
stderr content as an application event. Drain fixed byte chunks without line
buffering or UTF-8 decoding, discard content, and retain only parent-derived
byte/drop counts, child exit/signal status, observed startup phase and classified
protocol failure category. No new application-only child descriptor is added.
In-process native events reach storage through the typed queue. Standalone native
diagnostic-only CLIs may emit safe registered stderr events for their direct
console. Preserve presentation stderr for callers that already use it as a
result/error channel. No JSON logs are interleaved into those channels. This
intentionally trades detailed child-reported diagnostics for a simple privacy
boundary while product RPC failures use the safe-error policy above.
Preserve intentional direct diagnostic-CLI presentation separately.
Existing structured protocol status codes may be projected into a closed error
category after validation; payloads, exception text and protocol results remain
on their existing streams and are never copied into diagnostics. Arbitrary vendor
writes and pre-main runtime crashes outside owned child capture are not covered
by the product-log contract; inventory and suppress vendor verbosity where
supported without claiming to sanitize all process output.

The following routing table is mandatory; logging step 0 expands it to every runner:

| Child family | Output contract | Product logging treatment |
| --- | --- | --- |
| Helper | gRPC/control state is semantic output; startup stdout/stderr is diagnostic-only | Discard raw streams, retain parent observations and validated control enums/counters |
| Inference/embedding/speech workers | Protocol frames on saved stdout/fds; mixed vendor stderr | Preserve protocol; discard stderr bytes and record counts/exit/phase only |
| PipeWire capture | PCM in owned FIFO; stdout/stderr diagnostic-only | Preserve FIFO; discard diagnostic text and summarize counters |
| Swift file parser and Linux extractors | Extracted text on stdout, bounded human-readable errors on stderr | Preserve extraction/stdout and deadlines; convert product RPC failures to registered typed messages, log exit/category/size only |
| Model crypto | Existing success output and sanitized direct CLI stderr | Preserve direct CLI/protocol; classify RPC failures, log operation enum/status, never key/model paths or error text |
| macOS audio CLI | Capability/result JSON on stdout; probe events/usage on stderr | Preserve tool protocol; use typed RPC guidance, closed state/status enums and numeric codes |
| Notifications and platform tools | Existing result JSON/stdout/stderr depends on tool | Preserve direct tool presentation/deadlines; typed RPC guidance excludes helper text/paths/URIs, logs use action enum/outcome only |
| Dedicated legacy query/Python runtime | Framed stdout; bounded stderr tail retained at subprocess boundary | Preserve protocol/tail bounds; typed RPC operation/category/code replaces raw tail, which never enters product errors/logs |

An adopted helper has no reattachable stdout/stderr. New service owners log the
adoption and observe existing `HelperControl.GetState/WatchState`: project the
proto's free-form pipeline/index strings into closed diagnostic enums, with a
fixed `other` for unrecognized values; do not forward raw strings. Freeze the
actual value sets from helper code in logging step 0, along with readiness and bounded
attempted/completed/failed counters;
exclude `last_error`, model identity/paths and instance strings. These snapshots
and numeric gRPC status codes provide diagnostics after predecessor pipe loss,
including adapter failure, without assigning the helper its own persistent slot
or changing its lifetime. Lost historical child stderr is deliberately not
recoverable. No new control protocol fields are required for this initial design.

Extend native `run` and helper `ChildProcess` to drain diagnostic stderr concurrently
with protocol/PCM/input before waiting for readiness or exit. Diagnostic reads
must not block protocol delivery when the sink/queue is full. Preserve inference's
duplicated protocol stdout, speech frames, one-shot output and PipeWire FIFO.
Route the diagnostic pipe through fd 2; do not take supervisor ownership fds 3/4.
Relocate pipe sources away from 0 through 4 before spawn actions, preserve
CLOEXEC/default signal/process-group behavior, and explicitly test the supervisor
and child inheritance on macOS and Linux. Do not weaken close-from behavior.

For diagnostic-only streams, make child write ends nonblocking before spawn;
owned emitters use bounded try-writes with no retry loop and count drops on
EAGAIN/EPIPE. Configure the Dart-launched helper's diagnostic stdout/stderr only
in its socket/storage server branch, after `--build-id` and
`supervise_worker` have returned/not matched, before schema/vendor setup.
Never change stdout flags in build-id or supervisor mode: the supervisor passes
fd 1 to inference/speech as their protocol stream. Dart does not expose those
pipe descriptors. Inference's copied protocol descriptor
remains blocking with its existing backpressure; only its distinct diagnostic
descriptor gets nonblocking mode. A stalled parent must not block an owned
child's application threads on logging. If a safe diagnostic pipe cannot be
installed, use `/dev/null` and report lost diagnostic availability in the parent.
Presentation/result streams retain their existing backpressure and deadlines;
do not set nonblocking mode on PCM or protocol channels. After the parent dies,
EPIPE/dropped diagnostics must not kill a helper that is eligible for adoption.

Use RAII for pipe ownership and nonblocking polling. Never hold launch/process
locks during logging I/O. Keep diagnostic drains alive through owned-child
termination, but stop waiting for inherited descendant descriptors after a
bounded deadline; EOF is not a new shutdown precondition. Throwing/closed sinks
cannot escape C ABI barriers, lose ownership cleanup, or change operation results.

Core Audio and other realtime callbacks increment existing/preallocated atomic
counters only. Worker threads summarize xruns/device failures; no allocations,
locks, FFI calls, JSON, file writes, or log callbacks on realtime threads. No log
event per audio buffer, PCM sample, token, transcript chunk or capture-level tick.

### Logging implementation steps

These five logging steps are ordered implementation commits inside stage B of
the single PR. They are not separate PRs and have no file-count cap. Step 0's
inventory/proofs precede foundation code; then integrate Dart before native
delivery and finish support/qualification. Keep checkpoints functional and
update CHANGELOG for user-visible changes.

| Step | Deliverables | Exit condition |
| --- | --- | --- |
| 0 Inventory and fixtures | Enumerate every diagnostic/output owner, event catalog, sensitive-field policy, syscall/FD ownership table, source/head baseline, representative timing/RSS baselines | Every production site classified; no reliance on the untracked audit document |
| 1 Core foundation | Typed events/configuration, bounded producer/writer, secure storage/slots, fake and real sinks, core docs | Standalone multi-process fixtures prove quotas, privacy, queue and sink failure behavior; no app wiring required |
| 2 Dart integration | Bootstrap service/desktop/MCP, explicit isolate producers, error handlers, correlation, migrated Dart sites, replacement mac startup capture | Detached startup and real compiled service/MCP/desktop fixtures retain safe diagnostics without changing protocols/lifetimes |
| 3 Native integration | Additive drain ABI/bindings/compatibility checks, native queue, child diagnostic drains, C++/Swift events, sealed config | Root native tests and full compiled boundary suites pass, including flood and cancellation cases |
| 4 Support and completion | Open logs folder, health status, event/config/retention/troubleshooting docs, inventory guard, residual-site review | Final combined matrix and independent reviews pass; all residual sites have an explicit disposition |

Logging step 3 depends on logging step 1's frozen schema and storage; integrate logging step 2
first to avoid partial native event loss. No native logging callback ABI is added.
Update all affected native fixtures and ABI/version guards. Feature-detect the
additive diagnostic symbols before binding them. An otherwise compatible older
native library without them disables native diagnostics with a safe health
reason; it does not disable application operations or cause a lazy symbol-lookup
crash. Existing incompatibility checks still reject genuinely incompatible
native runtimes. Logging alone does not change a public protocol version.

For Flutter, install framework/platform/zone handlers once, preserve previous
reporting and fatal handling, and deduplicate the same reported failure. Initialize
bindings and `runApp` in the same zone. Do not swallow startup or worker failure
notifications. The desktop settings action uses the existing platform service
boundary; it reveals only this profile's validated directory, not sink controls.

Remove `traceServiceTransport` and free-text diagnostics only after their callers
have typed replacements. Preserve CLI presentation fixtures. Add a narrow source
inventory guard against new unmanaged diagnostic sinks, with explicit exceptions
for intentional user/protocol/tool output; do not ban every `print` mechanically.

Rollback disables persistence (`off` for all logging, or in-memory health only
when admission fails) without changing on-disk data schema or application protocol.
An old binary ignores the private logs directory; do not automatically import
legacy free-text logs or require migration of them.

### Acceptance matrix

| Area | Required executed evidence |
| --- | --- |
| Contract | Schema/version/severity filtering, lazy fields, safe exception/stack encoding, UTF-8 byte caps, invalid-field rejection, default/off/legacy trace precedence |
| Privacy | Secret/content/path/URL/account canaries through every product Dart/native/bootstrap/frame/health sink, including new provider-switch/manual OAuth flows; decoded JSONL and raw file scans; workspace clear keeps no content identifiers; no logger fd-2 writes |
| Queue | Flood all producers and native threads; verify credit and RSS bounds, reserved severity capacity, aggregation, recoverable writer/producer exit, no unbounded SendPort or newline-free buffers |
| Storage | Real concurrent processes rotate/restart and contend for role slots; assert byte/file bounds, failure evidence after 20+ short/admin/forwarded/MCP/contended/withdrawn launches, post-lock owner admission with shared slots full, lazy candidate admission, lease release after crash, same-process/second-isolate registry versus external reclaim, unsupported/network filesystem refusal, no child inheritance, active-writer protection, aliases/profile isolation, age and clock rollback behavior |
| Filesystem security | Private-at-create modes, symlink/hardlink/foreign/unsafe permissions and directory replacement races, incomplete/tampered manifests and segments, unknown-entry refusal |
| Sink faults | Inject short writes, ENOSPC, quota/permission/read-only errors and blocked file FFI; assert no logger writes or fd-flag mutations with stderr redirected to a full pipe, closed descriptor, or flow-controlled TTY; additionally exercise real ENOSPC on a disposable constrained filesystem where supported; distinguish external/injected causes without requiring errno classification |
| Lifecycle | Early startup failure, no inherited stdio, logger failure/hang, compiled service/MCP natural exit when healthy and explicit same-code exit after a writer timeout, complete final protocol/presentation bytes, admin early return, desktop async forward/startup quit with Retry disabled versus native window/menu quit, SIGTERM/worker crash, service close/restart/stop, no authority-release regression, no flush dependency, no leaked ports/threads/children |
| Ownership ordering | Post-lock failure before ready gets protection; ordinary queue saturation/unregister cannot drop the session-owned decision; frontend errors/close arriving first classify after it or a terminal unknown fallback; installation-lock, environment and local-owner setup failures emit pre-lock outcomes and exit naturally with a healthy writer; contended/withdrawn/unknown candidates never receive owner protection; no ports when off |
| Protocol | Compiled MCP stdout exact framing, service-admin output/progress, authenticated optional bridge metadata, concurrent requests/retries/outcomeUnknown, native inference/speech and PCM boundaries |
| Native ownership | All closed-stdio masks, build-id/supervisor/server branch flag separation, supervised protocol stdout remains blocking, stderr flood before ready, stalled parent, invalid UTF-8/no newline, vendor output exactly matching registered JSON still discarded, descriptor-holding descendant, cancellation/failure during flood, adopted helper failure after service restart, broken sink, exit after protocol stdout closes |
| Desktop | Framework/platform/worker failures logged once, startup retry, settings Open logs folder, process still usable with full/unavailable storage, desktop feature API guards |
| Performance | Compare identical operation/RPC/capture fixtures with logging off/default/trace; record throughput, p50/p95/p99, RSS, allocations and drop counts; no realtime callback work or unbounded tail latency |

Extend existing regression owners rather than create parallel harnesses:
`tests/native/spawn_contract.cpp`, `probe_deadline.cpp`, `run_exception.cpp`,
`tests/inference/fd_stream.cpp`, `test_probe_failure.py`,
`tests/integration/test_native.py`, `test_native_process.py`,
`test_persistent_speech.py`, `tests/service/test_worker_recovery.py`,
`test_service_process.py`, core service/isolate/stop tests, and desktop startup,
boundary and integration tests. Freeze a deterministic test budget in logging step 0:
logger closure at most 500 ms after application teardown; protocol and child
cleanup retain existing deadlines. Reject default logging changes above 5 percent
median RPC overhead or 10 percent p95 on repeatable no-model fixtures unless a
documented measurement explains an explicit reviewed adjustment. Trace may drop
under load; it may not block operations or inflate memory beyond fixed bounds.

### Required implementation commands and evidence

Use a short private disk-backed temp root, for example `install -d -m 700
/var/tmp/of-log-tests`, and export both `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` to
it. Use exact current build scripts and pinned tool versions; no cache deletion
or unrelated successful-job reruns. Capture failed subprocess output privately.

- Dart: analyze and `dart format --set-exit-if-changed` for changed packages,
  followed by complete core and desktop tests.
- Native/protocol/service: build from repository-root CMake and run full
  `ctest --test-dir build --output-on-failure`. Run Dart core/desktop against
  that freshly built library/helper with `FORESIGHT_NATIVE_LIBRARY` and
  `FORESIGHT_HELPER`; run `FORESIGHT_CORE_COVERAGE_MIN=90 tools/coverage_core.sh`.
  Preserve any stronger current checked-in coverage gates.
- Service/capture/desktop boundary: compile current service/MCP and run
  `tools/build_service_gate.sh` with its current platform/build/Python arguments,
  plus desktop integration on an isolated display. Follow
  [integration gates](../validation/integration-gates.md) for fast, model and
  virtual-audio suites relevant to changed boundaries.
- Python/tooling changes: `ruff check .`, `mypy`,
  `python tools/check_subprocess_timeouts.py`, and `pytest`.
- Run relevant existing native sanitizer fixtures for new concurrent queue/FD
  code. Verify Linux/libstdc++ and macOS/libc++ shutdown behavior. Real models,
  virtual and physical audio, GPU, Finder/MCP-first launch and OS permission
  attribution have separate evidence; mocks do not qualify those paths.

For each logging step, retain source/build identity, exact commands, executed/pass/fail/
skip counts with reasons, coverage, fault-injection versus real-platform evidence,
and performance data. A skipped required fixture is incomplete acceptance. Fetch
the PR head/reviews/CI before a follow-up push and resolve findings against current
code in batches. Stage B itself needs no workflow permission, publishing,
artifact-trust or toolchain change; D/F retain their own owner-reviewed changes.

Trace-enabled service/isolate/process harnesses that currently rely on captured
stderr must attach this run's temporary-profile JSONL segments and logging health
on failure, alongside their original captured stdout/stderr and subprocess
output. Preserve incomplete file tails and the exact failing bytes privately;
do not substitute an older profile/session's logs or erase failed artifacts.
Update these harnesses as part of their producer migration, not after removing
`traceServiceTransport`. Logging step 0 also proves the actual standalone Dart exit
path with a blocked writer FFI call and loaded application libraries on both
supported toolchains; destructor safety is executed evidence, not an assumption.

New service/integration test modules update `pytest-exclusions.json` and retain
the discovery guard. Dart fixtures use `createTestTempDirectory[Sync]` from test
support, with resource cleanup registered after allocation through `addTearDown`,
as CONTRIBUTING specifies; they do not hardcode `/tmp`.

## Stage C: ownership, boundaries and local hardening

### Client and service contracts (F14/F15)

Extract pure request/result DTOs, protocol errors and shared helpers such as
`outputWeekStart` from server-owned modules. Split client/server barrels and
bootstrap. Assert that desktop and MCP adapter transitive closures, including
conditional imports, exclude service authority, native capture/runtime and
mutation modules. Preserve the deliberate read-only SQLite snapshot path with
a narrowly named boundary; name hiding and extra `part` files do not fix the
compile graph. Keep the service executable as the mutation/native owner.

Replace whole-`Domain` coordinator dependencies with explicit ports and a single
composition root. Put typed encoders/result decoders on operation contracts and
migrate all 72 inventoried dynamic command call sites, re-counting on current
head. Keep public RPC compatibility or version changed semantics deliberately;
do not duplicate a parallel registry or weaken decode-first admission.

Move acquisition/install/cancel/progress and audio enumeration into service
operations, preserving explicit user consent for OS permission requests.
Unify downloader machinery behind the bounded acquisition policy from A.
Extract meetings/sources controller widgets into independent libraries with
immutable view data and callbacks; eliminate their shared private-state coupling.
Count logical libraries including parts in the size/complexity guard. Preserve
rendered selection, dialogs, async retirement, accessibility behavior and stale
workspace-response rejection with existing UI oracles.

### Generation ownership and asynchronous retirement (F14/F16/F22)

Create a single `GenerationRuntimeSlot` with epoch plus identity checks after
every await. A losing discovery/load candidate closes once; replacement retires
the old owner once, without allowing stale work to publish a new handle. All six
current adoption/replacement sites route through the slot. Cancellation reserves
ownership until its producer and native cleanup actually settle.

Before changing close, inventory every Dart, C++, Python and runner consumer.
Define synchronously detached handles, one destruction owner, request-close and
awaitable completion; repeated close joins that completion. No polling, callback,
replacement or new request may touch a retired handle. Engine teardown waits
for child workers and plaintext/model leases; partial initialization and failed
loads follow the same protocol. Borrowed raw pointers must not cross isolates.
Preserve frontend/refusal/shutdown ordering and helper ownership verification.

Use the reporter/fallback hardening introduced in B before its new C exports.
Verify `ffi_barrier`'s reporter and fallback paths stay nonthrowing: the current
mutex/string reporter and conversion of `error.what()` can themselves fail
inside a catch. Use bounded nonallocating storage or swallow reporter failures
and retain a constant/numeric fallback independent of logging. No secondary
allocation/lock/reporting failure may escape the export or worker boundary.
Route C exports through the hardened shared `ffi_barrier` while preserving each return
sentinel/error contract and free/destroy semantics; explicitly handle genuinely
nonthrowing/version functions. Guard against new unprotected throwing exports
and test thrown allocation/standard/unknown exceptions at representative exports,
including sustained allocation failure and simultaneous reporter failure.
Assert the original sentinel/cleanup result and that no C++ exception escapes;
error retrieval itself must have the same nonthrowing fallback guarantees.
Check `fs_abi_version` before binding or calling version-dependent functions;
negotiate optional diagnostics separately so a missing logging feature does not
make a compatible runtime unusable.

Acceptance: held producers, late polls, repeated close, partial load, cancelled
discovery, competing replacement, child failure, lease deletion ordering and
shutdown; root sanitizer matrices with positive controls; libc++ and libstdc++
stream-error paths. Fresh-source Linux/macOS real-model teardown and
`tools/measure_service_rpc.py` comparisons must identify native-active work and
actual child reaping. Use the existing warmed p95 responsiveness target of
50 ms; record baseline, workload progress and drain/drop metrics, not only idle
timing. Hardware/model paths not run remain explicitly unqualified.

### Local security and read policy (F13/F21/F23)

Keep the documented same-user default; add an opt-in policy for transcript,
note and Drive reads, with expiring/revocable client-scoped grants and no hidden
headless consent. Mark MCP results with provenance and untrusted-content tags
without treating those labels as a prompt-injection defence. Test denial, expiry,
revocation, disconnect/reconnect and authorization before data access; updates
to every MCP result shape include adapter/SDK interoperability coverage.

For imports, anchor to an approved root descriptor and use no-follow open/fstat
validation through every traversal component; pass the already-opened resource
to the sandbox rather than reopening the name. Define equivalent macOS sandbox
handling and descriptor lifetimes. Test path swaps, parent symlinks, hardlinks,
special files and non-regular inputs against real sandbox fixtures.

For helper identity, verify process start identity and executable device/inode
without trusting a stale PID or the literal `/proc` deleted suffix. Preserve
safe shutdown of a verified pre-upgrade helper; mismatch must fail closed.
Render approvals as bounded key/value data with escaped controls and explicit
trusted labels. Bound child output buffers, check every spawn-file-action result,
and resolve owned helper/worker executables explicitly instead of searching
`PATH`; retain documented developer overrides through validated configuration.

Create the initial desktop capability file privately at open, matching safe
rotation semantics. Remove persistent access-token duplication when a secret
store is used; expose a failed refresh-token secret-store write to the user and
make any plaintext fallback explicit. Never log credentials or silently discard
the only working grant. Test creation races/modes, migration from existing
tokens, secret-store unavailable/recovery and #178 provider switching.

Restart read workers after EOF/failure using fresh ports and worker generations;
do not retain permanently completed `_starting`/`_exited` futures. Invalidate
stale responses, close on shutdown and keep tracking SQLite work until actual
settlement even after subscriber deadlines. Bound queued reads and socket bytes;
a stalled client is closed with owned producers cleaned up and cannot block
capture/other clients. Give long-running reads a bounded execution budget and
connection/job-scoped SQLite cancellation. Because an isolate running synchronous
SQL cannot consume a cancellation message, first prove a safe progress-handler
deadline or an owner-controlled interrupt mechanism with no borrowed handle
crossing isolates. A subscriber timeout alone is insufficient. Keep the
coordinator's reservation until the statement actually settles, then admit the
next query. Test a deliberately long query, cancellation races, worker exit and
the next query's independence; no unrelated connection or replacement job may
receive the old interrupt.

Inject immutable runtime configuration through ports, remove the six-module
import cycle, and inventory the 52 ambient reads, subtracting the explicit
distribution-credential exclusions from the refactor target. Inventory preference-prefix
entity records and replace them with typed tables/foreign keys via ordered
migrations where they represent relational entities; genuinely scalar settings
remain preferences. Apply A's backup/restore and migration acceptance. Record
each retained case with its reason; do not close F23 merely because busy timeout
and worker restart are fixed.

## Stage D: verification, release assurance and documentation

### Honest executable acceptance (F12/F25)

Add a compiled first-run desktop/service/MCP journey using deterministic loopback
metadata/downloads: fresh profile, partial setup, restart, interruption, checksum
rejection, retry, adoption and indexing. It must traverse the actual setup UI and
production acquisition service rather than the helper that skips setup. A tiny
fixture is not real-model/physical-audio acceptance; retain those separate gates.

Wire the raw-query executable into its actual CTest/integration owner, or record
an explicit executable manual path and truthful exclusion reason if its assets
require separate authorization. Wire the isolated Keychain fixture with
`FORESIGHT_MODEL_CRYPTO_KEYCHAIN_TEST=1` into macOS validation. Do not infer
Developer ID, Finder or real TCC permission acceptance from that fixture.
Inventory the manual probes with owners, trigger/prerequisites and evidence;
missing LiteRT cannot pass a lane whose selected scope requires LiteRT.
Replace the proactive application's wall-clock race with held completers/fake
time, retaining the success/failure oracle; run it under CPU load without retries.

Enable LSan in both sanitizer script and workflow, with narrowly documented
CPython suppressions and a deliberate unsuppressed-leak control. Preserve ASan,
UBSan and TSan positive controls. Test the TSan probation transition around
**2026-10-25 UTC**, and inspect an actual post-deadline hosted run; it has not
expired as of this plan's date. Add report-only native line/branch coverage with
llvm-cov and explicit exclusions, not a guessed coverage percentage.
Retain Linux's 90% core/desktop floors and Python's 95% combined line/branch
floor. Default decision: document macOS coverage as report-only until comparable
executed data supports an owner-reviewed floor; do not claim a macOS PR gate or
combine Python/Dart/native percentages into a repository-wide figure.

### Dependency and release controls (F10/F11/F17)

Extend existing `tools/pins.json` and consistency tests to cover remaining native
commits/digests, duplicated gRPC inputs and macOS ICU; do not invent a competing
manifest. Snapshot Linux package-builder inputs including RPM/Arch tools, pin
or build ICU, and compare reproducibility on the same source/input identities.
Review current Dependabot successors rather than blindly resurrecting closed
#113–#116; consolidate compatible action updates, preserve SHA pins, add intended
Ubuntu/Fedora major-version ignore rules and document compatibility constraints.
Record a one-line PR justification for each SDK/toolchain input change.

Arrange an owner-provided GitHub App for snapshot PRs so they trigger normal CI;
request only the permissions needed by that bot. Scan native/SBOM/package inputs
in addition to Python/pub locks. Distinguish scanner execution failure from
findings; assign a triage owner and open High/Critical findings with component,
affected scope and remediation dates. Dev-only findings stay visible with their
scope. Severity-based publication blocking is an owner-reviewed policy change,
not a silent alteration of existing release behavior.

Prepare CODEOWNERS for workflows, CI/trust code and packaging, and the protected
release environment with required reviewer/main-only deployment and one required
code-owner approval. Record the actual owner settings changes and verify them
read-only after application; a YAML file cannot prove platform enforcement.
Keep the distribution-credential sourcing exclusion intact when designing the
environment. Strengthen documented attestation verification with source ref and
signer workflow, not only repository identity.

Bind manual acceptance receipts to source/tag and every final installer digest,
required per-platform scenarios, tester identity, observation time and explicit
outcomes. Validate schema, trusted reviewer and authenticity/integrity according
to the owner-approved mechanism before publication. Missing, stale, tampered,
wrong-source/platform/hash receipts fail. Audit acceptance reuse and
`skip_gpu_validation` so neither bypasses the new manual requirement. A waiver
is an explicit scoped owner decision and is never represented as a passed test.
Keep physical audio, permission revocation, sleep/wake, native export and
quarantined Finder launch as observations, not simulated acceptance.

Changes to workflow permissions, publishing jobs and artifact-trust code require
owner review under [CI integrity](../platforms/ci-integrity.md). Prepare code,
tests and a settings checklist before that review; do not weaken protections
or change external authority during this planning task.

### Reduce drift and operational weight (F18/F24)

Correct coverage claims, v18/v19 and subsequent migrations, all MCP tools/handler
counts, removed OAuth import text, release flow, ADR status and macOS desktop
support against current code. Generate or verify drift-prone facts from their
registries/configuration. Add a relative-link checker to the existing quality
lane, repair all broken links without recreating private `.granola-analysis/`
data, index the seven orphaned documents plus ADRs/RELEASING, and give every
plan a current/complete/superseded status. Remove machine-local paths from active
instructions; keep historical evidence paths clearly marked as historical.
Fold topic-specific docs/CHANGELOG updates into A–C/E/F; D performs the final
index/drift sweep without claiming future behavior already exists.

Freeze CI tooling scope, list the three high-frequency cron duties and consolidate
their schedule by required freshness rather than dropping checks arbitrarily.
Honor the user's explicit file-limit override: report changed files and provide
stage/owner navigation without a size-based rejection or mandatory split.
F24's proposed 100-file enforcement is intentionally waived for this work; keep
its other CI simplification, fixture-integrity and maintenance requirements.
The separate repository-wide size-check recommendation remains an open policy
decision, not an implemented or passed control. This PR's explicit size waiver
does not silently settle the policy for unrelated future work.
Remove transitional mechanisms only with an owner-reviewed replacement and
hosted safety evidence required by CI integrity; no blanket trigger deletion.
Move the large evidence tarball to a checksummed immutable fixture asset or LFS,
preserving offline/Git-free-export tests through an explicit verified fixture
provisioning step. Do not turn the offline Python suite into an implicit network
consumer or delete the original negative byte-level assertions.

## Stage E: tooling quality without a repository-wide flag day (F22/F24)

Inventory all in-scope Python entrypoints/import consumers before assigning
batches; leave the explicit distribution-credential paths/tests unchanged.
Make `tools` a real package; establish `python -m tools.<module>` for primary
entrypoints and update workflow, shell, documentation, installed/exported and
test callers together. Retain thin direct-script compatibility wrappers where
they are part of an external interface. New package imports must work from a
Git-free source export and without ambient cwd/PYTHONPATH assumptions.

Convert `sys.path` and dynamic import/runpy uses to normal package imports where
their semantics permit; record genuinely required fixture/loader cases explicitly.
The audit reports 84 path insertions and 38 dynamic loads. Convert them in
inventory-derived commit batches within the single PR, with one direction of
dependency and no half-converted entrypoints; file count does not require
additional PRs. Do not mark
the full import cleanup complete after adding only `tools/__init__.py`.

Introduce `tools/_common.py` only for truly shared digest/subprocess helpers,
preserving checksum algorithms, finite timeouts, captured output and exact return
semantics. Replace opaque smoke assertions with actionable `require` diagnostics
that show safe observed values. Derive operation boilerplate/counts from the
existing registry instead of a second hand-maintained source of truth.

Start per-module strict-typing and complexity ratchets with the shared `ci_*`
modules and touched consumers. Enable `avoid_dynamic_calls` in core after fixing
the inventoried sites. Add warning-clean native targets before broadening
`-Werror`; introduce report-only clang-tidy with an explicit reviewed baseline.
Keep ruff C901 and Python strictness debt measured, and forbid new debt in
ratcheted modules rather than blanket suppressions or mass annotation churn.
The 964 untyped-definition errors and untyped test suite are a measured residual,
not a claim of full strict typing. Track subsequent module batches in the same
execution issue; F22 is closed only to its stated ratchet/import/barrier outcome,
with remaining metrics disclosed.

## Stage F: trusted distribution and recovery (F20)

A supplies pre-migration backup and tested offline restore. Finish user-facing
rollback instructions with compatible application/schema versions, installed
binary/helper identity and the backup's data-loss point; never open a newer
schema with older code or silently overwrite the only good profile.

After the owner provides Developer ID/notarization access and a Linux signing
policy/key location, sign/notarize/staple macOS delivery and sign Linux packages
or publish a signed repository. Keep signing permissions/secrets out of PR code
execution. Signing changes installer bytes: generate final hashes, attestations,
manual receipts and installed acceptance from the final signed installers.
Exercise quarantined Finder launch and fresh-account TCC attribution on actual
macOS; run installed/upgrade acceptance across supported Linux package formats.

Add a minimal opt-in update notice using authenticated release metadata, with
finite network deadlines and version/channel checks. It downloads no installer,
executes no update, sends no profile/content data and cannot block application
startup. Test offline/timeout, malformed metadata, wrong channel, downgrade and
signature/identity failure. Document manual update/rollback and end-user trust
verification. External identities, keys, hosting and physical-platform acceptance
remain visible blockers until actually provisioned/executed.

## Coverage of all findings

Each checklist entry includes the full finding, not just its headline. Completion
is recorded per subitem with source/tests/evidence or an explicit unresolved
owner decision. Deferred/blocked is never a passed result.

| Finding | Delivery | Required closure evidence |
| --- | --- | --- |
| F1 | A | Start/stop/hide/disconnect storage faults physically stop capture; preserve original error |
| F2 | A | New migration, bounded history for all five entities including tasks, live-notes growth and backup/erasure |
| F3 | A | Incremental/idempotent live index, citations and measured near-linear processed content; interim throttle remains open |
| F4 | B | Detached service/worker failure diagnostics survive, private and bounded |
| F5 | A | Duplicate ID rejection, owner-checked cleanup and raw-socket cancellation/limit tests |
| F6 | A | Recording released after drain before indexing; next recording and recoverable background job |
| F7 | A/C | Every transport phase and total retry deadline; abort, cancellation, reservation/model retention |
| F8 | A | TMPDIR and compatible Linux/macOS per-user installation lock protocol |
| F9 | A/C | Off-isolate listing/SQL lookup, queue/execution timing, persistence retry and measured drain behavior |
| F10 | D | Dependency/SBOM coverage, distinct scanner failure and assigned actionable triage |
| F11 | D | Verified platform protections, workflow/ref instructions and authenticated hash-bound manual receipt |
| F12 | D | Compiled first run, raw-query/Keychain execution owner, truthful probes and deterministic proactive test |
| F13 | C | Opt-in scoped read policy and provenance, default trust-model compatibility |
| F14 | C | Real import closure, narrow ports, one generation owner and typed calls |
| F15 | C | Independent logical widget libraries, service model/device ownership and one downloader |
| F16 | C | Awaitable single-owner retirement, consumer audit, sanitizers/current-source model/RPC evidence |
| F17 | D | Reviewed updates, existing pins extended, bot CI trigger and reproducible package/ICU inputs |
| F18 | All/D | Every drift item/link/index/status repaired; registry/config-based checks |
| F19 | B | Fixed/registered RPC errors across desktop/MCP/helper plus safe logs/correlation, bounded macOS log and support guide/form |
| F20 | A/F | Backup/restore/erasure plus final signed-byte trust, update notice and platform acceptance |
| F21 | C | Descriptor import, process identity, safe approvals/spawn and capability/token-file/secret-store cases |
| F22 | C/E | Nonthrowing ABI barriers/reporting, package/import cleanup, shared helpers, smoke diagnostics and disclosed quality ratchets |
| F23 | A/C | Worker restart/cancellation, transactional imports/busy timeout, backpressure/ABI plus config/cycle/entity migrations |
| F24 | D/E | Cron/replacement safety, size visibility under this PR's waiver, repository-wide size-gate policy explicitly open (not passed), fixture integrity and registry boilerplate |
| F25 | D | LSan/positive controls, post-probation hosted TSan, native reports and truthful macOS coverage policy |

## Verification and reporting contract

Run focused checks at the ordered stage checkpoints, then the complete applicable
matrix once on the final combined PR head. Reuse valid evidence only for exactly
unchanged inputs with its original provenance; every changed surface gets its
required checks. Do not repeat an unchanged successful full matrix merely
because another commit adds planning prose. Any emergency/follow-up PR has its
own applicable head qualification.

Focused-only checkpoints stay local and are not pushed. Before every push to
the GitHub PR branch, including drafts and follow-up review/CI fixes, run the
full AGENTS.md before-push checks for all surfaces changed since the last fully
qualified push. Native/protocol/service changes require the complete root
CTest, fresh-library/helper core and desktop suites and coverage; boundary
changes also require compiled service/MCP and isolated-display integration.
Keep final-head combined qualification and valid unchanged-input evidence
separate from these mandatory pre-push obligations.
Use the commands in [AGENTS](../../AGENTS.md), CONTRIBUTING and
[native verification](../../native/README.md#verifying-native-changes).
Create a short private disk-backed directory with `install -d -m 700` under
`/var/tmp`; export both `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` to it for every
tool/build/test subprocess. Keep full failed stdout/stderr and test artifacts.
Storage exhaustion is infrastructure failure, never a pass.

| Changed surface | Mandatory checks |
| --- | --- |
| Python/tooling | Supported Python 3.13 and pinned locks; `ruff check .`, `mypy`, `python tools/check_subprocess_timeouts.py`, full `pytest`; retain 95% combined line/branch coverage |
| Dart/Flutter | Core `dart analyze`, desktop `flutter analyze`, pinned Dart `dart format --set-exit-if-changed` over affected sources, complete package suites; Linux core/desktop 90% floors |
| Native/protocol/service | Fresh repository-root CMake build and full `ctest --test-dir build --output-on-failure`; complete core and desktop suites with exported `FORESIGHT_NATIVE_LIBRARY` and `FORESIGHT_HELPER` pointing to that build, plus `FORESIGHT_CORE_COVERAGE_MIN=90 tools/coverage_core.sh` |
| Service/capture/desktop boundary | Fresh compiled service and MCP suite under `tests/service` plus desktop integration on an owned isolated display; native UI contract `test_native_desktop_and_mcp_share_service`; both test-hook modes and release hook refusal |
| Lifetime/native ownership | Root ASan/UBSan/TSan and positive controls; applicable real-model/virtual-audio gates; Linux/macOS and libc++/libstdc++ cases specified above |
| Workflow | Hosted-version actionlint with ShellCheck verified on PATH; required workflow/platform selection checks; no inferred shell pass |
| CI artifacts/cache/release tools | CI integrity suite, complete Git-free source export, explicit unrelated PR/main/unset-ref fixture metadata, real archive/checksum/provenance and receipt/reuse rejection assertions |
| Packaging/distribution | Actual supported Linux installed and N-1 upgrade acceptance, actual macOS package/Finder/TCC/signing paths; final signed byte identities for all downstream evidence |
| Documentation | Relative-link/anchor checks, generated facts/current gate values, source-status and Markdown whitespace checks |

The Dart build wrapper currently exports native paths inside its core subshell;
explicitly export them for desktop and coverage invocations as well. On macOS,
also use the freshly built owned SQLite runtime required by the platform guide.
Never substitute `/opt/open-foresight` or historical app binaries for fresh
application/native outputs. Reuse verified dependency SDKs/models with original
provenance; do not delete caches or rebuild dependencies to debug unrelated code.

Inspect pass counts, skips, deselections and terminal reporter events; reconcile
them with the inventory on that source instead of copying the audit's old counts.
Selected integration gates require their exact current count and zero skips.
Record unavailable Docker/macOS/GPU/physical audio/permission/model tests as not
executed, with owner/prerequisites; mocks and source review never qualify them.
Do not lower gates, remove assertions, add retries or relabel a failure as a skip.
Before a follow-up push, fetch PR head, review threads and CI, read failed-step
output and batch verified fixes. Run failed jobs first; do not rerun unrelated
successful jobs without a changed-input or unresolved-concern justification.

## Execution and review completion

For each completed stage record actual changed-file count, issue/PR, source head,
applied migrations, commands/environment, binary/model identities, counts/skips,
coverage, raw evidence locations, external blockers and each F-subitem outcome.
No overall closure while an unresolved required subitem is hidden by a green
aggregate. Owner-dependent signing/protections can remain pending without
delaying independently qualified recording repairs.

For this combined plan, freeze the complete document and SHA-256 before each
round. Three native agents review runtime/privacy, architecture/native ownership
and verification/release scope; Claude CLI independently reviews the same
snapshot with read-only source tools and no MCP integrations. Each reads the
entire revision and instruction files before inspecting peer reports. Verify
findings against current source, record dispositions, revise/freeze and repeat
with all four reviewers. Explicitly include the lifted size cap in each prompt;
reviewers must not reintroduce it from the historical source documents.
Converge only when all four explicitly find no unresolved substantive planning
issues on the same full revision/hash. If source or substantive plan text changes,
the earlier verdicts no longer close the new revision. Keep full private review
outputs and publish a compact repository review record. Planning review
qualifies the document only. Execute and qualify the implementation through the
local-worktree/HanSolo/final-GitHub flow above; only the verified final merge to
main completes the execution goal.
