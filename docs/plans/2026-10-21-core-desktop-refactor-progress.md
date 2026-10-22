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
| Renewed plan review | Verdict recorded separately | Rounds13 onward assess current implementation findings; the companion record identifies frozen revisions and latest native/Claude verdicts. Planning never grants runtime acceptance. |
| Core completion commit and full Linux checkpoint | Pending, latest container failed | No core_acceptance_sha. Exact 4bd container: native30/30; core1821/14skip/1error; desktop285/17skip/1failure. Later service/fast/platform stages did not run. Full current-source Linux matrix remains required before7A. |
| Phase 0 characterization/inventory | In progress | Frozen complete c28 source export without `.git`; 83-operation/32-MCP inventory, desktop consumer inventory, current schema fixtures, generation-settlement and workspace-clear characterizations. Regular baseline gates passed below; remaining baseline obligations are explicit. |
| 6A operation descriptors/typed boundary/errors/compatibility | Implemented, full gates pending | Actual 75+8 typed registry partition (9 tests), descriptor/MCP projection (187), complete service owner split, API compatibility, decode-first admission and Exception-based errors are live. Startup/registry batch260 passes; exact frozen full acceptance remains pending. |
| 6B Application/services/answer phases | Implemented, full gates pending | Explicit domain owners, phased answers and typed persistence boundaries are complete; real held-producer/RPC joins and child-gap regressions are retained. Scoped implementation reviews converge. No full current-source acceptance. |
| 6C relay/service split/read coordination/responsiveness | Implemented, full gates pending | One service lifetime authority; persistent guarded read workers, schema retirement and conservative previews. Exact214 real-model RPC passed100 samples/workload below50ms p95; native-close residual documented separately. Current-source process/RPC/sanitizer gates remain pending. |
| 6D migrations/Store/helper schema | Implemented, full gates pending | Frozen1–15, appended16/17, typed reads/label ordering and whole-helper-set preflight. Existing rollback journals use private readonly probes in all3 implementations; exact4bd root native30/30 passes. Full schema/runtime/platform matrix remains required. |
| 6E narrow APIs/core hygiene | Implemented, full gates pending | Curated APIs/external consumers and both pre-freeze seams are implemented; focused source tests and independent native reviews pass. Exact4bd container remains failed; next frozen source needs its complete matrix. |
| 7A composition/contracts/invalidation | Pending | |
| 7B independent feature modules/read models | Pending | |
| 7C public boundary/platform/disposal | Pending | |
| Complete native/core/desktop/coverage/process/UI gates | Partial changed-source evidence, no checkpoint | Exact2d host native30, core1825/12skip/92.04%, desktop286/17skip/91.33%; exact214 compiled process/UI32 and fast2 with zero skips. Exact4bd complete container fails. Each original source retains its own results; no carry-forward acceptance. |
| Git-free export/fixture CI metadata matrix | Partial changed-source evidence | Exact4bd export verifies1321 blobs/modes; exact214 explicit93-module provenance matrix passes3707 tests/1270subtests/3skips per unrelated-PR/main/unset context. Current-source full fixture matrix and actual Docker-cache gate remain pending. |
| Exact-source HanSolo Mac gates | Pending; compiler SDK setup qualified | Original main compiler SDK1564files qualifies without rebuild; pinned Flutter/Dart/Python found. Runtime/development dependency closure and final exact-source app gates remain required. Full Xcode exits69 pending owner license acceptance; no Mac runtime gate claimed. |
| Native-team and Claude CLI implementation review | Scoped core reviews converged, final review pending | Native core corrections and Claude incremental rounds1–6 assessed frozen deltas; round6 converges on4bd semantic namespace delta only. Final whole combined implementation review remains required after7. |
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
in a private compiler/package-matched container; all 1,632 files retain original
provenance and byte/mode/link identity. Only a private thread-instrumented
SentencePiece variant needed compilation from verified pinned source because its
instrumentation inputs differ. Baseline c28 full root TSan passes29/29, zero skips,
no sanitizer reports, including inference targets. Planted race exits66 as expected.
Evidence: tsan-qualification/baseline-c28/result.json and qualification-report.txt.
No host sysctl, shared cache or successful SDK producer was changed.

