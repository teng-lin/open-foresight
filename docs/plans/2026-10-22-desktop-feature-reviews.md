# Desktop feature implementation reviews

This records implementation review separately from
[plan review](2026-10-20-core-desktop-refactor-reviews.md). Acceptance commands
and source identities are in the [execution record](2026-10-22-desktop-feature-execution.md).

Native reviews use this session's Codex collaboration agents; their exact model
build identifier is not exposed by the collaboration interface. External reviews
use Claude Code CLI 2.1.304. Review is not evidence that acceptance tests ran.

## Prerequisite review, round 1

- Native reader reviewer checked `5e8bb301` against the actual Dart and native
  v1 status producers and reported no actionable findings.
- Native service reviewer checked `73110d39`: the extracted MCP tool body and
  filesystem metadata body are byte-identical to their predecessor. Executed
  old/new serializers confirmed all 32 MCP tool definitions remain identical.
  The plain internal service schema maps explicitly retain empty `required`
  lists; that is schema-equivalent and does not change MCP output.
- Native desktop reviewer checked `dd0c51c9` and `464d5be8` for subscriber
  deadlines, settlement, session replacement, status ordering and revision
  coverage, with no blocking findings.
- Claude reviewed frozen `5e8bb301` and found diagnostic loss, missing direct
  producer contracts, generator-interface state mismatch, the empty-capture
  default, missing macOS echo fields and absent selector equality.

All six Claude findings were accepted. `27d0e812` preserves diagnostics and
nullable capability flags, consumes the interface's generating fact, restores
the idle default, retains macOS fallback details, adds structural equality and
adds public-export and producer-JSON contracts. Native re-review found no blocker.

## Prerequisite review, round 2

Claude reviewed frozen `0b9fc7c5`, including the F-1b runner and 7.1 fixes.

| Finding | Disposition |
|---|---|
| Runner cleanup misses exited service descendants and native worker process groups | Accepted. Native desktop reviewer independently reproduced the early-leader-exit case. `0cc57c13` introduced an owned supervisor and partial evidence retention. Root then found that native `POSIX_SPAWN_SETPGROUP` also requires session-wide cleanup; `8f69384a` adds verified pidfd signalling across those groups. Real process regressions cover normal and TERM-resistant workers, including a stopped supervisor |
| Runtime library search paths/dependencies and inherited environment are not fully recorded | Accepted. `42944eca` hashes concrete files in each explicit loader directory and optional additional runtime files, records symlink targets, restricts inherited environment and rejects loader injection |
| Native loading state alone does not prove tokens streamed inside the measurement window | Accepted. `42944eca` waits for a changed non-empty answer chunk, requires a further chunk between the first and last status responses, and requires native generation throughout all 100 samples |
| Idle and capture conditions are not explicitly qualified | Accepted. `42944eca` rejects generation or capture during idle, generation during capture, and capture samples without advancing PCM counters |
| Retained service log needs a direct path/digest or output copy | Accepted. `42944eca` copies and hashes the log on successful and failing attempts; a failed copy makes evidence incomplete |
| Onboarding retry stays unready when its resume legitimately reconnects | Accepted and fixed in `b44285ef`. Readiness belongs to the same DesktopConnection instance; a new regression replaces the underlying client during resume |
| Missing HOME fails before the startup error surface | Accepted and fixed in `b44285ef`, with the existing macOS account-home fallback performed through the environment adapter |
| Default audio discovery bypasses the injected runner; source guard misses synchronous Process calls | Accepted and fixed in `b44285ef`. Explicit device-loader injection remains supported. Its effective default goes through the environment runner, and the guard covers every Process member access |
| Global preference failures should survive tab/selection changes | Rejected for this work package: the plan's Asynchronous actions contract explicitly binds the shared wrapper to feature, selection and epoch. The regression intentionally rejects an error from a retired feature selection. Changing that reporting policy would be a separate behavior decision |
| Extend the host-effect source guard to D-Bus construction | Deferred to 7C-2's platform adapter. 7.1's specified source guard covers Process, environment, URI and notification boundaries; it does not prohibit the existing portal implementation. No default widget transport leak was demonstrated |
| Real-producer contracts should exercise non-default Summary/workflow/Notes state | Accepted. `c945d773` drives Summary, multi-chunk Preparation, Notes and Google through actual coordinators, including remote status delivery, progress and settlement. All 56 focused tests passed |
| Cache whole-capture decoding rather than repeating it in future selectors | Deferred to 7B's prepared feature models. No production consumer uses these additive getters yet; features will decode outside building and cache their immutable state. Strict rejection of malformed typed v1 payloads remains intentional |

