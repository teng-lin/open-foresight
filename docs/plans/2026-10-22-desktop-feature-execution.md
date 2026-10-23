# Desktop feature refactor execution

The source of requirements is revision 24 of
[the plan](2026-10-20-core-desktop-refactor-plan.md). This record does not replace
its acceptance criteria. PR 8 and the follow-ups explicitly marked separate
remain outside the feature moves. Implementation and the qualified matrices
below are integrated; completion still requires the explicitly remaining UI,
hosted checks and single-PR delivery work.

## Current qualification and remaining work

The application/runtime candidate is `83a26aa9`; the current reviewed source
`0ec8ea49` adds only Python automation/gate corrections and Dart integration-
test readiness observations, the startup barrier and awaited export assertion.
All production Dart, native, service, protocol, lock and
build inputs remain identical to the qualified application. Runtime outputs are
never relabeled as a newer compilation. Evidence paths below are beneath
`/var/tmp/of-pr7/` unless stated otherwise.

| Gate | Current executed qualification |
|---|---|
| Whole Linux canonical, exact83 |Native30/0;core2,065/18 skips at95.011138%;desktop552/17 at93.667726%;compiledservice/nativeUI34/0;fast2/0;platform619/3/1 deliberate Arch deselection. Unmodified concurrent schedule1 passed; `canonical-combined-render-final/qualification-report.json` |
| Native sanitizers, exact83 |Fresh full-root ASan/UBSan and TSan,30/0 each,with real fatal/race controls; `final-durable-render-final/root-sanitizers-review.json` |
| HanSolo available matrix, exact83 |Native33/0;core2,068/14 at95.427365%;desktop554/13 at93.563401%;compiled/nativeUI32/2 Linux-layout skips;fast1/0;platform512/9/1 deliberate deselection;DMG4/0;contracts126/0. Package/runtime/ownedSQLite/public-fileWhisper passed; actual installed scenarios and broad model UI are reported separately |
| Current Python Quality, exact6ff |5,564 passed/31 skipped,95.820505% combined line/branch;Ruff,mypy166files,timeoutguard clean. Full1479sourceblobs/modes verified; `final-python-6ff877a6/host-logs/quality-python-final6ffr1/root-evidence-review.json` |
| Current Dart fixture package |Author `a2f7d987` has exactly the integrated `0ec8ea49` source tree: 552 passed / 17 skipped, 93.679074%; analysis and changed-file formatting clean, existing startup contract 1/0. Byte-bound AST checks preserve 146 assertion matchers, command order and four existing polling sites; all 31 newly observed sites are read-only. Reused qualified83 native/helper on private Xvfb/D-Bus; `/var/tmp/of-moc-checks-r1/qualification.json` |
| Actual responsiveness, exact83 |100 samples in each4conditions;p95ms1.058948/0.955492/1.243546/0.841808,all<50;actual native generation/progressingPCM and clean shutdown. Synthetic native peer disclosed; baseline/runtime differences prevent causal code-only attribution; `combined-pristine-render-final/model-acceptance/rpc-render-finalr3/root-evidence-review.json` |
| Real public models, exact83 |Canonical desktop5/core1 passed,zero skips;all SDK/runtime/package bindings unchanged; `combined-pristine-render-final/model-acceptance/models-render-finalr5/root-evidence-review.json` |
| Supported installed Linux GUI |Actual onboarding,PDF/RTF approval/import,source/note replacement persistence,graph service stale/current persistence/restart,refusal/cancellation and exact setupCancel passed; `linux-final-gui83/qualified-report.json`. Graph persistence is not rendered-graph evidence |
| Mac actual installed GUI |Five actual installed scenarios passed: relocated MCP, desktop-first attachment, document approval/import, persistence creation and restart verification. Exact83 source and sealed app before/after identities match; `mac-final-83a26aa9-r1/actual-gui-core-evidence-r4/gui-final-attached-r4/progress.json`. Broad real-model feature UI remains separate |
| Current helper smoke |Exact6ff Linux helper startup,setupCancel and one correlated approval/write+DB passed with83app unchanged; `helper-qualification-6ff877a6/actual-linux-review.json`. Exactead Mac helper supported smoke separately passed; broad Mac real-model UI remains required |
| Virtual audio |Desktop 2/core 1 passed with real Whisper/private PipeWire. Compiled meeting attempt r8 at `dfeb202d` failed on a valid noncurrent asynchronous source read after refresh. The independent review and full package checks passed for read-only observation batch `a2f7d987`, integrated `0ec8ea49`. Failed-only compiled attempt r9 passed 1/0 with `0ec8ea49` test source and unchanged83 runtime. Actual CPU generation/768-dimensional embeddings, record/transcript, Enhance, cited Ask, imports, rendered graph/Inspector/settings, clear/cancel and close/reconnect passed; 15 screenshots. All1479 source blobs, runtime/package/SDK identities unchanged, owned cleanup verified; `combined-pristine-render-final/model-acceptance/virtual-audio-render-finalr9/qualification.json` |
| Supported software GPU |Whisper Vulkan0 transcript passed on CPU-type Mesa lavapipe; LiteRT GPU startup/decode explicitly skipped for the CPU-only adapter. No physical GPU claim. Runtime83/test source03, all source/SDK/package inputs unchanged; `combined-pristine-render-final/model-acceptance/software-gpu-render-gpur1/root-evidence-review.json` |
| Source reviews |Independent native role reviews cover83production; root reviewed dependent Python/test corrections and Claude rounds 8–11 converged through `0ec8ea49` with no actionable findings. Review approval is separate from runtime execution |

Remaining work is the broad Mac real-model UI workflow, final evidence reconciliation,
required hosted packaging/acceptance checks and one final PR. Only the failed compiled meeting stage was rerun; previous RPC, models, low-level audio and supported software GPU results are retained. Readiness observation retries preserve the original deadline, strict current/revision requirements, assertion matchers and mutation order. This is a compiled Debug development UI test; installed-package acceptance remains separately qualified. Actual backends were CPU: inherited raw report keys mentioning GPU embeddings or Mac graph styling do not establish those platforms.

Final architecture metrics are 87 desktop Dart files,203-line `main.dart`,
largest file796 and largest widget method149. Seven-screen status stimuli
admit zero new reads/watches/worker operations and coalesce one UI notification;
actual guarded builders separately prove the scoped no-SQL-render correction.
See [the execution plan](2026-10-20-core-desktop-refactor-plan.md) and
`reader-admissions-comparison-83a26aa9.md` for the comparison and limits.

## Historical execution checkpoints

All checkpoints below retain their original source identity and failures.
Statements such as “pending” or “remaining” describe that checkpoint; the
current qualification table above is the current status. Earlier successful
runs never substitute for later required acceptance.

## Owner delivery update and parallel 7A work

The owner requested one final PR and parallel implementation on 2026-10-22.
The plan now treats its former PR labels as commit stages. The separate-PR,
intermediate-main-merge and file-budget delivery requirements are superseded;
implementation contracts and final combined acceptance remain required.

At `40271fd9`, the integration branch contains the core and desktop prerequisites,
the P0.1 production fixes including the admission/banner follow-ups, the residual
selection/admission characterizations and the navigation enum declaration.
`origin/main` was fetched again and remains `75898380`. Separate worktrees now
implement navigation conversion and shell ports/shared presentation, while a
third updates installed acceptance probes to use actual GUI approval. Root owns
composition integration and current-source characterization measurements.

The frozen core checkpoint `44a91b5e` passed fresh root CTest 30/30; full core
2,030 passed / 16 skipped at 95.22%; desktop 394 / 17 at 92.47%; fresh AOT service,
MCP and Release desktop; compiled service/real isolated-X11 UI 32/0; and fast
integration 2/0. An initial abbreviated build-revision input was caught and
retained separately, then the helper was rebuilt with the full SHA before these
accepted gates. The final matching head responsiveness measurement is running.
The baseline at `75898380` passed with the final runner: generation status p95
1.61 ms and synthetic-capture p95 2.09 ms, all 100 samples overlapping each
workload, qualified mapped inputs and clean service/supervisor exits. Raw reports
and audits are under `/var/tmp/of-pr7/rpc-baseline-final` and `rpc-audit`.

Earlier canonical attempts at `dc4439bb` remain failed evidence: one unchanged
analyzer-cache case timed out, then the retry exposed a lifetime fixture that
mistook the shared factory's 100 ms broadcast timer for the active 30-second idle
timer. Both failed-only cases passed unchanged. `1bdbcee2`, integrated as
`40c1dde6`, records actual active/cancelled/fired timers, preserves the idle-period
and zero-spin assertions and all deadlines, and deterministically interleaves the
broadcast timer. Full file 50/1 existing Mac-only skip; wrong-period and zero-spin
mutations both fail. Root and external source reviews converged. Full canonical
acceptance will run on the final combined head.