This freezes a candidate for full Linux execution, not core_acceptance_sha approval.
No desktop feature extraction, PR, push or merge has occurred yet. Final combined
Linux/HanSolo matrices and whole-implementation team/Claude review remain required.


## Frozen core candidate f225 and verification corrections

Core candidate `f225633b8c0eff18470bc883c9c9433f2ff3d030` contains the
completed6A–6E implementation, before desktop feature extraction. Its complete
Git-free export contains1316 files independently matched to Git blob hashes,
SHA256 and file modes. The source archive SHA256 is
`475462add1b87b8eba062e6a05ce973be3669d74332e58e13ed0b2328835bdd7`.
Main was fetched again and remains3fb25924; the reviewed plan revision11 is
unchanged. This candidate is not `core_acceptance_sha`.

Fresh root native compilation reused verified dependency bytes and passes 30/30
CTest targets, including inference and helper schema-preflight coverage. The
complete Python coverage command passes5164 tests,31 skips and95.86% coverage.
Artifact/provenance fixtures also pass under explicit unrelated PR998, main and
unset-ref environments:2672 tests plus1162 subtests in each environment. The
real opt-in offline Docker cache fixture passes. Pinned Dart/clang-format,
Ruff/Mypy and actionlint with ShellCheck available pass.

The initial full core suite reports1816 passed,12 skipped and two failures:
a30-second analyzer-boundary timeout and a3-second startup-index-recovery poll.
Both failed files pass in isolation unchanged. A full rerun is retained
separately; its startup-index poll has failed again and is under investigation.
These are failed complete gates; isolated passes do not establish coverage or
checkpoint acceptance. Enabled source-compiler hook regression and fresh AOT
service/MCP compilation pass independently, without a full-gate claim.

The full adapted desktop suite reports283 passed,17 skipped and two fixture
lifecycle failures. Focused reproduction showed that the explicit test adapter
completed initialize before an offline helper became ready. Its pending narrow
fix waits for onReady, caches initialization, and joins/cancels pending readiness
on close; production lifecycle behavior is unchanged. Seven affected files pass
23 tests with two existing Apple skips. The exact candidate's independent
Flutter release build passes; measured failed-suite coverage91.44% does not
make the failed full gate pass.

The timeout static checker also failed on the required source export because it
unconditionally required Git metadata. Its pending correction uses Git's ignore
engine with private external bare metadata only for archives, sanitizes inherited
Git configuration, and preserves failures for broken existing checkout metadata.
Thirteen fixture tests pass, including independent archived source after deleting
its producer repository; the candidate's Python inventory matches all361 tracked
Python files exactly. Frozen source bytes remain unchanged. These corrections
and any valid recovery-test fix will be batched into a new frozen candidate.

The complete local container/package/installer gate inventory is retained at
`desktop-boundary/linux-packaging-gate-inventory.md` under the evidence root.
Docker, inner document namespaces and all four pinned Linux distro routes are
locally executable; none is waived as hosted-only. Qualified SDK/seed/weights are
reused without dependency rebuild. Private synthetic audio/software GPU evidence
will remain separate from physical hardware acceptance. The existing HanSolo
full-Xcode license block still prevents Mac application acceptance.

Claude's second independent core implementation review is running against the
frozen f225 export. Native review identified a meaningful coverage gap between
settled native children of Summary/Actions/Preparation; a dedicated regression
will verify that peer admission remains busy while the parent reservation is
owned, then verifies release and single acceptance. Full combined implementation
review, final Linux/HanSolo evidence and PR/merge remain outstanding.


The repeated full core run finishes1817 passed,12 skipped and the one recovery
poll failure; its complete gate and coverage remain unverified. The fixture now
joins actual `service.ready` recovery instead of a3-second DB poll. A diagnostic
on frozen production records socket publication at107ms before helper/model
readiness, then recovery completion at190ms with the original durable indexing
error. This establishes the ordering gap without claiming isolated execution
reproduced the loaded3-second delay.