The native desktop reviewer confirmed the F-3 diagnostic, nullable-capability,
generating, idle-default, echo and equality corrections. Whole-prerequisite
convergence is still pending the remaining changes and a frozen re-review.

## Prerequisite review, round 3 (in progress)

The native reader reviewer found that unexpected supervisor exit could still
leave a responsiveness report marked passed. `be26024e` marks unexpected or
nonzero supervisor exit incomplete, snapshots live same-session survivors before
forced leader shutdown, and explicitly records verified empty-session cleanup.
The implementer ran 84 runner tests without skips, with 98.38% runner coverage;
root integrated the commit for independent re-review. This is runner verification,
not a real-model timing result.

Native and Claude reviews now target frozen `be26024e`. P0.1 is a separate change
and has not yet been integrated or accepted.

Native re-review passed all 84 runner tests with no skips and found no remaining
actionable finding in the reviewed runner and desktop follow-ups. The real-model
run subsequently exposed a workload qualification gap: grounded local answers
are intentionally buffered through verification. Runner changes will use an
existing genuinely incremental workload, without altering product grounding or
weakening streaming-overlap assertions. Those changes require another review.

## P0.1 security review (in progress)

The security implementation is isolated at `84e9e426` (security commits
`023b06ae` and `84e9e426`; its intervening commits are equivalents of 7.1).
Native and Claude review are independent of its implementer. Root identified
and the native reviewer reproduced a hidden replacement defect: attaching a
new verified hidden host leaves the previous recording active. The retained
real-service reproduction reports an attached hidden host and zero recording
stops after 200 ms. Root also identified possible concurrent initial-attach /
visibility races around token rotation. Follow-up fixes and held-reply
regressions are in a separate worktree; the reviewed source remains frozen.
No security convergence or macOS peer-credential acceptance is claimed yet.

`73e932e3` (integrated as `ae257f6c`) serializes token-consuming attachment and
coalesces visibility updates to the latest desired state. It guards disable,
dispose and reconnect generations, and prevents a displaced hidden window from
reclaiming the host. A hidden replacement now initiates capture finalization
while retaining desktop presence. Both initial reproductions failed before the
fix; 92 targeted regressions passed afterward.

HanSolo's frozen `84e9e426` run passed the fresh native inventory (33/33), then
48 focused core tests passed and one existing copied-interpreter test failed:
Mach-O symbol metadata lies beyond the verifier's initial 64 KiB scan. The
separate `2132ba92` fix (integrated as `bb9a86e3`) scans the whole native image
in bounded chunks with boundary overlap. All eight Linux process tests passed;
the failed Mac case is being retried before the full focused Mac group. Logs and
progress are mirrored under `/var/tmp/of-pr7/security-84e9` and `security-2132`.

The first external security review was interrupted by its tool's safety check
and is incomplete. A new review is restricted to defensive correctness findings,
fixes and test requirements, without attack walkthroughs. It does not inherit an
approval from the interrupted attempt.

## Round 3 follow-ups

Claude found no blocker or major issue in frozen `be26024e`, but identified two
minor runner gaps and three low findings. The first real baseline report
confirmed service exit `-15`: repeated TERM delivery interrupted graceful close.
`6f57e30a` (integrated as `d52420b7`) signals only the supervisor from the owner,
then delivers TERM once per process identity, records escalation and service
exit, and verifies a live delayed graceful shutdown regression. Its 116 runner
tests passed without skips. Observed mapped-runtime inventory is still being
implemented to supplement declared loader paths.

