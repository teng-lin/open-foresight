# Desktop feature refactor execution

The source of requirements is revision 24 of
[the plan](2026-10-20-core-desktop-refactor-plan.md). This record does not replace
its acceptance criteria. PR 8 and the follow-ups explicitly marked separate
remain outside the feature moves. All desktop extraction, final Linux and
HanSolo matrices, reviews, hosted checks and PR publication remain outstanding.

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

## Remaining execution

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