The new between-native-child reservation cases pass for Summary, Actions and
Preparation. Together with the fixed recovery fixture,9 focused cases pass.
Explicit default-disabled and enabled source-compiler hook checks each pass.
Claude core implementation round2 converged atf225; its optional streamed schema
observation led to the narrow error mapping and future-schema idle-policy
retirement described in the review record. The real stream/lifetime/handoff
batch passes87 tests with one existing Mac-only skip; analyzer and size audits
pass. These changes require a new frozen candidate and complete checkpoint gates.


The independent verification reviewer caught one additional future-schema path:
the real heartbeat and application change broadcasts could still throw from
snapshot reads. The final narrow fix shares monotonic schema-read retirement,
cancels only the owned heartbeat, and suppresses unsupported snapshots without
fabricating data. The lifetime policy keeps its last verified normalized value;
activity, busy accounting, departure/grace and close retain the same authority.
The real-socket tests separately trigger change and actual heartbeat retirement,
then check both epoch/no-epoch errors and existing grace behavior. The expanded
service/lifetime/handoff/recovery batch passes93 tests with one existing Mac-only
skip. Independent native verification review converges on this final fix. Pinned
format/analyzer/AST size checks pass; ApplicationService remains923 lines. The
archive timeout fixtures/quality gates pass13 tests, and its checkout CLI passes.
A new frozen source candidate will now run the complete Linux checkpoint; f225's
failed complete gates are preserved and are not acceptance evidence.


## Core candidate 405e and external integration correction

`405e13f7fddca2369e35162c98ecf13b81416a89` is a complete source export with 1,319 files.
Native Debug passes 30/30. The full canonical core gate passes 1,823 tests,
12 expected skips and 92.06% coverage, including both previously failing cases.
Both explicit source-hook configurations and current service/MCP compilation
pass. Full Python passes 5,172 tests,31 expected skips and 95.87%; exact pinned
format/lint/static gates pass. A separate actual Release build after cached Debug
hooks=ON retains the cached ON option, contains no production helper hooks and
passes all 30 root CTest targets. Verified dependencies were reused throughout.

The full compiled service/UI gate reports 30 passed/two failed: external Dart
fixtures still called reader APIs removed by 6E. The author missed these consumers
in the initial migration. A complete 26-file external-consumer audit found the
service probe and both desktop integration fixtures. Their corrected live batch
passes the targeted real facade subprocess and actual service/MCP UI with 59
recorded expectations; meeting target compilation, integration analysis and eight
actual SQLite receipt/ownership assertions pass. Independent review converged
after fixing source-summary metadata retention. Production core files remain
byte-identical to 405e. These diagnostics do not turn the failed complete process
gate into a pass; the next frozen candidate reruns its full checkpoint.

Claude implementation delta review round 3 converges at 405e. The measured native
teardown residual and separate follow-up are recorded in the linked review note;
no native join repair or full P2-4 resolution is claimed. ASan and TSan original
SDK provenance/bytes are independently reverified, including all 1,632 installed
entries per SDK. Their exact-source matrices remain held for the next candidate.
All four pinned Linux distro images are now available; container/package/model/
virtual-audio/installer gates remain locally executable obligations. Desktop
feature extraction, PR publication and merge have not started.

## Core candidate 21469 and root journal qualification

`21469a994a80e1eb2304511f3d0eeba9e7e565bb` exports all 1,321 tracked files and
modes without Git metadata. Native Debug passes 30/30. The full desktop gate
passes 286 tests, 17 expected skips, 91.33% coverage and Release compilation.
An initial core run overlapping desktop work reports two startup failures;
both unchanged files pass 37/37 serially, and phase diagnostics confirm launch,
cleanup and eight-host startup within the original deadlines. The standalone
canonical core rerun passes 1,823 tests, 12 expected skips and 92.04% coverage.
Both source-compiler hook configurations and fresh service/MCP AOT compilation
pass. No deadline or fixture change was made for those startup failures.