HanSolo's complete `98bbea2d` checkpoint passed native 33/0, core 2,030/14 at
95.52%, desktop 426/14 at 92.29%, compiled service/real UI 32/0, platform Python
512/9 with one Arch-only deselection, and DMG 4/0, plus packaging, relocation,
live private SQLite and cleanup. Its initial harness Git-environment pin failure
is retained. The updated `77e9c96a` checkpoint is running separately; neither
checkpoint is final P0 or combined extraction acceptance.

Production-bundle acceptance probes still need actual desktop approval under
P0.1. A controlled HanSolo query confirms `osascript is not allowed assistive
access (-25211)`; no Accessibility grants or host configuration were changed.
The actual-GUI harness is being prepared and reviewed before requesting that
external permission. Offline harness tests do not establish production GUI
acceptance.

## Starting point

- Integration branch: `refactor/core-desktop-plan`, initially `a29e8c4d`.
- Fetched `origin/main`: `75898380ac68a0a98dc4a9fdcfc38afc99d133d5`.
- The newer local documentation commit `a29e8c4d` is retained.
- Separate implementation worktrees: `of-reader-prereqs`, `of-status-prereqs`,
  and `of-desktop-fixes`, each branched from `a29e8c4d`.
- Pinned local SDK: `/tmp/foresight-flutter`, Flutter 3.35.7 / Dart 3.9.2.
- Temporary storage: private `/var/tmp/of-pr7/t`, plus private agent roots.

## Implemented prerequisites awaiting full acceptance

| Item | Integration commit | Focused evidence |
|---|---|---|
| F-3 immutable typed v1 presentation decoders and additive connection extensions | `5e8bb301` | Initial focused tests 7/0; accepted Claude findings fixed in `27d0e812`, with coordinator-driven producer contracts in `c945d773`. Terminal failure/cancellation contracts in `c0bd60a2`: 26 tests passed. Review details are in the companion record |
| F-8 MCP isolation, plain schema maps, shared filesystem metadata, core read-model naming and test-only recording setters | `73110d39` | Core analyze clean; schema, frozen policy, MCP protocol, socket, preflight and boundary tests 261/0. Independent byte comparison confirmed all 32 MCP definitions unchanged. `meta` is now a direct dependency solely for `visibleForTesting`; no resolved package version changed |
| F-2 bounded initial delivery for every reader subscriber; F-12 nine typed factories and prepared-model helpers | `dd0c51c9` | Analyze clean, 45 focused tests passed, no skips. Included in the full-core checkpoints below |
| F-4 bounded trailing status broadcasts, command/stream terminal ordering and settled-preview removal; F-10 data-identity invalidation | `464d5be8` | Agent: analyze clean, 11 final service/socket cases passed. Earlier relevant regression batches 34/0 and 134/1 documented macOS-only skip. Integrated new test import adapted to F-8 rename |
| F-1a hosted acceptance closure | This record's companion closing entry in the historical progress file | Current GitHub API confirms exact `75898380` run 39830379125 completed successfully with all named acceptance and package jobs successful |

The root native build freshly compiled the project's C++ outputs from this
worktree at `5e8bb301` into `/var/tmp/of-pr7/build`, using the retained dependency
SDK. Full root CTest passed 30/30, with no skips. Subsequent changes so far are
Dart and documentation only. This diagnostic build is not the final Git-free
export acceptance or an F-1b responsiveness result.

Logs, including earlier failed attempts, remain under `/var/tmp/of-pr7`,
`/var/tmp/of-readers`, `/var/tmp/of-status-check` and `/var/tmp/of71`.
An accidental repository-root `dart analyze` ran before other packages had
resolved dependencies and failed with missing-package/Flutter errors; the
required package-scoped core analysis subsequently passed. That repository-root
invocation is not an acceptance command.

## Remaining execution (historical startup checklist)

- Finish F-1b's provenance-checking runner, frozen-source baseline/head
  measurements, and the full Linux matrix for 7.0.
- Finish and review 7.1's desktop behavioral fixes and hermetic environment.
- Resolve P0.1 as a separate security change before 7A.
- Execute 7A, 7B-1 through 7B-6 and 7C-1 through 7C-4 in plan order.
- Run native-agent and Claude CLI reviews on frozen integrated changes and
  resolve every accepted finding.
- Run exact-source HanSolo Mac acceptance and final integration matrices.
- Publish reviewable PRs within the repository file budget, inspect hosted
  results and review threads, and integrate the verified changes.

The 7.1 implementation and reviewed follow-ups are integrated locally as
`0b9fc7c5`, `b44285ef` and `38e3883f`; the last addresses empty `HOME` with eight
environment tests passing. Its final exact-source matrix and publication remain
outstanding. `refactor/pr7-core-prereqs` separates 7.0 from desktop behavior and
security changes (76 files relative to current `origin/main`). A fresh fetch
still identifies main as `75898380`; no PR or branch has been pushed yet.

## Frozen-source acceptance checkpoints

These rows describe the exact tested source. Later fixes do not inherit an
earlier checkpoint's acceptance label. All exports were checked against Git
blobs, file modes and the exact file set before building.

| Source and host | Executed evidence |
|---|---|
| `75898380`, Linux baseline | Fresh root native CTest 30/30. Full core retry 1,998 passed / 16 expected skips, 95.13% (15,689/16,492); enabled-hook test 1/0; fresh service/MCP AOT binaries. The first full core attempt disconnected its Dart VM service; its failed output and the focused retry remain retained |
| `0b9fc7c5`, Linux | Python Quality: ruff, mypy (164 files), timeout guard clean; 5,262 passed / 31 expected skips, 95.98%. Platform Python: 465 passed / 4 skipped / 1 deliberate Arch deselection. Fresh root CTest 30/30; tracked Dart format and pinned clang-format checks clean |
| `0cc57c13`, Linux | Fresh root CTest 30/30; full core 2,028 passed / 16 expected skips, 95.22% (16,010/16,814); enabled-hook test 1/0; fresh compiled service and MCP. Logs under `/var/tmp/of-pr7/prep-final` |
| `8f69384a`, Linux desktop worktree | Full desktop 424 passed / 17 expected skips, 92.69% (6,395/6,899); analysis clean; fresh Release desktop built. Logs `/var/tmp/of-pr7/desktop-review-head-*`. This is a worktree checkpoint, not a pristine final export |
| `be26024e`, Linux compiled boundary | Compiled service/MCP gate 32 passed / 0 skipped, including real isolated-X11 desktop UI (59 assertions). Fast integration gate 2 passed / 0 skipped. Service, MCP, native and helper binaries came from the fresh `0cc57c13` export; core production is unchanged, while desktop contains `b44285ef`. This mixed diagnostic checkpoint is not final exact-source acceptance |
| `0b9fc7c5`, HanSolo | Fresh root native 33/33; core 2,028 passed / 14 expected skips, 95.52% (16,060/16,814); desktop 421 passed / 14 expected skips, 92.30% (6,351/6,881); compiled service/MCP plus real macOS desktop UI 32/32; platform Python 512 passed / 9 skipped / 1 Arch deselection; DMG fixtures 4/4 |

HanSolo additionally built fresh service/MCP AOT and Release desktop, passed
strict deep ad-hoc codesign and runtime qualification, exercised relocated
MCP-first and desktop-first startup, and verified application-owned SQLite
3.54.1 in both live service and desktop. The final audit rehashed source and
dependencies and found no remaining owned processes. The mirrored audit is
`/var/tmp/of-pr7/mac-0b/evidence/FINAL-AUDIT.json`; the isolated remote root is
`/var/tmp/of7m.MtpZa4`. Toolchain: Xcode 27.1, Flutter 3.35.7, Dart 3.9.2,
Python 3.13.15. This checkpoint precedes the later runner and desktop follow-ups.

Expected core skips cover opt-in real-model/reference inputs and platform-only
lock/namespace or PipeWire cases. Desktop skips cover opt-in integration groups
and platform-only D-Bus/Hyprland cases. Python skips include platform tools,
explicit Docker/original-query opt-ins and native LiteRT tests delegated to
CTest. Individual reasons remain in the logs and JSON events. Missing fresh
binary prerequisites were not counted as acceptance.

The first Mac core attempt incorrectly inherited `FORESIGHT_NATIVE` from the
outer harness, sealing the native cache before shutdown fixture substitution.
Removing that harness-only variable restored the canonical gate environment:
the four failed cases then passed unchanged, followed by the full suite above.
Other retained failed attempts include the initial export's Python bytecode
extra and a packaging-license path typo in the remote harness. None required
weakening a test or changing source to get the reported pass.

