# Core/desktop refactor implementation progress

Owner objective: execute the complete reviewed plan as one PR, coordinate exact-source Mac testing
on HanSolo, obtain native-agent and Claude CLI implementation review, create the PR and drive it
to merge. Deferred PR 8 remains outside scope.

Implementation base: 3fb259243a99137e3cba1d5e795c44100f42e688 (#168). Integration branch:
refactor/core-desktop, fast-forwarded to that source with its local foundation patch preserved.
Original runtime baseline/compiled outputs remain labeled c28a1561; no 3fb full gate is claimed.

## Requirement evidence ledger

| Requirement | State | Evidence |
| --- | --- | --- |
| Revision 11 plan review | Complete | Three native agents and Claude CLI converged through renewed rounds 9–12, including moved-main 3fb refresh; frozen hashes/findings are in the companion review record. |
| Core completion commit and full Linux checkpoint | Pending | Freeze core_acceptance_sha after 6A–6E/main refresh and before desktop feature extraction; final combined Linux/HanSolo gates remain required. |
| Phase 0 characterization/inventory | In progress | Frozen complete c28 source export without `.git`; 83-operation/32-MCP inventory, desktop consumer inventory, current schema fixtures, generation-settlement and workspace-clear characterizations. Regular baseline gates passed below; remaining baseline obligations are explicit. |
| 6A operation descriptors/typed boundary/errors/compatibility | Implemented, full gates pending | Actual 75+8 typed registry partition (9 tests), descriptor/MCP projection (187), complete service owner split, API compatibility, decode-first admission and Exception-based errors are live. Startup/registry batch260 passes; exact frozen full acceptance remains pending. |
| 6B Application/services/answer phases | Implemented, full gates pending | All reviewed owners and typed dispatch are live; Application533 lines before final formatting. Three ownership regressions fixed with7 permanent held-producer tests; embedding RPC shutdown separately passes its real-gRPC test. SQL boundary cleanup and complete Linux checkpoint pending. |
| 6C relay/service split/read coordination/responsiveness | Live integration in progress | Persistent lazy read isolate, guarded worker/authority/session/StoreReader, immutable DTOs/status: 26 initial cases pass plus regression expansion underway. Actual warm c28 RPC baseline completed; service extraction and final-head comparisons remain pending. |
| 6D migrations/Store/helper schema | Final integration in progress | Frozen1–15, appended16/17, Store modularization, typed reads, document parser, label domain service and genuine helper preflight are live (189 persistence tests; helper8 standalone CTest targets). Independent main/ancestor CI guard is wired and live-main verified. Domain/Google/Proactive SQL boundaries and full export acceptance remain pending. |
| 6E narrow APIs/core hygiene | Live integration in progress | DesktopConnection/RemoteDomain migrated to StoreReader, immutable HelperStatus and explicit close lifecycle; current desktop library analyzer clean, 53 RemoteDomain cases pass. Minimal consumer/fixture regression runs ongoing; final public-boundary and dependency gates pending. |
| 7A composition/contracts/invalidation | Pending | |
| 7B independent feature modules/read models | Pending | |
| 7C public boundary/platform/disposal | Pending | |
| Complete native/core/desktop/coverage/process/UI gates | Baseline only | Root native 29/29; core 1464 pass/12 skip, 92.73%; desktop 282 pass/17 skip, 91.19%; Python 5126 pass/30 skip, 96.06%; compiled service/MCP and isolated real UI 32/32, no skips. Changed implementation acceptance remains pending. |
| Git-free export/fixture CI metadata matrix | Partial baseline evidence | Regular baseline matrix ran from complete `git archive c28a1561` export without `.git`; new guard/ref matrix and full changed-source export remain pending. |
| Exact-source HanSolo Mac gates | Pending | Dedicated detached c28 worktree `/Users/tenglin/src/ofs-core-desktop-mac`; full Xcode exits 69 until owner reviews/accepts its license. CLT Git/Clang usable. No Mac runtime gate claimed. |
| Native-team and Claude CLI implementation review | Incremental core review active | Native reviews and first Claude core pass identified corrected lifecycle/typed persistence findings. Final whole combined implementation review remains required after7. |
| PR/CI/reviews/merge | Pending | Create after implementation reviews and applicable local gates. |

This ledger does not substitute for the plan's detailed acceptance criteria. Attach exact commands,
source identities, counts/skip reasons and logs as each requirement is verified. Do not mark a row
complete from unrelated green checks or mocked boundaries.

## Baseline execution evidence, 2026-10-21

All results in this section are for immutable reviewed-main source
`c28a1561b5091645718462169bc6c0cfd0040943`, not the current uncommitted implementation. Source:
`/var/tmp/foresight-core-desktop/baseline/source`; project outputs:
`/var/tmp/foresight-core-desktop/baseline/build`. Logs are preserved in
`/var/tmp/foresight-core-desktop/baseline/logs/`:

- `native-tests.log`: all 29 root CTest targets including inference probe/identity passed.
- `core-gate-short-tmp.log`: entire core, 1464 passed/12 skipped, 92.73% Linux coverage; explicitly
  enabled source-compiler hook test also passed, service/MCP compiled from current baseline.
- `desktop-gate-sanitized.log`: 282 passed/17 skipped, 91.19% Linux coverage, release desktop built.
- `python-quality.log`: complete Quality command, 5126 passed/30 skipped, 96.06% coverage.
- `service-ui-gate-isolated.log`: compiled service/MCP and actual desktop/service integration,
  32 passed/0 skipped; command exit 0. Private authenticated Xvfb and private D-Bus session.

The native Debug baseline has development hooks **enabled**, not disabled. Disabled-hook and
cached-ON production Release checks remain required. Original failures remain logged: direct
execution of tracked non-executable shell scripts (fixed invocation uses `bash`), overlong TMPDIR
(fixed private disk-backed `/var/tmp/ofcd-2tncucde`), inherited Hyprland environment inside Flutter
fake-async tests (unset `HYPRLAND_INSTANCE_SIGNATURE`), and absent system xvfb-run (qualified
checksum/signature-verified task-local Xvfb runner). These infrastructure corrections did not
change baseline production source or assertions. Full skip inventories remain in original suite
logs; any weight/device/platform prerequisites must be assessed before final acceptance.

Dependency reuse qualification is in `dependency-reuse.json`, `artifact.json`, `run.json` and
`job.json`: consumed SentencePiece library/headers and FlatBuffers generator/headers have checked
repository, producer attempt/job success, upload window, original receipt, identity and bytes.
Only current project code was compiled. The ASan/UBSan SDK was separately restored and verified in
a private mount namespace at its required canonical prefix; its original compilation provenance
was retained. An instrumented SentencePiece variant was legitimately compiled from checksum- and
mode-verified pinned source because instrumentation changed its inputs. No shared SDK cache was
cleared or restarted.

Baseline sanitizer fault probes passed. Initial ASan root CTest was 27/29: speech tests attempted
writes under the namespace's read-only home. A private home overlay corrects the runner without
changing HOME or production code. The failed-test retry exposed a missing read-only Python-runtime
bind, retained in its own log; after adding that bind, the full root sanitizer gate passed all
29 targets with command exit 0 and no ASan/UBSan report files. See `asan-home-isolated.log` and
`baseline/sanitizer-home-isolated/{ctest.log,junit.xml}`. TSan remains pending.
Docker access was initially unavailable to the inherited process group list. The account already
belongs to the docker group; `newgrp docker -c` recovered authorized daemon access without changing
membership. The qualified main SDK/container baseline now ran locally, as detailed below. HanSolo full-Xcode license acceptance remains an owner action. No waiver is inferred.

Renewed planning review rounds 9–12 are recorded in the companion record. Main advanced to 3fb
during final fetch; complete source/delta verification and all-four revision 11 convergence are at
`/var/tmp/foresight-plan-r12-review/`.
Implementation remained paused at the new-foundation boundary throughout review; only the
reviewed main fast-forward was applied afterward, preserving the local foundation patch.

Additional baseline evidence: `fast-integration.log` reports the complete fast integration gate
passed (2 passed, 0 skipped) using the current c28 native library and private display. Final guard
hardening rerun `persistence/migration-guard-final-hardening-tests.log` passes all 18, including the
real Git-free CLI under unrelated PR/main/unset refs. This does not cover newly added trusted-main
ancestry/changed-closure gate cases; those remain implementation obligations.

Main refresh evidence: `/var/tmp/foresight-plan-main-3fb25924/` contains complete new export, actual
delta, tree/blob/mode proof and focused changed-contract run (163 passed, 4 Apple-only skips,
97 subtests). Full new-head native/Dart/desktop/coverage/process/UI/Apple/container acceptance
remains pending; c28 builds/results above retain their original producer/source identity.


## Live application and environment progress, 2026-10-21

All new application test results in this section use current Dart source and previously compiled,
unchanged-component c28 native/helper binaries. They are incremental evidence, not final changed
helper/native acceptance. Logs: `/var/tmp/foresight-core-desktop/application/`.

- `live-owners-tests-retry.log`: 57 cases pass after live WorkspaceAdmin/GoogleMaintenance wiring;
  analyzer clean. Initial two invalid-field/cancellation fixture expectations were corrected to the
  reviewed decode-first contract; the original failure log remains.
- `model-registry-tests.log`: 59 cases pass after model/query-runtime ownership moved; analyzer clean.
- `generation-related-tests.log`: 74 cases pass after live SourceOperations and shared reservation
  integration, preserving deferred-model diagnostics and synchronous successor producer accounting.
- `generation-ownership-tests.log`: 27 cases pass including nine real held-stream ownership cases
  across summary/actions/notes cancellation, workspace clear with reused IDs, and actual close joins.
- `summary-final-tests.log`: 36 cases pass after independent SummaryCoordinator extraction and child/
  acceptance helper split. No private part/back-reference remains for Summary. Workflow/Notes/
  Recording and ConversationAnswer extraction are still required.

A stalled-note fixture now asserts synchronous restoration before releasing its held producer,
then awaits the actual close join. Application close returns the same cached completion future.
No test was changed to count cancellation acknowledgement as producer settlement.

Production Release hook checks on immutable c28 root source: configure Debug with the existing
cached hook option ON, reconfigure Release without clearing that cache, and compile actual current
project native/helper targets with verified dependencies. Both compile with hooks=0; all helper
hook markers and the native test marker are absent. With the development thread-failure variable
set, actual release native lifecycle tests pass 30 cases/one Apple-only permission skip. The first
attempt omitted the helper supervisor path and failed; corrected full output is preserved in
`hooks-release-native-correct-supervisor.log`. Actual release-helper legacy tests pass all three.
No SDK/toolchain build or shared-cache deletion occurred.

The TSan environment verifier refused the retained instrumented artifact on compiler/runtime/
package/prefix identity, as required (`tsan-environment.log`). This is not a runtime pass or waiver;
qualify a compatible environment or require the corresponding hosted gate. ASan/UBSan baseline
results above remain 29/29.

Docker main-SDK qualification passed through the repository receipt verifier: source qualification
run 39484475088, component identity 2cd149519ec75e753e739a04743c8c7066638d0db87602c4f6bdb1e33c5f7cf5,
immutable image digest 495dc3d4845df1076059e64a2da536fcbac50786017c24f793d6b15cbda43a57.
The existing dependency seed was reverified byte-for-byte; no dependency rebuild was authorized.
The frozen c28 container driver ran unchanged except its absolute source location and a private
image tag, recorded in `baseline/logs/container-driver.json`. Full driver exit 0 is recorded in
`container-gate.log`: root native 29/29, core/desktop coverage gates, compiled service/MCP and
isolated real UI 32/32, fast integration 2/2, Linux contracts 456 pass/three opt-in platform/model
skips/one deselected, and package checksum verification. This establishes c28 container baseline,
not final 3fb/current-source acceptance.

Real-model RPC baseline: `/var/tmp/foresight-core-desktop/baseline/rpc-responsiveness-baseline.json`,
runner `/var/tmp/foresight-core-desktop/measure-baseline-rpc.py`, log `rpc-responsiveness-retry.log`.
Generation, embedding and Whisper Medium weights were SHA256/size-verified against the frozen
model catalog; actual runtime and all five vendor libraries were qualified from the main SDK image
and its original manifest. Initial developer runtime layout omitted its adjacent build manifest;
the checksum gate rejected it. Restoring that original, verified manifest fixed the runner without
changing source or bypassing identity checks; failed log/report remain preserved.

All workloads have 100 status samples. p50/p95/max milliseconds: warmed idle 0.694/1.071/1.265;
actual warmed streaming 0.914/1.728/7.761 (generation active for all 100); actual native capture with
pinned Whisper CPU 0.772/1.151/2.223 (capture active). Startup to first status was 0.0526 seconds.
Capture used private deterministic 48kHz synthetic PCM writing to owned production FIFOs, with
stdout diagnostics; this makes no physical microphone/loopback-device claim. The CPU runner and
per-workload load averages/raw samples are in the report. These measurements describe c28 under
recorded host load, not final regression acceptance or an arbitrary hosted timing assertion.

The implementation scope remains the entire one-PR plan. No 7A feature extraction has started;
core_acceptance_sha and the full refreshed Linux checkpoint are still pending. HanSolo exact-head
Mac acceptance and final independent native-team/Claude CLI implementation review remain required.

## Typed core completion work, 2026-10-21 (pre-checkpoint)

All 75 application handlers now dispatch through the actual typed registry, alongside
8 service handlers. The runtime union guard passes nine cases; descriptor/MCP projection
passes 187; startup/registry regression passes 260. Independent service ownership,
immutable answer phases and the AnswerGateway are live. Gateway/admission tests pass 89.
Core evidence: `/var/tmp/foresight-core-desktop/core-contracts/implementation-evidence.json`.

Root composition now binds independent Summary, Actions/Preparation, Notes, Recording,
MeetingIndexer, plain Questions, Source/Graph, Workspace, Google, Model, answer and
shared generation owners. Application business SQL and its raw dispatch switch are gone.
The Domain/Application Expando and auto-creating convenience extension were removed;
explicit bindings across tests, tools and fixtures are being migrated before full suites.
Application is below 600 lines; the AST size audit currently flags one declarative
MeetingOperations handler-list getter at 150, to resolve before the checkpoint.

Incremental live-owner logs in `application/`: Workflow 62, Notes 82, Recording/Indexer/
plain Questions 78 (one existing Apple skip), and the final typed-registry application
batch 100 pass. Persistence evidence records 189 tests and typed meeting/workspace/runtime
families 84; reader/facade batches pass 88 and the updated helper passes all eight standalone
CTest targets. These are scoped results, not the full root/native/core/desktop matrix.

The independent implementation review identified two real close gaps: plain Questions
could accept output after a native cancellation acknowledgement, and pre-native automatic
answer retrieval had actual-work accounting but no shutdown join. Root corrections now
retain Questions cancellation state through acceptance inside the reservation and add an
actual-producer join to AutomaticAnswerCoordinator. Dedicated held-producer regressions
are being promoted by the core reviewer; complete-suite acceptance remains pending.

An incremental Claude CLI implementation review is running on frozen source with manifest
SHA256 `c6ae190fcefb85fdf183e1f842e7e54503dcdc8afc0f7f0afa2bcda92e43a69c`
in `/var/tmp/foresight-core-implementation-review-r1/`. Its snapshot predates the two close
corrections and the final fixture migration. It is not final implementation convergence.

The actual protoc35.1 was restored from the already qualified main SDK image into a private
prefix, with all 58 consumed files checked for SHA256 and mode. Its wrapper confines shared
library lookup to the tool process. `qualified-protoc/qualification.json` preserves the
original producer; no SDK was rebuilt. The old verified inference dependencies were also
rechecked (124 files) against their original artifact manifest. Current full Ruff passes;
Mypy found two fallback-import alias definitions in migrate_profile.py, assigned for repair.

The quality workflow still needs its independently fetched reviewed-main migration guard;
the verification owner is implementing that narrow mandatory gate. Main was fetched again
and remains `3fb259243a99137e3cba1d5e795c44100f42e688`.

HanSolo correction: `xcodebuild -version` reports27.1, but compiler/SDK/Git/Python commands
without the CLT override still reject the unaccepted Xcode license. The version probe did
not establish license acceptance. The previous owner action remains outstanding; no Mac
application/runtime gate has passed. The CLT override only supports tool discovery/setup.

## Core candidate freeze preparation

All six core work packages are implemented and source owners are holding writes.
Application is below600 lines; extracted functions/answer phases and persistence
modules meet the reviewed limits. The named query boundary now also covers Domain,
Google connections, ProactiveQuestions, model restore and startup capture recovery.
Typed answer query batches pass85 and17 test executions (overlapping cases are not
reported as unique102); Proactive batch99, Domain existing87/new10, Google core42/
widget17/actual-helper1 pass. The Source typed batch passes76. Whole core and
adapted desktop analyzers are clean. All seven SDK identities remain identical to
main after quality workflow wiring.

Application translates typed future-schema failures at epoch admission and dispatch
to actionable unavailable errors, while storage/coordinator retirement retains its
original typed exception. Two real Application tests rename dependent tables after
a future version advance and verify no incompatible query. The structural feature
SQL/raw-row/database guard also passes.

The complete Python run reported5160pass/31skip/4fail at95.86% coverage. All four
failures were one stale parser source-location assertion across workflow variants;
its full namespace/capability assertions now inspect document_parser.dart, and the
corrected60-case file plus guard/CI ownership batch153 pass. The full command will
be rerun from the frozen candidate; the failed full run is not reported as passing.

The exact existing TSan SDK was restored through the common provenance verifier
in a private compiler/package-matched container; all1632 files retain original
provenance and byte/mode/link identity. Only a private thread-instrumented
SentencePiece variant needed compilation from verified pinned source because its
instrumentation inputs differ. Baseline c28 full root TSan passes29/29, zero skips,
no sanitizer reports, including inference targets. Planted race exits66 as expected.
Evidence: tsan-qualification/baseline-c28/result.json and qualification-report.txt.
No host sysctl, shared cache or successful SDK producer was changed.

This freezes a candidate for full Linux execution, not core_acceptance_sha approval.
No desktop feature extraction, PR, push or merge has occurred yet. Final combined
Linux/HanSolo matrices and whole-implementation team/Claude review remain required.