The complete compiled service/MCP gate passes 32/32, including actual isolated
desktop integration; fast integration passes 2/2 with no skips. The real-model
responsiveness measurement passes the 50ms p95 target: warmed idle 0.921ms,
native generation 1.364ms and PCM capture 1.469ms. Each workload has 100 raw
samples; all streaming samples overlap native loading, and all capture samples
overlap capturing with advancing PCM counters. Independent review verifies
source/native/AOT digests and the calculations. Historical baseline measurements
have weaker overlap qualification, so these results make no statistical
equivalence claim. Claude implementation round 4 converges on the 21469 fixture
and native-close documentation delta.

The full container gate fails two of 30 native targets: `helper_contract` and
`helper_schema_preflight`. Build, portable manifest and ABI checks pass, but
these do not make the failed container gate pass. A preserved syscall diagnostic
shows SQLite 3.45.1 calling successful `fchown(fd, 0, 0)` on original hot journals
when running as root, advancing ctime while bytes, inode, size, ownership, mode
and mtime stay unchanged. The original checker passes the same case unprivileged.
The source-identity refusal is correct and remains strict.

The related correction probes a private database/journal copy whenever a
rollback journal exists, including an empty journal, in C++, Dart and Python.
No-journal probes retain their existing fast path. Raw original page-1, journal
checksum/version and superjournal checks remain; only SQLite performs actual
recovery after qualification. Copy-time and final source-identity checks remain.
Regression snapshots independently include nanosecond ctime, ownership, mode
and content hashes, with explicit metadata-only source-change rejection. Narrow
root-container diagnostics pass both failed CTest targets and all 18 preflight
cases; Dart preflight passes 10/10 and Python preflight 21/21 as root. All final
live hashes match these diagnostic snapshots. Native cross-review converges on
all three implementations. These are diagnostic worktree proofs, not acceptance
for 21469 or a new candidate. Independent Claude delta review and every full
checkpoint gate remain required at the next frozen commit.

Main remains `3fb259243a99137e3cba1d5e795c44100f42e688`. No
`core_acceptance_sha` is recorded yet; desktop extraction remains unstarted.
The remaining full Python, sanitizer, container, packaged model/audio and
four-distro installer gates remain local obligations. HanSolo discovery found
the pinned Flutter/Dart installation and a Python 3.13 environment; full Xcode
license acceptance remains an owner prerequisite for final Mac acceptance.

## Core candidate 2d388 and semantic namespace guard

`2d388cf64d1b9a60a48ad3027769b1c6436f6547` preserves all 1,321 exported Git
blobs/modes. Fresh host native Debug passes 30/30, compiling 67 project actions
and reusing the original 124 verified dependency files. The first standalone
canonical core run passes 1,825 tests, 12 expected skips and 92.04% coverage
(15,053/16,354), both source-hook configurations and fresh service/MCP AOT
compilation. Full desktop passes 286 tests, 17 expected skips, 91.33% coverage
and define-free Release compilation. All seven dependency component identities
equal reviewed main. Claude round 5 converges on the three-language private
journal delta and its regression/documentation changes.

The full container passes all 30 native targets, including the two former root
journal failures, and desktop passes 286 tests with 17 expected skips and 91.35%
coverage. Portable package, ABI and restored build-handoff checks pass. The core
namespace guard times out at its unchanged 30-second default; teardown then
disposes the pending analyzer request. This remains a failed full container run:
later service, fast-integration and platform-Python stages do not run. Comparing
named outcomes explains every count difference: one host pass becomes the
namespace error, two permission cases explicitly skip as root, and one
unreadable-endpoint case is intentionally not registered for root. The resulting
container count is 1,821 passed, 14 skipped and one error; the 222 hidden
successful loading/teardown cases match the host inventory.

The unchanged failed guard passes alone with its original coverage flags in
six seconds. A separate diagnostic compares complete namespaces from independent
analyzer contexts: both APIs return the same 132 desktop exports and five
bootstrap exports. The narrow fixture correction requests `LibraryElementResult`
through `getLibraryByUri`, using the same session and a checked `pathToUri`
conversion, rather than requesting full target-library analysis. Transitive
export linking, combinators and the active conditional branch still come from
the analyzer. Every existing required/forbidden/export/import assertion, context
configuration, disposal and timeout remains unchanged. This avoids requested
target-library AST analysis; it does not claim the old API resolved every
imported body or a different request priority. Both native reviewers converge;
the whole file passes 2/2 locally and as root with the original coverage flags.
These remain diagnostic proofs until the next frozen checkpoint passes.