`12911f08` (integrated as `d17a8b02`) replaces the buffered answer workload with
real incremental Summary previews and makes direct-socket RPC deadlines absolute
even under partial lines. `9eacd67d` (integrated as `9efd089f`) provides an optional
hashed native relay for explicit development-host timing after P0.1; it does not
claim graphical desktop acceptance. Combined runner tests: 113/0, 98.28% coverage
before the subsequent cleanup additions.

`c0bd60a2` adds actual coordinator failure/cancellation decoding assertions (26
tests passed). `38e3883f` prevents empty `HOME` from resolving effects under `/`
(eight environment tests passed). Sharing the private macOS home-lookup helper
is deferred to 7C-2's platform boundary: no injectable public core helper exists
today, and introducing that API solely to remove this small adapter duplication
would expand the prerequisite scope. All four changed files format clean;
core and desktop analysis pass. Another frozen review remains required.

## Runner round 4

Native review converged at `99dcaed9`, with 137 independent controlled tests
passing. Claude's review of the same frozen source confirmed the prior fixes and
found three minor and three low issues. Root accepted five: exclude a preview
first observed on sample zero; reject non-graceful service/relay shutdown; bind
mapped declared input paths and the executed service image to their pre-run
identity; restrict mutable shared-data handling to private workload roots and
label its post-run hash separately; and let the service settle its children
before signalling remaining orphans.

`0e4d0d2a` (integrated as `48813ed9`) implements all five with real process and
file regressions. Implementer tests: 153/0, 98.44% runner coverage; independent
native review and the same 153 tests passed without remaining actionable source
findings. Refusing deleted/memfd mappings is retained intentionally: the pinned
CPU workload passed without them, and unqualified memory-backed runtime code
must not be silently treated as a hashed disk artifact. Supporting additional
runtime mapping forms requires its own provenance treatment.

The canonical `99dcaed9` failure and deterministic consumer-acknowledgment fixture
fix are recorded in the execution record. The original failed case passed alone;
the fixed full file passed 12/0 with coverage and two correctness mutations
failed. Another frozen external review and canonical matrix remain pending.

## Defensive P0.1 review dispositions (in progress)

The completed external defensive review targets `2132ba92`; it is static evidence.

- The suspected missing macOS libproc library is rejected against actual target
  evidence: the fresh Mac process/bridge suite exercised that lookup and passed
  all 50 cases.
- Consistent inactive/hidden lifecycle reporting is accepted. `8c4f3cc2`
  (integrated as `d3b14a28`) treats resumed/inactive as visible and
  hidden/paused/detached as unavailable, with a seven-test lifecycle group. A
  persistent tray/menu indicator would be new product behavior. Physical OS
  visibility scenarios remain distinct from widget lifecycle tests.
- Direct Linux packaged entrypoints must enforce installed configuration without
  relying on launcher environment. Accepted and under follow-up verification;
  missing resource-directory and model-manifest compatibility cases, loader
  parity and actual relocated runtime closure are not yet accepted.
- Whole-process integrity against same-user OS injection or modification of a
  user-owned installation is outside this executable-identity boundary. The
  trust assumption is documented. Stronger kernel-generation/signature or
  signing-policy requirements are separate platform security design work; no
  such resistance is claimed here.
- A new host-displacement UI event is deferred: current service authorization
  always uses its actual host and denies displaced clients. Last verified attach
  wins, and a hidden replacement finalizes capture. A new v1 event would need
  its own compatibility treatment; no stale client-side host belief confers
  authorization.
- The hypothetical future await before recording starts is rejected against
  current dispatch: Start/Resume have no configuration gate, synchronous handler
  invocation reaches recording assignment/resume in the same turn, and helper
  readiness is already followed by the visible-host recheck. A future async
  boundary must preserve that invariant.
