# Core service and desktop feature refactoring execution plan

Revision 16, 2026-10-22. Reviewer verdicts and scope of convergence are recorded in the companion
review record. This is the execution specification for planned PRs 6 and 7 in [audit plan
3](../audit/2026-10-18-implementation-plan-3.md), not GitHub pull requests #6 and #7. The [review
record](2026-10-20-core-desktop-refactor-reviews.md) records frozen revisions and finding
dispositions. This revision reviews the owner-approved combined delivery before implementation
continues; planning approval does not establish implementation or runtime validation.

## Baseline and scope

The implementation source baseline is fetched `origin/main` at
`3fb259243a99137e3cba1d5e795c44100f42e688` (PR #168, after release 0.1.3). The immutable full
source export used for this refresh is recorded in the review record. The earlier ADR-0007 branch
`fea1fe93` remains historical review evidence, not the implementation source. ADR-0007 is now
merged in #164, on top of lifecycle follow-ups #160/#162; its reconciliation prerequisite is
complete. Main subsequently merged CI stabilization #163, Summary #165, meeting AI workflows #166
and release/GPU-policy changes #167, then owned-DMG recovery/parallel contract restoration #168.
Preserve that combined reviewed-main behavior. The local
checkout may still be older; use the pinned main commit for code facts and current commands rather
than silently treating local HEAD as the baseline. Before implementation, fetch main again and
record its actual SHA, schema versions, test inventory and metrics; if it moved, assess the delta
before extraction. Read ADR-0007 revision 7 and the current meeting Summary/AI architecture docs
at this source commit.

The final fetch during revision-10 review caught #168 landing. Its twelve changed files affect
DMG recovery, contract tests and CI selection/ordering, not core/desktop/native/helper code.
Tree/blob identities including modes were independently compared for the complete application,
native/services/protocol/CMake trees, AGENTS, pins and relevant runtime/host gate scripts; all are
byte-identical between c28 and 3fb. The complete new source export and delta proof are recorded in
the review record. Existing runtime measurements, compiled outputs and pass counts remain labeled
`c28a1561`; unchanged source is not a new compilation or a final-head acceptance result. Advance
the integration branch to this reviewed main before subsequent complete gates; the core checkpoint
and final-head matrices retain their exact-source requirements.

Owner delivery direction (2026-10-21): execute the complete PR 6 and PR 7 scope on
`refactor/core-desktop` as one PR. The old PR numbers below identify work packages and their
internal dependency order; they do not require separate PRs or an intervening merge. Keep
independently testable commits, integrate the core interfaces before migrating their desktop
consumers, and preserve both work packages' complete acceptance criteria. Coordinate exact-source
Mac verification on HanSolo in a dedicated worktree. The owner's latest direction (2026-10-22)
is to create a draft PR soon, with remaining implementation and validation disclosed. This
supersedes the earlier requirement to finish the final HanSolo matrix before PR creation;
complete final-source Mac acceptance remains required before merge. Run native-team and Claude
CLI implementation reviews, revise until those converge, and drive the PR's required checks and
reviews to merge. The plan-review rounds recorded here precede implementation
review and cannot substitute for it.

Owner coverage direction (2026-10-21): improve measured Dart core and desktop line
coverage to at least 95%, while keeping the enforced Linux minimum at 90%.
Reach the core target at the core checkpoint and final combined head. The owner
subsequently accepted the current desktop coverage for now (2026-10-22), so its
95% improvement target no longer blocks delivery. Preserve its enforced 90%
minimum and meaningful desktop characterization/extraction tests. Python retains its existing 95% gate. Use the actual CI
coverage commands and unchanged inclusion/exclusion rules. Record covered/total
lines, exact source, skips and uncovered behavior; add tests for meaningful
success, failure, stale-publication and cleanup paths rather than mirrored
implementation assertions. A 90% gate pass alone does not complete the requested
core 95% improvement. Do not raise the minimum, exclude files or branches, or count
unexecuted platform/model cases to reach the target.

No production behavior change is hidden in a mechanical extraction. Error classification,
compatibility enforcement and data migrations are intentional changes with their own tests and
release notes.

| Baseline observation at `3fb25924` (application trees unchanged from c28) | Consequence |
| --- | --- |
| `application.dart` 2,856 lines plus Summary/workflow/preparation parts 231/285/219 (3,591 combined); `service.dart` 3,313; `store.dart` 1,803; `remote_domain.dart` 1,053 | File separation is partial; shared-private Application parts are not independent services. Preserve the service lifecycle explicitly and measure aggregate scope. |
| `Operation` still has negative-list policies; handlers decode maps; `RpcError` extends `StateError` and classifies `TypeError` as caller error | Typed dispatch and error ownership remain pending. |
| Store schema 15: earlier migrations plus 14 (artifact manifests/Summary checkpoints) and 15 (action alias normalization/tasks/document-summary cache) | Freeze 1–15; allocate 16 or the next free version at implementation. Do not recreate delivered tables or normalization. |
| Google constructor still repairs modification times; its old source URI backfill is already a Store migration | Move only remaining constructor repair work. |
| Sources 2,386 lines, meetings 2,197 plus `meeting_ai_views.dart` 492 (2,689 combined), settings 1,348, integrations 669, chat 324, onboarding 282; main 1,059 | Feature modularization includes the new shared-private AI view part, onboarding, visuals and composition. |
| Capture levels already use a separate event/notifier path; ordinary UI revisions are coalesced | Preserve level isolation; characterize ordinary invalidation before narrowing it. |
| Frontend relay now coordinates closing refusals, socket ownership and worker failure | Keep the topology in these PRs. Its removal requires a separate evidence-backed decision. |
| DMG fixture contracts are independent of the `macos` application job after #168 | Preserve separate real runtime owners; a DMG-only selection must not force a full Mac build, and a passing fixture is not application acceptance. |

Summary, Action Items, Enhanced Notes, Live Q&A, document Preparation and scoped Chat are already
implemented. Reuse `summary_generator.dart`, `summary_output.dart`, `summary_prompt.dart`,
`meeting_actions.dart`, `meeting_preparation.dart`, `answer_source_scope.dart` and
`portable_query_setup.dart`; this plan reorganizes their ownership and boundaries, not their
algorithms or product behavior. Current `docs/architecture/meeting-summary.md` and
`docs/architecture/meeting-ai-workflows.md`, their validation records and frozen prompt fixtures
are implementation references. Those records report historical runs, not fresh validation of a
future refactor. `docs/architecture/schema-migrations.md` currently stops at 14 although code is
15; reconcile that documentation when preparing the persistence work, not by rerunning migration 15.

PR 8 remains deferred, including backend removal, wholesale native splitting and question-detector
consolidation. Native changes here are limited to helper schema integrity and any separately
characterized join/liveness repair needed by PR 6. Windows support, resident model unloading,
background-sync product policy and CI restructuring are outside scope. The Mac compatibility
follow-up is a narrow dependency exception: build application-owned SQLite 3.54.1 from its
checksum-pinned upstream amalgamation and select it through the protected runtime map for Dart
service/read isolates and desktop. Keep sqlite3's Dart API package at 2.9.4 and retain the existing
Dart/Flutter, helper SQLite, SDKs and toolchains. Preserve every original-source qualification,
future-version and read-only WAL guard. Package and sign the library with source/build provenance
and a checksum of its signed bytes; validate actual loaded identity, subprocesses and relocated UI.
This replaces the rejected writable PERSIST_WAL cleanup experiment, which broke Apple's live
read-only reopen semantics. It does not assert the cause of Apple's intermittent SHM ctime change.

## Execution status and checkpoint corrections

The current execution record includes PR #170 and exact fb925644 Linux/HanSolo host
matrices, with core coverage above 95% and both hosted native sanitizer jobs passing. That is not
the core checkpoint: a subsequently reviewed resume-discovery lifetime correction and a required
typed answer-scope projection must land and pass the updated full Linux matrix first. The latter
keeps the service's canonical scope digest authoritative when preparing scoped desktop history;
features must not copy the digest algorithm or import writable core implementation types.
Desktop characterizations are active; 7A production extraction and 7B/7C remain outstanding.
The progress record identifies actual hosted failures, source-bound evidence and the recovered
local Docker access. The updated23360009 canonical Linux matrix passes its90% gates but core
coverage is94.97%, so it is not the95% checkpoint; its full HanSolo matrix passes at95.39% core.
The next freeze batches the paused-recording coverage regressions, actual hosted Google-verifier
cancellation correction and valid MCP/graph/Stats review fixes. No historical failure or
intermediate review verdict is final acceptance.

The renewed review originally used core candidate `4bd2c75d5890399f03d57ce8a46788da2dfcc623`;
main resolved to `3fb259243a99137e3cba1d5e795c44100f42e688`.
At that review the initial core implementation existed and the focused6E seams were pending.
The following failure/correction requirements preserve that historical review input;
current source-bound execution status is in the companion progress record.
That complete container attempt passes
30/30 native targets, then fails the namespace guard at the unchanged 30-second deadline and one
graph-label fixture assertion: core 1,821 passed/14 skipped/one error; desktop 285 passed/17
skipped/one failure. Service, fast integration and platform Python do not run after those failures.
Both failed cases pass unchanged in isolation; these diagnostics neither resolve the complete gate
nor establish a cause for the timeout. Historical host passes remain bound to their original source.
The progress record retains exact attempts, counts, skipped cases and failed output.

Before freezing the next core candidate, diagnose the namespace guard using the actual required
container schedule and resource profile below. Preserve semantic transitive export/conditional
resolution, both entry points and every required/forbidden/import assertion. Any context or query
change needs complete namespace-set parity and the full required gate, not only an isolated pass.
Correct graph-label fixtures by source ID and `(documentId, labelName)`: opaque SHA256 IDs derived
from title and time do not sort by creation order. Retain per-document durable position, both
metadata/color associations, reopen, source revision/changed, JSON projection and deletion/cascade
assertions; test any global document order with explicit deterministic IDs in both lexical orders.
Do not change production ordering or ID generation to satisfy a global `.first` assumption.
Batch verified related corrections, freeze the actual source and rerun its complete applicable
Linux matrix before recording `core_acceptance_sha` or starting 7A production extraction.

The namespace/graph corrections and both6E seams have since landed. The c492
canonical baseline passes, below95% coverage; the subsequent94deb coverage-test
candidate fails one existing Linux connection-race assertion, so core acceptance
remains pending. Preserve the requirements above and the actual failure evidence.

HanSolo's original main compiler SDK has been provenance- and checksum-qualified without a rebuild.
The owner personally completed the Xcode license prerequisite; selected full
Xcode reports SDK27.0. Original dependency compatibility checks and a fresh94deb
native build pass all33 root cases. These results retain their source identity.
Final combined-source Mac acceptance still requires qualification of its full
runtime/development dependency closure (including ICU headers, FlatBuffers and
SentencePiece), locked pub/Pod resolution, actual
application configuration/dependency reuse checks, and fresh current native/core/desktop/process/
UI/installer gates. Prepare non-license prerequisites alongside Linux work before the final Mac
gate. Seek existing qualified outputs first; a verified content-addressed miss permits necessary
private compilation of pinned components with the reason/source/inputs recorded, as AGENTS allows.
An incomplete runtime bundle alone is not proof that a compiler-SDK rebuild is needed. Hosted Mac
checks do not substitute for the requested HanSolo matrix without an explicit owner change. CLT discovery,
original producer reports and cached runtime bytes are not application test results. Preserve the
original checkouts and verified dependency bytes; never accept the owner's license on their behalf.

## Contracts that must survive every commit

1. **Ownership and shutdown.** One writable application Store and one service owner per canonical
   profile. Keep the public frontend and private worker socket, the record/lock release order,
   closing refusals for undispatched work, `outcomeUnknown` for dispatched work without a proven
   result, and the single resend only for `closing`/`notSent`. Never replay an ambiguous mutation.
   Preserve helper identity/adoption verification and replacement-socket protection.
2. **ADR-0007 lifetime.** Desktop presence pins the service. Desktop-only departure keeps its grace;
   agent activity and helper-wait/dispatched/cancellation work follow revision 7's rules. The
   desktop branch still waits for serialized domain mutations. Idle exit sees all executing
   background work, including invalidated embedding drains; scheduled unfired timers and durable
   paused work do not falsely pin it. Only the service decides to exit. Extraction must neither lose
   nor double-count activity/busy state. Summary and meeting-workflow runs now contribute to
   `backgroundBusy`; `GenerationReservationGate.generationReserved` holds the generator between
   child calls. Foreground work joins preempted proactive/live-Notes cancellation before taking
   ownership, preserving queued jobs. Keep one reservation authority and underlying-child
   settlement.
3. **Approval and capability admission.** Preserve the exact per-operation host, approval,
   file-root, web-search and overwrite policies. Attach/bootstrap operations must remain reachable
   by their existing capability flow; do not mark every `security.*` operation as requiring an
   already attached host. No invalid request may start model work or acquire a write side effect. PR
   6 intentionally moves complete side-effect-free decoding before authorization: decode
   envelope/business arguments → reject stale workspace epoch → authorize/capability/approval →
   helper readiness → dispatch. Structural decoding is distinct from dynamic resource/permission
   checks. A structurally malformed stale request returns invalidArgument; a structurally valid
   stale request is refused before approval. Invalid approval-requiring requests emit no approval
   event. Preserve lease creation/origin and helper-wait accounting around this sequence; admission
   failures never stamp agent activity in the new order. This intentionally changes malformed agent
   requests: current code dispatches/stamps before handler decoding; decode-first rejection must
   return `invalidArgument`, never enter `_dispatched`, and leave agent activity unchanged at both
   dispatch and settlement. An already armed desktop-departure grace and its scheduled idle exit
   also remain unchanged; malformed input must not cancel the departure. Add a
   `service_lifetime_test.dart` regression and list this admission
   consequence among the PR's intentional lifetime changes; ADR-0007's definition of stamping when
   work starts remains unchanged. Durable idempotent replay stays inside authorized dispatch;
   decoding never returns a cached result before authorization.
4. **Commit and cancellation semantics.** Keep workspace epochs, idempotency keys, durable pending
   helper work, revision checks, after-commit notification ordering, cancellation cleanup and
   captured-transcript finalization. A cancelled future is not proof that underlying work settled.
   Keep operation completion separate from wire response delivery. Preserve atomic Summary
   artifact/checkpoint/derived-source acceptance and workflow artifact/task/cache/source acceptance,
   with indexing asynchronous afterward. Preview/progress is not accepted data. Preserve manual task
   details/completion/evidence/stale state, edited history, degraded results and retry identities.
   Source-scope identity is a privacy boundary: selected-empty never widens to Workspace, and a
   scope change invalidates in-flight retrieval/history/persistence and scoped web memory.
5. **Desktop behavior.** Preserve recording ownership on host disconnect, selected-meeting targets,
   recovery and reconnect behavior, transcript copying, autosave and enhancement edits, approvals,
   Google authorization/setup, navigation and onboarding. Late completions from a retired feature,
   connection, query or workspace epoch must not overwrite newer state. Keep the six meeting panels,
   Summary phase/previews/cancel/history, structured task editing, degraded Notes warnings, local
   Preparation selection and distinct manual/automatic answer scopes. Characterize missing switch,
   dialog, scope-change, clear and reconnect races before claiming they are already safe; any actual
   defect is a separately tested behavioral fix, not a weakened characterization assertion.
6. **Integrity and verification.** [AGENTS.md](../../AGENTS.md) governs dependency provenance, cache
   reuse and all gates. Reuse verified dependency SDKs; compile changed project code. Do not delete
   caches, weaken tests, substitute mocks for process acceptance, or represent reused bytes as a new
   build.

## Phase 0: establish an executable baseline

Owner: PR 6 author, with desktop author reviewing the interface inventory. Deliver before
extraction:

- Record the reconciled source SHA and run the verification matrix below once. Save counts, skip
  reasons, failures, coverage and command output. Existing failures need triage against current
  code; they are not acceptance waivers. Capture the root CTest inventory as well as any standalone
  native/helper inventory.
- Inventory every `Operation`, every service/client entry point (desktop, MCP, CLI, test support),
  MCP tool exposure, argument/default/nullable/unknown-field behavior, authorization and activity
  policy. Include `acceptsIdempotencyKey`, `carriesWorkspaceEpoch`, streaming, helper readiness and
  change notification. Record current payloads as focused characterization fixtures without private
  data.
- Inventory desktop accesses to Store, helper/channel/client, runtime status, account state and
  connection lifecycle. Classify reads, local writes and RPC writes. Identify the tests and tools
  using the concrete classes before narrowing them.
- Characterize behavior only where existing tests leave a gap: lifecycle/accounting across each
  extraction seam, RPC error mapping, Google repair, label conflicts, helper legacy databases,
  feature invalidation, asynchronous query cancellation and disposal. Each added characterization
  passes before the move; no blanket snapshot churn.
- Record file/function sizes and a reproducible RPC responsiveness baseline. Warm the actual
  helper/generator; measure `status` round trips during streaming and capture (100 samples,
  p50/p95/max), startup and idle, runner/toolchain and workload. A diagnostic records load; an
  arbitrary hosted timing assertion must not replace deterministic liveness tests.

Exit: the author can state which behavior each extraction must preserve, and every public desktop
dependency has a replacement or an explicit migration step.

## PR 6: core service structure

### 6A. Define operation contracts and compatibility before replacing dispatch

1. Introduce an explicit descriptor for each `Operation`: scope, read-only classification, approval
   policy, desktop/capability requirements, helper readiness, model gating, change notification,
   stream shape, epoch/dedup policy, and distinct activity-stamping and in-flight busy policies.
   Preserve the current distinction: `status`, `security.*` and `service.*` wire methods are
   stamp-exempt, but the lease busy check excludes only `status`; security/service calls currently
   bypass leasing. Test both descriptor projections and routing/lease parity rather than collapsing
   them into one flag. Use required constructor fields or exhaustive declarations; new operations cannot silently inherit permissive
   defaults. Preserve current operation wire names and service-only routing.
2. Define typed request values and one decoder per operation. Separate the wire envelope (request
   ID, epoch, idempotency key, cancellation/stream metadata) and service-injected
   conversation/request identity from caller business arguments. Preserve stale-workspace rejection
   before approval effects. Preserve currently accepted defaults, nullability, numeric values and
   additive fields; report validation failures as `invalidArgument` before authorization or invoking
   a handler. Carry the original `requestArgumentsDigest` alongside typed values: compute it from
   the original argument map with exactly the current key exclusions, recursive ordering, null-map
   handling, accepted additive fields and JSON numeric spelling. Do not derive it from a
   default-filled/reserialized DTO. Frozen pre-refactor `request_keys` rows must replay after
   upgrade; test nested/null fields, omitted versus explicit defaults, additive keys, `1` versus
   `1.0`, changed-argument refusal and epoch clear. A deliberate fingerprint change requires its own
   persisted-data transition. Have one registry own dispatch declarations. MCP tools remain an
   explicit subset with their existing names and adapters: generate their exposed schema from the
   same argument specification after applying tool-name/argument transforms, rather than exposing
   every internal operation.
3. Replace negative sets and prefix checks incrementally with descriptor reads, including ADR-0007's
   activity exemptions. Define registry membership by its single dispatch owner: ordinary
   application calls belong to the application registry; service/security operations and streams
   (`answer.stream`, `google.sign_in`, `google.add_account`) belong to the service registry and may
   delegate their implementation to application services. Disjointness concerns routing ownership,
   not a ban on delegation. Assert old/new policy parity per operation first; then remove the old
   tables. Admission and execution remain separate so helper waits and cancellations keep the
   current accounting. Test attach/detach/decide/import-root bootstrap independently.
4. Separate decoding errors from execution errors. Migrate `RpcError` to `implements Exception` only
   after auditing `StateError` catch sites in production and tests, including
   startup/CLI/desktop/MCP and helper verification. Preserve wire codes, optional reason fields,
   unknown-reason handling and byte-identical legacy closing messages. Decoder failures remain
   `invalidArgument`; unexpected handler `TypeError`s become `internal`. Do not blindly reclassify
   every `StateError` or serialize a stack trace to clients; retain diagnostic stacks in logs.
5. Enforce API compatibility for unpackaged as well as packaged clients, without breaking previously
   released version-1 peers. New clients always validate the service's advertised version during
   initial connect **and reconnect**, before business calls. Missing/unsupported advertised versions
   fail with a structured actionable error. An optional client-version field in the existing
   startup/status exchange lets a new server reject an explicitly incompatible peer; absence means
   legacy v1, supported while v1 payloads remain compatible. Keep install-root/runtime-revision
   checks in addition to API checks. Do not require a new mandatory handshake or bump the version
   for an internal refactor. Any incompatible wire change requires a separately specified version
   transition and peer matrix before implementation.
6. Extend operation-literal enforcement to `packages/foresight_core/bin/` and other actual
   consumers, with narrow fixture/schema exceptions. Cover registry exhaustiveness, schema/decoder
   equivalence for the MCP subset, malformed approval-requiring requests with no approval event,
   stale-versus-malformed precedence, handler exceptions, incompatible connect/reconnect, old/new
   peers, cancellation and internal operation non-exposure. The malformed-agent lifetime fixture
   must assert `invalidArgument`, no dispatched work and no activity stamp, including on settlement;
   also assert an armed desktop departure and its scheduled exit remain intact. Preserve valid-request
   start/settle activity tests and a structurally valid keyed request whose changed arguments are
   refused inside authorized dispatch (which still counts as dispatched activity).

Current registry parity includes the five added operations `meetings.tasks`, `meetings.edit_task`,
`meetings.prepare`, `meetings.cancel_generation` and `meetings.cancel_summary`. Keep these two
cancel operations available without helper readiness. Preserve `meetings.cancel_enhance`'s existing helper requirement
under per-operation parity; changing that admission policy requires a separately characterized and
justified behavioral change. Preserve `meetings.generate`'s legacy `action_items` alias to
`actions` and its Summary/actions/enhanced-notes dispatch plus the internal `questions` kind; MCP
remains its narrower published
schema/tool subset. Typed decoding preserves omitted versus explicitly null task owner/due fields,
one-to-100 distinct local preparation sources, source-scope preference values and current raw-map
digests. DTOs retain field-presence flags: owner/due omitted preserves stored values while explicit
null clears them; task null keeps stored text via the current fallback, but the presence of any
task/owner/due key still counts as a manual-details edit. Status-only edits keep details. Freeze
`{id,status}`, `{id,owner:null}` and `{id,task:null}` request/row outcomes. Do not expose internal
workflow variants (including `questions`) through MCP or silently widen an empty source scope.

Commit sequence: characterization → descriptor declarations with parity checks → typed
decode/adapters feature by feature → compatibility enforcement → error hierarchy migration → delete
old policy/dispatch branches. Keep a compiling adapter during migration; remove it before PR
completion.

### 6B. Extract domain services without moving lifetime ownership

`Application` becomes the composition and orchestration layer. A typed handler table dispatches
feature handlers; the shared wrapper retains epoch admission, cancellation, model gates,
notification and error mapping. Extract in this order, with constructor dependencies and typed
results, no `Application` back-reference or service locator:

| Service | Responsibility and acceptance |
| --- | --- |
| `WorkspaceAdmin` | Clear/purge/VACUUM and workspace epoch rotation. Preserve dedup reset and helper-delete durability, after-commit events and stale-write rejection. |
| `ModelRegistry` | Generation, embedding, speech and query registration/configuration/acquisition. Keep readiness, adopted-helper identity and model busy guards. |
| `SourceOperations` | Import/reimport/search/labels, revision revalidation and pending-source queue semantics. |
| `GoogleMaintenance` | Account maintenance, sync scheduling and cleanup. Preserve its network-versus-model-work distinction for idle exit. |
| `SummaryCoordinator` | Own Summary run/checkpoint identity, preview/progress, parent-to-child cancellation and atomic accepted artifact/checkpoint/derived-source commit. Reuse the existing generator/prompts/budget algorithms; retain full/incremental/MAP/REDUCE, latest-unedited checkpoint rules, clipping disclosure and prior accepted output on failure/cancel. |
| `MeetingWorkflowCoordinator` | Own Actions and document Preparation orchestration and shared generation reservation/preemption. Preserve task evidence/manual/completion/stale merges, source/calendar/title/notes/model revalidation, degraded preparation retry with good document-cache reuse and atomic accepted artifact/cache/source writes. Reuse `meeting_actions.dart`, `meeting_preparation.dart` and persistence methods. Also own the preserved internal `questions` transcript-window/plain-artifact branch with its existing gating; do not give it Summary manifests/checkpoints/derived sources or implicitly route it through the Actions/Preparation workflow wrapper. |
| `NoteEnhancementCoordinator` | Automatic/manual enhancement, edit mapping, autosave, cancellation and restoration. Keep it distinct from `Domain.noteEnhancementService`; preserve one owner of timers and in-flight work, latest-50 live chunks versus complete final transcript, raw-note revalidation, parent-child cancellation and degraded manifests. |
| `RecordingController` | Capture start/pause/resume/stop, final transcription, meeting state and indexing triggers. Preserve desktop ownership and finishing state through cleanup. |

Each service exposes a narrowly defined activity/completion view, aggregated into
`Application.backgroundBusy`. Use balanced `try/finally` accounting that covers work after
cancellation, invalidation or disposal. `Domain.mutating`, helper startup/adoption state and
dispatched request tracking retain their existing meanings. Tests hold real work at the existing
gates across every new ownership boundary and verify busy remains true until actual settlement.

Introduce the narrow shared generation-reservation/yield contract before moving Summary, workflow
or Notes owners, then extract those owners one at a time. Preserve `_summarizing`, `_workflowBusy`,
active enhancement and proactive settlement semantics, request-parent to owned-child cancellation,
`capture.meeting_summaries[id]` and `capture.meeting_workflows[id:kind]` status shapes, clear/close
cancellation and no late acceptance. Replace `application_summary.dart`,
`application_workflows.dart`
and `application_preparation.dart` with independently testable services, not another shared-private
part boundary. Count their 735 lines in the pre-refactor Application scope; moving code into a part
alone is not completion. Keep the already independent algorithms unchanged unless a separate
characterized defect requires a fix.

Split `ConversationAnswer` into immutable retrieval, prompt preparation and generation results.
Preserve streaming order, citations, partial output, revision revalidation and cancellation/close
behavior, foreground generation reservation, source-scope filtering of retrieved IDs/previous
questions/history, and `web-memory-v2` identity/budget rules. Keep manual Chat default Workspace,
automatic Q&A default Meeting, selected-empty scope empty, Unicode production output policy and the
portable `raw_query_jsonl_v1` detector's model digest/executable/probe/deadline/cancellation
contract.
Meeting scope retains the transcript plus four derived artifact source IDs; changing scope cannot
persist an old answer.
Remove the `ApplicationDomain`/`Expando` convenience ownership only after every caller has
explicit dependencies, including test support and service startup.

### 6C. Keep the relay, isolate persistence and address measured blocking work

Document frontend, worker, native tasks, sockets, lock/record ownership, error channel, startup and
ordered shutdown in `docs/architecture/application-service.md`, linking the existing lifecycle
matrix. This documentation debt is partially addressed already; extend it rather than claim a new
topology.

Keep SQLite's writer and native ownership in the domain worker. Name the two executions explicitly:
a **service read worker** serves service-originated projections, while a **desktop reader isolate**
backs the direct read-only SQLite `StoreReader` facade; it is not an RPC proxy. Both follow the same
coordinator protocol below. Move demonstrably heavy **read-only** queries to a separate read
connection in a worker, using serializable query requests/results. A core-owned query coordinator,
scoped to one profile and connection generation, owns one long-lived authoritative connection (the
existing writer for service-originated reads, or a private long-lived read-only connection for
desktop-originated reads). Its `Store.dataRevision` is an opaque **connection-local invalidation
token**, never a transferable SQLite snapshot ID. At an autocommit boundary the coordinator records
its own token plus owner/profile/connection identity, workspace epoch and query generation, then
dispatches a serializable query. The worker begins one read transaction and reads the actual stored
workspace epoch and all rows needed for the projection in that same snapshot; it echoes the caller
token as a request tag only, never equates it with its own `dataRevision`. Before deciding whether
and how to publish the reply, the coordinator rereads its token on the **same authoritative
connection** to classify freshness, and checks the returned actual epoch, current workspace epoch,
owner/connection generation and query identity. Distinguish identity from freshness: an epoch,
owner/profile/connection generation or query-generation mismatch always discards, including a result
superseded by a newer completed request. A token change alone on the same authoritative connection
must not starve reads under sustained transcript/autosave writes: publish the first completed
snapshot-consistent projection as a **preview**, tagged with its dispatch token as a request tag
(not a claimed snapshot version), do not mark/cache it as current, and schedule one coalesced
refresh. If the same-owner token is unchanged, mark that projection current. Retain at most one
active query and one pending refresh per query key; ordinary commits never repeatedly cancel that
active query. Thus continuous writes still deliver a preview after one completed read, and the next
read after writes stop becomes current. Never accept by comparing coincident tokens from independent
connections. Preview publication must retain the same epoch/owner/query and monotonic
request-sequence checks as current publication; it cannot replace a later completed result. Commands
based on displayed preview rows must retain current epoch/resource/revision admission checks rather
than treating a preview tag as mutation authorization. Keep freshness/refresh status internal to the
view model and existing loading/error presentation, not exposed SQLite counters. A 30-second caller
deadline returns a typed retryable busy result while retaining the last valid view; a late worker
reply is ignored, and no replacement worker/query starts until the original read actually settles.
This bounds caller waiting without pretending timeout cancels synchronous SQLite work or
accumulating detached queries. Tests inject the clock/deadline. Service `changed` tokens invalidate
a desktop coordinator but are not compared numerically with its private connection token. Retain one
read transaction for multi-query projections so rows cannot mix commits; reads never invoke
migrations. Inside every worker read transaction, check `user_version` before application queries;
an already open reader must detect a newer schema introduced by another owner. Return a typed
incompatible-schema failure, publish no rows from that transaction, retire the coordinator and its
cached projections, and close only after actual reads settle. Map any RPC representation through
the existing actionable `unavailable` code rather than introducing an incompatible v1 wire code.
Test a live reader across a future-schema upgrade and settlement/disposal of pending requests.
Apply this guard to every connection issuing application reads, including the coordinator's
authoritative identity/epoch checks before dispatch and acceptance and any retained synchronous
`StoreReader` adapters. Schema and the dependent identity/projection are read in the same short
snapshot before application-table SQL; opaque same-connection token samples remain at autocommit
boundaries, not inside the snapshot. Never hold an identity transaction across a worker await.
These paths trigger the same typed retirement/cache invalidation and actual-read settlement;
do not convert a schema incompatibility into a generic internal error or a retry/reissue loop.
Test a future migration changing an identity table before dispatch, between worker completion and
acceptance, and before a synchronous adapter read, rather than only bumping the version while old
queries still work. Assert no incompatible query or published/retained projection. No startup
qualification copy runs on these refresh paths.
Use normal read-only/WAL semantics, never `immutable=1` on a live query connection. A disposed
coordinator/worker closes its own connection once its active read settles and pending caller
requests settle; cancellation and caller deadlines remain responsive without losing track of the
underlying read. Do not share SQLite handles across isolates or move writes into the reader.

Audit capture/generation polling and `fs_conversation_destroy` call paths with ownership and timing
evidence. A 20 ms asynchronous poll alone does not prove domain blocking. Keep polling unless
measurements show it causes material responsiveness harm. Do not add `NativeCallable.listener`
merely to remove a timer. Any native join repair must define handle ownership, asynchronous
completion and no-use-after-free/callback-after-close semantics, keep the C ABI or version it
deliberately, and update every runner/consumer fixture. If a safe repair expands into PR 8's native
redesign, stop that extraction and write a separately scoped follow-up with the measured residual;
do not claim P2-4 fully resolved. Acceptance for PR 6 still requires no responsiveness regression
and deterministic cancellation/shutdown liveness.

Tests: sustained streaming/capture with responsive status, no response starvation under a
deliberately gated worker task, frontend structured refusal during worker close, unexpected worker
exit, replacement-socket ownership, and read-worker revision/cancellation/disposal races. Gate
writes/clear between dispatch and snapshot, a write between queries inside one projection, a write
between snapshot and acceptance, repeated independent readers with equal local tokens, and service
owner replacement; prove unchanged-identity results distinguish current versus preview freshness,
changed-identity results are discarded/reissued without comparing foreign connection tokens, and
sustained transcript commits still publish a preview after one completed read with at most one
active/one pending refresh. After writes stop, require a current result reflecting the final commit;
also exercise the caller deadline, late reply and no-overlapping-worker rule. The 50 ms p95 target
over 100 warmed requests remains a measured target on a documented idle host; report misses and
causes. Deterministic gates establish ordering; timing measurements establish performance, neither
substitutes for the other.

#### 6C.1 Extract the service implementation by responsibility

This is required PR 6 work, after descriptor/admission characterization and before final metrics,
rather than an unowned line-count condition. First pin `_RequestLease`
creation/helper-wait/dispatch/future-and-stream settlement, `_exitIfIdle`, `_stopIfIdle`, frontend
draining/refusal and lock/socket release in tests. Move `ServiceClient` transport, connect/status
probe and retirement to `service_client.dart`; keep the desktop-facade reconnect policy in
`RemoteDomain`. Move profile/socket/record ownership to `service_ownership.dart`, and frontend
relay to `service_frontend.dart`, preserving existing public exports through `service.dart`. Split
internal request routing/lease bookkeeping behind narrow service-owned interfaces if needed. Keep
`ApplicationService` the sole authority that invokes close or stamps activity; a separately testable
private lifetime evaluator may compute decisions from snapshots but cannot own a second timer,
independent busy ledger or shutdown side effect. Move one responsibility per commit, with the
lifecycle matrix after each move; compare lease state/event order before/after. Use explicit
internal dependencies rather than a wide service back-reference, global locator or new
shared-private part monolith. No topology, timer-policy, lock or retry change accompanies a move.
Finish with the complete ownership/close/crash suite before claiming the touched-module size target.

### 6D. Complete schema residuals, then split persistence

1. Freeze shipped Store migrations 1–15 from the reconciled reviewed baseline before changing live
   label/query code. The first persistence commit extracts them and migration-private copies of
   every transitive business helper, including source-URI parsing, label reconciliation,
   stored-name/color allocation and label read/write helpers, into a dedicated historical
   implementation module. Historical migrations may call its frozen helpers and a minimal SQLite
   transaction/execute/select interface, never live Store/query/label methods that later refactors
   alter. Characterization fixtures pass before and after this isolation. Current business helpers
   can then evolve independently. Protect complete executable definitions, including transitive Dart
   data-transform helpers, with a committed digest manifest and checksummed frozen historical
   fixtures. Unit tests consume these files without Git history. The initial combined PR cannot fetch a
   manifest that main does not yet contain. Bootstrap explicitly from an independently resolved and
   recorded reviewed-main commit: fetch its complete migration definitions plus transitive helper
   source as a checksummed input, and derive the expected initial semantic-body digest set using the
   reviewed extractor on **that source**, never candidate definitions. Missing manifest is permitted
   only for this first-introduction mode with that verified source input; it is never a fallback to
   trusting candidate hashes. A PR gate compares the candidate's frozen implementations with those
   extracted reviewed-main bodies, so editing both implementation and local manifest cannot bypass
   the comparison. After the initial merge, the gate consumes the independently supplied
   reviewed-main manifest and requires its existing prefix and frozen fixture checksums unchanged.
   Tests inject both bootstrap-source and subsequent-manifest inputs under unrelated PR, main and
   unset refs, without local Git history. Hash canonical executable bodies/dependency closures
   separately from file locations (explicitly map migration-private copied/renamed symbols to stable
   historical identifiers; permit only that verified binding-preserving rename and
   formatting/comment normalization): mechanical relocation supplies an explicit old-to-new
   symbol/location map but keeps body digests byte-identical (apart from that documented
   deterministic tokenization and verified symbol mapping). Any changed body is rejected; there is
   no same-PR override or hash rebaseline for a semantic change. Verify canonicalization against
   formatting-only moves, verified private-helper renames, attempted redirection back to live
   helpers, changed constants/control flow and changed transitive helper behavior, and record
   bootstrap SHA/digests, mapping and historical fixture parity in PR evidence. New versions append
   entries; allocate the next free number at implementation time. The hashing unit is an entry keyed
   by schema-version number containing that step's executable body and complete historical
   dependency closure (including `DocumentLabel.fromRow`, color-allocation logic and palette
   constants). The bootstrap extractor handles inline case bodies for 10–15 and the shared 1/2 body
   by producing an entry for each version with the applicable shared body. Exclude the registry
   container, version loop and current `schemaVersion` maximum from step digests so appending
   version 16 does not rewrite versions 1–15. CI resolves the reviewed-main baseline SHA
   independently of PR inputs. On first introduction, the extractor/canonicalizer is new code and
   therefore needs explicit review with frozen positive/negative tests; record that bootstrap
   limitation rather than claiming a previously trusted tool exists. After bootstrap, CI executes
   the **reviewed-main** extractor/canonicalizer against candidate historical implementations, not a
   PR-edited executable. Any PR changing that tooling calls it out in its description, passes its
   negative tests, and must also pass the old main checker; later main runs adopt the newly reviewed
   checker only after merge. A canonicalizer change cannot excuse altered old step bodies or
   silently change their digest format. Preserve migrations 5/9 and their helper behavior even as
   current label/query helpers evolve.
   For first introduction, CI independently resolves fetched reviewed-main HEAD, requires the
   manifest's recorded bootstrap source to be reachable from it, and extracts expected bodies from
   that actual HEAD. The PR's recorded commit is evidence, never the source of authority. If HEAD's
   migration set or frozen closures differ from the bootstrap input, fail with a rebase/refresh
   diagnostic; refresh the candidate from current main, reallocate appended versions and rerun
   bootstrap/review rather than silently selecting the older commit. Test unrelated main movement,
   appended migrations, changed closures and a non-reachable bootstrap commit.
   The extractor may promote already resolved packages to exact-pinned direct development
   dependencies without changing resolved lock versions: the current foundation uses analyzer
   12.1.0 and crypto 3.0.7. This is development guard tooling, not a runtime dependency upgrade.
   Record the one-line dependency-input justification in the PR description and retain the existing
   SDK/tool pins.
   Preserve new migrations 14/15 exactly, including old summaries without fabricated checkpoints,
   all legacy `action_items` artifacts normalized to `actions`, edited or not, manifest columns,
   task evidence/manual
   flags and the document-cache foreign keys. Cover schema 13→14→15→new upgrades, failure rollback,
   fresh/current stores and future-version refusal. Keep workspace clear's three new content tables
   (`meeting_summary_checkpoints`, `meeting_tasks`, `document_summary_cache`) and its scoped
   preference/memory cleanup and latest-artifact-only derived source updates. A source delete is a
   soft delete/revision bump; existing document-summary cache rows remain physically stored until
   workspace clear. They become unreachable through revision/content-digest keys and deleted/source
   revision revalidation before reuse. Characterize soft-delete cache retention, refused reuse and
   clear-time physical removal. Purging on soft delete would be a separate privacy/product decision,
   not refactor work. The current meeting-AI architecture doc claims source-delete cache clearing;
   correct that prose to match code during persistence documentation upkeep, without introducing a
   purge silently. `MeetingWorkflowStore` is an existing mixed read/write extension: move its SQL
   into appropriate persistence/query modules while preserving savepoints/transaction boundaries;
   exporting the whole extension is not a narrow reader interface.
2. Move only `_restoreModificationTimes` from `GoogleConnections` construction into the next ordered
   Store migration. The source URI backfill already lives in Store migration 5 and Google table
   creation in 8. Preserve current live-source/local-edit filters, repeated `user edit; ` provenance
   handling and null/malformed timestamp parsing; preserve repaired timestamps for legacy rows and
   do not overwrite a newer user edit. Preserve the live import `_setSourceUri` path; it is not
   constructor backfill. Test a pre-repair schema, already repaired data, empty/fresh stores and
   interrupted/retried migration. Existing schema-15 databases must receive the new repair exactly
   once.
3. Make `document_labels` authoritative. Specify and test conflict rules before migrating: preserve
   explicit/manual labels, source/color/rationale metadata and the existing reconciled visible label
   set; retain meaningful JSON-only labels. Pin malformed/non-array JSON, duplicate names, ordering,
   orphan/deleted sources and automatic/manual conflicts in fixtures. The chosen merge preserves
   meaningful legacy JSON names in first-occurrence order, intentionally removes duplicate names,
   then appends structured-only names in a deterministic documented order. Matching structured rows
   keep their source/color/rationale metadata; JSON-only names become manual (`user_defined`)
   labels using the frozen migration-private stored-name/color allocator, included in the new
   migration's dependency closure rather than calling mutable live allocation code.
   Keep deleted-source/tombstone rows rather
   than silently purging them. Store order in an explicit durable `position`/ordinal column, never
   implicit rowid; current writes use named columns and atomically maintain ordering. Test reorder,
   VACUUM and reopen, not only initial insertion order. These guarantees apply to records available
   when the appended canonicalization step runs. Frozen migration 9 treats valid JSON as the name
   authority and can already discard structured-only manual rows on pre-9 upgrades; characterize
   and preserve that historical behavior. The new migration does not promise to resurrect those
   lost rows. Such recovery would require a separately specified adoption mechanism. Keep historical
   five-column writes unchanged because they execute before the new ordering column exists.
   All label projections, including `graphLabelSet` and graph persistence comparisons, explicitly
   order by document/source identity and durable position; a rebuild/VACUUM must not spuriously
   change graph state. Preserve a currently valid saved force layout when only order/representation
   changes: capture old membership/signatures and rewrite `graph_force_state.label_set` to the new
   canonical projection within the same migration transaction, only where the saved signature was
   valid and per-document `(name,source)` membership remains equal. Keep positions/vectors and
   document identities unchanged. Never make an already-stale saved layout valid by rewriting its
   signature or by an accidental match with the new canonical string; remove obsolete force-state
   entries as necessary while retaining saved positions. Real membership/source changes retain the existing invalidation/acknowledgement
   policy. Upgrade fixtures cover complete saved-layout preservation, already-stale state, actual
   membership change and rollback of the signature rewrite. Preserving structured-only records
   still present at this new step is an
   intentional merge policy, even where old JSON omitted them; report that visible union behavior
   rather than describing it as recovery of already-lost historical rows.
   Derive the existing
   `sources.labels` JSON string read projection from structured records until all consumers migrate,
   preserving RPC/desktop payloads. Backfill and verify row counts/content before dropping the
   redundant `source_details.labels` column. Use a transactional table rebuild instead of assuming
   SQLite 3.35+ `DROP COLUMN` support on every supported runtime; preserve IDs, foreign keys, indexes
   and constraints, and assert referential integrity in upgrade fixtures. Record the actual SQLite
   versions and loaded library paths as migration evidence: Linux host tests use the host SQLite
   library, packaged Linux acceptance uses its bundled library, and HanSolo's Dart application
   uses the protected application-owned SQLite 3.54.1 runtime described above; helper SQLite is
   unchanged. Verify each exercised runtime instead of inferring the bundle version from the host. Update all serializers, queries, imports/exports,
   graph/auto-label paths and fixtures together. Test fresh schema, every supported upgrade path,
   repeated open, failure rollback, clear/delete and newer-version refusal. Old application readers
   must refuse the newer schema before issuing incompatible queries; do not imply downgrade
   compatibility.
4. Version the helper's `agent_metadata.db`, `linux_state.db` and `rag_vector.db` as one documented
   schema set with individually checked versions. Qualify all existing members and relevant
   sidecars, including the absence of missing members, before any live writable open, new live-file
   creation, sidecar mutation, PRAGMA setting, DDL or embedding rewrite. Private preflight scratch
   files are permitted; they are never live profile files. Reject newer versions actionably without
   changing original file sets, bytes or identities. Only after whole-set compatibility and a final
   source-identity recheck may SQLite open/create the writable set. Use this grounded protocol:

   - An existing rollback journal, including an empty journal, requires a source-stable private
     DB+journal copy for the read-only SQLite probe in C++, Dart and Python. SQLite may change an
     original journal's ctime through `fchown` even on a read-only open as UID 0. Preserve original
     raw page-1 bounds, checksum/version walking, copy-time and final whole-set identity checks,
     including ownership, mode and ctime; do not relax identity verification. Direct original
     read-only/no-create inspection remains permitted only when the journal is absent and that
     path is demonstrably non-mutating. The private probe never performs recovery or follows
     absolute original superjournal paths. A genuine hot journal can make this fail with
     `SQLITE_READONLY_ROLLBACK` both before and after the attached commit point; that error cannot
     decide whether rollback should occur. Qualify such members conservatively with a bounded,
     read-only modern-format journal walker: validate the current DB header and every applicable
     checksummed original page-1 image, requiring all possible recovered versions to be supported.
     A current header can hide a future version in rollback page 1. Validate segment geometry,
     arithmetic, checksums and documented unsynced/terminal tails; stream bounded pages rather
     than loading an entire index or journal into memory. Reject unsupported, corrupt, truncated,
     unstable or ambiguous layouts with a recovery diagnostic and no live writes. Do not rewrite
     journals, decide superjournal commit state or perform custom recovery. SQLite alone performs
     original recovery after whole-set qualification. Never recover a naive private copy of
     attached journals whose superjournal contains absolute original paths.
   - Detect WAL before opening originals, including a WAL-mode main file with no current sidecars.
     Read-only SQLite can create or change source SHM, while
     `immutable=1` can miss a committed WAL-only future version. Inspect a source-stable private
     DB+WAL snapshot, omit/rebuild SHM privately, and verify original DB/sidecar identities before
     and after copying and again at the whole-set gate. Fail on ambiguous mixed WAL/rollback
     layouts rather than guessing. Apply the same protection to application writer migration
     preflight and profile-copy tooling. Application Store normally uses WAL, so acknowledge this
     startup/migration qualification copy cost; do not copy on query refresh. Live query readers
     retain normal WAL semantics and never use immutable or run migrations. Qualification scratch
     is private (0700 directory/0600 files), outside the original profile file set, and removed on
     success and failure. Distinguish a torn/unreadable/unstable copy from a proven future version.
     A short immutable version probe is allowed only for a source-stable, sidecar-free qualified
     image or private snapshot, never as authority for a live WAL or hot journal.
   - Permanent real-SQLite tests cover journal-absent and empty-journal paths, UID 0 and ordinary
     user qualification with independent nanosecond metadata/content snapshots, metadata-only
     original-source changes, ordinary hot journals, abrupt attached transactions both
     immediately before and after actual superjournal deletion, hidden future rollback page-1
     versions, WAL-only future versions with absent/existing SHM, future versions in each of the
     three members, source changes during qualification, rollback/retry and exact original
     file-set/byte/identity preservation on refusal. Keep before/after-commit content assertions;
     a probe that only patches journal bytes or mocks recovery is insufficient.

   Preserve
   DELETE journal mode and the existing multi-attached-database transaction boundary. Adopt
   unversioned legacy databases via ordered steps, including the JSON-to-BLOB rewrite. Advance
   versions only after successful transactional work. Test all-legacy, fresh, mixed/partially
   upgraded sets, corrupt JSON, interrupted upgrade, newer version in each member and retry after
   rollback. Do not reset or silently rebuild a user's index. Keep recurring vector-generation/chunk
   pruning and crash recovery after startup separate from once-only schema migration. Inventory and
   update `tools/migrate_profile.py`, `tests/test_profile_migration.py` and
   `tests/helper/contract.cpp` as consumers: profile-copy tools must preflight supported helper
   versions before settings rewrites and preserve versions, and helper contracts exercise all three
   members.
5. Split Store into connection/transaction/write ownership, immutable migration definitions, typed
   `SourceQueries`/`MeetingQueries`, a document parser with Linux/macOS implementations, and label
   planning in a domain service. Move SQL behind the persistence/query layer; read implementations
   and migration code may contain SQL. UI and application handlers receive typed records and named
   methods, not `db`/`rows`. Preserve extraction sandbox, failure diagnostics, source identity,
   transaction scope, WAL/read visibility and `dataRevision` semantics. Avoid reconstructing whole
   tables solely to hit file targets.
   Extend `docs/architecture/schema-migrations.md` with shipped version 15, every newly allocated
   application/helper version, the historical/current persistence module boundary and these
   ordering/preflight decisions. Test privacy checkpoint/VACUUM with an idle long-lived reader;
   an active read may defer maintenance, but must preserve the durable pending marker and complete
   cleanup after settlement. Preserve capped-interval retries until success and rescheduling on
   reopen; do not impose a retry-count cap or introduce a busy loop. Close stops owned timers while
   retaining durable unfinished intent.

### 6E. Publish narrow desktop interfaces and finish core hygiene

Extend the existing curated `remote.dart` public barrel with only the required DTOs/enums and
interfaces. `DesktopConnection` exposes read-only `StoreReader`, state-only `HelperStatus`,
runtime/account/capture status, change notifications and RPC capabilities. Include a separate
connection-owned lifecycle/change-subscription capability to replace current helper
`changed`/`onReady`/`start`/`close` use; state-only `HelperStatus` cannot perform lifecycle actions.
Cover `meeting_export.dart`, model setup views, `model_terms_dialog.dart` preference-write fallback,
core model-setup helpers and `background_store.dart`, not only controllers. Model-terms acceptance
writes go through explicit RPC commands; read workers are core-owned factories behind the reader
API. Define only members from the Phase 0 consumer inventory; do not export a database handle, write
method, native handle, gRPC channel or `RagServiceClient`. Keep profile/database identity available
only to the read-worker implementation, not feature widgets.

Use composition for remote helper status and reconnect retargeting; remove `RemoteHelper extends
Helper`. Remote status/retargeting must not construct a `RagServiceClient` in the desktop process;
move any remaining legitimate helper-backed read behind service RPCs. The service alone owns helper
channels. Existing commands become RPCs or service-owned methods. Adapt desktop call sites
sufficiently in PR 6 to compile against the new boundary; PR 7 reorganizes them, rather than relying
on a removed concrete API. Test warm attach, helper replacement, reconnect, retired-state disposal
and no direct desktop mutation path.

Finish scoped cleanups after their owners are extracted: lazy trace strings, shared cancellation
helper with preserved error text/reasons, one Store generation-digest query, one helper
protocol-version constant, explicit Google initialization instead of side-effect getters, and
consumption of the existing `tools/pins.json` for its declared SDK/tool pins; avoid dependency
upgrades. For the grpc-internal subclass, document exact grpc/http2 pins and add a resolved-version
guard reading both grpc and http2 from the resolved `packages/foresight_core/pubspec.lock`, checked
against the documented exact pubspec pins. Prepare an upstream issue draft if no matching report is
found; publishing it needs separate authorization to message others. Remove the workaround only
after a verified upstream fix passes the EOF/write-race regressions.

The read-only 7A consumer inventory identifies two additive core seams that must land before
freezing the core checkpoint, without starting desktop feature extraction. Expose a narrow opaque
read-only client-session generation/notification at the desktop connection boundary: every actual
client/service replacement, even at the same path and epoch, advances it. Keep that feature/RPC
session generation distinct from the authoritative SQLite reader's owner/connection/data token;
retain the existing reader where valid without admitting retired feature work. Separately split
Stats' immutable scheduling identity from its fresh dispatch-time argument snapshot, with an
injected clock and unchanged defaults for other queries. Test replacement/late-result refusal,
ordinary same-session preview/coalescing, exact Stats cutoffs and scheduler settlement before the
freeze. These are focused consumer prerequisites within 6E, not authority to move feature owners.
If a later migration discovers another core interface/ownership/read-scheduling change required
for the desktop contract, stop moves, review that change and establish the updated core checkpoint
with its full Linux matrix. Routine fixture adaptation does not retroactively relabel an earlier
pass; it needs affected checks and the final combined matrix, without inventing a full checkpoint
for every test-only edit.

### PR 6 acceptance

- Every operation, including the shipped meeting workflows, has a complete descriptor and typed
  decoding; registry/tool/schema/admission tests
  pass. Old/new peer compatibility and error classification are explicit and tested. Replace the
  existing switch-source-parsing exhaustiveness test with runtime checks that service/application
  registries are disjoint and their union equals all Operations; retain raw-name, epoch and
  idempotency guards.
- Application business services have explicit dependencies and no handwritten `part of
  application.dart` ownership; SQL is confined to
  persistence/query/migration implementations. Desktop consumers compile through narrow interfaces;
  no write-capable helper client escapes them.
- ADR-0007 busy/activity/exit and lifecycle ownership tests pass unchanged in meaning. Relay
  topology remains. Schema upgrades preserve data, reject future schemas before mutation and recover
  from failure.
- Size targets: `Application` under 600 lines, `call` under 80, extracted functions under 150,
  answer phases under 100, persistence files under 600, other touched handwritten core modules under
  1,000. Complete the required service split in 6C.1, preserving the reviewed topology and one
  service-level lifetime authority; any residual size miss after that split needs a documented
  justification. Record justified misses with concrete retained responsibilities; do not add
  arbitrary forwarding layers or weaken contracts to reach a count.
  The current AST inventory retains two justified function-size exceptions:
  `rankAnswerPassages` is 164 lines with its existing ranking algorithm unchanged from main;
  `rpcTools` is a 170-line declarative list preserving the explicit published MCP subset,
  descriptions and descriptor-derived schemas. Neither contains an extracted business-service
  owner; splitting their declarations solely for line counts would obscure those contracts.
- All applicable verification gates below pass. Report any measured P2-4 residual explicitly;
  deferred native redesign is not completion evidence.
- Before 7A production extraction, complete 6A–6E, refresh/rebase reviewed main and assess any
  delta, then freeze the resulting core completion commit as `core_acceptance_sha` in the evidence
  ledger. Run the full applicable Linux matrix below at that exact commit, including the adapted
  existing desktop, and preserve this work package's acceptance and metric evidence. Core line
  coverage reaches the requested 95% target with the enforced minimum still 90%; desktop keeps
  its existing 90% minimum through final acceptance; the owner waived the desktop 95% target on 2026-10-22. This replaces
  the old intermediate PR's final-head gate; interface compilation alone is insufficient. HanSolo's
  complete Mac matrix is required at the final combined head, not this intermediate commit.
  Explicitly inventory Linux gates that require hosted execution and cannot run on this host; record
  them as unexecuted obligations deferred to the final PR head, where they must pass before merge.
  Keep every locally runnable native/sanitizer/container/installer/process/UI gate at the checkpoint;
  absence of a PR is not a reason to omit local execution or mark a hosted gate passed. Any
  later rebase or main integration invalidates the core commit's evidence: identify the updated
  core completion commit and rerun its full Linux matrix before treating the checkpoint as valid.

## PR 7: desktop feature modules

### 7A. Establish composition, contracts and invalidation

Start after the core completion commit above passes its Linux matrix. Record its SHA and actual
public interfaces; the required main refresh/rebase occurs before freezing that commit, not
between it and desktop extraction. Freeze before/after desktop behavior and rebuild/query counts.
Retain `CaptureLevelEvents`,
`captureVolumes` and the early-return capture notification path as existing functionality.
Characterize the coalesced `serviceUiRevision` path and which screens consume it; do not describe
every event as a full-workspace rebuild.

Include `workspace_controller.dart` in the handwritten part inventory; it defines
`_FeatureController` and its back-reference to `_WorkspaceState`, which is defined in `main.dart`. Create an application composition root and
independently importable libraries under
`features/settings`, `integrations`, `chat`, `sources`, `meetings` and `onboarding`. Move
`workspace_visuals.dart` into a shared presentation library, and leave `main.dart` responsible for
process entry and composition, not feature-private state. The new `meeting_ai_views.dart` part and
shared `meeting_visuals.dart`
rendering belong in the meetings feature; moving the old controller without those leaves the shared
private boundary intact. Remove the shared
`_FeatureController`/`_WorkspaceState` back-reference; dependencies are explicit interfaces such as
navigation, Google account status/commands, approval presentation, meeting selection and error
reporting. Do not replace `shell` with a global service locator or a wide context exposing all
features.

Specify ownership before extraction: composition owns the service connection, read-only reader and
helper status proxy; the Workspace drains pending note saves before disconnect; each feature owns
subscriptions, timers, text/scroll/focus controllers, view-model requests and notifiers it creates.
The connection owns the persistent read worker/coordinator and joins actual reads on close;
features own their subscriptions and presentation generations, without duplicating that scheduler.
Dispose each owned resource exactly once and ignore late results using a
feature/request/connection/epoch identity. Preserve window close/detach and settings persistence
sequencing. Consume the core session-generation contract completed before the checkpoint. Same-path,
same-epoch client/service replacement must remain observable and retire old feature actions/results;
a retained valid SQLite reader is not evidence that the feature session survived. Feature
client-session generation is distinct from the authoritative SQLite connection/token; never
compare foreign data tokens. Do not infer identity from socket paths or cast back to a concrete
transport client.

Invalidation starts conservatively. A change with known scope invalidates that feature's cached read
models; an unknown/coarse service event invalidates all affected data consumers as today, until
completeness is proven. Track dependencies explicitly for shared account/model/meeting/source
changes. Do not require new fine-grained wire events merely to reduce rebuilds. Because current
events contain a coarse `Stream<void>`/full snapshot and one `dataRevision`, choose immutable
view-model projection comparison with broad invalidation as the initial mechanism: every event
refreshes relevant cached projections asynchronously and only changed projections notify widgets.
Typed per-feature wire scopes are a separate optional additive optimization after
mutation/background-path completeness is proven. Dependency map: sources/imports → Sources, Stats
and Ask citations; meeting notes/transcripts → Meetings, Stats and affected source graph/citations;
model/helper identity → setup and graph; account changes → integrations and meeting calendar;
artifact acceptance/edit/task completion/preparation/cache acceptance changes → meetings plus
derived source,
Stats, graph and scoped Chat consumers; source soft-delete/revision changes invalidate preparation
eligibility and reuse, but do not imply physical cache-row removal; scope selection → the affected
manual/automatic answer
view and retrieval/history identity; unknown/reconnect/clear → all. A source change may legitimately
invalidate a meetings dependency;
test an unrelated screen rather than assert that meetings never rebuilds.

Before the first feature move, fill the characterized gaps with held producers/replies: Summary
and actions/preparation across selection, clear/ID reuse, same-epoch connection replacement and
disposal; task edits/completion and local source-picker/preference writes across those boundaries;
same-conversation answer-scope changes with late text/history/citations; cancellation retaining
accepted artifacts and manual task metadata; and a held note save proving Workspace drains before
connection disconnect. Reuse the strong existing startup, pending-create/idempotency, clear/offline,
accepted-history and capture-level fixtures. Characterizations pass before a mechanical move;
if a stale generic preference write is reproduced, record a separate behavioral regression/fix.
Freeze query admissions at the typed StoreReader/read/watch boundary and worker projections,
then count feature notifications and widget builds separately. Legacy Store.rows overrides can
be bypassed by current typed db.select queries: retain their semantic/large-source assertions,
but supplement or replace those spies instead of treating zero calls as proof of zero SQL or
isolate placement. Newly allocated value-equal DTO/list projections must not notify; relevant
coarse events still refresh every dependent consumer, while capture ticks and graph frames cause
no persistence admissions. Retain real worker/snapshot tests and actual process/UI integration
as separate acceptance.

### 7B. Move one feature at a time

Commit order: shared visuals/composition seams → settings → integrations → chat → sources → meetings
→ onboarding/shell cleanup. Cross-feature dependencies may be introduced as small interfaces before
either side moves. For each feature: characterize the existing behavior, introduce its
interfaces/view model, move controller logic and widgets without logic changes, remove its old part,
and verify its isolated and existing tests before proceeding. Keep public navigation and settings
keys stable.

Read models use PR 6's `StoreReader` and typed async query results; perform queries outside widget
building, cache by relevant query parameters plus workspace epoch/data revision and connection
identity, including week boundary for usage statistics and `(model JSON, instanceId,
activeGeneration)` for helper-dependent graph results, and invalidate on change. Existing
off-isolate helpers may be reused behind the boundary. No Store/SQL query or expensive graph layout
runs inside a `build` or widget-returning method or helper it invokes, including export dialogs,
setup helpers, filtered-source lists and statistics. Keep cheap synchronous reads of already
prepared immutable view state. Queries for an old search/selection or profile cannot publish, and an
older completion cannot replace a newer result. Apply 6C’s identity-versus-freshness protocol to
revision changes: same-identity previews may refresh the view without being marked current; stale
identity results are always rejected. Preserve `resetWorkspaceViews` dropping drafts/IDs before
`adoptWorkspace`, `rowsAreCurrent` dialog guards and `PendingRequestKey` reuse on retries with reset
after workspace clear. Debounce/coalesce without dropping required invalidation or autosave.
Before moving Sources, relocate standalone note-editor state and its New Note PendingRequestKey
into Sources/Notes ownership in a separate mechanical commit; rebind composition's note-save
drain, navigation and reset. Do not expose Meetings' mutable editor/controller as a cross-feature
port. Preserve pending-create exact payload/idempotency-key and workspace-epoch assertions,
including lost-reply retry, held save and reset-before-adopt behavior.

Extract large builders into widgets with explicit state/actions. Use feature notifiers and small
selectors; capture meters listen only to their existing level notifier. Scope loading/error state to
the owning feature while preserving shell-level startup/fatal errors. Keep responsive layouts,
accessibility/keyboard selection, transcript clipboard behavior and platform styling.

Include captured answer scope in query/view/cache identity separately from ordinary data freshness;
a scope change advances query generation and always rejects the old result, rather than publishing
it as a preview. A stable scheduling key covers
profile/connection/epoch/projection/filters/selection;
ordinary data-revision changes affect freshness/cache tags but do not create a new scheduler or
retire a valid active query. For Stats, consume the scheduling/dispatch seam completed before the
core checkpoint: use a stable calendar-week/timezone scheduling identity while freezing a fresh exact
`now` cutoff for each actual worker dispatch, preserving exclusion of future-created rows. Values
and chart labels share the same captured period. Rearm a calendar-based next-Monday timer on
period change and check calendar identity on resume. Also detect timezone/calendar changes while
the app remains awake and focused, without a service event, through a reliable existing platform
notification or a bounded clock/zone-identity recheck; resume alone is insufficient. Capture the
effective zone and calendar identity, recompute boundaries on change, and reject any held
prior-period reply rather than labeling it with the new period. Consume the typed scheduling/
dispatch seam landed in 6E; 7B adds no core change for Stats. If that seam is insufficient, stop
moves and apply 6E's review/re-checkpoint rule instead of extending core during the feature move.
Retain one-active/one-pending and actual-settlement rules. Tests cover
held refreshes, exact cutoffs, Monday/DST rollover and a midweek timezone change with neither
resume nor a service event: one coalesced replacement uses the new boundaries/cutoff, and stable
same-period updates do not create a second coordinator.
Preserve `answerScope.meeting:<id>` versus `proactiveScope.<id>`, their
selected-source keys and preparation selection. Local source pickers are not network authorization.
Snapshot task/source dialogs and pending preference commands against their original meeting/epoch;
current generic `preferences.set` is not epoch-scoped, so test for stale-dialog writes and fix an
actual gap separately instead of asserting that current code already prevents it.

Feature acceptance scenarios:

| Feature | Scenarios that must retain assertions |
| --- | --- |
| Settings | Model reuse and repair, portable detector executable/SHA-256/backend setup, Unicode policy, idle preference, usage/statistics, version/license, platform controls and hook-free release behavior. |
| Integrations | Google and Granola calendar setup/sign-in, multiple accounts/imports, cancellation, approval UI, connection status through reconnect. |
| Chat | Streaming/cancellation/preemption, web approval, citations/history/memory filtered to captured scope, manual Workspace versus automatic Meeting defaults, selected-empty isolation and scope-change rejection. |
| Sources | File/URL/Drive import, permissions, revision-safe search, selection, labels, graph layout, delete/clear and stale completion rejection. |
| Meetings | All six panels; Summary streaming/progress/cancel/history/clipping; task evidence/manual completion/stale state; local Preparation/cache/degraded retry; Enhanced Notes edits/degraded warnings; detector readiness and Q&A queue age; record/finalization, transcript copy, calendar and recovery. |
| Onboarding/shell | First-run and pending-create flows, model acquisition, navigation restoration, reconnect, retired workspace events, close/dispose and multiple desktop ownership. |

Before moving the new AI view part, add any missing characterization for switching meetings,
clear/reconnect/dispose during Summary/workflow preview, stale task/source-picker completion,
source-scope changes during an answer and cancellation that retains accepted artifacts/manual
tasks. Reuse `summary_stream_test.dart`, `meeting_ai_views_test.dart`,
`meeting_actions_workflow_test.dart` and `test_support/meeting_panel.dart` (visible-tab/overflow,
scope selector and citation helpers); adapt fixture setup without losing its production selector
behavior or replacing the real service integration with widget-only coverage.

### 7C. Close the boundary and remove obsolete coupling

Use the curated public core API everywhere, including remaining shims/tests that exercise the
desktop boundary. Remove one-line `foresight_core/src` re-export shims after consumers migrate. A
source architecture guard covers imports, exports and parts and rejects implementation imports and
write-capable core types in desktop production code. Narrow test-support adapters may implement
fakes; they do not exempt production. `StoreReader` remains typed/read-only without `dynamic`, casts
to concrete classes or exposed callbacks returning writable objects.

Move platform policy into an injected `PlatformCapabilities`/platform adapter chosen at startup.
Presentation receives capability facts and actions; platform implementation code may use `Platform`.
Keep macOS title bar, Linux capture/shortcuts and existing unsupported-action messages. This is not
a Windows port.

Delete `noteEnhancementChanges`, the redundant close wrapper and side-effect getter statements only
after verifying their replacement/disposal paths. Apply the cleanup inventory to onboarding/shared
files too. Remove migration adapters and all production `part`/`part of` links to `main.dart` at
completion; generated Dart part directives are exempt.

### PR 7 acceptance

- Every feature builds independently with fake narrow interfaces; production has no feature
  back-reference to shell state, global locator or implementation import. All handwritten main parts
  have been replaced.
- No persistence queries/graph work occur in widget building. Async results are
  revision/epoch/connection safe; queries, subscriptions and controllers settle/dispose correctly
  during reconnect and workspace clear.
- Rebuild-count tests prove a level tick rebuilds only its meter, a local feature edit leaves
  unrelated features alone, and coarse/unknown changes still refresh all relevant data. Preserve
  existing capture-level tests rather than duplicate them.
- Targets: feature files under 800 lines, widget-returning/build methods under 150, small
  composition root with explicit ownership. Explain misses rather than introducing empty abstraction
  layers.
- Existing desktop and process integration assertions retain their meaning; replace private shell
  introspection in `controller_fixture.dart` with feature fakes. Anchor
  epoch/reset/pending-create/clear-offline/note-save/startup/approval/buffer workflows and core
  `remote_domain_test.dart` before moving them. Full Linux and macOS record, enhance, Ask, import,
  graph, settings, onboarding, approval, close and reconnect smoke passes using current binaries.

### Current-main regression anchors

These delivered tests are required preservation evidence, not work still to implement:
`summary_application_test.dart`, `summary_generator_test.dart` with frozen summary prompts,
`meeting_actions_test.dart`, `meeting_workflows_test.dart`, `meeting_ai_reference_test.dart`,
`notes_workflow_safety_test.dart`, `answer_source_scope_test.dart`,
`portable_query_setup_test.dart`,
`proactive_application_test.dart`, `web_answer_test.dart`, the current
`service_cancellation_test.dart`
variants, and migration tests for 14/15. Retain helper-tokenizer independence, conservative UTF-8
admission, Unicode/map-reduce bounds, owned cancellation, preemption, edited-history and manual-task
preservation, degraded retry/cache behavior, generic `questions` generation/cancellation in
`application_operations_test.dart` and `service_cancellation_test.dart`, and source-scope privacy.

The compiled service gate must still execute
`test_summary_commits_checkpoint_and_retains_edited_history`,
`test_actions_and_preparation_through_compiled_service_and_mcp` and
`test_stalled_notes_batch_is_cancelled_by_its_service_lease` in
`tests/service/test_service_process.py`, together with the real desktop/service/MCP integration.
Their structured-stdin/probe/finish worker protocol and production source-selector helpers are part
of the contract. Controlled workers establish protocol and persistence, not real-model quality.

## Verification matrix and implementation stop conditions

The command authority is the reconciled source's CI scripts, not old audit line numbers. At Phase 0
save their exact invocations and tool versions; update the command manifest only when CI changes.
Run focused relevant tests per commit, the full applicable Linux matrix at the frozen core
completion commit, and the full applicable Linux and HanSolo Mac matrix at the final combined
head. Record both source identities. Re-run affected checks after each later code change; a new
rebase/main integration invalidates the earlier core checkpoint as specified above. A passing
unrelated check is not verification.

| Gate | Required execution and evidence |
| --- | --- |
| Static/contracts | Dart/Flutter analyze and format, operation registry/MCP schemas/literal guard, bindings and source-boundary guards; Python contracts and migration fixtures. Use the pinned CI Python environment; `python -m pytest --cov --cov-config=.coveragerc --cov-report=term --cov-report=xml --durations=20 --junitxml=coverage/python/junit.xml` is Quality's baseline command. Enforce its current 95% Python threshold; Linux core/desktop enforced minimums remain 90%, with the separate 95% improvement target above. |
| Native | Root CMake/CTest inventory, all native/helper/inference tests, `tools/run_native_sanitizers.sh` and `tools/run_thread_sanitizers.sh` where applicable; GCC/libstdc++ and Clang/libc++ for stream/shutdown changes. Reuse verified SDKs/toolchains; report omitted or unsupported targets. |
| Dart core | Entire `packages/foresight_core` suite, current native/helper paths configured. `FORESIGHT_CORE_COVERAGE_MIN=90 bash tools/coverage_core.sh` collects and enforces Linux core coverage. Reach at least 95% measured coverage at the core checkpoint and final head without raising the 90% minimum. No skipped native integration due to missing binary paths. |
| Desktop | Entire Flutter desktop suite with current binaries, coverage using the current CI command/90% minimum, rebuild/feature isolation/query cancellation tests and full `integration_test` target. Keep the enforced 90% minimum; the owner waived the desktop 95% target for now. Retain skip inventory and counts. |
| Compiled boundaries | Compile current service and MCP executables, then run `tests/service/test_service_process.py` and the current MCP process suite through the CI service stage; run actual desktop/service integration on an isolated display. Record binary paths and source identity. Capture fixtures write raw PCM to the owned FIFO and diagnostics to stdout. |
| Lifetime/ownership | Source-compiler tests with test hooks explicitly enabled, ordinary tests with hooks disabled, release builds ignoring hooks even after cached development configuration; ADR-0007 idle/grace/busy and structured close/resend/ownership/adoption matrix. |
| Schema/data | Frozen checksummed source/database fixtures without deep Git dependency; fresh/legacy/current/future/corrupt/partial and rollback/retry cases for application and helper databases; real hot-journal/attached-commit/WAL preflight and refusal-without-mutation fixtures from 6D; durable label ordering and Google repair identity/content assertions. |
| Complete source export | Applicable archive/container/fixture checks from a full export without `.git`; explicit fixture CI metadata under unrelated PR, main and unset refs if these fixtures are touched. Preserve provenance/checksum assertions. |
| Platform acceptance | Linux compiled desktop/service smoke and installer acceptance; macOS native/Flutter/process/installer smoke and cold-start/responsiveness observations. Preserve #168's independent real DMG fixture contracts, including owned-attachment cleanup; fixture success is not a Mac application pass. Docker/Apple paths unavailable locally remain required hosted checks, explicitly unexecuted locally. |

The canonical container schedule is the required CI owner's current invocation. At reviewed main,
`tools/linux_container_test.sh` defaults `FORESIGHT_LINUX_TEST_SCHEDULE` to 1: native first, then
core/desktop/platform Python branches concurrently, then compiled service. Schedule 0 instead uses
`build.sh --test-only` followed by fast/platform Python; it still enables parallel Dart gates.
The external local adapter selected 0 for the failed 4bd attempt. Record this difference and use
the required default schedule 1 for the next acceptance attempt; alternate or isolated invocations
remain diagnostic. Before that attempt record outer workloads, inner test/gate concurrency,
compiler jobs, visible CPUs, CPU quota/cpuset, memory/swap limits and current host load/memory/swap.
No CPU, memory or swap cause is established merely by observing a timeout or an isolated pass.
Do not silently serialize the canonical gate, raise deadlines, exclude architecture coverage or
alter hosted routing to obtain a pass. Preserve inventory, thresholds, original logs and every
namespace assertion; a deliberate gate change requires its own review and complete validation.

Concrete Linux gate invocations at the frozen baseline (set task-specific absolute paths first;
inspect scripts again after reconciliation):

```sh
set -euo pipefail
export FORESIGHT_PYTHON="$task_python" FORESIGHT_BUILD_DIR="$task_build"
export LIBGL_ALWAYS_SOFTWARE=1
# Choose short private disk-backed paths; generated Unix socket paths must fit platform limits.
export TMPDIR="$task_short_tmp" FORESIGHT_TEST_TEMP_ROOT="$task_short_tmp"
# Keep widget/private-display tests independent of the host compositor session.
unset HYPRLAND_INSTANCE_SIGNATURE
export FORESIGHT_NATIVE_LIBRARY="$task_build/native/libforesight_native.so"
export FORESIGHT_HELPER="$task_build/services/helper/ForesightHelper"
bash tools/build.sh --platform linux --test-only --stage native
"$task_python" tools/platform_python_tests.py --platform linux
FORESIGHT_COVERAGE=1 FORESIGHT_CORE_COVERAGE_MIN=90 \
  bash tools/build_dart_gates.sh core linux "$task_build" "$task_python"
bash tools/build_dart_gates.sh desktop linux "$task_build" "$task_python"
test -x "$task_flutter_executable" # absolute pinned Flutter SDK bin/flutter, not the app binary
export FORESIGHT_FLUTTER_EXECUTABLE="$task_flutter_executable"
export FORESIGHT_LINUX_UI_TEST=1 FORESIGHT_REQUIRE_NATIVE_UI_TEST=1
unset WAYLAND_DISPLAY
export GDK_BACKEND=x11
xvfb-run -a dbus-run-session -- \
  bash tools/build_service_gate.sh linux "$task_build" "$task_python"
xvfb-run -a dbus-run-session -- "$task_python" tools/integration_gates.py \
  --suite fast --native "$FORESIGHT_NATIVE_LIBRARY" \
  --output test-results/fast-integration
tools/run_native_sanitizers.sh "$task_asan_build" test-results/sanitizers
tools/run_thread_sanitizers.sh "$task_tsan_build" test-results/thread
```

The native test-only stage requires current configured/compiled project outputs and verifies that no
build would be needed; compile changed project code first using the existing verified dependency
SDK, never pass old application bytes as new output. In the CI dependency-reuse/container path
retain `FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=1` and the existing verified handoff; this is a
dependency-compilation guard, not permission to skip project compilation. Keep `FORESIGHT_PYTHON`
set to the pinned Python executable so coverage does not fall back to an unrelated PATH interpreter.
The desktop gate does not inherit the core gate's internal subprocess exports; set native/helper in
the outer environment as above. Linux core and desktop gates enforce 90% coverage. Core compiles the
current service/MCP and explicitly runs source-compiler enabled-hook tests; retain
disabled-hook/release tests too. The compiled service gate drives the actual
`integration_test/service_mcp_test.dart`; running a generic Flutter unit test command does not
substitute for it. Set the UI prerequisite variables and examine skipped tests so the desktop
process boundary actually runs. Configure sanitizer trees from root using
`-DFORESIGHT_SANITIZERS=ON`/`-DFORESIGHT_THREAD_SANITIZER=ON` with verified compatible SDKs, and
compare `ctest --show-only=json-v1` inventories including `native_probe_failure`.

The tracked Dart/service gate scripts have mode 100644 at this baseline; invoke them through
`bash`, preserving modes rather than treating a failed direct invocation as a product failure.
Record these invocations and the sanitized subprocess environment in Phase 0's command manifest.
Inherited `HYPRLAND_INSTANCE_SIGNATURE` can make widget fake-async tests launch real `hyprctl`
and can direct a private-display test at the host compositor. Unsetting it for these gates preserves
production Hyprland behavior; exercise that behavior through the appropriate adapter/process
fixtures. The Linux UI subprocess tree must inherit the private X display/authentication, private
D-Bus session and explicit X11 backend. A qualified task-local Xvfb runner may replace unavailable
`xvfb-run` with the same isolation; record its bytes/provenance and exact invocation. Preserve the
original infrastructure failures and successful corrected reruns.

Use `tools/run_ci_stage.py --help` and its selected stage implementation for stage arguments; do not
guess obsolete commands. Current Linux runner `tools/linux_container_test.sh` sets coverage and
threshold 90; macOS coverage has a different policy and is not proof of Linux coverage. If a changed
workflow is necessary, first confirm ShellCheck on PATH, then run both ShellCheck and actionlint at
hosted versions. Limit workflow edits to wiring the reviewed-main migration guard or necessary
existing gates; CI restructuring is out of scope.

The main refresh leaves `tools/build_dart_gates.sh`, `tools/build_service_gate.sh` and
`tools/linux_container_test.sh` byte-identical to the old baseline. The commands above incorporate
the baseline's executable-mode and local environment prerequisites. CI #163 changed **ownership and
routing**, not these runtime gates: portable Python
contracts belong to Quality, shared platform contracts route to macOS and Linux build, real Apple
checks to macOS, external DMG contracts to their DMG gate and RPM checks to packaging. Inventory new
checker/fixture files in
`tools/platform_python_tests.py`/`tools/ci_changes.py`/`tools/ci_selection.py`
as appropriate and extend `tests/test_ci_gate_owners.py` plus dependency/selection tests. A green
aggregate or selection result is not execution evidence for a required runtime owner. Keep new
migration-guard wiring main-read-only and preserve existing qualification/receipt and missing-proof
broadening behavior; do not retire checks or activate routing as part of this refactor.

Preserve #168's restored independence: `.github/workflows/macos.yml`'s DMG contract job depends on
`changes`, not successful `macos`; both classifiers no longer add a Mac application build merely
because DMG is selected. The fixture builds its own signed image and may run in parallel with
application checks. Actual packaging still consumes verified application artifacts, and this
application refactor still requires its complete Mac matrix. Keep the new real owned-attachment
fixture: only the invocation's exact canonical created image, current owner and one unambiguous
outer GUID device may be normally detached within the existing bounded recovery window, while
unrelated images and original SHA256 bytes remain unchanged. Cleanup alone never proves checksum
verification; genuine verification failures remain failures. These delivered fixes are preservation
anchors, not new refactor work or permission to change installer policy.

Release 0.1.3 keeps physical GPU validation required by default with an explicit per-invocation
`skip_gpu_validation` waiver. This documentation update neither exercises nor requests a waiver.
Preserve that policy and automated installer/provenance/accepted-byte requirements; a GPU waiver
never waives those checks. Publishing a release or changing its validation policy is outside scope.

Before large parallel suites, check disk/quota capacity and choose a short private disk-backed
TMPDIR whose derived runtime/socket paths fit platform limits; directory capacity alone is insufficient.
Preserve failed stdout/stderr and subprocess logs; repair infrastructure and rerun affected tests.
Do not clean successful dependencies. Before pushing, fetch the actual PR head/reviews/checks,
inspect failed-step output, batch valid related fixes and check for new reviews while CI runs.

Stop extraction on an unresolved ownership/data-loss/cancellation discrepancy, new
binary-path-related skips, unaccounted busy work, unintended admission policy change, migration
compatibility ambiguity or unexplained responsiveness regression. Resolve and review it before
advancing. Owner choices are required only for new product behavior, wire incompatibility, native
redesign or lifting PR 8's deferral; routine extraction decisions are within this plan.

## Completion and reporting

The combined PR description lists intentional compatibility/error/data changes, migration versions
and rollback limits, the label union/order policy and unrecoverable frozen-v9 losses, intentional
lifetime changes (including malformed-agent activity stamping and retained desktop-departure grace),
feature boundaries, ownership/invalidation contracts, metrics, measured
blocking residuals and gates. Record `core_acceptance_sha` with its Linux matrix evidence and
the final combined head with its Linux and HanSolo matrix evidence, including any platform checks
that still require hosted verification. Justify SDK/toolchain input changes in
one line if any become necessary. Failed upgrades must leave recoverable data; after a successful
schema upgrade an older binary must refuse it, so rollback uses a verified pre-upgrade backup rather
than pretending schema downgrade is supported.

The execution plan converges only when the native core, desktop and verification reviewers and
Claude CLI review the same frozen revision with no unresolved actionable planning findings. Record
every round and accepted/rejected/deferred finding with reasons. Re-review changes and their
dependent sections; any material scope or interface change requires a complete pass. Reviewer
approval does not establish that implementation tests ran.