The external container adapter now routes the dependency verifier's supported
blob-cache directory outside its pristine source context. Four task-owned
checksum-addressed blobs are relocated intact, preserving bytes, modes,
ownership and inodes; no shared cache is deleted. Exact source inventory and
unchanged verifier/tooling-recipe admission pass again. Failed container attempts
remain preserved and noncanonical.

HanSolo's original main SDK is qualified in a task-private directory using the
unchanged current artifact pull and dependency verifier: 1,564 files, original
receipt, payload/ZIP/sidecar hashes and successful producer proofs. Its pinned
Flutter/Dart and Python 3.13 environment are available. No SDK is rebuilt, no
application test is claimed, and full Xcode license acceptance is still required.
No core acceptance SHA, desktop extraction, PR or merge is complete; the next
frozen source still needs independent Claude delta review and the full matrix.

## Core candidate 4bd2 and renewed plan review

`4bd2c75d5890399f03d57ce8a46788da2dfcc623` is a complete 1,321-blob/mode
export. Its full container attempt `logs/container-attempt.wkETgt` exits 1:
native 30/30; core 1,821 passed, 14 skipped and one namespace-timeout error;
desktop 285 passed, 17 skipped and one graph-label assertion failure. The later
compiled service, fast-integration and platform-Python stages do not run. There
is no canonical accepted output link. Private-journal native regressions pass;
this does not establish the failed Dart or remaining container gates.

The namespace guard still exceeds its unchanged 30-second deadline under the
full parallel run; teardown produces `UnspecifiedInvalidResult`. Its unchanged
isolated retry passes 1/1 in six seconds with coverage and the same deadline.
The graph-label case also passes unchanged in isolation. Both diagnostic logs
are retained in that attempt's `failed-case-triage/`; neither retry changes the
failed complete result or proves a resource cause. Source inspection confirms
that the fixture updates `(a, Planning)` but asserts a global first label/source.
Opaque SHA256 IDs derived from title and microsecond time are not creation-order
sortable. The planned correction preserves keyed associations and per-document
order, with explicit lexical-order fixtures where global order is asserted.

The external adapter uses schedule 0, while the repository container runner
defaults to schedule 1; both enable parallel Dart gates. The next acceptance
attempt must use the required existing default schedule with a recorded CPU/
cgroup/memory/swap/load and inner/outer concurrency profile. Isolated or alternate
schedule diagnostics remain labeled separately. No timeout increase, architecture
coverage reduction, production ordering change or hosted-routing change has been
made. The exact exported source/context inventory remains intact after both real
dependency-verifier invocations; the external blob-cache fix works.

Claude implementation round 6 converges on the semantic namespace delta at4bd;
this is static delta review, not full-gate or combined-implementation approval.
The renewed native-team and independent Claude plan review records bounded
protocol/runbook/desktop-interface amendments in the companion review record.
No source change, planned fixture correction, prepared driver or review result
creates an acceptance SHA. All remaining current-source host/Python/provenance/
sanitizer/release-hook/process/UI/RPC/container/model/audio/installer gates remain
required. Feature extraction, final HanSolo gates, PR publication and merge have
not started.


The graph-label test-only correction is now diagnostic-tested with explicit
Apollo-first and Borealis-first lexical IDs. Complete keyed colors/provenance/
rationale, durable positions before/after reopen, both sources' revision/changed/
JSON projections, removal and cascade assertions are retained. The full file
passes 7/7 on the host and as UID 0, zero skips; analyzer/format pass, independent
native verification review converges. Evidence:
`4bd2c75d5890/logs/graph-label-fixture-correction/`; corrected file SHA256
`2ae1a49619f78f819c38f97055508b4876d882f6e05a26f28a65c8709e48f3c7`.
This is an uncommitted live fixture proof against the preserved4bd environment,
not a new frozen-source acceptance or a passed complete container.