Remaining prerequisite acceptance includes real-model F-1b measurements at the
merged baseline and 7.0 head, final-source Linux checks including the canonical
container schedule, final frozen review convergence, and the separate P0.1
security matrix. Desktop extraction 7A–7C has not started.

The first real-model F-1b baseline attempt is incomplete and retained at
`/var/tmp/of-pr7/rpc-baseline-r1`: 100 idle samples (p95 0.808337 ms) and 100
warmed-idle samples (p95 0.860615 ms), followed by failed streaming qualification.
The existing grounded-answer worker deliberately buffers its answer until
verification finishes (`services/inference/main.cpp`), so its first exposed
answer chunk cannot prove token streaming during native generation. The runner
is being adapted to an existing incremental Summary workload, with the same
workload to be run at baseline and head. No streaming or capture timing result
is claimed for this failed attempt.

The retained Linux SDK dependency seed was reverified against its producer and
actual bytes without recompiling dependencies. Container preparation uses the
official driver and verifies a dry run with no dependency compile/archive/link
work; preparation alone is not the canonical test schedule.

## 7.0 final-run checkpoints

The core-only export `99dcaed99013cd8c5bc4c9bfb97f204696927bf2` was verified
pristine before building (`/var/tmp/of-pr7/core-7-final/pristine.json`). Its fresh
host native build passed 30/30 CTests. Quality passed ruff, mypy (164 files), the
timeout guard and 5,344 Python tests / 31 expected skips at 96.03% combined
coverage. The complete Python log is `core-7-final/python-tests.log`.

The official container driver reused the verified immutable SDK and dependency
seed, freshly built the application, packaged 146 files and checked 111 ELF
objects against the ABI baseline. Its canonical schedule 1 passed native 30/30,
desktop 394 / 17 expected skips at 92.48% (6,284/6,795), the fast suite 2/0, and
platform Python 603 / 3 skips / 1 Arch deselection. Core failed one Summary
fixture wait: 2,026 passed / 18 skipped / 1 failed. The compiled service gate was
therefore not run. This is a failed matrix, not acceptance. The two additional
core skips versus the host are existing root-user filesystem-permission cases,
not missing binaries. Full retained output is `core-container-final.log` and
`container-core-final/evidence/` under `/var/tmp/of-pr7`.

The failed case alone passed unchanged, with coverage, after restoring the exact
qualified handoff into a fresh container. Its fixture queued 201 previews and
polled for the last one on a wall-clock deadline. `c745d98e` (integrated as
`27624db3`) instead acknowledges each event after the real coordinator consumer
requests its next event, then asserts the exact final state. All 201 events,
timer/snapshot/remote/reply assertions and test timeouts remain. The whole file
passed 12/0 with coverage; mutations that corrupt the final preview or fire the
broadcast prematurely both failed. Logs: `/var/tmp/of-status-sync` and
`/var/tmp/of-pr7/core-status-failed-only*`. The full canonical rerun is pending.

The real-model baseline checkpoint passed at `75898380` with the runner before
the last review batch: 100 samples per condition; warmed-idle p50/p95/max
0.790/0.907/1.344 ms, incremental Summary 0.799/1.192/1.526 ms, capture
0.901/1.427/2.715 ms. Native generation overlapped all 100 Summary samples;
capture progressed throughout all 100 samples. Service and supervisor exited 0,
with verified empty-session cleanup; 182 mapped objects were inventoried.
Startup to the first status reply was 0.102 seconds. No other heavy tests ran;
initial host load was 0.45/0.49/1.57. Raw samples, host details, binary/model/
runtime hashes and workload evidence are in `/var/tmp/of-pr7/rpc-baseline-r2`.
Final matching baseline/head measurements with the stricter final runner remain
pending; this checkpoint is not relabeled as having used later runner bytes.


## Desktop extraction checkpoint, 2026-10-23

The owner selected one final PR. All implementation remains on the integration
branch with separate commits; no intermediate GitHub PRs have been opened.
Earlier “not started” and “pending” statements above describe their dated
checkpoints rather than the present implementation.

All six feature owners now live in independent libraries under `features/`,
constructed with explicit shell and outward feature ports. The application no
longer has feature parts or the old top-level ownership shims. Integrations,
Settings/Stats, Chat, Sources and Onboarding have prepared typed readers. Meetings
has its mechanical owner and typed status consumers; its prepared-reader wiring
is still in progress. Feature-local size splits and the 7C removal/guard work
remain. `f563effe` split the shell header, sidebar and content into presentation
widgets; `application.dart` was 674 lines at that commit and `main.dart` 203.

Representative integration commits:

| Area | Integration commit | Checkpoint evidence |
|---|---|---|
| Integrations | `d2ea6ef0`, `a0ac012c` | Mechanical move and stable typed preference watches; 99 focused passes / 6 platform skips, plus 6 isolated-port tests |
| Settings and Stats | `0260cd30`, `e1e0f879`, `e4749d3f`, `b676f4ea`, `ec2b6b0a`, `463e81cd`, `2f012c93` | Prepared preferences/models, calendar-period scheduling and value equality; current-only model readiness; focused regressions and view-size checks |
| Sources | `dbf482e5`, `a362e275`, `6df2aac6`, `344e6bf3` | Note ownership, standalone owner, guarded current source-by-ID action, eight stable typed watches and search; latest author checkpoint 51 focused passes and 3 isolated feature passes, no skips |
| Chat | `47c99c7c` | Prepared scope/history, guarded generation and citations; 42 focused and 6 isolated-port passes, no skips |
| Meetings | `35dd59f5`, `194efb06`, `8735aeb3`, `95134de1` | Explicit status field-presence semantics, typed consumers, independent owner and actual DI cleanup; 65 focused passes / 4 platform skips |
| Onboarding and shell | `3ed85d60`, `20a659f0`, `f563effe`, `d5c6647b` | Four stable setup watches, owner replacement and held action guards, fake-port mounting, shell presentation and typed startup reads; Onboarding 36 passes / 6 platform skips; subsequent startup checks 41 passes / 6 platform skips |

The complete desktop suite at `f563effe` finished with 479 passes, 17 skips and
one failure: `setup_surfaces_test.dart` still passed raw maps to the newly typed
Onboarding status method. `439e81b` converts those fixture inputs and publishes
the actual model change before checking prepared status. That failed case then
passed (1/0). The retained whole-run LCOV measured 93.03% (7,323/7,872), but the
failed whole run is not a final green matrix. Logs are under
`/var/tmp/of-pr7/all-prepared-before-cleanup/` and
`/var/tmp/of-pr7/setup-prepared-fixture.log`.

Other retained fixture corrections preserve assertions: pending read-only
connection shutdown is pumped across the widget and IO zones (`7f42d59`), actual
reader invalidation follows the reader used by the connection (`303fa498`,
`b590e5d0`), and manually inserted Chat history publishes its durable-change
event (`bba70115`). Status-only events still do not invalidate worker reads.

### Fresh native and compiled boundary checkpoint

The Git-free `1418eca4d866fc9d0f56e473710ccde28b2d3a4a` export under
`/var/tmp/of-pr7/feature-ui-1418/` freshly built all native application targets,
passed root CTest 30/30, and built fresh AOT service/MCP plus Release desktop.
Its desktop suite passed 450 tests / 17 skips at 92.70% (6,599/7,119).

The compiled 34-case boundary run initially had 31 passes and three failures.
Two packaging fixtures assumed the old default model runtime mapping; explicitly
selecting their intended `llama_cpp` outside-runtime path restored those exact
checks (2/0). The third tried to reserve desktop presence from a Dart interpreter,
which P0.1 deliberately denies. `dabc8b40` executes the same remote facade probe
inside an actual native Flutter desktop integration image, retaining its
read-only, change, reconnect, no-replay and OAuth assertions. That failed case
passed against the fresh native/helper/service binaries (1/0). The complete
combined boundary run remains required on the final head.

### Actual installed Linux approval checkpoint

The same fresh 1418 application was packaged from the verified immutable SDK
inputs and qualified through its normal installed launcher. Directly launching
the native image bypasses the product's private library path and is not the
installed-app acceptance path. The diagnostic crash, loader evidence and failed
attempts are retained under `/var/tmp/of-gui-approval/`.

The Linux harness observes the exact owned native process through its private
AT-SPI bus and invokes the app's public accessibility actions. It refuses capture
consent and ambiguous controls. The harness now waits for a clicked approval
dialog to disappear within the original request deadline, including failed RPCs,
and samples coherent `/proc` identity across wrapper exec transitions.

With harness `8ee7fda1`, the actual document gate passed: onboarding, import-root
consent, PDF and RTF parser output, durable source records and GUI approval. RTF
used the signed pinned-snapshot `unrtf` package at its normal runtime paths only
inside a disposable mount namespace; the production nested parser sandbox was
unchanged and host `/usr` was untouched. Report:
`/var/tmp/of-gui-approval/actual-1418-parser-qualified/documents.json`.