- Canonical runtime execution and LiteRT probe/load parity are accepted and
  being implemented. Executable-format caching and broader format recognition
  are not required: supported-platform native process tests exercise actual
  accepted executables; the exact canonical allowlist is the trust boundary,
  while interpreter marker checks are supplementary.
- Remove-by-key and stale-generation failure handling are fixed in `763c9575`
  (integrated as `75c85bdf`), independently reproduced green with four focused
  regressions. Concrete Linux development startup instructions were added.

No whole-security convergence or final platform matrix is claimed by this triage.

## Combined implementation review rounds, 2026-10-23

The external reviewer used Claude Code CLI. The installed CLI version observed
during evidence consolidation is `2.1.304`; the retained review output does not
independently record a version for each earlier invocation. The native reviewers
are independent Codex collaboration agents. Static review and runtime acceptance
remain separate evidence.

| Round and frozen scope | Findings and disposition |
|---|---|
| Claude round 1, `75898380..f803bfdc` | Accepted: a single workspace-epoch event could bind prepared readers before adoption; a slow successful note read could allow an unseen-body overwrite; and Chat scope verification remounted history and lost scroll state. Separate regressions and corrections landed in `228480ed`, `c3934c2f` and `e8273512`. The independently identified failed-note-load overwrite was fixed in `f0110863`. Global busy invalidation and canonical/conditional dependency guards were already corrected in `57efa674` |
| Native follow-up source reviews | Independent reviewers cleared the workspace-adoption, note-load/save and Chat corrections within their reviewed source scope. Runtime review reproduced the whitespace-only executable-selection gap; `8a16233c` closes it with the real private-executable regression. The final combined core/desktop/verification role consolidation remains required |
| Claude round 2, `f803bfdc..dab55126` | Cleared the product corrections in its scope. Accepted two installed-GUI harness findings: argument text could supply fake snapshot facts, and AppleScript rechecks compared case-insensitively. `55d70da4` parses strict frames before decoding, requires the complete expected fact set and uses case-sensitive AppleScript comparisons. Its 114 focused contracts passed; script compilation and independent source review passed |
| Claude round 3b, `dab55126..b03c6002` | Exit 0; no actionable source findings. Cleared both round-2 harness findings and reviewed typed probe snapshots, original bounded deadlines, fixture dispatch, Mac fact injection and restrictive-umask fixture corrections. This is scoped source convergence, with no build, test or OS GUI execution by the reviewer |

The round-1 hypothetical transitive feature-ownership guard gap was retained as
future hardening: the reviewer enumerated the current shared/port imports and
found no actual forbidden dependency. The existing guard checks feature
dependencies directly and checks the desktop MCP import closure transitively.
Supporting additional normalization forms is not evidence of a current source
violation; actual imports and the negative tests remain part of final analysis.

The final Claude review explicitly excludes real AT-SPI/macOS Accessibility
behavior and platform matrix results. Its liveness-only observations about
Unicode line separators or unexpected accessible text fail closed; they were
not classified as wrong-consent findings. Distinct clients with identical
visible facts remain indistinguishable by the public GUI, as documented by the
harness; no external-client identity guarantee is claimed.

Evidence is retained in
`/var/tmp/of-pr7/final-review/claude-r{1,2,3b}-oauth.txt` and
`claude-r3b-report.json`. The last report binds the successful review to full
source SHA `b03c6002fa94adabd4cff05351333812f93cdca6` and hashes its output.

## Independent completion audit

The read-only whole-plan audit mapped 95 requirements at `b03c6002`, including
preserved core contracts, F-1 through F-12 scope, P0.1, all six owners, 7C, size,
invalidation, fixture boundaries and final gate/deliverable evidence. It did not
treat deferred F-5/F-6/F-7/F-11 or PR 8 as missing extraction work. The concrete
missing scoped acceptance was Integrations' standalone fake-port widget test.
`7a0a50b`, integrated as `b32688ad`, adds it without production changes; 1/0,
analysis and formatting passed, and the integration owner independently reviewed
the new test without finding an issue.