## Pre-checkpoint consumer seams and canonical-run preparation

The revision13 prerequisites are now implemented in the live worktree after
`a5e1553c5d4c0a0e5793f2b9ee733df80e8bdc6f`. Client-session generation uses
an opaque identity per facade/actual adoption and forces a change notification
even for byte-equal replacement status. It remains independent of retained
SQLite read identity. Ordinary command replay, late owner settlement and error
semantics remain unchanged. Thirteen real-socket session tests and 54 unchanged
RemoteDomain regressions pass; desktop fixture/approval tests pass9/9, zero
skips. Independent native verification converges on source and actual assertions.
Late-publication harness tests establish the seam, not feature conversion.

Stats now separates immutable scheduling arguments from deeply frozen
actual-dispatch arguments. Existing fixed queries remain compatible. The new
calendar-period query retains absolute Monday boundaries and label dates, samples
a fresh exact clock cutoff per dispatch and refuses a changed period without
starting a worker. Real SQLite, held/coalesced/cancelled reads, actual close
settlement, schema admission/factory errors and calendar tests pass57/57 with
zero skips. A subsequent import-only fixture change exercises the curated
`desktop.dart` API; the affected real TZ/DST child test passes1/1, analyzer/format
clean. Native cross-review converges. Feature timers, awake timezone rechecks
and period-watch replacement still belong to7A/B and are not claimed delivered.
Evidence/hashes: `core-contracts/session-seam-implementation/` and
`core-contracts/stats-seam-implementation/`.

The narrower namespace fixture passes complete-set parity with both public
entry points, forbidden transitive canaries, show/hide and both conditional
branches:196 assertions across12 independent collections, all disposed. Its
actual two cases pass on host and as UID0 with coverage/default30s unchanged.
New public Stats DTOs are required exports; the updated public guard passes2/2.
Initial no-write formatter failure and corrected formatted retry remain logged.
These are diagnostic/static proofs, not a fix declared verified under full load.

A reusable external canonical adapter now selects existing schedule1 and records
safe resource/cgroup/CPU/concurrency observations for the exact test container.
Both generated shells pass bash syntax and pinned ShellCheck; eleven synthetic
fixtures pass, preserving early failure status and joining the owned monitor.
A preserved startup signal race was fixed with a durable stopfile/ready handshake
and bounded cleanup. Actual Docker/CID/signal behavior remains unproven until the
next real attempt. No source runner, deadline, coverage or resource limit changed.
Evidence: `profile-adapter-preflight-xt5qvl6b/PREFLIGHT-RESULT.md`.
Two completed old task-owned diagnostic containers were retired after evidence
capture; original handoffs, images, logs, SDKs and shared caches remain.

No core acceptance SHA exists. The next complete source freeze still requires
independent Claude implementation delta review and the entire applicable local
Linux matrix. Native dependencies/protocol/SDK inputs have not changed. Desktop
feature extraction, final Linux/HanSolo matrices, combined implementation review,
PR checks and merge remain pending.

## 1ac62bb0 full-container attempt and follow-up

Claude CLI independently converged on the complete 4bd→1ac consumer-seam and
fixture delta, with no actionable defect. Exact frozen source admission passed
after review. Its verdict does not establish complete checkpoint acceptance;
feature period timers/session retirement and final combined implementation review
remain pending. Evidence: `/var/tmp/foresight-core-implementation-review-r7/`.

The exact1ac source passes all seven local static commands: Ruff, mypy, subprocess
timeouts, Dart/C++ formatting, actionlint and ShellCheck. All seven SDK component
identities match freshly fetched main 3fb; no SDK build is justified by this delta.

The complete default schedule 1 container attempt `container-attempt.zvcQdH` fails:
native 30/30; core 1,843 passed / 14 skipped / 1 namespace timeout;
desktop 287 passed / 17 skipped with 91.35% coverage and fast integration 2/2;
Linux platform contracts 458 passed / 3 skipped / 1 deselected.
The later compiled service stage did not run. Core coverage did not
complete and no canonical output or core acceptance SHA was published. The
narrow included-files change alone does not resolve the loaded semantic guard.
The actual resource/event observations show a 52.06 second namespace interval for
the configured 30 second timeout; these observations do not establish its cause.