Persistence also passed: GUI-approved source and MCP-created note survived
service shutdown, replacement of the private installation with identical package
bytes/modes, and restart. This exercised application persistence, not OS package
manager lifecycle. Report:
`/var/tmp/of-gui-approval/actual-1418-persistence/report.json`.
Separate actual refusal qualification is still being completed.

These are checkpoint results, not final combined-source acceptance. Final Linux,
canonical container, sanitizers, real-model acceptance, HanSolo, and independent
native-agent/Claude reviews remain required. The requested HanSolo Accessibility
grant for `/usr/bin/osascript` has not been confirmed; no final Mac GUI approval
result is claimed.

## Cleanup and review checkpoint, 2026-10-23

Meetings now uses prepared typed readers, including collections, previews,
attachments, citations and editor bodies. All 25 synchronous `StoreReader`
projections and the desktop row adapters have been removed. Typed fixture access,
injected platform capabilities, feature-scoped rebuild selection, and AST guards
for ownership, imports, public reader shape and size limits are integrated.
The guards follow conditional dependencies and normalized package/relative URIs.

Independent review found and corrected two desktop regressions. Global operation
transitions now invalidate cached controls, with a held-operation regression.
Existing-note saves now require an accepted body for the current editor, note,
session and workspace; failure offers retry without losing deliberate drafts.
The note correction (`f0110863`) passed 52 focused tests with no skips and a
separate review. Runtime review also reproduced a whitespace-only executable
name bypass with a real private executable. `8a16233c` applies installation-root
containment to every nonempty selection; all seven runtime-policy tests passed,
including the real process regression and the preserved empty-default behavior.

The complete core coverage run at `3b44ce07801033846f1844a7507aea4997d9f993`
passed 2,063 tests, skipped 16, and measured 95.11% (16,215/17,049).
Its preceding run overlapped the full desktop job and failed two unchanged
startup-deadline fixtures; both failed cases passed alone, then the complete
quiet rerun passed without changing their deadlines or assertions. Native
admission cases now use bounded owned processes: copying a shared library does
not isolate its GNU unique process globals. Logs remain under
`/var/tmp/of-async/core-full-coverage-r{3,4-quiet}.log`.

These remain checkpoint results. The final combined source, fresh builds,
platform matrices, installed-package acceptance and final external CLI review
are still pending. Delivery remains one final PR, with no intermediate PRs.

The first combined Claude CLI review at `f803bfdc` found a workspace-adoption
ordering bug (`228480ed`, actual single-event remote regression), a second note
overwrite window during successful slow reads (`c3934c2f`, 58 focused passes),
and destructive Chat history remounts during scope verification (`e8273512`,
13 focused passes). Chat now retains its hidden scroll/render state while the
scope is uncertain; it still hides old content from pixels, semantics, pointer
and keyboard access until scope verification finishes. Scope or session changes
retire the retained state. Independent native-agent source reviews cleared the
workspace and note corrections; Chat source review and the final CLI convergence
round remain pending.

The installed GUI harness now matches supported visible action, arguments and
requester class before consent, rechecks the snapshot at activation, observes
unnamed accessibility Text values, and rejects unexpected already-exited desktop
processes (`5da70779`, 104 focused passes). Generic, truncated or otherwise
unmatchable requests fail closed. Identical visible facts cannot establish the
identity of distinct external clients. Fresh actual GUI acceptance is required
for the new accessibility observation; earlier button-only snapshots do not
establish that matching ran.

### First combined validation candidate

`dab551266553cc9ccd49564120ccd5eeaeb6bae9` was exported with exact blob/mode
and file-set verification. Its fresh Linux native build passed 30/30 CTest;
HanSolo passed 33/33 and core 2,066 passed / 14 skipped at 95.42%
(16,276/17,058). Linux freshly compiled AOT service/MCP and Release Flutter.

The remaining whole jobs failed and are retained as failures: Linux desktop
541 passed / 4 failed / 17 skipped; HanSolo desktop 517 / 30 / 13; Python
5,506 / 4 / 31 at 95.79% coverage; compiled service/MCP 32 / 2 / 0.
The desktop failures were stale scope selectors, redundant fixture interception
and missing injected Mac facts. Their bounded corrections (`4a55eba1`) passed
all 30 exact failed Mac cases, then 33 affected-file cases on each platform.
Python's stale typed-helper assertion and three fixtures that never created the
intended bad permissions under restrictive umask were corrected in `af62fed7`
and `8b52ea92`, preserving the rejection and ordering assertions. Compiled probe
migration remains in progress. Full jobs must pass on the next candidate.

Claude's second round cleared the product corrections within its source scope,
but found text-frame ambiguity and case-insensitive AppleScript comparisons in
the harness. `55d70da4` establishes frame boundaries before decoding payloads,
checks the complete expected fact set and uses case-sensitive Mac comparisons.
The original matcher accepted a mismatched framed argument; the correction
rejects it, including through the complete call path. Its 114 focused tests,
analysis and actual Mac script compilation passed, followed by an independent
source review. Actual GUI behavior and final CLI convergence remain pending.
The native-agent Chat follow-up review also found no remaining actionable issue.

## Combined-source acceptance snapshot, 2026-10-23

This section supersedes the earlier outstanding-check lists only for the gates
explicitly reported here. Delivery remains **one final PR**. The owner's decision
replaces intermediate PRs, intermediate merges to main and the approximately
100-file limit; the implementation and acceptance requirements remain in force.

The qualified source is `b03c6002fa94adabd4cff05351333812f93cdca6`.
The Linux Git-free export contains 1,478 tracked files, with exact Git blob,
mode and file-set verification before building and before/after the completed
host gates. Its source archive SHA-256 is
`56ccda4d48e39a38a5eb67af2e6d0163fefa694db5d24e2aa771eb7ef1029f46`.
Fresh project native/helper, AOT service/MCP and Release desktop outputs were
compiled against the verified dependency SDK. Native host testing used the
disclosed Debug/test-hook configuration; the Release desktop and compiled
release-hook refusal cases are separate evidence.

| Linux gate at `b03c6002` | Executed result |
|---|---|
| Root native inventory | 30 passed / 0 skipped, 32.53 seconds |
| Core analysis and full suite | Clean; 2,066 passed / 16 skipped; 95.11% line coverage (16,224/17,058); separate enabled-hook regression 1/0 |
| Desktop analysis and full suite | Clean; 545 passed / 17 skipped; 93.60% line coverage (8,239/8,802) |
| Fresh compiled service/MCP and isolated-X11 native desktop integration | 34 passed / 0 skipped, including Summary/history, Actions/Preparation, stalled-note cancellation and release-hook refusal cases |
| Fast integration | 2 passed / 0 skipped |
| Platform Python | 618 passed / 4 skipped / 1 deliberate Arch deselection |
| Python Quality | Ruff, mypy and subprocess-timeout guard passed; 5,520 passed / 31 skipped, 187 warnings; 95.80% combined line/branch coverage |
| Formatting | clang-format 22.1.8 passed all tracked non-vendored C/C++; Dart 3.9.2 checked 724 tracked Dart files, 0 changed |

The core command used an invocation-local 95% coverage minimum; the checked-in
90% core floor is unchanged. The desktop floor remains 90%. The formatter
reported an unresolved `lints/recommended.yaml` include for the standalone
test-support package, which had no separate package configuration; the core and
desktop package configurations were resolved, and formatting succeeded.

The Linux core skips are eight macOS-only cases, seven model/reference-asset
cases and one private-PipeWire case. The desktop skips are eight macOS-only
cases and nine explicitly gated cases: one fast, five models, two virtual-audio
and one saved-profile case. These do not establish those acceptance paths.
Platform Python skips are the absent native deb/rpm packagers and two opt-in
authenticated-original-detector cases. Quality's 31 skips retain their actual
Apple-toolchain, native-CTest, opt-in detector/Docker and packaging reasons.
No native test was skipped for a missing library or helper path.

Full logs, normalized Dart events, LCOV and source proofs are under
`/var/tmp/of-pr7/combined-final-r3/`; the Quality summary is
`host-logs/quality-final-summary.json`. The interrupted first Quality coverage
attempt remains preserved; only the interrupted full job was repeated.

### Admission, notification and rebuild comparison

The frozen seven-screen baseline remains unchanged in
`apps/desktop/test_support/reader_admissions_baseline.linux.json`. It records
production base `40271fd9`, measured source `e85f9fd6`, and was committed as
`01e325ee`. The new measurements come from the full successful `b03c6002`
desktop run, not the older pre-move `reader-baseline-current.json`.

