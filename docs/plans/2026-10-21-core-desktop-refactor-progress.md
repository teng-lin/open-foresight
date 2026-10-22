# Core/desktop refactor implementation progress

Owner objective: execute the complete reviewed plan as one PR, coordinate exact-source Mac testing
on HanSolo, obtain native-agent and Claude CLI implementation review, and drive it to merge.
The owner subsequently authorized opening a draft before final acceptance. PR #170 now exists;
desktop extraction and final acceptance remain required before merge. Deferred PR 8 remains outside scope.

Implementation base: 3fb259243a99137e3cba1d5e795c44100f42e688 (#168). Integration branch:
refactor/core-desktop, fast-forwarded to that source with its local foundation patch preserved.
Original runtime baseline/compiled outputs remain labeled c28a1561. The reviewed host matrix remains
bound to fb925644. The narrow CI correction is committed at 36756534; later core/desktop corrections
have not inherited those earlier test results.

## Current execution status, 2026-10-22

The authoritative current evidence supersedes the historical ledger entries below. There is still
no `core_acceptance_sha`: the next core candidate must include the reviewed resume-discovery
lifetime correction and the missing typed answer-scope projection, then pass its complete Linux
checkpoint. Mechanical desktop extraction has not started. Work-package 7A characterization is
active and records typed reader admissions, worker queries and widget builds separately.

| Requirement | Current evidence and remaining work |
| --- | --- |
| Core structure, contracts, migrations and metrics | Native audit verifies 6A–6D at fb925644. Application is 540 lines, service authority 923, persistence maximum 537. The plan records the unchanged ranking/declarative-MCP function exceptions. Frozen migrations 1–15 and appended 16/17 remain intact. |
| Linux host matrix at fb925644 | Native 30; core 1,984 passed/16 expected skips, 15,652/16,464 lines (95.07%); desktop 287/17, 6,103/6,682 (91.33%); current AOT service/MCP and Release desktop; compiled process 32/0, real isolated UI 59 observations, fast 2/0, both hook modes and six real-model cases. |
| HanSolo matrix at fb925644 | Native 33; core 1,984/14, 15,703/16,464 (95.38%); desktop 289/13, 6,093/6,679 (91.23%); current AOT service/MCP, Release desktop, process 32/0 and real UI 59 observations. The exact 1,361-file/mode snapshot matches Linux and Python exports. Qualified native/helper/SQLite bytes retain their original provenance; current Dart applications were compiled. |
| Quality and review at fb925644 | Python 5,187/31 expected skips, 95.91%; Ruff, mypy, subprocess guard, actionlint with ShellCheck and explicit composite shell checks pass. Native-agent review and Claude CLI closure review converge on that delta. These are not implementation reviews of unfinished desktop extraction. |
| Hosted checks at fb925644 | Actual ASan/UBSan and TSan jobs each pass all 30 root tests. Mac desktop/Release passes; one calendar fixture exceeds its unchanged 30-second deadline while compiling the same source four times. Linux consumers reject stale GitHub producer status beyond their 60-second visibility budget, despite the original producer completing successfully. Original failed output and job/artifact timing are retained. Neither failure is reported as a passing gate. |
| CI correction at 36756534 | Exact complete Git-free export: Python 5,201 passed/31 expected skips, 95.91%; Ruff, mypy and subprocess guard pass. All 1,361 committed files/modes match the tested and reviewed export. The 300-second producer visibility budget preserves all mandatory original-success/attempt/source/upload/checksum proofs; original and saved-copy receipt fixtures pass unrelated PR/main/unset-ref contexts, with all 14 additions failing against the old default. Unchanged Stats timezone source compiles once then runs four fresh VMs, retaining the 30-second deadline and assertions; whole file 9/0 on Linux and HanSolo. Independent native and Claude CLI review converge on this three-file correction. Hosted checks are pending. |
| Current core/desktop corrections | Resume discovery retains a candidate locally and rejects/cleans late results before Store access/adoption. The immutable answer-scope query resolves authoritative identity in one SQLite snapshot. Focused core tests and independent native review pass. Desktop fixes reject retired answer chunks/history, dialog continuations, render-captured task/scope/preparation actions and retired command errors while retaining current failure/outcomeUnknown behavior. Characterization adds 33 tests plus typed graph/capture admission assertions; the combined 66-case batch and 19-case dialog/existing-AI batch pass. These results precede the updated complete-source matrix and do not establish a core checkpoint or completed extraction. |
| Core checkpoint and desktop 7A–7C | Pending the updated core freeze and full matrix. Held-reply characterizations precede feature moves. Composition, independent feature libraries, prepared asynchronous read models, public-import closure and injected platform policy remain undelivered. |
| Container/installer obligations | Docker access was restored using the account's existing docker-group membership with newgrp; no membership or host configuration changed. The next checkpoint can run the canonical container schedule and portable/installer acceptance locally. Earlier statements that the socket was unavailable describe those prior process groups, not a permanent waiver. |
| PR, conflicts and merge | PR #170 tracks the one combined delivery. The latest fetch still resolves main to 3fb25924; branch 36756534 is pushed and no conflict or review thread was present. Required checks, remaining implementation, final Linux/HanSolo matrices and full native/Claude implementation reviews must finish before merging. |

Evidence is under `/var/tmp/foresight-core-desktop/pr170-ci-fix/`, including `FINAL-AUDIT.json`,
`cross-platform-source-proof.json`, the Linux and Mac `final` audits, and
`core-acceptance-audit/`. Current hosted failures and polling regressions are under
`/var/tmp/foresight-core-desktop/pr170-fb-ci/`. Original failed attempts remain preserved.
Coverage minimums remain 90%; the requested core 95% target remains mandatory, while the owner
waived the desktop 95% improvement target. Python retains its existing 95% threshold.

## Historical requirement evidence ledger

| Requirement | State | Evidence |
| --- | --- | --- |
| Revision 11 plan review | Complete | Three native agents and Claude CLI converged through renewed rounds 9–12, including moved-main 3fb refresh; frozen hashes/findings are in the companion review record. |
| Renewed plan review | Verdict recorded separately | Rounds13 onward assess current implementation findings; the companion record identifies frozen revisions and latest native/Claude verdicts. Planning never grants runtime acceptance. |
| Core completion commit and full Linux checkpoint | Pending, latest94deb core fails one existing race test | No core_acceptance_sha. Exact94deb container: native30/30; core1965/14skip/1failure; desktop287/17skip/91.35%; platform host462 pass. Core coverage and downstream service stage did not run. Core95% and full Linux matrix remain required before7A; historical c492 passes remain source-bound. |
| Phase 0 characterization/inventory | In progress | Frozen complete c28 source export without `.git`; 83-operation/32-MCP inventory, desktop consumer inventory, current schema fixtures, generation-settlement and workspace-clear characterizations. Regular baseline gates passed below; remaining baseline obligations are explicit. |
| 6A operation descriptors/typed boundary/errors/compatibility | Implemented, full gates pending | Actual 75+8 typed registry partition (9 tests), descriptor/MCP projection (187), complete service owner split, API compatibility, decode-first admission and Exception-based errors are live. Startup/registry batch260 passes; exact frozen full acceptance remains pending. |
| 6B Application/services/answer phases | Implemented, full gates pending | Explicit domain owners, phased answers and typed persistence boundaries are complete; real held-producer/RPC joins and child-gap regressions are retained. Scoped implementation reviews converge. No full current-source acceptance. |
| 6C relay/service split/read coordination/responsiveness | Implemented, full gates pending | One service lifetime authority; persistent guarded read workers, schema retirement and conservative previews. Exact214 real-model RPC passed100 samples/workload below50ms p95; native-close residual documented separately. Current-source process/RPC/sanitizer gates remain pending. |
| 6D migrations/Store/helper schema | Implemented, full gates pending | Frozen1–15, appended16/17, typed reads/label ordering and whole-helper-set preflight. Existing rollback journals use private readonly probes in all3 implementations; exact4bd root native30/30 passes. Full schema/runtime/platform matrix remains required. |
| 6E narrow APIs/core hygiene | Implemented, full gates pending | Curated APIs/external consumers and both pre-freeze seams are implemented; focused source tests and independent native reviews pass. Exact c492 canonical container passes; complete matrix and core95% remain pending. |
| 7A composition/contracts/invalidation | Pending | |
| 7B independent feature modules/read models | Pending | |
| 7C public boundary/platform/disposal | Pending | |
| Complete native/core/desktop/coverage/process/UI gates | Partial changed-source evidence, no checkpoint | Exact c492 host/root native30 and canonical native/core/desktop/compiled service32/fast2 pass; coverage remains below95%. Current host UI, remaining platform/sanitizer/provenance matrices and final combined-head gates remain required. Each original source retains its own results; no carry-forward acceptance. |
| Git-free export/fixture CI metadata matrix | Partial changed-source evidence | Exact4bd export verifies1321 blobs/modes; exact214 explicit93-module provenance matrix passes3707 tests/1270subtests/3skips per unrelated-PR/main/unset context. Current-source full fixture matrix and actual Docker-cache gate remain pending. |
| Exact-source HanSolo Mac gates | Native94deb passes; full pre-PR matrix pending | Owner license acceptance verified at2026-10-22T03:56:52Z, SDK27.0. Fresh94deb native33/33 passes with original dependencies and qualified ICU headers/libraries. Portable46 also passes at its own snapshot. Full final-source core/desktop/process/installer Mac acceptance remains required before PR creation. |
| Native-team and Claude CLI implementation review | Scoped core reviews converged, final review pending | Native corrections and Claude incremental rounds through10 assess frozen deltas; round10 converges on c492 pending-write correction and revision14 coverage amendment. Final whole combined implementation review remains required after7. |
| PR/CI/reviews/merge | Pending | Create after implementation reviews, applicable local gates and complete final-source HanSolo Mac verification. |

This ledger does not substitute for the plan's detailed acceptance criteria. Attach exact commands,
source identities, counts/skip reasons and logs as each requirement is verified. Do not mark a row
complete from unrelated green checks or mocked boundaries.

## Historical c492 baseline and Mac coordination, 2026-10-22

Frozen `c4923b5e64719c5ab610af4e0e3768582bfccd80` has1329 tracked blobs/modes
and no `.git` in its source export. Canonical attempt `EGWEBY` exits0: root
native30/0skip; core1848/14skip; separately enabled source-compiler hook1;
desktop287/17skip; fast integration2/0skip; platform host462/3skip/1deselected;
compiled service/MCP32/0skip. Core coverage is15106/16425 (91.97%) and desktop
6103/6682 (91.33%). Both unchanged90% gates pass; neither result establishes95%.
The full current-source host/sanitizer/provenance/package/model/installer matrix
remains pending, and no core_acceptance_sha is recorded.

Evidence root: `/var/tmp/foresight-core-desktop/core-checkpoint/c4923b5e6471/`.
See `logs/root-container-result.json`,
`logs/container-attempt.EGWEBY/CORE-CENSUS.{md,json}` and the actual LCOV files
under that attempt's `output/evidence/coverage/`. Current host native qualification
also passes all30 root tests, with original dependency provenance retained;
seven static commands pass. These results retain c492 as their source identity.

New test-only coverage work is under independent native review and focused
execution. Incremental LCOV unions are planning diagnostics, never a full-suite
95% result or reusable stage receipt. A new frozen source needs its actual CI
coverage command, complete source-export checks and applicable full matrix.
Desktop7A/7B/7C extraction has not started.

HanSolo coordination is active. At2026-10-22T03:30:08Z its selected full Xcode
still returns69 from `xcrun --show-sdk-version` with the license message. No
license acceptance, sudo or developer-directory change was performed. Receipt:
`/var/tmp/foresight-core-desktop/mac-portable-readiness-zq2bu2ku/readiness-2.json`.
Portable direct-Dart/SQLite checks are being assessed against a complete exact
snapshot; they cannot substitute for native/application acceptance. The owner
explicitly requires final-source HanSolo verification before creating the PR.
No PR has been created. A fresh fetch still resolves main to3fb25924.

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

Frozen follow-up `63fc4a80546a5d856bc11fb5aeca620984f674f1` passes all seven
current-source static commands, and native review converges on the split. Claude
round9 identifies a cleanup diagnostic issue and a missing retained metadata
finalizer, so no complete 63fc canonical run is launched. The next correction
retains pending-write state until independent disk verification, then avoids
rechecking intentionally damaged completed entries during teardown. Actual
before/after fault injection and the six unaffected-deadline semantic tests are
required; original failed and focused-run evidence remains source-bound. No
checkpoint acceptance is implied by static or review results.

## Owner coverage target, revision14 amendment

The owner requests 95% coverage while retaining the 90% minimum. This applies to
the Dart core and desktop suites that currently enforce 90%; Python retains its
existing 95% threshold. Plan revision14 requires core to reach 95% at its
checkpoint and both suites to reach 95% at the final combined head. CI minima,
coverage inclusions/exclusions and skip requirements remain unchanged. Native
tests do not acquire an invented percentage requirement.

At amendment time the latest completed core coverage measurement was historical2d (92.04%,
15,053/16,354); subsequent failed canonical runs did not complete core coverage.
The authentic278 desktop measurement is91.35% (6,104/6,682). These are diagnostic
starting points, not new-source results. Native agents are mapping meaningful
uncovered success/error/stale-publication/cleanup behavior. The next actual full
run must supply current core coverage before choosing its additional tests.
The subsequent c492 canonical result and independent review convergence are
recorded above. Reaching the existing90% gate alone does not complete the
requested improvement.

## Focused coverage contracts and HanSolo readiness follow-up

Twenty-eight new test files and one additional session-adoption case cover typed
reader values, private SQLite recovery, schema/argument admission, graph worker
behavior, real service/socket ownership, filesystem publication, model/network/
OAuth failures and meeting budget/cancellation/artifact contracts. Production
source, coverage rules and enforced minima are unchanged. The focused batches
pass with zero skips, but their tests still need a combined frozen-source run.
Root's planning-only normalized LCOV union adds501 unique c492 misses, equivalent
to95.0198% if the full denominator and baseline hits remain fixed. This narrow
margin is not a full-suite95% result. Retained driver and input hashes:
`/var/tmp/foresight-core-desktop/recount-coverage-batches.py` and
`coverage-batches-diagnostic-union-v2.json` in the same evidence root.

Independent native review found and corrected a progress/cancellation fixture
race by holding actual network tail bytes behind observed progress and joining
the owned peer; the original failed diagnostic variants remain retained. A
second review strengthened each action-window fragment's source-substring
assertion. Real Mac execution found a nonportable `/bin/true` fixture path;
the test now resolves the available true executable. Review also corrected the
profile-boundary expected parent to its actual canonical path on macOS.
The session-adoption regression now captures the exact failed socket in the
synchronous failure notification; all14 session tests and analyzer pass against
that source, closing the assertion-target finding.

HanSolo's final scoped portable attempt passes46/0skip plus offline enforced
lockfile resolution, analyzer and format. Its complete1357-file source snapshot
and6433 private dependency paths retain hashes/modes before and after; native/
helper project binaries are not used. Evidence:
`/var/tmp/foresight-core-desktop/mac-portable-readiness-zq2bu2ku/REPORT.md`.
Earlier44/2failed and46-pass/format-failed attempts remain retained.
This focused snapshot predates the final two review-only assertion corrections;
the final-source Mac matrix must execute the final bytes.

The owner personally accepted the Xcode license. At
2026-10-22T03:56:52.849660Z the selected full developer directory
`/Applications/Xcode.app/Contents/Developer` returns macOS SDK27.0, exit0, from
`/usr/bin/xcrun --show-sdk-version`. No agent accepted a license or used sudo.
Receipt: `/var/tmp/foresight-core-desktop/mac-owner-accepted-readiness-f2khdk10/readiness.json`.
Full-Xcode compiler/dependency compatibility admission and a fresh current-source
Mac build are next; dependency setup and portable tests are not app acceptance.

## Exact94deb canonical failure and first full-Xcode Mac native pass

Committed source `94deb4cfdb8f192d2066c0934ea62a962953087d` freezes1357
tracked files/modes without `.git`; archive SHA256
`f4b3e29143b4f251242196b1f0eb07175dad13590018548f1f2acda6eebf993a`,
manifest `47b77474eff0c122e78c6d61ef391520dd65ff28aff0cf15bb801ae03f3f2829`.
Its Linux native qualification passes30 distinct root cases. The actual canonical
container attempt `jZOc1t` exits1: core1965/14skip/1failure; desktop287/17skip
and6104/6682 coverage (91.35%); fast2/0skip; platform host462/3skip/1deselected;
root native30/0skip. No core LCOV is produced because the test command fails;
the separate enabled-hook and compiled service/MCP stages do not run. No
canonical output link or checkpoint acceptance is published.

The sole failure is the existing Linux backlog-close test in
`service_connection_test.dart`: it expects SocketException errno104 but receives
a ServiceClient. A failed-only diagnostic passes1/1, which does not establish a
fix. Independent source reviewers identify the invalid assumption: a queued
kernel connection does not prove the VM has not already completed connect.
The correction retains real socket disconnect evidence while independently
controlling pending bare-OSError normalization and SocketException identity.
Production transport and deadlines remain unchanged. Original assertion output,
raw events, skips and diagnostics are retained; the audit driver is
`94deb4cfdb8f/audit-failed-canonical.py` in the checkpoint evidence root, with
`logs/container-attempt.jZOc1t/CORE-CENSUS.{md,json}` and
`logs/connect-race-diagnostic/`. Current host/remaining driver preparations pass,
but their heavier runtime stages are held for the corrected source.

HanSolo now completes real full-Xcode compilation of the94deb native project:
Apple clang21/libc++, Xcode27.1, SDK27.0, arm64, deployment target15.0. All33 root
CTest cases pass with zero failures/skips/disabled, including probe failures,
schema preflight and three Mac-specific contracts. Configure/cache-root guards
and actual full-application Ninja dry-run pass without dependency compilation,
archive or relink. Project compilation takes24.1s; results finish at
2026-10-22T04:13:56Z. Before/after1357 source paths,1564 original SDK paths and124
selected original dependency paths retain their verified hashes/modes.

Homebrew ICU libraries require macOS26, so the build consumes unchanged original
main-produced ICU78.3 libraries supporting macOS15. All205 consumed public
headers match the official checksum-pinned78.3 source. Separate smoke probes
follow actual inference versus helper link graphs; the earlier artificial
combined probe's duplicate protobuf-symbol failure remains retained as a harness
issue. Current SDK, FlatBuffers, SentencePiece, ICU, protobuf and gRPC checks pass
without SDK rebuilds or an ABI waiver. Report:
`/var/tmp/foresight-core-desktop/mac-owner-accepted-readiness-f2khdk10/native-current-94deb/REPORT.json`.
These binaries/results retain94deb as their source; full corrected-source core,
desktop, process/UI and installer Mac acceptance is still pending before PR.

HanSolo's94deb language/application prerequisites subsequently pass: private
pinned Flutter3.35.7/Dart3.9.2, core/desktop offline enforced-lockfile resolution,
service AOT4.16s, MCP AOT2.36s, deployment-locked CocoaPods1.17.0 resolution and
fresh desktop Release compilation31.79s. Original1357 source hashes/modes remain
unchanged after each command; generated files are inventoried separately. These
are current94deb compiler/setup results, not core/desktop/process acceptance.
Reports under `mac-owner-accepted-readiness-f2khdk10/` retain native,
`language-preparation-94deb/` and `application-compilation-94deb/` evidence.
No Mac setup blocker remains; full tests await the corrected-source freeze.

The connection fixture correction passes the entire affected31-case file,
analyzer/format and independent native review. It retains the real Linux
disconnect contract and separately proves pending error normalization/identity
without production hooks. Claude round11 also finds one valid fixture P2 in the
new credential-registry tests: nonprivate directories refuse before registry
validation. The correction passes13 focused cases with zero skips, clean
analyzer/format and native source review: explicit private permissions, a valid
private-registry control, zero-request transport and actual LCOV hits on all four
intended refusal branches. Bytes and modes remain unchanged after operations.
Its original focused
passes remain retained and are not presented as proof of those content checks.
The corrected freeze still needs scoped review and a complete successful run.

Final credential correction receipt:
`/var/tmp/foresight-core-desktop/coverage-b2/registry-permission-fix/result-final.json`.
It binds source SHA58732abedfbd30855ef9503e32aac64a2745d659b56657de2c41fabf5813eabe
and hits on google_auth.dart149/158/161/174. The socket correction binds
SHA5981a7c8419036f33f73009f81f0308e4311b9be843e4366c6116fbdbfae69f4
and31 affected-file passes. These are focused checks using94deb native/helper
bytes, not a new whole-source gate,95% result or checkpoint acceptance.

## bc7 Linux core target reached; complete checkpoint still pending

Frozen source `bc7b2f241b38d7097ddb9de0e05a0959826feca3` contains1357
tracked files with exact modes and no `.git`. Archive SHA256 is
`ae53cdfd0a3d517f1dde0a6b7c40110723edec37de63ce4e6809fe3386ddcf65`;
manifest SHA256 is
`6a920280d0ca9ef94d2ab31fe8d1ae9d0e3a7db9111196f54bf31312bee1490e`.
The complete Linux canonical container gate passes, with actual core coverage
15610/16425 (95.04%),1968 passed and14 skipped. This reaches the owner core95
target in one actual run; the enforced minimum remains90. Its other stages
pass: native30, desktop287/17skip with6104/6682 (91.35%), fast2,
host462/3skip/1deselected, and compiled service/MCP32/0skip including the real
desktop/service integration. Evidence is under
`/var/tmp/foresight-core-desktop/core-checkpoint/bc7b2f241b38/`, especially
`logs/container-attempt.GbtkzT/CORE-CENSUS.json` and
`logs/root-container-result.json`.

The separate Linux host sequence also passes all five stages: core1971/12skip
with15629/16425 (95.15%), default-disabled hooks, desktop287/17skip,
compiled service/MCP32/0skip plus fast2 and the isolated-display integration,
and cached-development-option-to-Release hook exclusion. These are separate
measurements, not merged coverage. The Release helper has hooks disabled even
when its build cache retains the development option as ON. Current project
native binaries use verified original dependencies; no SDK rebuild is claimed.
`logs/host-runtime-sequence/result.json` and the individual stage receipts retain
commands, exits, source checks and consumed binary identities.

All seven static checks pass, including actionlint with ShellCheck0.10 on PATH.
Full Python Quality fails one fixture-hygiene assertion despite5179 passing,
31 skipped and95.89% coverage: the new boundary compiler-cache fixture used
a raw temporary-directory allocator. The working correction uses the shared
cleanup helper while retaining pending-write drainage and all semantic cache
assertions. Its six affected Dart cases, three Python hygiene cases, analyzer
and zero-change format check pass. Receipt:
`/var/tmp/foresight-core-desktop/boundary-temp-helper-fix/result.json`.
This focused correction is not a passing full Python Quality result. Ref/cache
fixtures subsequently pass: all93 selected modules run under unrelated PR998,
main and unset CI metadata, each3707/3skip plus1270 passing subtests; the real
offline BuildKit cache fixture passes1/0skip. Sanitizer, dual-standard-library and remaining packaged
acceptance checks are not yet accepted for the corrected source.

HanSolo's actual bc7 native33, desktop289/13skip, compiled process plus real
desktop/MCP32/0skip, host504/9skip/1deselected, enabled-hook and local development
DMG/install/upgrade acceptance checks pass. Full Mac core fails1958/14skip/9:
eight failures concern process-wide sealed native configuration replay across
Dart isolates, and one concerns strict SQLite preflight identity checking.
Subsequent diagnostic overlays are explicitly separate from frozen acceptance
source; they identify original SHM ctime drift and a separate sub-millisecond
metadata-detection gap. These findings remain under correction/investigation;
neither focused successes nor the Linux95 result supersede the Mac failures.
Current Mac evidence is `/var/tmp/foresight-core-desktop/mac-bc7-saj1rktf/`.

No `core_acceptance_sha` is recorded. Desktop7A/B/C has not started, its final95
target remains outstanding, and no PR has been created or pushed. The next
corrected freeze needs native and Claude delta review plus the applicable full
Linux and Mac matrix before checkpoint acceptance; the complete combined
implementation and final Mac acceptance remain prerequisites to PR creation.

## Mac SQLite engine comparison, 2026-10-22

The native identical-value replay correction passes all54 cases across the five
originally affected Mac test files. A separate coherent native metadata signature
fixes the demonstrated sub-millisecond detection gap without changing general
socket identity semantics; focused preflight/recovery/socket tests pass39 on
Linux and38 on Mac. Independent source/ABI review finds no blocking issue.
Neither correction exempts original SHM ctime changes from qualification.

The owner requested an actual comparison with newer SQLite. A complete1357-file
working-source snapshot, including those corrections, is tested on HanSolo with
the same native/helper binaries, test inventory, default fanout and timeouts.
Two explicitly retained diagnostic overlays select the engine in a private copy
of sqlite3-2.9.4 and log metadata only after the unchanged rejection predicate
has already fired. These are diagnostic runs, not final-source acceptance.

| Selected Mac engine | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Apple system3.51.0 | 1966 | 14 | 3 |
| Existing Homebrew upstream3.53.4 | 1969 | 14 | 0 |
| Private upstream3.54.1 | 1969 | 14 | 0 |

All1983 visible test outcomes have the same inventory. Apple failures are two
strict original-SHM-ctime-only rejections (migration rollback and legacy
proactive-origin migration) and one oversized-socket fixture timeout. Main/WAL
metadata remains unchanged in both unexpected SQLite rejections. The latest
engine is genuinely compiled in8.01s from official3.54.1 amalgamation source,
with published archive and sqlite3.c SHA3 checks verified. It is a new private
SQLite diagnostic build, not a new SDK/application compilation or an installed
dependency. Original qualified native/helper bytes are reused with their
producer identity retained. All transferred command-log hashes and raw outcome
counts are independently recomputed by the root audit.

Native file-control probes identify a real build-policy difference: Apple
defaults `SQLITE_FCNTL_PERSIST_WAL` to1; both upstream builds default to0.
Explicit0 on an owned Apple fixture removes WAL/SHM after close; explicit1 on
either upstream fixture retains them. This explains sidecar retention, but
does not prove the causal operation behind the intermittent SHM ctime changes
or establish a version-specific SQLite defect. A writable-only policy also
cannot repair a first qualification that refuses an already-existing unstable
profile. Read-only close ordering and non-writable-directory compatibility must
be checked before adopting any such policy.

The independent oversized-fixture correction supplies the identical16MiB space
payload as Uint8List, avoiding repeated generic-list copies after partial socket
writes. All five affected cases pass on Linux and Mac, with exact payload-byte
equivalence, unchanged assertions/deadlines and clean analyzer/format. The engine
comparisons above retain the original fixture to isolate their engine change.
Initial follow-up probe pointer-type/CLI harness errors are preserved; corrected
probe and focused-test results are separately labeled r2.

Evidence and audit:
`/var/tmp/foresight-core-desktop/sqlite-engine-suite-ab/audit-results.json`,
with retained drivers, diagnostic diffs, raw events and full command logs.
Application defaults and dependency pins remain unchanged; the app still uses
Apple's system library. Engine/configuration integration, corrected-source
review/coverage/full matrices and desktop extraction remain outstanding.


## Mac application-owned SQLite correction, 2026-10-22

Latest owner direction accepts current desktop coverage for now, retaining its
90% enforced minimum, and requests a draft PR soon. Revision15 reconciles those
instructions: final Mac acceptance and unfinished desktop7A/B/C remain merge
requirements, rather than prerequisites to opening a transparent draft. The
core95% target and Python95% gate are unchanged. A fresh main fetch still
resolves to3fb259243a99137e3cba1d5e795c44100f42e688. No existing branch PR or
bc7 pull-request workflow is found before publication.

The first writable PERSIST_WAL=0 experiment passes118 related Linux cases but
fails20 of118 on Apple: sidecar-free WAL-mode files cannot be read through its
ordinary read-only probe. Independent review identifies the required live
reader-after-writer-close sequence as a further incompatibility. The production
policy is completely reverted. A real regression now covers that sequence and
later commits on the same reader, plus both pinned-reader close orders. No live
immutable reader or metadata exception is introduced. A policy-free, full Apple
core rerun still fails the original strict qualification under load. All2,080
bounded simple/complex Apple probes fail to reproduce that metadata change;
its causal syscall/kernel behavior remains unproven.

The implemented correction builds application-owned SQLite3.54.1, rather than
using an environment-only diagnostic override or changing system SQLite.
ForesightSqlite.cmake verifies the official archive SHA256 and extracted C/header
hashes, retains a content-addressed local source cache, and emits build-input
provenance. Its actual Mac output is arm64, minimum deployment15, with @rpath
identity and the tested upstream options. Real corrupted archive/source checks
refuse; untouched incremental compilation reuses exact bytes and mtime. The
original SDK/helper dependency inputs and toolchains remain unchanged.

Dart's existing2.9.4 package is configured before its first cached getter in each
isolate. The selected source ID must match3.54.1; absent/relative/wrong and
previously cached Apple runtime cases refuse instead of falling back. Production
Store, private preflight and reader fallback share this loader; current test and
crash-writer fixtures use it too. Frozen migration bodies and type-only imports
remain unchanged. Protected signed-bundle runtime configuration supplies both
main and nested service hosts, and packaging records the checksum after dylib
relocation/signing, before bundle sealing. Artifact and saved-copy provenance
retain the dylib and generated source/build receipt. Real Make/Ninja fixtures
still reject dependency compilation/relinking and preserve all eight dependency
objects through application configuration and build.

Initial integration runs expose fixture maps that intentionally stripped all
FORESIGHT_ variables, including the new mandatory runtime asset. Their profile,
helper and gate isolation is retained while explicitly forwarding the qualified
SQLite resource. The private startup-handoff fixture still strips every ambient
FORESIGHT_ value and carries SQLite only through its handoff. The Debug desktop
fixture now requires an existing absolute SQLite file in its private manifest;
its sealed resolver rejects ambient replacement. Failed attempts and output
remain retained. The r14 Claude finding about filesystem timestamp precision
is addressed by requiring an observed native-nanosecond delta before exercising
the real same-millisecond committed-write assertion, with a bounded explicit
skip on filesystems that cannot expose that condition. Production qualification
never retries or ignores metadata changes.

Current working-source results, before a final frozen-head claim:

| Gate | Result | Evidence |
| --- | --- | --- |
| Mac full root native |33 passed, zero skips; all16 targets omitted by standalone native also executed |mac-owned-sqlite-native-r2/attempt-2/AUDIT.json |
| Mac canonical core |1980 passed/14 expected skips;95.38% (15700/16461); enabled source-compiler hook1; current service/MCP AOT compiled |mac-owned-sqlite-validation-r4/audit-r4.json |
| Mac desktop unit suite |289 passed/13 expected skips;91.23% (6093/6679), analyzer passed |same r4 raw events and LCOV |
| Linux full root native |30 passed, zero skips, fresh project compilation with verified original dependencies |linux-macfix-validation-r3/logs/native-qualification/result.json |
| Linux canonical core |1980 passed/16 expected skips;95.08% (15651/16461); enabled source-compiler hook1 |linux-macfix-validation-r3/logs/runtime/ |
| Changed shutdown fixture on Linux r4 |4 passed/zero skips; every other1360 source files/modes match r3 |linux-macfix-validation-r4/logs/r3-r4-comparison.json |

All paths above are beneath /var/tmp/foresight-core-desktop/. Mac r4 is a complete
1361-file Git-free export, with all source hashes/modes verified before/after.
Native r2 and application r4 retain distinct source identities; matching actual
native/component inputs are verified, never relabeled as a new compilation.
The original r4 desktop stage exits1 after its passing tests because its Release
compile lacks the existing qualified CocoaPods Ruby environment. Only that
failed compilation is rerun with the original qualified Ruby/CocoaPods cache;
its original failure remains recorded. Current real compiled service/MCP/UI,
packaged/relocated runtime, final Python Quality rerun, Linux desktop/process
matrix and renewed Claude integration review are still pending at this record.
No core_acceptance_sha, completed desktop extraction, final Mac acceptance or
merge readiness is claimed here.


Follow-up: Linux desktop287/17 expected skips passes91.33% (6103/6682), current
Release app and AOT service/MCP compile, compiled-process/MCP suite32/zero skips,
real isolated UI59 observations and fast integration2 pass. Full current Python
Quality passes5185/31 expected skips at95.91%, with Ruff, mypy163 files and
subprocess-timeout checks passing. Both use exact Git-free source exports and
retain component/source identities. Their remaining working-tree differences
are only subsequent Mac project controls and documentation.

The qualified CocoaPods environment makes the Mac Release command compile, but
its post-build source proof correctly rejects two generated tracked updates:
the already locked file_selector_macos Pod entry and the standard Embed Pods
Frameworks phase. These bytes are inspected and admitted locally with0644
repository modes; original failure and generated diffs remain retained. The
corrected source needs its own clean build/source proof before service/UI and
packaged runtime acceptance. No dependency version or SDK input changed for this
CocoaPods synchronization. The latest prior Mac unit/coverage results remain
bound to their original export, not silently relabeled as this later source.