The first owned profiler failed when Docker exposed an empty CID file before
writing its identifier. Tests continued unchanged; a separately identified late
monitor supplied diagnostics only. Both the failed monitor and original complete
gate failure remain preserved. A private versioned readiness fix passes21
synthetic cases, retains exact CID/image verification, and leaves the original
run/tool bytes untouched. Actual corrected Docker readiness remains unverified.

HanSolo's original runtime requalification passes the unchanged pull and runtime
verifier, including actual Whisper `--help`, with source and runtime bytes
unchanged. Two original reusable full-native receipts have also been located
through approved-final source/main-reach proofs. Preferred original artifact
12257494567 is now quarantined and byte-qualified on HanSolo: exact original
receipt, ZIP/payload checksums, all 3,240 paths/types/modes/links and 124 candidate
dependency files pass verification. Current compiler compatibility, actual
consumption and the full Mac application matrix remain unqualified; the owner's
full-Xcode license prerequisite is still outstanding. None is a Mac application
or model-inference acceptance result.

The subsequent namespace correction reuses analyzer compiler bundles within a
single private test invocation. The warmer and guard share the same context
configuration; the guard still resolves actual linked library namespaces and
retains every assertion, its default 30 second timeout and normal concurrency.
No namespace/assertion result is persisted. All 8 runtime/fixture files pass an
independent native review. A complete 1,329 file Git-free export passes 48 Python
runner fixtures under each unrelated-PR/main/no-ref context, 3 actual cached-boundary
tests, 2 direct no-cache guard tests, analyzer/format/Ruff/ShellCheck and explicit
actionlint on all 22 workflows. Exact 134 + 5 namespace sets equal the public factory and
frozen 1ac. Transitive additions, show/hide, conditional switching and damaged
compiler bundles are exercised by real analyzer tests. Isolated timings are
diagnostic; the next frozen candidate still needs Claude delta review and the
complete canonical/local matrix before any 7A extraction.

## 27887f8e full-container attempt and cache-test follow-up

Claude CLI converged on the namespace compiler-bundle delta, with no blocking
finding. Its optional observations are recorded separately from runtime results;
the documentation now names the actual source, language-feature, SDK and
declared-variable signatures rather than implying every analyzer option is a
compiler-bundle input. Evidence: `/var/tmp/foresight-core-implementation-review-r8/`.

The exact 278 source fails complete default-schedule-1 attempt
`container-attempt.c216Zl`: native 30/30; core 1,844 passed / 14 skipped /
1 timeout; desktop 287 passed / 17 skipped with 91.35% coverage and fast
integration 2/2; Linux platform contracts 462 passed / 3 skipped / 1 deselected.
The original semantic namespace guard passes under the actual full load.
The newly added compound cache regression case exceeds its unchanged default
30 second timeout. Core coverage and the later compiled-service stage do not
complete; this failed attempt publishes no canonical output or acceptance SHA.
The corrected owned CID profiler records the real container without errors.
Evidence: `27887f8ecdec/logs/container-attempt.c216Zl/`.

The follow-up separates warm reuse, transitive-source invalidation,
declared-variable invalidation and damaged-bundle recovery into four independent
tests. Each owns a fresh fixture/cache and waits for real disk writes before
cleanup; every original semantic assertion, default 30 second timeout and
5 second disk-write bound remains. Damaged bundles additionally require zero
cache hits. The actual guard, warmer, cache helper and runner remain unchanged.
All six actual boundary/cache cases pass with zero skips from a complete
1,329-file Git-free source export; targeted analyzer and formatting also pass.
Evidence: `27887f8ecdec/logs/cache-case-granularity/`. The exported test/tool bytes
match this follow-up; later progress/review prose edits are separate documentation
changes. Independent native/Claude delta review and another complete frozen-source
canonical run remain required before checkpoint acceptance.
Freshly fetched main remains `3fb259243a99137e3cba1d5e795c44100f42e688`.