The stimulus is unchanged: after initial loading settles, emit 20 coarse helper
notifications, pump 100 milliseconds, then settle. Integrations and Settings
share the Settings screen. Counts exclude initial subscriptions and reads.

| Screen | Synchronous durable projections, baseline → current | Current read / watch / worker admissions | Service UI notifications | Widget builds, baseline → current | Metadata getter calls, baseline → current |
|---|---:|---:|---:|---:|---:|
| Sources | 5 → 0 | 0 / 0 / 0 | 1 → 1 | 604 → 603 | 60 → 181 |
| Chat | 3 → 0 | 0 / 0 / 0 | 1 → 1 | 270 → 281 | 60 → 221 |
| Meetings | 1 → 0 | 0 / 0 / 0 | 1 → 1 | 332 → 331 | 60 → 181 |
| Stats | 1 → 0 | 0 / 0 / 0 | 1 → 1 | 218 → 217 | 64 → 181 |
| Settings | 15 → 0 | 0 / 0 / 0 | 1 → 1 | 925 → 926 | 60 → 181 |
| Integrations | 15 → 0 | 0 / 0 / 0 | 1 → 1 | 925 → 926 | 60 → 181 |
| Onboarding | 3 → 0 | 0 / 0 / 0 | 1 → 1 | 110 → 110 | 60 → 181 |

All seven screens preserve the zero status-only query/worker-admission and one
coalesced-notification assertions. Chat adds 11 widget builds (4.07%); Settings
and Integrations each add one (0.108%). The baseline describes build counts as
comparison evidence rather than portable widget-count goldens; the plan has no
numeric percentage threshold for these counts. Additional Chat presentation and
retained-scope visibility/focus widgets are consistent with the increase, but
exact attribution has not been profiled. The independent local-edit and
capture-meter tests retain their separate assertions.

Metadata getters are a separate category. Prepared owners now check session
and workspace identity independently on events, and Chat also checks scope
revision. These checks increased; they are not projection admissions or SQL
statement counts. In particular, `SqliteStoreReader.workspaceEpoch` and
`dataRevision` sample `SqliteReadSession.identity()`, including SQLite revision,
schema and epoch checks. Zero projection/worker admissions therefore does **not**
mean zero SQLite activity. Metadata latency was not measured, and final F-1b
RPC timing remains a separate required gate.

Input hashes, per-key deltas, normalized test counts/coverage and every desktop
skip are retained in
`/var/tmp/of-pr7/reader-admissions-comparison-b03.{json,md}`.

### Final ownership and size inventory

The 87 handwritten desktop Dart libraries comprise the following ownership:

| Owner | Dart files | Principal boundary |
|---|---:|---|
| Composition and shared adapters | 15 | Process entry, application composition, account/approval presentation, commands/menu and host environment/capabilities |
| Shared presentation | 1 | `presentation/workspace_presentation.dart` |
| Shell | 6 | Interface ports, navigation, narrow bridges, scoped rebuild identities, typed test access and shell view |
| Integrations | 11 | Account/calendar/audio/shortcut actions and prepared preferences |
| Settings | 13 | Model/setup controls and calendar-period statistics |
| Chat | 4 | Scoped conversation ownership, typed reads and presentation |
| Sources | 18 | Imports, source collections/labels/graph and standalone note editor |
| Meetings | 15 | Recording, six assistant panels, prepared collections/artifacts/attachments and note-save scheduling |
| Onboarding | 4 | First-run ownership, prepared setup reads, presentation and outward port |

The shared adapters retain the baseline's multi-feature utilities, including
generated-content presentation, request identity and service edit dialogs. Each
feature imports other features only through their outward port libraries.
Feature-local parts remain inside their owner; no handwritten part links to
`main.dart`. The synchronous reader/row adapters are deleted, and production
platform inspection is confined to `DesktopEnvironment`.

A read-only AST audit at `b03c6002` found no size misses: `main.dart` is 203
lines, down from 1,054; the largest library is the Integrations controller at
796, followed by Meetings at 782 and application composition at 777. The largest
widget-returning method is Sources' note view at 148 lines. All files are below
800 lines, all widget/build methods below 150, and main below 300. The AST guards
exercise negative oversized fixtures and conditional/canonical dependency
bypasses as well as the production tree.

The completion audit found that Integrations still lacked the required
standalone fake-port widget mount. The new test-only commit `7a0a50b`, integrated
as `b32688ad`, mounts its actual controller-owned device selector with only fake
ports, selects a microphone through the preference port, then verifies owned
reader/event subscriptions retire and the account closes on disposal. It passed
1/0; desktop analysis and formatting passed. The other five owners already have
standalone fake-port widget tests. The test-only `b32688ad` delta preserves the production source from
`b03c6002`; the full matrices above remain evidence for `b03c6002`, not an
unexecuted full matrix at `b32688ad`. The later caption follow-up is recorded
separately below.

Dependency justification: direct core `meta` supports `@visibleForTesting`, and
desktop dev dependency `analyzer` 10.0.1 supplies syntax-aware architecture and
size guards compatible with the pinned Flutter/Dart toolchain. These changes do
not change SDK/toolchain inputs or resolve newer production package versions.

### HanSolo result and outstanding acceptance

HanSolo's separate fresh Git-free export also targets `b03c6002`, with the
1,478 source files and SDK/dependency inputs rechecked after execution.

| HanSolo gate at `b03c6002` | Executed result |
|---|---|
| Root native inventory | 33 passed / 0 skipped |
| Core | 2,066 passed / 14 skipped; 95.42% (16,277/17,058); enabled-hook regression 1/0; fresh service/MCP AOT |
| Desktop | 547 passed / 13 skipped; 93.49% (8,226/8,799); fresh Release app |
| Compiled service/MCP including native UI | **31 passed / 1 failed / 2 skipped**; the native desktop/service sharing UI case failed |
| Platform Python | 512 passed / 9 skipped / 1 deliberate Arch deselection |
| Fast / DMG / approval-harness contracts | 1/0; 4/0; 114/0 respectively |
| Packaged application | Ad-hoc codesign and runtime closure passed; relocated minimal-environment live service and desktop both mapped application-owned SQLite 3.54.1 |

The Mac core skips are six Linux lock/namespace cases, seven model/reference
cases and one private-PipeWire case. Desktop skips are four Linux portal cases
and nine suite-gated cases. The two compiled-service skips require the Linux
native package layout. Detailed skip names/reasons remain in the copied event
streams, JUnit and `CURRENT-AUDIT-r1.json` under
`/var/tmp/of-pr7/mac-combined-final-r3/evidence-complete-r1/`.

The failed Mac native UI case is retained as a required failed gate. Read-only
diagnostics confirmed that `loginwindow` was the front application and the
console session reported `CGSSessionScreenIsLocked=true`. This is a locked
console prerequisite failure, not passing UI evidence; no fixture or product
assertion was changed. Actual installed approval also awaits the previously
requested `/usr/bin/osascript` Accessibility grant. Unlocking the console and
granting Accessibility are distinct prerequisites. No tool changed either OS
setting. Owned matrix/diagnostic process cleanup was verified without touching
unrelated processes.

Still required before declaring the plan complete:

- A successful final Mac compiled native UI run after the console is unlocked,
  and actual installed approval, document-import and persistence/relocation
  acceptance after Accessibility is available.
- The canonical schedule-1 container matrix, instrumented root ASan/UBSan and
  TSan, final models/virtual-audio acceptance, F-1b timings, and fresh actual
  installed Linux GUI acceptance. Prepared drivers and earlier checkpoints do
  not establish these results.
- The current-binary Linux/Mac feature-smoke scenario inventory, independent
  review consolidation, affected checks for the added standalone test, final
  evidence updates, one final PR and its required hosted checks/review threads.

At the audited `b03c6002` source there is also a concrete readiness gap in the
existing Mac relocated smoke:
`smoke_macos_bundle.py` always runs its source/graph persistence probe, including
`labels.set` and `graph.save`. The installed approval harness currently matches
complete visible facts only for text/file import and preference writes; the
larger `APPROVABLE` list does not make other methods matchable. The production
dialog uses a generic data-action caption for labels and graph writes. The
harness therefore refuses these requests rather than guessing consent. Unlock
and Accessibility alone will not establish the complete relocated smoke until
its existing graph/revision/persistence assertions can execute safely. The
read-only relocated status/SQLite probe above is deliberately narrower evidence.

The plan does not separately require every manual installed real-model probe.
The probe index labels `test_native_service.py` and
`test_packaged_model_runtime.py` as diagnostics; they are not substitutes for,
or additions to, the selected required models and virtual-audio suites. The
compiled virtual-audio meeting workflow itself exercises enhancement, Ask,
imports, graph rendering and persistence, close and reconnect. Its exact final
execution remains required. Supporting additional installed-model approval
methods is unnecessary solely to satisfy that Linux path; the existing required
Mac relocated smoke remains an independent gap.