For that test-only delta, the author and independent reviewer are distinct: the
quality/audit agent implemented the test; the root integration agent then read
all 224 lines after cherry-picking `b32688ad`. The reviewer verified the actual
controller-owned widget, fake-only connection/reader/ports, meaningful exact
outbound preference action, listener retirement, account close and safe late
event. The author's own acceptance mapping is not counted as independent review.

The audit also required a fresh seven-screen admission/build comparison; the
successful full `b03c6002` desktop run now supplies it. The execution record
reports the actual values, including small build increases and increased
metadata identity checks that can still execute SQLite work. No zero-SQL or
timing claim follows from zero projection admissions.

The audit and comparison are retained at
`/var/tmp/of-pr7/completion-audit-b03.{json,md}` and
`reader-admissions-comparison-b03.{json,md}`. They do not establish completion:
the canonical/sanitizer/model/audio/RPC/installed-GUI gates, locked HanSolo native
UI and pending Accessibility paths, final review consolidation and final PR
remain outstanding. Existing successful matrices name `b03c6002`; the new
test-only commit is not relabeled as an executed full combined matrix.

An additional read-only gate audit found that the installed approval harness's
strict matchable-method set is narrower than `APPROVABLE`. No unsafe fallback
was added. Optional manual installed-model diagnostics are not required to
expand that set. The existing required Mac relocated bundle smoke does call
label/graph writes, however, so its full execution remains pending separately
from the locked console and Accessibility prerequisites. A read-only relocated
SQLite/status check is not acceptance of its graph or upgrade assertions.

`4597466f` supplies the narrow readiness correction: explicit production action
captions and the matching two harness facts for labels and graph save, without
allowing generic fallback consent. Existing exact framing and complete-fact
checks remain. The new tests reproduce missing captions/facts before the fix,
then verify actual widget captions and nested graph arguments, as well as
whole-call refusal of mismatched actions, arguments, requester, forged frame
markers and unexpected risk facts before any click. Approval widgets passed
12/0 and GUI/accessibility contracts 126/0, with analysis/format/static checks
clean. At this checkpoint, independent review of the source delta and actual OS
GUI execution remained pending; the author did not count this mapping as
independent review.

## Final scoped source convergence at `f7ba7e8a`

The root integration agent independently reviewed the full new-test/caption diff
after integration as `f7ba7e8adfb156e73c01a06c0992200549930569` and found no issue.
The final Claude CLI round 4 reviewed `b03c6002..f7ba7e8a` and exited 0 with no
actionable defects. It verified all five exact action captions, continued
refusal of other generic methods, unchanged complete framed arguments/requester/
risk checks, and Python/Dart display parity for the actual full nested
`source_graph_probe` payloads. It also reviewed the independent Integrations
widget's real action and disposal contracts.

The report is `/var/tmp/of-pr7/final-review/claude-r4-report.json`; the output
`claude-r4-oauth.txt` has SHA-256
`8a7f1261bb8dac6ab7bed44cd72b78c6d7ef77c1b9a7da7ca5833b3c5cc04a94`.
This closes the source delta after the whole `b03c6002` review chain. The reviewer
ran no tests or builds and explicitly made no OS GUI/runtime acceptance claim.
The pending runtime gates remain required regardless of source convergence.

## Request-correlated interpreter fixture review

The initial canonical peer-test failure did not prove a P0 admission bypass.
An independent SDK/source check found the expected `dart` executable and
`Dart_Initialize` marker, while the fixture used `.first` on a stream containing
unsolicited status events. The new deterministic real-child regression
reproduced the wrong-frame result before correction. Test-only `27a7894f`
correlates the terminal/error reply, retains actual source and renamed-kernel
interpreter denial, and strengthens its denial-code/message assertions. The
production verifier is unchanged.

The orchestration agent independently reviewed the full one-file diff and
reported no findings, including the absolute five-second deadline and socket
cleanup. The author's whole peer file passed 9/0, with core analysis/format
clean. Corrected full-core and compiled-service replay evidence is pending;
focused success does not overwrite the original canonical failure.

