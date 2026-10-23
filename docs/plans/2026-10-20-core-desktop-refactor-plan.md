# Core service and desktop feature refactoring execution plan

Revision 24, 2026-10-22. This revision records the owner's single-PR delivery decision. Revision 23 refreshed the plan after #170 merged the core work package and incorporated rounds 1 to 6 of its review.

- **Revision 16**, the pre-merge specification, is preserved at
  [`75898380`](https://github.com/teng-lin/open-foresight/blob/75898380ac68a0a98dc4a9fdcfc38afc99d133d5/docs/plans/2026-10-20-core-desktop-refactor-plan.md).
  It includes the complete PR 6 (6A–6E) design.
- **The [review record](2026-10-20-core-desktop-refactor-reviews.md)** covers revisions up to 15 and the revision 17 review. Whole-plan convergence was last reached at revision 13. Revisions 14 and 15 were scoped amendments, and revision 16 was not separately reviewed before #170 merged.
- **The [progress record](2026-10-21-core-desktop-refactor-progress.md)** holds the evidence for #170.

A plan review does not establish that implementation tests ran.

"PR 6" and "PR 7" name work packages from [audit plan 3](../audit/2026-10-18-implementation-plan-3.md), not GitHub PRs #6 and #7.

## Current delivery decision

During execution on 2026-10-22, the owner requested collapsing the planned PRs
and minimizing their number, followed by parallel implementation with sub-agents.
This execution therefore ships **one final PR**, with separate reviewable commits
for 7.0, 7.1, P0.1, 7A, the six 7B moves and the 7C cleanup stages. This supersedes
the earlier separate-PR, intermediate-main-merge and approximately 100-file
delivery requirements below. Stage names and dependency order remain useful;
the implementation scope and acceptance criteria remain in force.

Prerequisites integrate locally before their dependent stages. Run relevant
checks during each stage, including the full desktop suite and compiled boundary
gate required for feature moves. Run the complete applicable Linux and HanSolo
matrices, canonical container schedule, sanitizer checks, integration acceptance
and independent native-agent/Claude reviews on the final combined head before
opening the final PR. Scoped worktrees may proceed in parallel where ownership
and dependencies permit; merge and resolve their changes on the integration
branch before validating the combined result.

## Status

| Work package | State |
|---|---|
| Phase 0: baseline and inventories | Done for core and for the desktop consumer inventory. Most per-feature desktop characterization exists; see [7A](#7a-establish-composition-ports-and-invalidation) for the residual gaps |
| PR 6 (6A–6E): core service structure | **Merged** in #170 as `75898380` on 2026-10-22, from head `0f24e09c` (tree-identical to `75898380`) |
| Core follow-ups found after the merge | Implemented locally with focused reviews and checkpoint evidence; final combined acceptance remains pending. See the [execution record](2026-10-22-desktop-feature-execution.md) |
| PR 7 (7A–7C): desktop feature modules | **7A complete; all six feature owners and shell extraction integrated locally.** Integrations, Settings/Stats, Chat, Sources and Onboarding use prepared reads. Meetings prepared reads, size cleanup and 7C are in progress. Final combined acceptance and independent reviews remain pending; see the [execution record](2026-10-22-desktop-feature-execution.md) |
| PR 8: native split, backend removal, detector consolidation | Deferred by the owner; unchanged |

#170 merged the core work on its own. Revision 16 and #170's description both required the desktop work (7A–7C) to land in the same PR. The owner has now selected one final PR for the remaining implementation; see [Current delivery decision](#current-delivery-decision).

## Baseline at 75898380

The measurements below were taken at `75898380` on 2026-10-22. Before each PR in the series, fetch `main`, record its SHA, and re-measure the rows that PR touches. If `main` moved in a way that affects a row, assess that change before extracting.

| Area | Measurement at `75898380` | Consequence for PR 7 |
|---|---|---|
| Core application | `application.dart` 540 lines. `Application.call` is 11 lines and dispatches through an exhaustive typed `OperationRegistry`. 17 owners in `application_services/`. `store.dart` 598 lines; `application_service.dart` 923. Business owners (`application*.dart`, `domain.dart`, `application_services/`) contain no SQL, enforced by `application_persistence_boundary_test.dart`; `Store` and `graph_persistence.dart` remain SQL owners | The core boundary PR 7 depends on exists. PR 7's core changes are limited to the follow-ups below and the core API removals that 7C-1 and 7C-4 list |
| Operations | 83 operations (75 application, 8 service) and 32 MCP tools. Typed decoding precedes admission; the API version is negotiated in both directions. Typed requests are decode-only (private constructors, no client encoder) | Desktop commands still send untyped argument maps at about 72 call sites (`desktop_connection.dart:110-118`). Typed desktop commands are out of PR 7's scope (F-11) |
| Schema | Store schema 17 (16: Google modification-time repair; 17: canonical ordered labels). Helper databases are versioned. `docs/architecture/schema-migrations.md` lists 1–17 | Migrations are frozen and guarded. PR 7 adds none |
| Mac SQLite | Application-owned SQLite 3.54.1 is live in the macOS service and desktop processes (#170) | Delivered. Preserve it |
| Desktop public API | Desktop `lib/` imports only `package:foresight_core/desktop.dart`; `main.dart` also imports `desktop_bootstrap.dart`. `desktop_boundary_test.dart` checks the import and export namespace | 7C closes the remaining edges; the boundary itself exists |
| Desktop reader | `StoreReader` (`store_reader.dart`) exposes 25 synchronous projections, kept for "the compiling boundary migration", plus typed `watch` and `read`. Desktop production code uses the synchronous projections at about 87 sites, `read` at 3 and `watch` at none. About 40 `readRows`/`toRow` map conversions sit in 10 files, 9 of them in `desktop_reader_adapters.dart`. Nine projections the worker already serves have no typed `StoreReadQueries` factory: `notes`, `note_body`, `source_mimes`, `labels`, `clusters`, `cluster_names`, `graph_label_set`, `meeting_revision` and `enhanced_notes`. Two core APIs exported to the desktop also call synchronous projections: the `model_setup.dart` helpers (`model_setup.dart:286,381,406`), called during build in Settings and Meetings, and the `ConnectedSources.attachments` interface member (`desktop_connection.dart:64`; remote implementation `remote_google.dart:161-171`), called during build in Meetings (`meetings_controller.dart:514,1803`) | 7.0 adds the missing factories and reader-free helpers (F-12). 7B moves features to prepared asynchronous read models. 7C-1 only removes |
| Desktop session seams | `DesktopConnection.clientSessionGeneration` and the Stats scheduling identity `OutputStatsPeriod` exist (6E). The desktop still calls the one-shot `StoreReadQueries.outputStats(now:)` (`background_store.dart:9-19`) | 7A and 7B consume them. Stats needs no further core change |
| Desktop structure | 43 files, 14,459 lines. `main.dart` plus 9 `part` files form one 9,273-line library (7,697 at `1cfd203`); see the part sizes below. 33 other standalone libraries, listed in [Library ownership](#library-ownership). No `features/` directory exists yet | Unchanged target from revision 16 |
| Desktop coupling | 168 cross-feature references and 236 `shell.` back-references. Every controller routes through one `shell.update` → `setState`. Shell services every part uses: the global operation gate (`run`, `busy`, `error`; `main.dart:618-635`; 42 `run` calls and 59 `busy` reads), `showInputDialog` (9), `reportAsyncError` (9), `rowsAreCurrent` (4) and the workspace-clear hooks. Tab indices 0–6 are integers at 38 sites in 7 files | 7A introduces the shell ports and explicit navigation (a `WorkspaceTab` enum) |
| Feature dependencies | Outbound cross-feature references per part: settings → integrations 52, → meetings 5; integrations → meetings 8, → settings 3, → onboarding 2; chat → meetings 4, → sources 1; sources → meetings 21, → integrations 11; meetings → chat 16, → integrations 14, → settings 6; onboarding → integrations 18, → sources 4, → settings 3. Features also write each other's state directly (`integrations_controller.dart:340`; `meetings_controller.dart:1040,1581,1761,1892`) | Sets the 7B order: integrations first |
| Largest desktop functions | `settings` 521 lines, `sources` 483, `meetingNotesEditor` 377, `screenshotWorkspace` 344, `scheduleGraphLayout` 298, `sourceGraph` 270, `models` 219, `stats` 218, `chat` 213. Outside the parts, `gemma_setup_view.dart:320` `build` is 203 | All exceed the 150-line build-method target |
| Status and progress | Service status and events are untyped maps read by string paths: `capture[...]` for meeting summaries, workflows, note enhancement, the question detector, proactive state and echo cancellation (for example `meeting_ai_views.dart:87`, `meetings_controller.dart:159-161,279-283,1616-1620,1937`); `googleStatus[...]` (`integrations_controller.dart:49-67`); `generator.effectiveState` (`settings_controller.dart:326,377`). `RemoteDomain` treats every event other than `capture_levels` and the approval events as a full status snapshot, and invalidates every active reader query on each distinct one (`remote_domain.dart:49-52,176-221`) | Typed status decoders, coalesced broadcasts and data-only reader invalidation are prerequisites (F-3, F-4, F-10) |
| Tests | Linux at `75898380` (2026-10-22 audit): core 1,998 passed / 16 skipped, 95.11% coverage; desktop 394 / 17, 92.47%. HanSolo at `0ba00435` (#170's evidence head): core 95.43%, desktop 92.36%. 48 desktop test, `integration_test` and `test_support` files reach private `Workspace` and feature state through `dynamic` (15 of them through `controller_fixture.dart`), and 13 test files set integer tabs. `reader_admissions_baseline_test.dart` measures admissions, notifications and builds for the Sources, Chat, Meetings and Stats tabs, but its numbers are not committed | Keep core at or above 95% measured. Desktop keeps its 90% minimum. Dynamic test access fails only at runtime (see [7B](#7b-move-one-feature-at-a-time)) |

Desktop `part` files of the `main.dart` library, in lines:

| File | Lines |
|---|---|
| `sources_controller.dart` | 2,422 |
| `meetings_controller.dart` | 2,213 |
| `settings_controller.dart` | 1,370 |
| `main.dart` | 1,054 |
| `integrations_controller.dart` | 669 |
| `meeting_ai_views.dart` | 549 |
| `chat_controller.dart` | 387 |
| `onboarding_controller.dart` | 283 |
| `workspace_visuals.dart` | 230 |
| `workspace_controller.dart` | 96 |

Summary, Action Items, Enhanced Notes, Live Q&A, document Preparation and scoped Chat are implemented. Reuse `summary_generator.dart`, `summary_output.dart`, `summary_prompt.dart`, `meeting_actions.dart`, `meeting_preparation.dart`, `answer_source_scope.dart` and `portable_query_setup.dart`. This plan reorganizes the desktop around them; it does not change their algorithms or product behavior. The current implementation references are:
- `docs/architecture/meeting-summary.md`;
- `docs/architecture/meeting-ai-workflows.md`;
- their validation records and frozen prompt fixtures.

PR 8 remains deferred. Windows support, resident model unloading, background-sync product policy and CI restructuring are out of scope.

## What #170 delivered

The complete 6A–6E specification is in revision 16. This section records what landed, so later PRs build on it rather than re-plan it.

- **6A, operation contracts.**
  - Every operation has a descriptor and a typed request with one decoder. Admission decodes first.
  - `RpcError` implements `Exception`, and an unexpected `TypeError` maps to `internal`.
  - API compatibility is checked on connect and reconnect.
  - Runtime checks prove the application and service registries are disjoint and cover every operation.
  - MCP schemas come from the same argument specification.
- **6B, domain services.** `Application` composes 17 explicitly constructed owners:
  - `SummaryCoordinator` and `MeetingWorkflowCoordinator`;
  - `NoteEnhancementCoordinator` and `RecordingController`;
  - `WorkspaceAdmin`, `ModelRegistry`, `SourceOperations` and `GoogleMaintenance`;
  - and others.

  `ConversationAnswer` is split into immutable phases. No `part of 'application.dart'` ownership remains.
- **6C, service and reads.**
  - The frontend relay topology is kept and documented.
  - `service.dart` is a barrel over `service_client`, `service_frontend`, `application_service` and `service_startup`.
  - `ApplicationService` is the single lifetime authority, deciding from the pure value `ServiceLifetimeSnapshot`.
  - Persistent read workers follow the identity-versus-freshness protocol summarized in [Core interfaces PR 7 consumes](#core-interfaces-pr-7-consumes).
  - The progress record measured RPC p95 below 2 ms during generation and capture at an intermediate candidate.
- **6D, persistence.**
  - Migrations 1–15 are frozen behind a digest manifest and a CI guard, and 16 and 17 are appended.
  - Business owners contain no SQL (see the Baseline).
  - The three helper databases are versioned as one set, with a non-mutating preflight.
- **6E, desktop interfaces.**
  - A curated `desktop.dart` API.
  - `DesktopConnection` exposes `StoreReader` and `HelperStatus`. `RemoteHelper extends Helper` and the one-line re-export shims are gone.
  - Two seams: `clientSessionGeneration`, and the Stats scheduling identity `OutputStatsPeriod`.
  - Lazy trace strings and the grpc pin guard.

Two function-size exceptions are retained with justification: `rankAnswerPassages` (164 lines) and the declarative `rpcTools` list (170).

**Merge-time evidence.** #170 merged from head `0f24e09c`. Its description's local evidence was recorded at `0ba00435`, one commit earlier: a Git-free export of 1,375 files and modes. `0f24e09c` adds only four tests to `tests/test_macos_tools.py`; hosted checks are its only evidence, and they passed.

| Gate at `0ba00435` | Linux | HanSolo Mac |
|---|---|---|
| Native root inventory | 30 passed | 33 passed |
| Core | 1,995 / 18 skipped, 95.02% | 1,998 / 14, 95.43% |
| Desktop | 394 / 17, 92.48% | 396 / 13, 92.36% |
| Compiled service/MCP | 32 / 0 | 32 / 0 |
| Real desktop/service UI | 59 assertions | 59 assertions |

- Python Quality passed with 5,202 tests and 31 skips at 95.91% (5,206 at `75898380`, including the four added tests).
- #170 merged with its five required hosted checks passing.
- Its description listed three gates as not yet run: fresh local native sanitizers, the responsiveness measurement, and Linux portable-model, audio, package and installer acceptance.
- Since then:
  - The 2026-10-22 audit ran the root CTest under Clang ASan/UBSan (30/30) and a standalone `native/` ThreadSanitizer run (16/16) at `75898380`. The hosted root ASan/UBSan and TSan jobs passed on the `75898380` push.
  - Main-push run [39830379125](https://github.com/teng-lin/open-foresight/actions/runs/39830379125) at `75898380` passed the Linux acceptance jobs with every phase selected (F-1a).
  - The responsiveness measurement remains unrecorded for merged source (F-1b).

## Core follow-ups

The 2026-10-22 audits ([consolidated](../audit/2026-10-22-consolidated.md)) found most of these; the review of revisions 17 and 18 found F-10 and F-12. An item whose "When" names a step is a prerequisite of that step and lands in the PR the Delivery table assigns. Items marked "Separate" or "Any time" must not ride along in PR 7's feature moves.

| # | Item | Source | When |
|---|---|---|---|
| F-1a | Record the hosted Linux acceptance for `75898380` in a closing #170 entry of the progress record: run 39830379125 passed `acceptance-cpu` (models suite), `acceptance-audio` (software GPU and virtual audio), `acceptance-deb`, and deb, rpm and arch packaging. Physical audio and physical GPU were not run. Rerun only if the owner rejects hosted evidence. `cpu` and `audio` can run locally: `bash tools/build_linux_container.sh --sdk-image <verified SDK> --seed <verified seed>` (default output `build/portable`, which `tools/linux_acceptance.sh` reads), then `VERSION=<version> SDK_IMAGE=<verified SDK> GITHUB_REPOSITORY=teng-lin/open-foresight bash tools/linux_acceptance.sh cpu`, and the same for `audio`. `deb`, and the deb, rpm and arch packaging jobs, run only on a GitHub-hosted runner: `tools/ci_package_sandbox.sh` refuses to run elsewhere, and must never be bypassed or installed on a developer host. To repeat them, dispatch `macos.yml` from `main` with the full SHA: `gh workflow run macos.yml --ref main -f source=75898380ac68a0a98dc4a9fdcfc38afc99d133d5 -f acceptance=full` | #170 description | 7.0 |
| F-1b | Responsiveness of the service's `status` RPC. Commit the runner that produced #170's candidate numbers (today outside the repository at `/var/tmp/foresight-core-desktop/measure-current-rpc.py`, which takes source, build, commit and output arguments; not `measure-baseline-rpc.py`, which is fixed to the `c28a1561` build). Before committing, parameterize its host-local paths, use a private `/var/tmp` temporary root (AGENTS.md), make it pass `ruff`, `mypy` and `tools/check_subprocess_timeouts.py`, and unit-test its sampling and report logic without models so it does not lower Quality's coverage. Its source and build provenance checks, today against out-of-tree `source-manifest.json`, `native-build-evidence.json`, `logs/core/aot-build-evidence.json` and the baseline directory's model and runtime qualification files, become explicit inputs: the repository and commit, the Git-free export, the service, helper, native library, model-worker, LiteRT and Whisper runtime paths, and the model files. Immediately after the export, before compiling it or running any gate, the runner's export check verifies the pristine export against `git ls-tree -rz --full-tree <commit>` (blob hash, mode and exact file set, as the out-of-tree `/var/tmp/foresight-core-desktop/freeze_candidate.py` does today, with a subprocess timeout). At measurement time it re-verifies every Git-listed blob and mode, allows extra files only under an explicit allow-list of generated paths that the runner documents (at least `test-results/`, `coverage/`, `.dart_tool/`, `build/` directories including the build directory if it is inside the export, Flutter `ephemeral/` directories, `.flutter-plugins-dependencies`, `.coverage*`, and Python and linter caches; `tools/ci_rollout.py:32` is the existing list of generated-output names), never a modified or missing Git-listed file, and checks each model file against the export's `model_pins.dart` digest. It hashes the binaries and runtimes and records every digest with the commit in its report. The author compiles that export and runs the runner against the same build that the session's gate block then passed. It never trusts a pre-made evidence file, and it raises instead of using `assert`. Method: warm the real helper and generator; take 100 `status` round trips each while idle, during streaming generation and during capture; report p50, p95 and max, startup time, runner, toolchain, workload and host load. Target p95 below 50 ms on a documented idle host; report misses and causes. The 7.0 author runs it on the local Linux host at `75898380` and at 7.0's head, and records both in 7.0's description. Later PRs re-measure only when they change service-side status, broadcast, dispatch or read code; desktop-only PRs from 7A on rely on 7A's committed admission and build baselines. Timing never replaces the deterministic liveness tests | #170 description | 7.0 |
| F-2 | Fix late subscribers in `ReadCoordinator`. A second `watch` or `read` on an active key receives nothing until another invalidation, and its 30-second deadline never starts (`read_coordinator.dart:166-186,408-416`). Give every subscriber initial delivery or work and a bounded wait, keeping one active query and one pending refresh per key. Any retained-result replay revalidates identity and freshness | CDX-F4 | 7.0, because PR 7 adds the first production watchers |
| F-3 | Client-side typed decoders over the **unchanged** v1 status payload: capture and recording, meeting summaries, meeting workflows, note enhancement, question-detector, proactive and echo-cancellation state, Google status, and generator effective state. 7.0 adds them beside the existing maps. Each 7B PR switches its own feature's consumers in a separate commit before the move (see [7B](#7b-move-one-feature-at-a-time)). 7C-4 removes `capture` and `googleStatus` from `DesktopConnection` | ARCH-4 | 7.0 |
| F-4 | Coalesce `ApplicationService._broadcast` on the trailing edge so the latest snapshot is always delivered: use `domain.createTimer` (at most about 100 ms), never drop a `workspace_epoch` change, keep `_exitIfIdle` synchronous in the `changes` listener, and cancel the pending broadcast in `close` and `_discard`. Drop a run's `preview` from status when the run settles (`summary_coordinator.dart:218` and the workflow equivalent), so status no longer keeps every finished body. Today one 201-chunk Summary produces 205 full-status broadcasts. Preferred: keep progress inside the existing status event. A separate progress event is allowed only if all of these hold: the service sends it only to clients advertising `client_api_version` 2 or higher, with a specified peer matrix as revision 16's §6A item 5 requires; `RemoteDomain._apply` handles it before the generic branch (released v1 clients treat unknown events as a full snapshot and would reset `capture`, `googleStatus`, `generation` and `helper`); it notifies presentation without invalidating the reader; and the desktop preview consumers and fixtures change in the same PR. **Event before reply.** Today the status event for a command precedes its reply (`changed()` in `callRequest`'s `finally`, `application.dart:394-397`, versus the reply at `application_service.dart:769-778`), and the desktop depends on it: Start, Stop, Pause/Resume and Enhance call `syncCapture()` right after their reply (`meetings_controller.dart:207-208,213-214,798-807,2163-2169`); stop-meeting is ignored while `recording` is null (`main.dart:384-388`); quick start admits a second meeting while it is null (`meetings_controller.dart:296`). So when a request whose operation `notifiesChanges` settles, with success or failure, cancel any pending coalesced broadcast and send the current status before the reply. For application-scope requests, flush in a `finally` immediately after `callRequest` and before the `request.committed` gate, so held-reply gate tests keep today's order. For service-scope streams, flush before the terminal `done` or error frame (`application_service.dart:595-616`), not before every frame. Bootstrap service operations (`createsLease: false`) and `service.stop_if_idle` send no status today and get no flush. Coalescing then covers only background progress, provisional transcripts and the heartbeat. Tests: a service test that the event precedes the reply for start, pause and stop, with the coalescing timer held; and a test that drives a streamed Summary through the real `ApplicationService._broadcast` and `RemoteDomain._apply` path, asserting that `capture['meeting_summaries']` carries the latest preview, that `changes` fires for each distinct delivered snapshot (`_apply` drops identical ones, `remote_domain.dart:196-197`), and that the settled snapshot drops the preview | ARCH-2, DART-N7 | 7.0 |
| F-5 | Per-workflow invalidation keys. A document-only Preparation brief is cancelled by transcript rows and notes edits | ARCH-1 | Separate fix |
| F-6 | One generation-run owner in place of the duplicated run, cancel and 20 ms SQL-polling machinery in the Summary and workflow coordinators | ARCH-3, DART-N8 | Separate, after F-5 |
| F-7 | Descriptor fields. `response` is never read: route streams by it or delete it. `notifiesChanges` drives the after-commit `changed()` (`application.dart:396`) and `readOnly` drives the MCP `readOnlyHint` (`operations.dart:250`): keep both, and add tests that each declaration matches handler behavior. Pass the typed request to `authorize` | ARCH-5 | Separate |
| F-8 | Layering fixes: <ul><li>move every `mcp_dart` use (`rpcTools`/`RpcTool`, `operation_tool_projection.dart`, and `OperationArgumentSchema.schema`, `operation_argument_schema.dart:1,162-165`) into an MCP-only library that nothing in `apps/desktop/lib` can reach, including through `desktop_bootstrap.dart`, which already pulls in `application_service.dart` through `remote_domain.dart` and `service.dart`; descriptors keep a plain JSON-schema map;</li><li>remove persistence imports of service modules (`sqlite_preflight.dart:6` → `service_socket.dart`; `source_store.dart:4` → `operations.dart`);</li><li>rename `desktop_read_models.dart`, which is core's shared projection layer;</li><li>mark `Application`'s recording setters `@visibleForTesting`, which needs `package:meta` as a direct `foresight_core` dependency with a one-line justification, or use a test-only seam</li></ul>`mcp_dart` stays a `foresight_core` package dependency, so it remains in the desktop's `pubspec.lock`. Removing it from the resolved dependencies would need a package split, which is an owner decision outside this plan | ARCH-7 | 7.0 if ready; otherwise its own core PR before 7C-4's boundary guard |
| F-9 | `meeting-summary.md` still names the deleted `application_summary.dart` (ownership is now `SummaryCoordinator`). ADR 0007 is still "Proposed" | ARCH-6 | Any time |
| F-10 | Invalidate the `StoreReader` only when status changes data identity: the status `revision` (`Store.dataRevision`, `application_service.dart:397`), `workspace_epoch` or `clientSessionGeneration`. Presentation-only status still notifies `changes`. Today the 1 Hz recording heartbeat (`elapsed_ms`) and each provisional-transcript update re-run every active watch (`application_service.dart:199-202`; `recording_controller.dart:66-71,139-143`). Prove with a test that every committed write a desktop projection reads changes the revision the next status event carries | Revision 17 review | 7.0, before 7B adds watchers |
| F-11 | Typed desktop commands: client-constructible command values and a typed `DesktopConnection` command method. Encode field presence explicitly (`hasOwner`/`hasDue` come from `rawArguments.containsKey`, `operation_requests/meetings.dart:199-202`), and keep the wire map and request digest of every command the desktop sends byte-identical, proven by a fixture test, so `PendingRequestKey` retries stay valid | ARCH-4, revision 17 review | Separate, after 7C. Converting about 72 call sites is a logic change, so it does not ride along in the moves |
| F-12 | Additive read APIs, so 7B never stops on a core interface gap and 7C-1 only removes: <ul><li>typed `StoreReadQueries` factories, with worker tests, for the nine projections that lack one (`notes`, `note_body`, `source_mimes`, `labels`, `clusters`, `cluster_names`, `graph_label_set`, `meeting_revision`, `enhanced_notes`);</li><li>reader-free versions of the `model_setup.dart` helpers that take a prepared `ModelRegistration?` (from `StoreReadQueries.model`) instead of a `StoreReader`.</li></ul>Features construct reads only through `StoreReadQueries`, never by constructing `ReadQuery` with a projection name; 7C-4's guard enforces this | Revision 18 review | 7.0, before 7B |

**Security fixes.** Three consolidated tasks touch contracts this plan preserves:
- P0.1 binds desktop approval to the verified desktop process. Its fix also changes desktop behavior: the host slot is kept while the window is hidden, capture is refused with no visible window, and the `commands.sock` quick meeting is gated (`agent_approval_surface.dart:47-56`, `commands.dart:115-140`).
- P0.2 enforces each operation's declared policy at admission; `service.stop_if_idle` currently bypasses it.
- P0.3 gates agent overwrites.

Each is a deliberate behavior change with its own tests, and none rides along in PR 7. P0.1 changes 7A's composition-only approval port, the shell's approval characterizations (moved in 7B-6) and integrations' quick-meeting activation (7B-1), so land it before 7A (see [Delivery](#delivery)). A security PR that lands later updates the characterizations its intended behavior change replaces, in that PR; that is not a weakened assertion.

The remaining defects are outside this plan: DART-N1, DART-N2, DART-N10 and CDX-F3 in core; CDX-F2 in native; DART-N9 (ungated `test_support` analysis) in desktop test hygiene.

## Delivery

The table retains the original stage names. The owner's [current delivery
decision](#current-delivery-decision) combines them in one final PR; keep each
stage independently reviewable in its commits.

| PR | Content | Notes |
|---|---|---|
| 7.0 | F-1a, F-1b (baseline and re-measure), F-2, F-3, F-4, F-10, F-12; F-8 if ready | Core, plus the desktop consumers and fixtures F-3 and F-4 require. No feature moves. Full Linux matrix including native CTest, the compiled service/MCP gate, isolated-display desktop integration and the fast suite. Widget tests cannot see F-4 because the desktop fixture bypasses `_broadcast` and `_apply` (`desktop_connection_fixture.dart:68,100-101`); F-4's own service and real-path tests cover it |
| 7.1 | Fix current desktop defects, each with a regression test: <ul><li>DART-N3: the preview's Generate button sends nothing (a #170 regression);</li><li>DART-N4: a slow save reply re-targets the note editor;</li><li>DART-N5: onboarding retry never marks the runtime ready;</li><li>DART-N6: UI callbacks drop request failures (see [Asynchronous actions](#asynchronous-actions));</li><li>DART-N11: the sign-in dialog pops whichever route is on top (`google_sign_in_dialog.dart:91`);</li><li>TEST-2: inject the platform environment so widget tests never run the real `hyprctl` or touch the real config (see [Hermetic tests](#hermetic-tests))</li></ul> | Keeps behavior fixes out of the mechanical moves |
| 7A | Composition root, shared presentation, shell ports, `WorkspaceTab`, the interim rebuild bridge, the library ownership table, residual characterizations and committed admission baselines | No feature moves |
| 7B-1 to 7B-6 | One feature per PR: integrations, settings, chat, sources (with the note editor), meetings (with the AI views and `meeting_visuals.dart`), then onboarding and shell | Meetings may need two PRs to stay under the file budget |
| 7C-1 | Remove the synchronous `StoreReader` projections, the map conversions, `desktop_reader_adapters.dart`, the `StoreReader` versions of the `model_setup.dart` helpers and `ConnectedSources.attachments` (planned core API removals) | Core and desktop |
| 7C-2 | Platform adapter replacing inline `Platform.is*` checks | |
| 7C-3 | Test fixtures: replace `controller_fixture.dart`'s introspection and the remaining dynamic test access; enable `avoid_dynamic_calls` for desktop tests | |
| 7C-4 | Architecture guard, `GoogleAccount.configured` (a planned core API change), removal of `capture`/`googleStatus` maps, remaining cleanup | |

**Sequencing.**
- 7.0 and 7.1 precede 7A. 7B-n follow 7A in order. 7C-1 follows 7B-6; 7C-2 to 7C-4 follow 7C-1 in any order, with 7C-4 last if it carries the guard.
- P0.1 lands before 7A. If the owner schedules it later, the P0.1 PR updates the approval port and characterizations as its intended change.
- F-8 lands before 7C-4.

For every PR in the series:
1. Rebase on current `main`.
2. Run the full applicable Linux matrix (see [Verification](#verification-matrix-and-implementation-stop-conditions)), plus the HanSolo matrix where owner decision 1 requires it.
3. Pass the required hosted checks.
4. Run native-team implementation reviews and an external CLI review by a different agent than the implementer (Codex CLI while Claude Code implements) until they converge.
5. Before each follow-up push, fetch the PR head, review threads (including bot reviews) and CI results. Read the failed step's output, verify each finding against current code, and batch the fixes (AGENTS.md).

Record the evidence (source SHA, counts, skip reasons, coverage) in the PR description. The progress record stays the historical record for #170, apart from F-1a's closing entry.

**Owner decisions needed:**
1. **When to run the HanSolo Mac matrix.** Revision 16 required it at the final combined head. Recommended:
   - run it on 7B-1 (integrations: shortcuts, accounts, platform behavior), on the Meetings PR (capture UI) and on 7C-2 (platform adapter);
   - also run it whenever a hosted macOS check fails;
   - rely on the hosted macOS checks for the other PRs.

   The HanSolo matrix is the set #170 recorded, run from an exact Git-free export in a dedicated HanSolo worktree: the root native inventory; core and desktop suites with coverage; fresh AOT service and MCP, and the Release desktop; the compiled service/MCP gate and the real macOS UI test; `platform_python_tests.py --platform macos`; DMG fixtures; ad-hoc codesign and runtime closure, and the relocated MCP; live application-owned SQLite in both processes. Record each row as the merge-time table does. The hosted `macos` job covers most of this, but not coverage (off on PRs) or local Xcode and hardware.
2. **Order of 7.0 and 7.1.** Recommended: land 7.1 first, because it fixes user-visible bugs, and develop 7.0 in parallel.
3. **When P0.1 lands.** Recommended: before 7A, as above.

## Contracts that must survive every commit

1. **Ownership and shutdown.**
   - One writable application Store and one service owner per canonical profile.
   - Keep the public frontend and the private worker socket, the record and lock release order, and closing refusals for undispatched work.
   - Return `outcomeUnknown` for dispatched work without a proven result, and resend once only for `closing`/`notSent`. Never replay an ambiguous mutation.
   - Preserve helper identity and adoption verification, and replacement-socket protection.
2. **ADR-0007 lifetime.**
   - Desktop presence pins the service.
   - Desktop-only departure keeps its grace period. Agent activity and helper-wait, dispatched and cancellation work follow revision 7's rules.
   - Idle exit sees all executing background work, including Summary and meeting-workflow runs. Scheduled timers that have not fired and durable paused work do not pin it.
   - Only the service decides to exit. Keep one generation-reservation authority and underlying-child settlement.
3. **Approval and capability admission.**
   - Preserve each operation's current host, approval, file-root, web-search and overwrite policy. Bootstrap operations stay reachable through their existing capability flow.
   - Keep #170's admission order (`application_service.dart:440-528,586-587,745-772`): structural envelope decode → closing refusal → typed decode → bootstrap routes and `service.stop_if_idle` exit here (P0.2 changes this); a desktop `status` with an invalid token is denied here, and a valid one reserves desktop presence and continues → per-connection request cap → stale-epoch rejection → approval (`authorize` is approval-only) → for application-scope requests (`_execute`): closing re-check → helper readiness → closing re-check → the `hostedRecording` capability check, at dispatch time so the host must still be attached → cancellation check → dispatch → `Application.callRequest` (open, epoch and configuration gate). Service-scope streams go to their service handler after approval (`application_service.dart:640-692`). Do not move the capability check before the helper wait.
   - A malformed request returns `invalidArgument`, emits no approval event, never enters dispatched work, never stamps agent activity, and leaves an armed desktop-departure grace intact.
   - Durable idempotent replay stays inside authorized dispatch.
   - Changes to these policies are security work (see Core follow-ups), not refactoring.
4. **Commit and cancellation semantics.**
   - Keep workspace epochs, idempotency keys, durable pending helper work, revision checks, after-commit notification order, cancellation cleanup and captured-transcript finalization. A cancelled future is not proof that the underlying work settled.
   - Preserve atomic acceptance of Summary and workflow artifacts. Preview and progress output is not accepted data.
   - Preserve manual task details, completion, evidence and stale state, edited history, degraded results and retry identities.
   - Source scope is a privacy boundary: a selected-empty scope never widens to Workspace, and a scope change invalidates in-flight retrieval, history, persistence and scoped web memory.
5. **Desktop behavior.**
   - Preserve:
     - recording ownership on host disconnect;
     - selected-meeting targets, recovery and reconnect;
     - transcript copying;
     - autosave and enhancement edits;
     - approvals and Google authorization and setup;
     - navigation and onboarding.
   - Late completions from a retired feature, connection, query or workspace epoch must not overwrite newer state. #170's retired-action guards must keep their meaning, without DART-N3's over-narrow `meetingId == id` check.
   - The global operation gate (`busy`, `error`, the outcome-unknown refresh and the failure notification) stays shell-wide. Narrowing it per feature would let, for example, a meeting Generate start during a workspace clear; that is a product change outside this plan.
   - Keep the six meeting-assistant panels; Summary phase, previews, cancel and history; structured task editing; degraded Notes warnings; local Preparation selection; and distinct manual and automatic answer scopes.
   - Characterize missing races before claiming they are safe. A real defect gets a separately tested behavioral fix, never a weakened characterization assertion.
6. **Integrity and verification.**
   - [AGENTS.md](../../AGENTS.md) and [CI integrity](../platforms/ci-integrity.md) govern dependency provenance, cache reuse and gates.
   - Reuse verified dependency SDKs, and compile the changed project code.
   - Do not delete caches, weaken tests, substitute mocks for process acceptance, or present reused bytes as a new build.

## Core interfaces PR 7 consumes

- **Composition and ownership.** Composition owns the service connection, the read-only `StoreReader` and the `HelperStatus` proxy. The connection owns the persistent read worker and coordinator, and joins actual reads on close. Features own their subscriptions and presentation generations; they never duplicate the coordinator's scheduling.
- **Identity versus freshness.**
  - A mismatch in workspace epoch, owner, profile, reader connection (the endpoint, which a same-path replacement does not change) or query generation always discards a result, including one superseded by a newer completed request.
  - A data-token change alone, on the same authoritative connection, publishes the completed projection as a **preview** and schedules one coalesced refresh. The result becomes current only when the token is unchanged.
  - The coordinator keeps at most one active query and one pending refresh per query key.
  - A 30-second caller deadline returns a typed retryable busy result and keeps the last valid view; a late reply is ignored.
  - A schema incompatibility retires the coordinator with a typed failure (over RPC, `unavailable`).
  - Commands based on preview rows keep their own epoch, resource and revision admission checks.
- **Session identity.**
  - `clientSessionGeneration` advances on every client or service replacement, even at the same path and epoch. It is distinct from the SQLite reader's connection and data token; never compare foreign tokens.
  - Do not infer identity from socket paths, and do not cast back to a concrete transport client.
- **Invalidation.** After F-10, the reader is invalidated only by data-identity changes, so status-only changes cause no `watch`, `read` or worker admissions. They still notify `changes`, which drives the `serviceUiRevision` rebuild, so a feature that has not moved still re-runs its synchronous build-time reads until its 7B PR. Until F-10 lands, every distinct status event re-runs every active watch.
- **Stats.** `OutputStatsPeriod` is the stable calendar and zone scheduling identity; `OutputStatsWeek` is one captured Monday within it. Use `StoreReadQueries.outputStatsForPeriod(period: OutputStatsPeriod.capture(now))`, keyed by `period.key`. Each worker dispatch samples a fresh exact cutoff. If the period changed, the dispatch fails with an ordinary `ReadFreshness.failed` result (`RpcErrorCode.internal`; `store_read_queries.dart:57-76`, `read_coordinator.dart:297,319-330`). On any failed result, the Stats feature recaptures `OutputStatsPeriod` and compares its `key`: a changed key means "replace the query with the new period", never a user-visible error. Do not match the error message. If this seam proves insufficient, stop the move and treat the gap as a core follow-up.
- **Multiple subscribers.** Until F-2 lands, a feature must not depend on a second subscriber to an active query key.

## PR 7: desktop feature modules

### 7A. Establish composition, ports and invalidation

**Start condition.** Under the current single-PR decision, start after 7.0, 7.1 and P0.1 production changes integrate locally with their focused checks and reviews. Record the fetched `main` SHA and the actual integrated public interfaces. Final combined platform acceptance remains required before publication.

**What to freeze and preserve.**
- Commit the admission, notification and build numbers that `reader_admissions_baseline_test.dart` measures for Sources, Chat, Meetings and Stats, and add baselines for Settings, Integrations and Onboarding. "Freeze" means these committed numbers.
- Retain `CaptureLevelEvents`, `captureVolumes` and the early-return capture notification path as existing functionality.
- Characterize the coalesced `serviceUiRevision` path and which screens consume it. Today:
  - each service event costs a schema check and a full `jsonEncode` signature on the UI isolate (`remote_domain.dart:195-196`);
  - each distinct event rebuilds the active tab within 100 ms (`main.dart:312-339`), re-running synchronous Store reads in build.
- Do not describe every event as a full-workspace rebuild.

**Libraries to create.**
- An application composition root, a shared presentation library, and one interface-only shell-port library (for example `lib/shell/ports.dart`) holding the ports below. When a feature moves, the 7A cross-feature ports it provides (for example Google account status, recording facts) move into its outward port file or are re-exported by it, so each dependency has one interface.
- Publish `_FeatureController`'s shared helpers (`pill`, `heading`, `searchBox`, `timeLabel`; `workspace_controller.dart:19-95`) and the cross-feature parts of `workspace_visuals.dart` as shared presentation. Feature-specific widgets in `workspace_visuals.dart` (`_CaptureWaveform` for meetings, `_DashedStadiumBorder` and `_SourceLinks` for sources, `_UsageChart` for settings) move with their feature in 7B.
- Empty `features/integrations`, `settings`, `chat`, `sources`, `meetings` and `onboarding` directories are not needed; each 7B PR creates its own.
- Leave `main.dart` responsible for process entry and composition, not feature-private state.
- Record the final [library ownership](#library-ownership) table in the 7A PR, confirming the defaults below from actual symbol use.

**Shell ports.** 7A defines these interfaces and makes the shell implement them. Features keep `extends _FeatureController` until their own 7B PR.
- **Feature host:** what `_FeatureController` supplies besides helpers and feature getters (`workspace_controller.dart:8-18`): the connection, `mounted`, a `BuildContext`, the rebuild callback (the interim bridge below) and a `TickerProvider` (the shell creates Sources' ticker and camera controller, `main.dart:358,361`); the `captureVolumes` and `serviceUiRevision` listenables; the `Workspace` constructor dependencies `deviceLoader`, `commands` and `sourceLinkOpener`; and 7.1's platform environment (runner, URI opener, notifier, environment variables and directories). `sourceLinkOpener` defaults to the environment's URI opener. `deviceLoader` stays a separately injected dependency (its default runs `pw-dump`; widget tests already inject it).
- **Navigation:** a `WorkspaceTab` enum with exhaustive switches in place of integer tab indices (MNT-5). Cross-feature jumps go through a navigation method, never `shell.tab = N`. 7A converts the 38 lib sites and the integer tab reads and writes in 15 test files.
- **Operation gate:** `run`, `busy`, `error`, the outcome-unknown refresh and the failure notification, unchanged in behavior (Contract 5).
- **Dialogs:** `showInputDialog` and `rowsAreCurrent`.
- **Error reporting:** `reportAsyncError`.
- **Workspace lifecycle:** the clearing flag, `resetWorkspaceViews` and `serviceChanged`.
- **Read-only activity facts:** chat `asking`, meeting `meetingEnhancing`, recording state and onboarding `active`.
- **Owner commands** replacing each direct cross-feature write: `systemAudioSetupReviewed` (`integrations_controller.dart:340`), `modelKind` (`meetings_controller.dart:1040`), `answerFontSize` (`:1581`) and question text (`:1761,1892`).
- **Google account status and commands, and meeting selection.**
- **Approval presentation:** composition-only. The shell's `AgentApprovalSurface` wraps the workspace (`main.dart:667-671`); no feature part consumes it.
- Do not replace `shell` with a global service locator or a wide context exposing all features.

**Interim rebuild bridge.** Until the last reader of a feature's state has moved, every state change in a moved feature must also trigger the shell rebuild, either through an injected `update` or by the shell listening to the feature's notifier. The shell build reads settings (`localWords`, `embeddingName`, `embeddingGpu`, `helperEmbeddingHealthy`), and `main.dart` makes 61 `meetingFeature` and 24 `sourceFeature` references; meetings reads `chatFeature.asking` and `answerFontSize` (`meetings_controller.dart:1363,1705,2039`). Narrow rebuilds only after all readers use selectors. Each 7B PR shows that none of its consumer screens shows stale state.

**Resource ownership.**
- The Workspace drains pending note saves before disconnect.
- Each feature owns the subscriptions, timers, text, scroll and focus controllers, view-model requests and notifiers it creates.
- Dispose each owned resource exactly once.
- Ignore late results using a feature, request, connection and epoch identity.
- Preserve the sequencing of window close, detach and settings persistence.

**Session replacement.** Consume `clientSessionGeneration`. A same-path, same-epoch client or service replacement must remain observable, and it retires old feature actions and results. A retained valid SQLite reader is not evidence that the feature session survived.

**Invalidation.**
- **Initial mechanism.** Start conservatively:
  - a change with known scope invalidates that feature's cached read models;
  - an unknown or coarse service event invalidates every affected data consumer, as today, until completeness is proven.

  Current events carry a coarse `Stream<void>` or full snapshot and one `dataRevision`. So begin with immutable view-model comparison under broad invalidation: every data-identity change refreshes the relevant cached projections asynchronously, and only projections that actually changed notify widgets. Typed per-feature wire scopes are an optional later optimization.
- **Dependency map.**

  | Change | Consumers to invalidate |
  |---|---|
  | Sources and imports | Sources, Stats and Ask citations |
  | Meeting notes and transcripts | Meetings, Stats, and the affected source graph and citations |
  | Model or helper identity | Setup and graph |
  | Account changes | Integrations and the meeting calendar |
  | Artifact acceptance or edit, task completion, preparation or cache acceptance | Meetings, plus derived-source, Stats, graph and scoped Chat consumers |
  | Source soft delete or revision change | Preparation eligibility and reuse. This does not imply physical cache-row removal |
  | Scope selection | The affected manual or automatic answer view, and retrieval and history identity |
  | Unknown change, reconnect, clear | Everything |

  A source change may legitimately invalidate a Meetings dependency. Test an unrelated screen rather than asserting that Meetings never rebuilds.

**Characterization.** #170 and its follow-ups already cover most lifetime races. Reuse these; do not duplicate them:

| Behavior | Existing coverage |
|---|---|
| Summary, actions and preparation across selection, clear (including ID reuse), session replacement and disposal | `meeting_producer_lifetime_test.dart`, `meeting_ui_producer_lifetime_test.dart` |
| Task edits, completion, source picker and preference writes across clear and session | `meeting_dialog_lifetime_regression_test.dart`, `meeting_action_error_lifetime_test.dart`, `preference_reply_lifetime_test.dart` |
| Same-conversation answer-scope changes with late text, history and citations | `answer_scope_lifetime_regression_test.dart` |
| Cancellation that keeps accepted artifacts and manual tasks | `summary_stream_test.dart`, `meeting_producer_lifetime_test.dart` |
| A held note save drained before disconnect | `note_save_scheduler_test.dart` |

Fill only the residual gaps before the first move:
- actions started from the meeting-list preview (every producer test sets `meetingId`, which is how DART-N3 escaped; 7.1 adds the first);
- task and source-picker dialogs across a meeting-selection change (only clear and session are covered);
- admission and build baselines for Settings, Integrations and Onboarding.

Also reuse startup, pending-create and idempotency, clear and offline, accepted history and capture-level fixtures.

**Measurement.**
- Count query admissions at the typed `StoreReader` `read`/`watch` boundary and the worker projections, then count feature notifications and widget builds separately.
- Legacy `Store.rows` overrides can be bypassed by typed `db.select` queries. Keep their semantic and large-source assertions, but do not treat zero calls as proof of zero SQL.
- Newly allocated value-equal projections must not notify.
- Capture-level events (`capture_levels`) and graph frames cause no persistence admissions. After F-10, other status-only changes, including the 1 Hz recording heartbeat, cause none for a feature once it reads prepared models (its 7B PR); until then, the committed baseline records them.

### Library ownership

Default owner of each standalone desktop library, from its main symbol's users at `75898380`. A library used by two or more features is shared. 7A confirms the table; a feature PR moves the libraries it owns.

| Owner | Libraries |
|---|---|
| Shell and composition | `main.dart`, `account_button.dart`, `agent_approval_surface.dart`, `calendar_auth_links.dart`, `commands.dart`, `desktop_menu.dart` |
| Shared presentation and utilities | `app_theme.dart`, `desktop_visuals.dart`, `generated_content.dart` (chat, meetings), `failure_text.dart`, `feature_request_identity.dart`, `model_setup.dart` (settings, meetings, shell), `service_edit_dialog.dart` (sources, meetings), the shared parts of `workspace_visuals.dart` |
| Integrations (7B-1) | `desktop_settings.dart`, `global_shortcuts.dart`, `hypr_shortcuts.dart`, `google_picker.dart`, `google_sign_in_dialog.dart`, `system_audio_setup_dialog.dart` |
| Settings (7B-2) | `gemma_setup_view.dart`, `speech_setup_view.dart`, `model_setup_surface.dart`, `model_terms_dialog.dart`; `localOutputStats` from `background_store.dart` |
| Sources (7B-4) | `file_discovery_sheet.dart`, `graph_label_controls.dart`, `graph_rendering.dart`, `cluster_rendering.dart`; `searchSourceIds` from `background_store.dart` |
| Meetings (7B-5) | `meeting_visuals.dart`, `meeting_export.dart`, `meeting_note_state.dart`, `note_save_scheduler.dart` (shared if the relocated note editor uses it) |
| Onboarding (7B-6) | `onboarding_view.dart` |
| Removed in 7C-1 | `desktop_reader_adapters.dart` |

The size targets in [PR 7 acceptance](#pr-7-acceptance) apply to all of desktop `lib/`.

### 7B. Move one feature at a time

**Order and method.**
- Order: integrations, settings, chat, sources, meetings, then onboarding and shell cleanup. Each is its own PR (see [Delivery](#delivery)). Integrations is the hub: settings, onboarding, meetings and sources all depend on it, while it needs only small ports from unmoved features (a preference writer, recording and quick-start facts and commands, and the onboarding-active flag).
- A moved library cannot see the private controllers still in `main.dart`. Every reference from a moved feature to an unmoved one goes through a 7A port or a small public interface added in that PR.
- For each feature:
  1. Characterize the existing behavior.
  2. Introduce its interfaces and view model, and publish its outward port file. Unmoved parts and later features use only that file.
  3. In a separate commit before the move, switch the feature's status consumers to F-3's typed decoders.
  4. Move controller logic, widgets and its owned libraries without logic changes, and remove its `extends _FeatureController`.
  5. Remove its old part.
  6. Verify its isolated and existing tests.
- 7B-6 deletes `workspace_controller.dart`.
- Keep public navigation and settings keys stable.

**Dynamic test access.** 48 test files reach feature state through `dynamic`, so a rename or restructure compiles and fails only at runtime, including in the compiled service gate's `service_mcp_test.dart:105-109,222-355`. Each PR converts the dynamic accesses its change breaks, counts those files in its budget, and runs the full desktop suite and the compiled service gate. A typed `@visibleForTesting` facade on the Workspace may carry tests until 7C-3.

**Read models.**
- Read models use `StoreReader` typed asynchronous queries, built only through `StoreReadQueries` (F-12), instead of the synchronous projections and the `readRows`/`toRow` map conversions. Perform queries outside widget building. Meetings reads attachments through `StoreReadQueries.attachments`, not `ConnectedSources.attachments`.
- Cache by the relevant query parameters plus workspace epoch, data revision and connection identity. That includes `OutputStatsPeriod.key` for usage statistics and `(model JSON, instanceId, activeGeneration)` for helper-dependent graph results.
- No Store or SQL query and no expensive graph layout may run inside a `build` or widget-returning method, or any helper it invokes. That covers export dialogs, setup helpers, filtered-source lists and statistics.
- Cheap synchronous reads of already-prepared immutable view state are fine.
- A query for an old search, selection or profile cannot publish, and an older completion cannot replace a newer result.
- Apply the identity-versus-freshness protocol above.

**State preservation.**
- Keep `resetWorkspaceViews` dropping drafts and IDs before `adoptWorkspace`.
- Keep the `rowsAreCurrent` dialog guards.
- Keep `PendingRequestKey` reuse on retries, with reset after workspace clear.
- Debounce or coalesce without dropping required invalidation or autosave.

#### Asynchronous actions

DART-N6 is fixed in 7.1, not during the moves. 7.1 introduces one action wrapper that reports failures and binds the reply to the feature, selection and epoch it started from, and applies it at the known sites: `settings_controller.dart:837,990,1014,1315`; `integrations_controller.dart:666`; `meetings_controller.dart:1471-1473,1495-1496,1638-1639`. `discarded_futures` does not catch expression-bodied closures, so do not rely on the analyzer. 7.1 also fixes DART-N11 with a route-scoped pop. The 7B moves keep the wrapper and the route-scoped pop.

**Sources.**
- Before moving Sources, relocate the standalone note-editor state and its New Note `PendingRequestKey` into Sources/Notes ownership, in a separate mechanical commit.
- Rebind composition's unsaved-edits check (`main.dart:572-573`), controller disposal (`:536-537`), clear reset (`:592-595,603`), New Note shortcut (`:722-727`) and navigation. The note-save drain before disconnect is Meetings' `NoteSaveScheduler` (`main.dart:506-507`).
- Do not expose the Meetings editor or controller as a cross-feature port.
- A save or create reply applies only while the editor still shows the note it was issued for (DART-N4, fixed in 7.1; the move must keep that guard).
- Preserve the pending-create payload, idempotency-key and workspace-epoch assertions, including lost-reply retry, held save and reset-before-adopt.

**Integrations.** `connectGranolaCalendar` overwrites `d.googleStatus` with the configure reply and then reads `granolaCalendar` from it (`integrations_controller.dart:52-59`). F-3's decoders are read-only, so 7B-1 replaces that write before 7C-4 removes the map: with F-4's event-before-reply, the `google` status that precedes the reply carries the new provider, so verify that and delete the write; otherwise keep the configured provider as feature-local state from the reply, without mutating connection state.

#### Hermetic tests

TEST-2 is fixed in 7.1. Today, under `HYPRLAND_INSTANCE_SIGNATURE`, desktop widget tests run the real `/usr/bin/hyprctl` and can rewrite the user's `hypr/bindings.lua`. 50 test files mount `Foresight(` or `Workspace(` directly, so fixing only shared fixtures is not enough.
- `Foresight` and `Workspace` take a platform environment value: environment variables, config and data directories, a process runner, a URI opener and a notifier. `main()` creates the real one and `DesktopStartup` carries it; the parameter is required on `DesktopStartup`, so a production path cannot silently fall back to a fake. The `Foresight`/`Workspace` widget default is hermetic.
- Route through it every direct host access in desktop `lib`:
  - process launches: `activateWindow`'s `/usr/bin/hyprctl` call (`integrations_controller.dart:107-120`), the `HyprShortcuts` getter that drops `run` (`:6-12,95-96`) and its default `run = Process.run` (`hypr_shortcuts.dart:11`), `commands.dart:88` (`/bin/chmod`), `system_audio_setup_dialog.dart:25` (`/usr/bin/open`), and Gemma setup's `Process.start(widget.runner, ['--check'])` (`gemma_setup_view.dart:203`; `gemma_setup_test.dart` drives it with `/usr/bin/true`, which becomes a fake runner);
  - environment reads: `integrations_controller.dart:7-9,108,163,199,612`, `sources_controller.dart:372` (`HOME` for file discovery), `main.dart:110,132,400`, and `DesktopSettings`' `HOME` and `XDG_DATA_HOME` (`desktop_settings.dart:31-33`);
  - core helpers that launch host processes: `openPlatformUri` (`xdg-open`, `platform_services.dart:406-412`; called at `chat_controller.dart:67`, `model_terms_dialog.dart:42,49,96`, `integrations_controller.dart:370`, and the default opener at `generated_content.dart:12` and `main.dart:238`) and `platformNotification` (`notify-send`, `platform_services.dart:414-427`; called at `integrations_controller.dart:483`, which the shell gate reaches on every failure while notifications are on).
- Guard: a source test rejects `Process.run`, `Process.start`, `Platform.environment`, `openPlatformUri` and `platformNotification` in desktop `lib` outside the environment adapter and `main()`. A behavioral test sets `HYPRLAND_INSTANCE_SIGNATURE` in the injected environment and asserts that the fake runner receives the `hyprctl` calls and that nothing outside the temporary directories changes; it skips on macOS until 7C-2 injects the platform, because every Hyprland path also checks the real `Platform.isMacOS` (`integrations_controller.dart:107,162,198,608`); register that skip in `tools/integration_skips.json`, which Quality's inventory check requires. A third test asserts that `main()`'s environment binds the real runner, opener and notifier. CI never has Hyprland, so the source guard carries the enforcement.
- Production Hyprland behavior is tested through the adapter.

**Widgets and loading state.**
- Extract large builders into widgets with explicit state and actions.
- Use feature notifiers and small selectors, within the interim rebuild bridge. Capture meters listen only to their existing level notifier.
- Feature-local loading indicators may be added for work the feature owns, but the shell-wide operation gate keeps its meaning (Contract 5).
- Keep responsive layouts, accessibility and keyboard selection, transcript clipboard behavior and platform styling.

**Answer scope.**
- Include the captured answer scope in query, view and cache identity, separately from ordinary data freshness.
- A scope change advances the query generation and always rejects the old result; it is never published as a preview.
- A stable scheduling key covers profile, connection, epoch, projection, filters and selection. Ordinary data-revision changes affect freshness and cache tags, but do not create a new scheduler or retire a valid active query.
- Preserve `answerScope.meeting:<id>` versus `proactiveScope.<id>`, their selected-source keys, and preparation selection. Local source pickers are not network authorization.
- Snapshot task and source dialogs, and pending preference commands, against their original meeting and epoch. Generic `preferences.set` is not epoch-scoped: test for stale-dialog writes, and fix any real gap separately.

**Stats (with Settings, 7B-2).** Stats is Settings' tab, and today its period re-keys only when `localWords()` runs during a rebuild (`settings_controller.dart:425-429`). The next-Monday timer and the timezone recheck below are new behavior: list them as 7B-2's intentional behavior changes, with their tests.
- Schedule by `OutputStatsPeriod` (see [Core interfaces](#core-interfaces-pr-7-consumes)), and let each worker dispatch freeze a fresh exact `now` cutoff, preserving the exclusion of future-created rows.
- Values and chart labels share the same captured period.
- Rearm a calendar-based next-Monday timer from `nextWeekMilliseconds` when the period changes, and check calendar identity on resume.
- Detect timezone and calendar changes while the app stays awake and focused, with no service event, through a reliable platform notification or a bounded clock and zone recheck.
- Reject any held reply from the prior period; a period-change dispatch failure replaces the query.
- Keep the one-active, one-pending and actual-settlement rules.
- Tests cover held refreshes, exact cutoffs, Monday and DST rollover, and a midweek timezone change with neither resume nor a service event.

**Feature acceptance scenarios:**

| Feature | Scenarios that must keep their assertions |
| --- | --- |
| Integrations | Google and Granola calendar setup and sign-in; multiple accounts and imports; cancellation; quick-meeting activation from `commands.sock`; connection status through reconnect; Hyprland shortcut and focus behavior through the injected adapter |
| Settings | Model reuse and repair; portable detector executable, SHA-256 and backend setup; Unicode policy; idle preference; usage statistics; version and license; platform controls; hook-free release behavior |
| Chat | Streaming, cancellation and preemption; web approval; citations, history and memory filtered to the captured scope; manual Workspace versus automatic Meeting defaults; selected-empty isolation; scope-change rejection |
| Sources | File, URL and Drive import; permissions; revision-safe search; selection; labels; graph layout; delete and clear; stale-completion rejection; note save and create bound to the issuing note |
| Meetings | All six assistant panels (Chat, Live Q&A, Summary, Transcript, Actions, Preparation) from the meeting workspace; from the meeting-list preview, Notes, AI summary (including Generate, DART-N3) and Transcript; Summary streaming, progress, cancel, history and clipping; task evidence, manual completion and stale state; local Preparation, cache and degraded retry; Enhanced Notes edits and degraded warnings; detector readiness and Q&A queue age; recording and finalization, transcript copy, calendar and recovery |
| Onboarding and shell | First-run and pending-create flows; model acquisition; retry after a failed first connection; navigation restoration; reconnect; retired workspace events; approval UI (`AgentApprovalSurface`); close and dispose; multiple desktop ownership |

**Before moving the AI view part.**
- Confirm characterization exists for:
  - switching meetings;
  - clear, reconnect or dispose during a Summary or workflow preview;
  - stale task and source-picker completion;
  - source-scope changes during an answer;
  - cancellation that retains accepted artifacts and manual tasks.
- Reuse `summary_stream_test.dart`, `meeting_ai_views_test.dart`, `meeting_actions_workflow_test.dart` and `test_support/meeting_panel.dart`.
- Adapt fixture setup without losing production selector behavior, and without replacing the real service integration with widget-only coverage.

### 7C. Close the boundary and remove obsolete coupling

**7C-1: synchronous reads.**
- Remove the 25 synchronous projections from `StoreReader` and its SQLite implementation once no consumer remains. By then the 7B moves have switched every consumer to F-12's factories and reader-free helpers, so 7C-1 only removes: the `StoreReader` versions of the `model_setup.dart` helpers (`model_setup.dart:286,381,406`), and `attachments` from the `ConnectedSources` interface (`desktop_connection.dart:64`) and its overrides in `RemoteGoogleConnections` (`remote_google.dart:161-171`), `GoogleConnections` and the desktop test fake `SettingsSources`. `GoogleConnections` keeps an internal method where `google_connections.dart:551` needs one. Update the core tests (including `remote_domain_test.dart` and `google_connections_test.dart`), `CountingStoreReader`, `store_reader_fixture.dart`, `stats_retry_lifetime_test.dart`'s `_StatsReader`, the typed reader reads in `integration_test/service_mcp_test.dart:173-175`, and every typed reader read in `integration_test/meeting_workflow_test.dart` (its `readerFor`/`sourceRows` helpers, about two dozen direct projection reads, and a `readerSpeechSetupProblem` call). The desktop gate's `flutter analyze` reports both files, and `test/agent_approval_surface_test.dart` imports `meeting_workflow_test.dart` into the ordinary suite; only the virtual-audio and compiled service gates execute them.
- Delete `desktop_reader_adapters.dart`. Criterion: no `toRow`, `fromRow` or `readRows` in desktop `lib`, and no core API exported to the desktop that reads a synchronous projection.

**7C-2: platform adapter.**
- Move platform policy into a `PlatformCapabilities` or platform adapter, extending 7.1's injected environment and chosen at startup.
- Presentation receives capability facts and actions. Only platform implementation code may use `Platform`; there are 41 inline `Platform.is*` checks in desktop `lib` today, across 10 files.
- Keep the macOS title bar, Linux capture and shortcuts, and the existing unsupported-action messages. This is not a Windows port.
- Remove the macOS skip from 7.1's behavioral Hyprland test and its `tools/integration_skips.json` entry, and run the test in 7C-2's HanSolo matrix.

**7C-3: test fixtures.**
- Replace `controller_fixture.dart`'s private shell introspection (15 users) and any remaining dynamic Workspace access with feature fakes or the typed test facade's replacement.
- Enable `avoid_dynamic_calls` for desktop tests, or an equivalent guard.
- In-process service fixtures may keep `package:foresight_core/src/...` imports through a single test-support library. Desktop production code and boundary tests use only the curated public API.

**7C-4: guard and cleanup.**
- **Architecture guard.** A source guard covers imports, exports and parts. It rejects implementation imports and write-capable core types in desktop production code, any construction of `ReadQuery` in desktop `lib`, including with type arguments and the `ReadQuery.new` tear-off (reads go through `StoreReadQueries`; removing `ReadQuery` from `desktop.dart`'s `show` list, so desktop `lib` can neither name nor construct it, also satisfies this; then change `desktop_boundary_test.dart`'s expected `desktop.dart` export list, which includes `ReadQuery` today), and `package:mcp_dart` in the transitive **import** closure of `apps/desktop/lib` (after F-8). Narrow test-support adapters may implement fakes, but they do not exempt production. `StoreReader` stays typed and read-only: no `dynamic`, no casts to concrete classes, and no exposed callbacks that return writable objects. For each `features/<x>`, the guard asserts that it imports only `foresight_core/desktop.dart`, shared presentation, the shell-port library and other features' port files.
- **Google account.** Replace `GoogleAccount.client`'s credential-bearing `GoogleClient` type with `bool configured`; the desktop only null-checks it (`settings_controller.dart:1213,1252`, `integrations_controller.dart:360`) and the remote side fakes it as `GoogleClient('', '')` (`remote_google.dart:38-39`). Type `accounts` as account values.
- **Status maps.** Remove `capture` and `googleStatus` from `DesktopConnection` once every consumer uses F-3's decoders.
- **Cleanup.** Delete `noteEnhancementChanges`, the redundant close wrapper and the side-effect getter statements, only after verifying their replacement and disposal paths. Apply the same cleanup inventory to onboarding and shared files. At completion, remove the migration adapters and every production `part`/`part of` link to `main.dart`. Generated Dart part directives are exempt.

### PR 7 acceptance

Assessed at the last 7C PR, with each earlier PR meeting the parts it touches.

- **Independence.**
  - For each `features/<x>`, one widget test mounts the feature root with only fake ports, without `Foresight` or `Workspace`.
  - The 7C-4 guard passes: no feature back-reference to shell state, no global locator, no implementation import. All handwritten main parts are gone.
- **Read safety.**
  - No persistence query or graph work happens during widget building.
  - Asynchronous results are safe across revisions, epochs and connections.
  - Queries, subscriptions and controllers settle and dispose correctly during reconnect and workspace clear.
- **Rebuild counts.** Against the committed 7A baselines, tests prove that:
  - a level tick rebuilds only its meter;
  - a local feature edit leaves unrelated features alone;
  - a coarse or unknown change still refreshes all relevant data.

  Keep the existing capture-level tests rather than duplicating them.
- **Hermetic tests.** 7.1's source guard, behavioral test and production-binding test pass: no widget test spawns `/usr/bin/hyprctl` or reads or writes the real XDG config, and `main()` binds the real runner, opener and notifier.
- **Size targets.** Across desktop `lib/`: files under 800 lines; widget-returning and build methods under 150; `main.dart` holding only process entry and composition, under 300 lines. Explain any miss rather than adding empty abstraction layers.
- **Behavior preserved.**
  - Existing desktop and process integration assertions keep their meaning.
  - The epoch, reset, pending-create, clear-offline, note-save, startup, approval and buffer workflows, and core `remote_domain_test.dart`, are anchored before they move.
  - Full Linux and macOS smoke passes on current binaries: record, enhance, Ask, import, graph, settings, onboarding, approval, close and reconnect.

### Current-main regression anchors

These existing tests are preservation evidence, not work to implement:
- `summary_application_test.dart` and `summary_generator_test.dart`, with the frozen summary prompts;
- `meeting_actions_test.dart`, `meeting_workflows_test.dart` and `meeting_ai_reference_test.dart`;
- `notes_workflow_safety_test.dart` and `answer_source_scope_test.dart`;
- `portable_query_setup_test.dart`, `proactive_application_test.dart` and `web_answer_test.dart`;
- the `service_cancellation_test.dart` variants;
- the migration tests for 14 to 17;
- the persistence characterization fixtures (`persistence-c28a1561`) and `operation_policy_baseline.json`.

Retain these behaviors:
- helper-tokenizer independence and conservative UTF-8 admission;
- Unicode and map/reduce bounds;
- owned cancellation and preemption;
- edited-history and manual-task preservation;
- degraded retry and cache behavior;
- generic `questions` generation and cancellation;
- source-scope privacy.

The compiled service gate must still execute these tests in `tests/service/test_service_process.py`, together with the real desktop/service/MCP integration:
- `test_summary_commits_checkpoint_and_retains_edited_history`;
- `test_actions_and_preparation_through_compiled_service_and_mcp`;
- `test_stalled_notes_batch_is_cancelled_by_its_service_lease`.

Their worker protocol (structured stdin, probe, finish) and the production source-selector helpers are part of the contract. Controlled workers establish protocol and persistence behavior, not real-model quality.

## Verification matrix and implementation stop conditions

**Command authority.** The current CI scripts are the authority for commands, not old audit line numbers. Record their exact invocations and tool versions in each PR's evidence.

**What to run.**
- Run focused relevant tests for each commit.
- Run the full applicable Linux matrix at each PR's final head, plus the HanSolo matrix where owner decision 1 requires it.
- Rerun the affected checks after every later code change.
- A rebase onto a moved `main` requires rerunning the matrix before merge.
- A passing unrelated check is not verification.

| Gate | Required execution and evidence |
| --- | --- |
| Static and contracts | Quality's `python` job in order: `ruff check .`, `mypy`, `python tools/check_subprocess_timeouts.py`, then `python -m pytest --cov --cov-config=.coveragerc --cov-report=term --cov-report=xml --durations=20 --junitxml=coverage/python/junit.xml` (95% through `.coveragerc`). Quality's `format` job: pinned `dart format --set-exit-if-changed` and clang-format. Dart and Flutter analyze; operation registry, MCP schema and literal guards; bindings and source-boundary guards; migration fixtures. Use the pinned CI Python environment, with `protoc` 35.1 first on `PATH` as Quality installs it (`tests/contracts/test_owned_descriptors.py` runs `protoc` directly) |
| Native | Every PR: the root CTest inventory through the native test-only stage in the block below; AGENTS.md requires it for native, protocol or service changes, which include 7.0. When a PR changes paths in `native-sanitizers.yml`'s filter (native, services, proto, CMake): configure instrumented root trees with clang, the verified sanitizer SDK as `CMAKE_PREFIX_PATH`, and `-DFORESIGHT_SANITIZERS=ON` or `-DFORESIGHT_THREAD_SANITIZER=ON`, then run `tools/run_native_sanitizers.sh "$task_asan_build" test-results/sanitizers` and `tools/run_thread_sanitizers.sh "$task_tsan_build" test-results/thread` with the pinned Python first on `PATH` as `python`. Reuse verified SDKs and toolchains; report omitted or unsupported targets |
| Dart core | The entire `packages/foresight_core` suite, with the current native library and helper configured. `FORESIGHT_CORE_COVERAGE_MIN=90 bash tools/coverage_core.sh` collects and enforces Linux core coverage. Keep measured core coverage at or above 95% without raising the 90% minimum. No native integration test may skip because a binary path is missing |
| Desktop | The entire Flutter desktop suite with current binaries; coverage with the current CI command and its 90% minimum; rebuild, feature-isolation and query-cancellation tests. The `integration_test` target: `service_mcp_test.dart` through the compiled service gate, and `meeting_workflow_test.dart` through `integration_gates.py --suite virtual-audio` (locally, or as hosted `acceptance-audio` at the PR head). The Meetings PR and 7C-1 need models-suite and virtual-audio evidence at their heads. Keep the skip inventory: 8 macOS-only and 9 suite-gated tests on Linux. The owner waived the desktop 95% target |
| Compiled boundaries | Compile the current service and MCP executables. Run `tests/service/test_service_process.py` and the current MCP process suite through the CI service stage, then the real desktop/service integration on an isolated display. Record binary paths and source identity. Capture fixtures write raw PCM to the owned FIFO and diagnostics to stdout |
| Lifetime and ownership | Source-compiler tests with test hooks explicitly enabled; ordinary tests with hooks disabled; release builds ignoring hooks even after a cached development configuration; the ADR-0007 idle, grace and busy matrix; the structured close, resend, ownership and adoption matrix |
| Responsiveness | F-1b's runner and method at 7.0's head, and at the head of any later PR that changes service-side status, broadcast, dispatch or read code. The runner times only the service's `status` RPC; desktop-only PRs from 7A on use 7A's committed admission and build baselines instead |
| Complete source export | Run applicable archive, container and fixture checks from a full export without `.git`. If those fixtures are touched, inject fixture CI metadata explicitly and run under an unrelated PR ref, a `main` ref and no ref ([CI integrity](../platforms/ci-integrity.md#testing-ci-tooling-changes)) |
| Platform acceptance | Linux compiled desktop and service smoke; portable-bundle acceptance through `linux_acceptance.sh cpu`/`audio` (local or hosted); installer and package acceptance (`acceptance-deb` and the deb, rpm and arch package jobs) as hosted checks only (F-1a). macOS: the HanSolo matrix (owner decision 1) where that decision requires it. Docker and Apple paths unavailable locally remain required hosted checks and are reported as not run locally |

**Concrete Linux gate invocations.** This block is the required local host test matrix. Before every push, also run the Static row's Quality `python` and `format` commands. Set task-specific absolute paths first, and inspect the scripts again before each PR:

```sh
set -euo pipefail
export FORESIGHT_PYTHON="$task_python" FORESIGHT_BUILD_DIR="$task_build"
export LIBGL_ALWAYS_SOFTWARE=1
# A short `install -d -m 700` directory under /var/tmp (AGENTS.md), never below
# a .cache directory until CDX-F5 is fixed; Unix socket paths must fit limits.
export TMPDIR="$task_short_tmp" FORESIGHT_TEST_TEMP_ROOT="$task_short_tmp"
# Keep tests off the host compositor, display and session bus, as the canonical
# schedule does (TEST-2).
unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY
export GDK_BACKEND=x11
export FORESIGHT_NATIVE_LIBRARY="$task_build/native/libforesight_native.so"
export FORESIGHT_HELPER="$task_build/services/helper/ForesightHelper"
bash tools/build.sh --platform linux --test-only --stage native
"$task_python" tools/platform_python_tests.py --platform linux
FORESIGHT_COVERAGE=1 FORESIGHT_CORE_COVERAGE_MIN=90 xvfb-run -a dbus-run-session -- \
  bash tools/build_dart_gates.sh core linux "$task_build" "$task_python"
xvfb-run -a dbus-run-session -- \
  bash tools/build_dart_gates.sh desktop linux "$task_build" "$task_python"
test -x "$task_flutter_executable" # absolute pinned Flutter SDK bin/flutter, not the app binary
export FORESIGHT_FLUTTER_EXECUTABLE="$task_flutter_executable"
export FORESIGHT_LINUX_UI_TEST=1 FORESIGHT_REQUIRE_NATIVE_UI_TEST=1
xvfb-run -a dbus-run-session -- \
  bash tools/build_service_gate.sh linux "$task_build" "$task_python"
xvfb-run -a dbus-run-session -- "$task_python" tools/integration_gates.py \
  --suite fast --native "$FORESIGHT_NATIVE_LIBRARY" \
  --output test-results/fast-integration
```

**Notes on these commands.**
- **Native stage.** The native test-only stage needs current compiled project outputs and verifies that no build would be needed. Compile changed project code first against the verified dependency SDK; never pass old application bytes off as new output.
- **Container path.** In the CI dependency-reuse and container path, keep `FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=1`.
- **Python.** Keep `FORESIGHT_PYTHON` set to the pinned interpreter.
- **Desktop native tests.** They read `FORESIGHT_NATIVE` and are gated by suite flags, so they run in the fast, models and virtual-audio suites of `integration_gates.py`, not in `build_dart_gates.sh desktop`. Nothing in the desktop suite reads `FORESIGHT_NATIVE_LIBRARY`. The Dart and service gate scripts set their own library and helper paths (`build_dart_gates.sh:31-32`, `build_service_gate.sh:32-33`); the outer exports feed the fast suite's `--native` and focused Dart runs.
- **Compiled service gate.** It drives the actual `integration_test/service_mcp_test.dart`; a generic Flutter unit-test command does not substitute for it.
- **Script modes.** The Dart and service gate scripts are mode 100644. Invoke them through `bash`.
- **Fast suite temp root.** `integration_gates.py` uses `/tmp` regardless of `TMPDIR` (`tools/integration_gates.py:537,668,674`). Check `/tmp` capacity before running it.
- **Hyprland.** After 7.1's TEST-2 fix, keep unsetting `HYPRLAND_INSTANCE_SIGNATURE` as defense in depth.
- **Linux UI isolation.** The Linux UI subprocess tree must inherit the private X display and authentication, the private D-Bus session and the explicit X11 backend. A qualified task-local Xvfb runner may replace an unavailable `xvfb-run` with the same isolation.
- **Container schedule.** The canonical schedule (`FORESIGHT_LINUX_TEST_SCHEDULE=1`: native first, then core, desktop and platform Python concurrently, then the compiled service) runs inside the CI container through `tools/linux_container_test.sh`, in the required hosted `linux-test` job (`bash tools/build_linux_container.sh --test-only`). To run it locally, use `bash tools/build_linux_container.sh --output <dir>` with the verified SDK image and dependency seed. The serial host block above does not replace the canonical schedule; schedule 0 and isolated reruns are diagnostic only.
- **Recording conditions.** Before a timed acceptance run, record workload, concurrency, CPU and memory limits, and host load. Do not serialize the canonical gate, raise deadlines, exclude coverage or change hosted routing to get a pass.

**Preserved behavior these PRs must not disturb.**
- **CI routing (#163).** Portable Python contracts go to Quality, real Apple checks to macOS, DMG contracts to their own gate, and RPM checks to packaging.
- **DMG contract independence (#168).** The DMG contract job depends on `changes`, not on a successful `macos` job. The owned-attachment fixture detaches only the invocation's own image.
- **GPU validation (0.1.3).** Physical GPU validation stays required by default, with an explicit per-invocation `skip_gpu_validation` waiver.

These are preservation anchors, not refactor work. Workflow edits need actionlint with ShellCheck on PATH, at the hosted versions.

**Stop conditions.** Stop extraction on any of these, and resolve and review it before continuing:
- an unresolved ownership, data-loss or cancellation discrepancy;
- new skips caused by binary paths;
- unaccounted busy work;
- an unintended admission-policy change;
- a core interface gap;
- an unexplained responsiveness regression against F-1b's baseline or 7A's committed admission and build baselines.

A core interface gap becomes a core follow-up PR with its own full matrix. It does not grow inside a feature move.

Owner choices are needed only for new product behavior, wire incompatibility, native redesign, package splits, or lifting PR 8's deferral. Routine extraction decisions fall within this plan.

## Completion and reporting

**Each PR description lists:**
- intentional behavior changes, which should be limited to 7.0's core follow-ups (F-2, F-4, F-10), 7.1's fixes, 7B-2's Stats rollover timer and timezone recheck, and anything a characterization exposed;
- the feature boundary it establishes;
- its ownership and invalidation contracts;
- before-and-after metrics: file and function sizes, rebuild and query counts against the committed baselines;
- the gates run, with source SHA, counts, skip reasons and coverage;
- any checks that still require hosted verification.

Justify SDK, toolchain or package-dependency input changes in one line, if any become necessary.

**The last 7C PR reports:**
- the completed PR 7 acceptance;
- the final desktop metrics against the targets;
- any justified misses.

**Review convergence.** This plan converges when the native core, desktop and verification reviewers and an independent external CLI reviewer (Codex CLI from revision 17; Claude CLI through revision 15) review the same frozen revision with no unresolved blocker, major or minor findings.
- Record every round, each reviewer's tool and version, and each accepted, rejected or deferred finding with its reason, in the review record.
- Re-review changes and the sections that depend on them. A material scope or interface change requires a complete pass.
- Reviewer approval does not establish that implementation tests ran.