The bounded follow-up `4597466f` addresses that readiness gap: the production
dialog and strict matcher now distinguish only `labels.set` ("Change source
labels") and `graph.save` ("Save source graph data") in addition to the existing
three matchable methods. Other generic actions remain refused. Framing, exact
visible argument/requester/risk facts, size limits, snapshot recheck and request
deadlines are unchanged. The two new widget caption regressions and two Python
facts cases failed before the four caption entries were added. Afterwards the
whole approval widget file passed 12/0 and the GUI/accessibility Python files
passed 126/0; desktop analysis, formatting, ruff, mypy (166 files) and the timeout
guard passed. This is focused source/test evidence, not an actual relocated
smoke result. That runtime gate still awaits the OS prerequisites and final
current-source execution.

Developer ID signing, notarization, macOS 15/fresh-user/quarantine qualification
and physical audio/GPU execution are not proved by the ad-hoc build, software
GPU or synthetic-audio paths. Preserve the existing physical-GPU default and
explicit per-invocation waiver requirement wherever that acceptance applies.
No unsupported mode is being reported as passing. The separate F-5/F-6/F-7/F-11
work and owner-deferred PR 8 remain outside this extraction. F-9's ownership-doc
and ADR-status corrections are already present.

### Final caption-source Quality at `f7ba7e8a`

After the standalone-test and bounded consent-caption changes integrated, a new
Git-free export of exact `f7ba7e8adfb156e73c01a06c0992200549930569` verified all
1,479 tracked blobs/modes and the exact pristine file set. Its archive SHA-256 is
`799e7a59735ec2e07e210554da7393c8f78285cbc4d7231b326d53ba7d0f22c0`.
The complete Python Quality rerun passed **5,532 tests / 31 skips**, with 187
warnings and **95.82% combined line/branch coverage**, in 288.79 seconds. Ruff,
mypy (166 files) and the subprocess-timeout guard also passed on that export.
The 31 skip reasons are unchanged from the prior Quality result and are fully
listed in the retained summary; no missing runtime path is being counted as
acceptance.

All tracked formatting passed at this same source: clang-format 22.1.8 on
non-vendored C/C++, and Dart 3.9.2 on 725 Dart files with zero changes. Pinned
lockfiles were enforced for core, test support, the protoc plugin and desktop;
this run emitted no unresolved lint-include warning. The external stage driver
verified all 1,479 source files before and after every completed Quality and
format stage. Logs, JUnit, coverage XML/LCOV, artifact hashes and every skip are
under `/var/tmp/of-pr7/quality-final-f7b/`, summarized in
`host-logs/quality-final-summary.json`.

The full Python run waited until the earlier canonical Dart processes had
terminated. Final canonical compilation could overlap Python, but its full
Dart phase waited for the terminal successful Quality report; there was no
full-Python/full-Dart overlap. The preceding `b32688ad` canonical run remains
failed with two infrastructure errors (a 108-byte nested socket path and a
user-namespace temporary-directory ownership mismatch). The final environment
uses a shorter mounted temporary root and matching ownership without changing
source, assertions, deadlines, coverage or schedule. A prepared or running
canonical retry is not a passing result.

These final-source Quality/format results supplement, rather than rename, the
`b03c6002` native/core/desktop/process matrices above. Current-source canonical,
sanitizer, model/audio, RPC and actual installed-GUI execution still need their
own terminal evidence. Main was fetched and remained `75898380`; no branch PR
was open at this checkpoint. One final PR remains the authorized deliverable.

### Final-source HanSolo continuation

The fresh `f7ba7e8adfb156e73c01a06c0992200549930569` matrix at
`/private/var/tmp/ofcf.2Wchvx7x` passed the available non-installed-GUI gates:

| HanSolo gate at `f7ba7e8a` | Executed result |
|---|---|
| Root native | 33 passed / 0 skipped |
| Core | 2,066 passed / 14 skipped; 95.42% (16,277/17,058); enabled-hook regression 1/0; fresh service/MCP AOT |
| Desktop | 550 passed / 13 skipped; 93.52% (8,229/8,799); fresh Release app |
| Compiled service/MCP and native desktop UI | 32 passed / 2 expected Linux-package-layout skips / 0 failures |
| Fast / approval-harness contracts / DMG | 1/0; 126/0; 4/0 |
| Platform Python | 512 passed / 9 skipped / 1 deliberate Arch deselection |
| Package/runtime checks | Dependency verification, packaging, ad-hoc codesign, packaged runtime and owned live SQLite probes exited 0 |

The console was verified unlocked before the native UI retry; no lifecycle
assertion or fixture bypass was added. This clears the current compiled native
UI gate. The earlier locked-console failure at `b03c6002` remains retained as a
failure and is not relabeled.

A read-only evidence query verified the final commit and every stage's exit in
`progress.json`, the result lines in `logs/{core,desktop,desktop-coverage,
compiled-service-available}.log`, and identical before/after lists of all 1,479
source file blobs/modes. Compact local snapshots are retained at
`/var/tmp/of-pr7/mac-f7b-doc-snapshot.json` and
`mac-f7b-doc-compact-snapshot.json`; the Mac agent is consolidating the complete
final audit/dossier separately. Full-source skip inventories retain the same
platform/suite reasons described above.

Actual installed Accessibility acceptance is still distinct. The first process
attribution identified `/usr/libexec/sshd-session`; the owner enabled that entry,
but the fresh Accessibility preflight still returned `false`. A narrower query
of TCC records for the exact owned application/query PIDs then identified
`AUTHREQ_SUBJECT: /usr/libexec/sshd-keygen-wrapper`. Its responsibility record
separately names `sshd-session` as the running binary. The permission subject,
rather than that binary path, is the entry the owner has now been asked to
enable. The retained attribution explicitly returned `authValue=0`; a pending
grant is not a successful Accessibility query or GUI smoke. The actual app query
and relocated approval/document/graph/persistence/upgrade assertions still need
their own successful runtime reports. No tool changed the OS permission setting.

### Canonical peer-probe fixture correction

The subsequent full `f7ba7e8a` canonical run retained two failures: the generic-
interpreter peer assertion and a 500-millisecond web-import fixture. The latter
passed its unchanged failed-only replay (1/0); no web deadline or source was
changed. The peer assertion required a test-source correction, not an
infrastructure waiver or a production admission change.

Independent inspection confirmed that the actual pinned SDK executable is
`dart`, and its `Dart_Initialize` marker is present (the local identical-size
39,684,616-byte SDK image contains it at byte 19,487). The verifier already
rejects both the basename and renamed images carrying that marker. The child
fixture instead consumed the first socket frame without checking request ID;
service `changed` events may precede its reply. A new deterministic real Dart
child/Unix-socket regression sent a changed event and a foreign-ID reply before
the denial. Before correction it failed with captured stdout
`{"event":"changed","workspace_epoch":"fixture-epoch"}`, proving that a null
`error` field in that frame did not establish interpreter acceptance.

Test-only `27a7894f` shares a request-correlated child probe across the actual
source and renamed-kernel cases. It waits for request ID 1's terminal/error
frame within one absolute five-second deadline and closes its socket in a
`finally` block. The original non-null rejection assertions remain and now
also require the correlated ID, `denied` code and verified-desktop diagnostic.
The whole peer file passed 9/0; core analysis and formatting passed. Focused
checks used the existing qualified native/helper outputs from
`combined-final-r3`; no fresh native build was claimed. Product sources and
verifier policy are byte-identical to `f7ba7e8a`.

The independent orchestration reviewer read the complete one-file diff and
found no issue. It is replaying the failed full core gate and the previously
unexecuted compiled-service gate using the qualified `f7ba7e8a` runtime with
only the exact `27a7894f` test blob overlaid. Those results must identify both
source and fixture revisions and are still pending here. The initial failed
canonical result remains failed and retained; successful native, desktop, host
and Python jobs are not being rerun to diagnose this unrelated fixture race.

### Current candidate and remaining smoke scope

The peer correction integrates on the delivery branch as
`d53321a3e3a419859f7c7af1a736d7429737dfc8`. Its only change from the fully
qualified Mac/Quality source `f7ba7e8a` is
`packages/foresight_core/test/desktop_peer_process_test.dart`; production bytes
are unchanged. A separate Mac clone overlaid only that exact test blob and
passed all nine affected peer cases, core analysis and formatting against the
already qualified `f7ba7e8a` native/helper outputs. It explicitly makes no new
native-build claim. The overlay proof, stage exits and output hashes are in
`/var/tmp/of-pr7/mac-final-f7b-r1/evidence-current/fixture-d533-progress.json`.

The failed `f7ba7e8a` canonical run remains failed. A quiet full-core replay is
diagnostic evidence only: revision 24 still requires the complete schedule-1
matrix on the corrected candidate. The detached `d53321a3` canonical worker was
verified live with its recorded PID/start identity; no terminal pass is inferred
from its launch or prepared sanitizer queue.

The current whole-plan audit remains a 95-requirement map at
`/var/tmp/of-pr7/completion-audit-d533.{json,md}`. It distinguishes the final
candidate, earlier full matrices and the later fixture overlay. In particular,
the plan's broad current-binary smoke is a separate requirement from installed
approval and source/graph service persistence:

| Scenario | Linux evidence still required | macOS evidence still required |
|---|---|---|
| Record, onboarding, approval, close, reconnect | Final native virtual-audio meeting workflow and installed GUI | The fresh `f7ba7e8a` compiled native service/UI case passed; final installed approval remains pending Accessibility |
| Enhance and Ask | Final real-model native meeting workflow | Successful current native UI flows with qualified real models; controlled workers and widget tests do not establish these flows |
| Import and graph | Final native meeting workflow plus installed document/graph persistence | Installed document/graph persistence after Accessibility, and explicit rendered-graph smoke; service graph rows alone do not establish rendering |
| Settings | Final native meeting workflow plus installed preferences | Current native settings interaction and persistence |

The Linux meeting workflow uses private PipeWire and cannot establish a Mac
flow. The existing relocated Mac smoke deliberately reports real models and
graph UI restore as not run. Model setup for additional native UI smoke can use
the actual trusted local-model screen, with its model-file/runner fields and
`Register and load` action; there is no need to permit generic external-client
approval captions. These are remaining execution paths, not passing evidence.

### Exact coverage and remaining render-read correction

The complete `d53321a3` canonical schedule finished with every collected test
passing: native 30/0, core 2,064 passed / 18 skipped, desktop 548/17 at
93.64% (8,242/8,802), compiled service/native UI 34/0, fast 2/0 and platform
Python 619/3 with one deliberate Arch deselection. Its strict final core target
still **failed**: 16,205/17,058 is 94.999413%, below the required 95%. Rounding
the displayed result to 95.00% does not satisfy that target. The checked-in 90%
floor, invocation-local 95% postcheck, deadlines and canonical schedule remain
unchanged. Exact counts, dynamic skip reasons and hook evidence are retained in
`/var/tmp/of-pr7/canonical-combined-d533/qualification-failed-coverage.json`.

The two additional core skips compared with the earlier host result are the
existing negative permission tests whose assumptions cannot hold as container
root: root may connect to a protected socket and may remove the socket anyway.
They are not missing native/helper paths. Source-compiler enabled-hook and
ordinary disabled-hook paths were separately verified in the canonical report.

The uncovered lifecycle branch was worker teardown failure propagation through
`ReadCoordinator.close`. Test-only `7428d842`, integrated as `51529440`, now keeps
a real watcher warm, fails worker teardown, and requires the same shared close
future to propagate the original error while reader/activity streams, retained
data, owner callback and worker lifetime retire exactly once. Subsequent reads
must be cancelled without worker reuse. The entire focused file passed 19/0,
core analysis and formatting passed, and focused LCOV confirms the previously
uncovered propagation line executed. Independent root and orchestration reviews
found no issue. This is a missing lifecycle regression, not a product-policy or
coverage-gate change; the next full matrix must establish its actual aggregate
coverage.

A separate source audit found a remaining violation of the plan's no-SQL-during-
render requirement. Several Meetings widget builders capture a
`FeatureRequestIdentity`, and Sources' note readiness rendering checks one.
Those helpers reach `SqliteStoreReader.workspaceEpoch`, which samples the
SQLite read-session identity. Earlier zero projection admissions and passing
architecture checks therefore did not prove the broader render invariant.
The correction is in progress: rendering must use an already prepared identity,
while actions and asynchronous completions retain live session/workspace checks.
In particular, cached note readiness cannot authorize saving an accepted body
after an out-of-band epoch reset or reveal an obsolete saved body in a review
dialog. The final source correction, guarded-builder regressions and independent
review remain required before a new combined candidate is frozen. The existing
`d53321a3` runtime and earlier matrices are not relabeled as testing that future
production source.

### Prepared render identity at `83a26aa9`

The bounded correction `b9b0bd59` integrates as
`83a26aa9f8e6990270e52b9e65007bb0582aa21f`, on top of the teardown regression
`51529440`. Meetings now passes the identity captured when its prepared reader
owner binds, disabling affected actions if no owner was prepared. Sources uses
private cached readiness checks for note rendering. The public accepted-note
readiness and action checks still consult the durable epoch: Save checks both
before entering the operation gate and inside it, and saved-body review checks
the accepted owner before displaying the dialog and again after it returns.
An old callback cannot authorize a write using a newly captured owner.

Four guarded-builder regressions failed against the original source and passed
after correction. They exercise actual `BuildOwner` callbacks, including deferred
layout builders, after startup preparation. Sources guards metadata identity
access; Meetings also guards typed `read`/`watch` admissions. They additionally
require retained Save, saved-body review and Summary actions to refuse an
out-of-band durable epoch replacement, including reused meeting IDs before the
client adopts the event. The final eight affected files passed 70 tests with
zero skips; analysis and formatting passed. An initial 153-line Actions builder
failed the existing strict size guard; extracting its existing supporting-
evidence presentation restored 143 lines. The original failed output remains.

Independent root and audit reviewers read the complete source/test delta with
no findings. The audit reviewer verified all eight changed-source hashes and
the actual red/green/analysis/format artifact hashes. Claude CLI round 6 reviewed
the full `d53321a3..83a26aa9` delta and exited 0 with no actionable findings.
Its report is `/var/tmp/of-pr7/final-review/claude-r6-report.json`; output SHA-256
is `acb71544fd079bbbcc7fb62be113d13539c528b939e94605c9503576ab0f8a72`.
Review convergence does not establish the pending runtime matrices.

The authorized two-test metrics rerun used a pristine full export of exact
`83a26aa9`, archive SHA-256
`69e6254b08f6477994f254e675066df6e712299abafece33a76a51d103f99882`.
Both tests passed with zero skips, and all 1,479 tracked blobs/modes were checked
before and after. All seven screens' admission, notification and build deltas
exactly match the earlier successful `b03c6002` measurements in the table above.
This collection-screen stimulus is distinct from the targeted meeting-panel
and note-editor guarded-builder evidence; unchanged aggregate counts alone
would not prove that the rendering defect was corrected. Metadata getters may
still execute SQLite outside rendering, and no latency claim follows.

The current AST inventory is **87 Dart files**, rather than 87 independent Dart
libraries: feature-local part files share their owner's library. Main remains
203 lines and the largest file 796; the largest widget-returning method is now
Sources' note view at 149. All strict size targets pass. The normalized comparison,
raw seven-screen JSON, test events, AST results and exact-source proofs are in
`/var/tmp/of-pr7/reader-admissions-comparison-83a26aa9.{json,md}` and
`reader-metrics-83a26aa9/`.

The canonical schedule and both sanitizer matrices are now being prepared/run
against this source with managed, independently observable processes. Their
launches are not passing results. Real models, virtual audio, software GPU,
responsiveness and installed Linux/Mac GUI still require their own final
artifact-bound execution and explicit resource handoff.

### Exact final canonical and sanitizer execution

The whole unmodified canonical schedule for `83a26aa9` passed: native 30/0,
core 2,065 passed / 18 skipped, desktop 552/17, compiled service/native UI
34/0, fast 2/0 and platform Python 619/3 with one deliberate Arch deselection.
Core coverage is exactly 16,207/17,058 = 95.011138%, satisfying the strict 95%
postcheck; desktop is 8,254/8,812 = 93.667726%, satisfying its 90% target.
The two container-root permission skips retain their explicit reasons. Source
identity, all 1,479 tracked blobs/modes, production hooks disabled and the
separate enabled-hook probe are recorded in
`/var/tmp/of-pr7/canonical-combined-render-final/qualification-report.json`.
The portable artifact binding is
`/var/tmp/of-pr7/canonical-artifacts-render-final/proof.json`.

Both fresh project sanitizer builds then passed the full native CTest inventory
of 30 tests with zero skips: ASan/UBSan and TSan. Actual planted fatal sanitizer
probes and a planted race, detected with exit 66, establish instrumentation
activity. Their project binaries were rebuilt from exact final source; qualified
SDK and dependency bytes were reused and checked unchanged. The historical
`d533` basename within a preparation directory does not identify the built
source. The root reviewer read raw logs, all 17 CMake controls, compilation and
input proofs in
`/var/tmp/of-pr7/final-durable-render-final/root-sanitizers-review.json`.
The queue's actual `queue-result.json` is `PASSED`, and all its owned
processes/containers were verified terminal before the installed Linux GUI lane
was released. Real model, audio, responsiveness and software GPU jobs remain
held until that independent GUI gate passes and releases its owned resources.

The final Mac available matrix also passed: native 33/0, core 2,068/14 at
95.427365%, desktop 554/13 at 93.563401%, compiled service/native UI 32/2
(expected Linux-layout exclusions), fast 1/0, platform 512/9 with one deliberate
deselection, DMG 4/0 and harness 126/0. The final source, installed runtime,
public Whisper model and private SQLite evidence are independently reviewed in
`/var/tmp/of-pr7/mac-final-83a26aa9-r1/root-evidence-review.json`. Its installed
GUI flag remains explicitly false. These available matrix results do not prove
the pending Mac trusted UI workflows.

### Supported installed Linux GUI qualification

Exact final `83a26aa9` now passes the supported installed Linux GUI scope.
Actual onboarding and PDF/RTF approval/import succeeded. Source and note data
survived a byte-identical private installation-directory replacement. Actual
GUI consent authorized source/label/graph commands, and stale/current graph
writes and restart persistence passed. These graph results verify service
persistence; they do not establish rendered graph behavior or real embeddings.
The first attempt's three successful stages remain unchanged. Only the failed
refusal/cancellation stage was rerun: capture/security/arbitrary-preference
automation was refused; an existing approval dialog was not clicked; dropping
the pending import connection cancelled it without a source write.

Actual accessibility snapshots identified the reopen timeout as the expected
initial local-model setup dialog hiding workspace controls. The original
30-second diagnostic limit was preserved. An attempted generic Cancel action
was correctly refused by the existing production helper. A task-local trusted
UI helper then required the exact owned native PID/executable, complete setup
facts, two unchanged whole-dialog snapshots and one visible enabled Cancel;
any capture or approval dialog was refused. Its separate actual cancellation
scenario returned to Sources/Settings without changing model registrations.
The successful refusal scenario did not require this popup branch, so that
separate execution is retained explicitly rather than inferred. Production
source and generic approval allowlists were not changed.

The composed report
`/var/tmp/of-pr7/linux-final-gui83/qualified-report.json` binds the original
successes and failed-step rerun to exact source and artifact proofs. All 1,479
tracked source blobs/modes and canonical/replacement bundle bytes/modes were
verified unchanged. All five owned sessions and profile roots were checked
with no survivors, and the shared resource lock was free. Original failed
output and all actual snapshots remain in the reports' evidence paths.

The real acceptance queue's first managed attempt then failed closed during
canonical runtime binding, before any RPC/model/audio/GPU workload: its generic
source checker did not recognize the handoff's qualified dependency cache.
A bounded external adaptation retains independent Git blob/mode verification
and exact complete handoff inventory checks, accepting only cache entries
listed in the pinned canonical manifest. Twelve real tiny Git/archive fixtures
verify acceptance of unchanged bound inputs and rejection of tracked-source,
cache, manifest, output and package mutations. Actual final binding was checked
twice with identical results, without starting workloads. Owner review and a
new unique managed queue attempt are required; this preflight is not acceptance.

### Exact final responsiveness execution and remaining real acceptance

The released `83a26aa9` responsiveness measurement passed with the same runner
bytes as the frozen `75898380` baseline. Each of the four conditions contains
100 raw status-RPC samples: idle before model loading, warmed idle, real native
generation and progressing PCM capture. Final p95 values are respectively
1.058948, 0.955492, 1.243546 and 0.841808 milliseconds, all below 50 milliseconds.
The captured previews, generation activity, actual mapped public-model inputs,
full runtime identities and graceful service/supervisor/relay shutdown are in
`combined-pristine-render-final/model-acceptance/rpc-render-finalr3/` beneath
`/var/tmp/of-pr7/`. Its `comparison.json` retains baseline/final p50, p95 and
maximum; `baseline-final-audit.json` verifies matching measurement-runner bytes
and both reports' activity/input/cleanup evidence. This uses an explicitly
synthetic native peer rather than a graphical desktop. Runtime and peer
configuration differences are disclosed, so the comparison is not a causal
measurement of code changes alone. Independent root review remains separate.

The same queue then failed before model tests because capability-free container
root could not access host-owned private directories. The next attempt mapped
only disposable source/output/temp ownership through a separate CHOWN-only
helper, retaining private modes and zero capabilities in the actual test
container. An actual negative/positive control verified the access correction,
postorder host ownership restoration, and an unchanged external symlink target.
No canonical source, bundle, SDK or public-model ownership changed. That attempt
correctly refused offline dependency resolution because the older dependency
image cache lacks the already pinned analyzer 10.0.1. Both original failures,
SDK identities and cleanup output remain retained.

The current unique managed attempt reuses a disposable copy of the complete,
manifest-bound canonical package cache, keeps network disabled and retains
`--offline --enforce-lockfile`. Its actual models suite is running the final
portable native/helper/model binaries and public Gemma/EmbeddingGemma inputs.
Successful RPC timing is not repeated. The remaining queue is models, virtual
audio including the compiled meeting workflow, then software GPU. No model,
audio, rendered-graph or software-GPU result is claimed before terminal evidence.

The actual final models suite has now passed: all five canonical desktop cases
and the core real-model web-answer case, with zero skips/failures. This includes
real native generation/grounded citation/owned cancellation, helper-backed
answer restart/deletion, saved meeting citation and Drive metadata exclusion.
SDK, bundle, portable package and complete canonical runtime bindings match
before/after; disposable private mounts returned to their original host owners
and 0700 modes. Compact evidence is
`/var/tmp/of-pr7/final-model-driver/models-final83-qualification.json`. The queue
advanced to the still-required virtual-audio stage; that launch is not a pass.

Virtual audio's two desktop recording cases and core private-PipeWire case
passed with real Whisper and zero skips. Its compiled meeting test then failed
at startup: the separately compiled native Debug desktop could not claim the
installed Release service's desktop capability. The sealed service correctly
accepts only its own installed desktop. Merely supplying a development allowlist
to that service cannot work because sealed configuration discards it.

A scoped Python gate correction is review-ready at `1bb7c8bd`: stage an identical
service executable outside the installed layout and allow only the exact native
Debug integration executable through the existing unbundled development policy.
The installed service, installation configuration and package remain untouched.
A regression fails on the original sealed-service selection, then passes with
the correction; it proves copied SHA/mode, destination outside the bundle,
exact peer list and unchanged source bundle bytes/modes/timestamps. Negative
cases refuse an in-bundle destination, nonexecutable input and existing copy.
All 67 affected Python tests pass with zero skips; full Ruff, mypy over 166
files and subprocess-timeout checks pass. The check evidence and original red
output are retained in `/var/tmp/of-audio-peer-checks-r1/`. This is fixture
configuration, not a relaxation of the installed peer verifier. The actual
failed compiled workflow and later software-GPU acceptance remain unexecuted
with this correction until reviewed integration and resource release.


The next compiled meeting attempt successfully passed startup, actual recording,
transcription, summary, Enhance, Ask and file-import assertions before failing
at a synchronous matcher receiving `Future<String>` from the intentionally
asynchronous markdown export. Its original output remains retained as r7.
The sole correction is to await that value before the unchanged `contains`
assertion. Independent review audited the entire 1,751-line fixture/API surface;
a resolved analyzer audit of all three integration files found exactly this one
Future-valued matcher argument before correction and none after. Integrated
`dfeb202d` has no production change. Current package verification again passes
552/17 at 93.679074%, with analysis/format clean and identical runtime/SDK inputs.
Claude round 10 and root/tooling reviewers accept the exact one-line correction.
The actual meeting-only r8 remains separate required terminal evidence.

## Final Linux compiled real-model workflow

Failed-only attempt r9 passed the canonical compiled meeting test, one test with
zero skips. It used exact `0ec8ea49` fixture source and unchanged83 production
Dart/native/bundle inputs, a fresh Debug desktop on private Xvfb/D-Bus and a
byte-identical unbundled service under its supported development allowlist.
The original 2,400-second test deadline and 146 expected assertion matchers were
preserved. Real public Gemma4 and EmbeddingGemma2 CPU inference, Whisper and
private PipeWire playback produced the transcript, enhanced notes, cited answer
after restart and an 11-point/11-edge rendered graph. Source import/refresh,
Find Files selection, graph selection/Inspector/labels/clusters/restoration,
settings, clear cancellation/confirmation and reconnect assertions passed.
Fifteen screenshots and all retained failed attempts remain in the evidence.
All1,479 source blobs/modes and SDK, runtime and package identities remained
unchanged; disposable private ownership was restored and no owned process or
container survived. This is functional smoke coverage, with no physical
microphone/GPU, pixel-baseline or comprehensive accessibility claim.