## Final source review convergence at `83a26aa9`

The unchanged full-source review chain and dependent rounds now cover frozen
source `83a26aa9f8e6990270e52b9e65007bb0582aa21f`. This establishes source
convergence; final runtime acceptance remains separately required.

| Role and reviewed delta | Independent disposition |
|---|---|
| Core lifecycle fixture | Root and orchestration reviewers read the complete teardown-failure regression `7428d842` (integrated as `51529440`) independently of its audit-agent author; no findings. The test preserves error propagation, shared/idempotent closure, stream settlement and no reader reuse |
| Desktop render safety and action authority | Root and audit reviewers read all six production and two test files of `b9b0bd59` (integrated as `83a26aa9`) independently of its orchestration-agent author; no findings. Cached render identity does not replace live command/completion authority |
| Verification orchestration | Root independently reviewed the audit agent's common pre/post canonical/package-binding correction and eight actual tiny Git/archive mutation guards; no findings. Root also reviewed the exact-source canonical/sanitizer queue, strict 95%/90% checks, immutable SDK/source inventory and `/src` artifact mapping; no findings |
| Claude round 5, `f7ba7e8a..d53321a3` | Exit 0, no actionable findings. Read the complete correlated peer fixture and dependent production verification/reply framing; interpreter and renamed-kernel rejection remain stronger and bounded |
| Claude round 6, `d53321a3..83a26aa9` | Exit 0, no actionable findings. Reviewed worker teardown semantics, prepared render identity, null-owner action disablement, durable Save/Review/meeting guards and dependent reset/adoption sequencing |

The final audit reviewer verified every changed source hash and retained
red/green/analysis/format artifact hash before recording the independent action-
authority review. Original source fails all four new guarded-builder cases;
the final eight-file run passes 70 tests with no skips. Sources' build guard
covers identity metadata; Meetings' also covers typed read/watch admissions.
Both are armed after preparation and inspect actual framework build scopes.
They are scoped regression evidence, rather than proof that every future
presentation path can never access persistence.

Round 6 notes the unchanged possibility of an external epoch change between
two successive live checks. The production client epoch makes that path refuse
the newly mismatched identity. This observation is not a requested source
change or an unresolved finding. No live ownership guard was replaced by the
new in-memory presentation check.

Claude round 5's report/output are
`/var/tmp/of-pr7/final-review/claude-r5-report.json` and `claude-r5-oauth.txt`,
output SHA-256
`1c405daf623692b00ce37b1c4cb622a1eb66ebf3504d11abe91bffc8d48c5cd3`.
Round 6's corresponding output SHA-256 is
`acb71544fd079bbbcc7fb62be113d13539c528b939e94605c9503576ab0f8a72`.
Both explicitly performed source review without builds or tests. The independent
native review is retained at
`/var/tmp/of-pr7/render-identity-proof/independent-action-authority-review.json`.
Final native/model/audio/RPC/installed-GUI/hosted results must still be inspected
before any completion or publication claim.


## Dependent automation and fixture review through `03ee17b3`

The application remains the qualified `83a26aa9` production tree. Later scoped
reviews cover the changed automation and integration fixtures, preserving
installed peer verification and every test deadline/assertion.

