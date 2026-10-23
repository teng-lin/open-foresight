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