| Review and dependent scope | Disposition |
|---|---|
| Root independent review, automation/gate | Accepted exact owned-PID accessibility startup,complete dialog facts,retained subprocess diagnostics and the unbundled Debug-service fixture. The installed service still refuses a different executable; only identical service bytes outside the installation use the existing exact development peer list |
| Claude round7 | Found one diagnostic-order issue: live app lookup could mask failed subprocess output. Accepted and corrected in6ff877a6 by retaining output before identity checks; refusal remains intact and meaningful tests pass |
| Claude round8,exact6ff | Exit0,no actionable findings,scope converged; output SHA-256 `f1de404315eb1fd81dab7398dcc9f946dbe40c7b594593541c90be08b924041f` |
| Root independent review,meeting fixture | Accepted the actual-first-screen barrier copied from the established service/MCP fixture: within the same existing60-second startup wait,require Workspace plus OnboardingView orMeetings,then use unchanged onboarding actions. Actual failed output demonstrated the original race |
| Claude round9,exact03 | Exit0,no actionable findings,scope converged; output SHA-256 `99ef9e1ad9efbb6944593116c690b2e83da159b416e217f1ee93dc0a643bc1cf` |
| Root independent review,failed-only orchestration | Accepted strict1479-file current test-source binding,separate83runtime/package identity,exact eight-path tooling/test delta allowlist,ten real Git/event controls including production-Dart refusal,retention of actually passed low-level audio stages and unchanged canonical compiled-meeting test/default2400-second gate timeout |

The source tree of author fixture commit11c154e exactly equals integrated03ee17b3.
Its complete desktop package ran552passed/17explicit skips at93.679074%,with
analysis and changed-file formatting clean. This is scoped fixture verification
using the qualified83native/helper and private display; it is not a new native
or Release compilation. Actual compiled meeting/GPU and full Mac UI evidence
remain separately required. Full current Python Quality at6ff passes5,564/31
at95.820505% combined coverage,independently reviewed by root.


## Final asynchronous export fixture review at `dfeb202d`

The actual compiled meeting r7 failed when the unchanged content matcher received
`Future<String>` rather than its resolved markdown. Root traced the production
export API through `meetingMarkdown` and `readMeetingExport`; the independent
verification reviewer audited the entire fixture and confirmed every other
future is awaited, deliberately retained and joined, or synchronous by contract.
The one-line `await` preserves the original matcher, ordering and failure behavior.

Author commit `b75801e` and integrated `dfeb202d` have identical full Git trees.
The full package passes 552 tests / 17 documented skips at 93.679074%, with
analysis and formatting clean. Resolved analyzer evidence covers all three
integration files: one original Future-valued matcher argument, zero after the
correction. The independent report is
`/var/tmp/of-pr7/meeting-await-review-r1.json`; package proof is
`/var/tmp/of-ma-checks-r1/qualification.json`.

Claude round 10 reviewed exact `dfeb202d`, exited 0 and reported no actionable
findings with scope convergence. Output SHA-256 is
`9d0ae64c67a97a62fdac618744bce2a75d3dff254d9a78f9b897ed8216fd2023`.
The compiled meeting must still complete; these source/package reviews do not
turn its original failed run into a pass. Successful software GPU qualification
is retained independently: real Whisper on lavapipe passes, LiteRT GPU is an
explicit unattempted skip and physical GPU is unverified.

## Current-read observation fixture batch

Compiled Linux meeting attempt r8 at `dfeb202d` reached the source-refresh
checks and correctly rejected a noncurrent projection. The frozen test-only
batch `a2f7d987` observes direct and composite read readiness through the existing
60-second workflow deadline. Strict `currentRead`, composite revision matching
and the four existing polling sites are retained; graph save, export and other
mutations stay outside observation retries. Independent review found no actionable issue. A byte-bound AST audit preserves
146 expected-value/matcher expressions, command/export order, four existing
polling sites and strict read helpers; all 31 observed sites are read-only. Full
package analysis, formatting and 552 tests passed with 17 documented skips at
93.679074% coverage. The author tree equals integrated `0ec8ea49`;83 native and
helper inputs were explicitly reused and remained unchanged. These checks are
fixture qualification, not evidence that the actual workflow passed. Failed-only
compiled meeting attempt r9 subsequently passed 1/0 with the original deadline,
current0ec8 fixture source and unchanged83runtime; runtime qualification is
recorded separately in the execution record. Claude round11 reviewed exact
0ec8 and found no actionable issue. It confirmed error propagation, read-only
callbacks, one unreset deadline, preserved expected assertions and stricter
graph currentness. Output SHA256: `3700e1230347cc2093ca34dd654db2ea94cc508a0ec555a92519a4196b49cdbb`.
