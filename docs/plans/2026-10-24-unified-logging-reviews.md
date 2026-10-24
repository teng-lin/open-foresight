# Unified logging plan review record

Status: historical input review. The revision-6 design has been incorporated
in the [single combined implementation plan](2026-10-24-repository-remediation-plan.md#stage-b-diagnostics-and-support-f4f19).
Current review status belongs in the [combined review record](2026-10-24-repository-remediation-reviews.md).
The six-round history below is preserved; its old one-PR-per-package and file-cap
assumptions are superseded by the user's current one-PR/size-waiver instructions.

The [implementation plan](2026-10-24-unified-logging-plan.md) covers a common
diagnostic event contract, bounded storage/delivery, Dart and native integration,
and implementation acceptance. This record retains independent planning reviews
and dispositions. It is not implementation or runtime acceptance evidence.

## Review baseline

- Checkout: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`.
- Pre-existing untracked `docs/audit/2026-10-24-repository-review.md` is preserved
  and is not an implementation prerequisite.
- Three native agents review service architecture, native ownership/processes,
  and privacy/storage/testing. Claude CLI provides a fourth independent review
  using only Read/Glob/Grep tools and no MCP integrations.
- Frozen revisions, prompts, complete CLI stdout/stderr and review responses are
  retained privately under `/var/tmp/of-logging-review-20261024`.
- Convergence requires all four reviewers to find no unresolved substantive
  issues on the same complete plan revision and SHA-256.

## Round 1

Revision 1 SHA-256:
`0c42216dcdcddaefbeb9c7538f19f8ddfd3aa39c7a763d748291447965a6f25c`.
All reviewers read the complete frozen revision. Its hash was computed by the
coordinator before and after review; Claude's read-only tools cannot compute
hashes. Claude CLI 2.1.309 completed successfully with model `claude-opus-5-5`;
its full result and limitations are retained in `round-1/claude-stdout.json`.

| Reviewer | Verdict | Substantive findings |
| --- | --- | --- |
| Native service | Changes required | Writer shutdown can prevent natural process exit; shared vendor/application stderr has no trusted origin |
| Native process ownership | Changes required | Shared stderr cannot distinguish application events from vendor bytes |
| Native privacy and storage | Changes required | Unspecified advisory locks permit same-process lock release/probe races |
| Claude CLI | Changes required | Short-lived sessions evict service failures/exhaust slots; lock primitive; unsupported native log keys; presentation stderr; adopted-helper/stalled-parent diagnostics |

### Revision 2 dispositions

All substantive findings were accepted and checked against current source:

1. **Writer shutdown:** `bin/service.dart:177-186` and `bin/mcp.dart:182-195`
   rely on natural return; desktop has direct quit. Revision 2 assigns a
   coordinator-owned session, independent 500 ms watchdog, idempotent close on
   every exit path, forced writer termination and compiled natural-exit tests.
2. **Mixed stderr:** `services/inference/main.cpp:589-590` merges vendor stdout
   into stderr. Revision 2 discards all shared diagnostic bytes, including valid
   event-shaped JSON, and records parent-derived numeric/category observations.
3. **Lease semantics:** `service_ownership.dart:68-72` documents the same-process
   POSIX lock hazard. Revision 2 specifies independently opened nonblocking
   `flock` leases on both platforms, permanent lock files, descriptor-based
   operations, CLOEXEC/fd relocation and candidate lease retention through reset.
4. **Retention and service priority:** service startup can contend/retry;
   desktop can forward then quit; MCP and admin commands are separate short
   processes. Revision 2 excludes admin/forwarded launches from persistence,
   admits desktop/MCP lazily, reserves role slots and protects the latest failed
   service session for seven days. Acceptance includes 20+ short launches.
5. **Native compatibility:** `platform_services.dart:488-528` and
   `native/foresight_native.cpp:1934-1951` have separate allowlists and a sealed
   runtime. Revision 2 negotiates optional diagnostics before logging-only
   native keys, preserves required-key failures/seal rules, and disables only
   diagnostics for compatible older libraries. Package 2 remains usable before
   the native work lands.
6. **Presentation channels:** verified parser, crypto, audio, notifications,
   platform tools and dedicated-query callers use stdout/stderr as results or
   user-facing errors. Revision 2 adds an explicit routing table and preserves
   these channels, tails and timeouts without persisting their messages.
7. **Adopted helper and backpressure:** `helper.dart:211-231,390-392` adopts
   helpers without stdio; current HelperControl State already exposes bounded
   counters, pipeline/index/readiness. Revision 2 uses validated projections of
   that state after adoption and excludes raw last_error/model/instance values.
   Diagnostic-only child write ends are nonblocking, owned writes drop on
   EAGAIN/EPIPE, and acceptance covers stalled parents and adopted failures.

Optional suggestions incorporated: writer sequence is serialization order;
`off` consumes no slot/writer; bounded caller-owned native drain ABI; both native
configuration allowlists; bootstrap storage independent of the application
native library; process-lifetime native queue without destructor races; desktop
Retry initialization is idempotent; startup status and OS crash reporting remain
after retiring macOS free-text capture.

No application tests/builds were run for planning. Initial document link and
whitespace checks passed; implementation acceptance remains future work.

## Round 2

Revision 2 SHA-256:
`7f3b96322a06c8aa7399eab23a9dcb140b4eda01a5b9cf7a46f997f5dacac51e`.
The coordinator froze the complete 541-line plan before review. Source and the
pre-existing untracked audit file remain unchanged against the recorded manifest.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native service | Converged | Both prior findings resolved; no substantive findings across the full revised interfaces |
| Native process ownership | Converged | Shared-stream policy, native ABI/configuration, nonblocking drains and adoption are adequately specified |
| Native privacy and storage | Converged | Lease semantics, off-mode admission, storage/privacy/failure acceptance are adequately specified |
| Claude CLI | Changes required | Blocked FFI shutdown, helper supervisor flags, service-candidate contention, native desktop quit, errno/variadic bindings |

Native optional notes do not require a design change: the inventory table's
"validated events" refers to control-state projections under the explicit
routing table, never parsing mixed stderr. Seven days is expiration priority and
failed-service protection with opportunistic cleanup on admission, not a promise
of timed erasure when no process requests admission. Implementation user docs
must preserve those meanings.

Document checks on the frozen revision passed: five relative links and referenced
anchors resolve, neither new document has trailing whitespace, the plan matches
its frozen bytes, and all 14 source/audit fingerprints match their baseline.
No application build, test suite, live model/audio/GPU, or macOS acceptance was
executed for this documentation-only task.

### Revision 3 dispositions

Claude's second invocation completed successfully and read the entire frozen
revision. It confirmed all round-1 findings resolved, then reported five further
substantive issues. All five are accepted, with these specific resolutions:

1. **Blocking writer:** descriptor-anchored file operations are synchronous
   system-libc FFI, so `Isolate.kill` is not an interrupt guarantee. Revision 3
   states this explicitly. Once existing application/client/child teardown has
   completed, standalone service/MCP use explicit `exit(exitCode)` if the logger
   does not confirm exit within 500 ms. The process stays running normally on
   logger failure while the application remains active. Dart's documented
   [exit](https://api.dart.dev/dart-io/exit.html) and
   [kill](https://api.dart.dev/dart-isolate/Isolate/kill.html) contracts support
   this distinction. Application cleanup is not bypassed.
2. **Inherited stderr:** the proposed poll-before-write mitigation is insufficient
   when another writer fills a blocking pipe after the poll, and changing flags
   on inherited fd 2 changes shared state. Version 3 defers automatic stderr
   mirroring and adds no logger stderr bootstrap/fallback writes. Version 1
   product sinks are persistent files plus bounded in-memory health; intentional
   CLI output is preserved. Pipe semantics were checked against the
   [Linux pipe contract](https://man7.org/linux/man-pages/man7/pipe.7.html).
3. **Helper modes:** `services/helper/main.cpp` handles build-id and supervisor
   mode before the socket/storage server branch. Only that server branch may
   make its diagnostic stdout/stderr nonblocking. Build-id output and supervised
   protocol stdout remain untouched, with explicit fd-flag acceptance tests.
4. **Service candidates:** `acquireServiceProfileLock` rejects contention and
   withdrawn launches. A candidate has lazy shared-slot eligibility until that
   method succeeds, including its withdrawal check. Only a real owner receives
   reserved slots and failure-protection eligibility. Contended/withdrawn exits
   are info outcomes and cannot replace a real failed owner's protection.
5. **Desktop termination:** the direct startup/forward quit callback remains a
   VoidCallback adapter around bounded asynchronous close-and-exit. Native GTK
   window/macOS menu/window termination has no new Dart flush hook and can lose
   recent unflushed records. Acceptance distinguishes these paths instead of
   promising a finally block on native termination.
6. **FFI status:** storage safety no longer depends on decoding errno after a
   Dart FFI call. Generic unavailable health and bounded retries cover failed
   lease attempts; failed/short writes disable persistence. Precise OS codes
   require reliable capture at the syscall boundary. The pinned-platform ABI
   proof must cover variadic open/openat/fcntl signatures and `VarArgs`, checked
   against the [Dart declaration contract](https://api.dart.dev/dart-ffi/VarArgs-class.html).

Optional notes incorporated: closed diagnostic mappings for free-form helper
state strings; local-filesystem qualification with NFS/SMB refusal; one process
registry prevents same-process slot probing; canonical native environment values
overwrite raw invalid level input on capable runtimes; cleanup semantics and
table wording clarified.

The source checkout advanced after round 2 to
`ae9170830ca115cb40a44ad7e9ade8714a170bec` (#178, 17 changed files). The delta
adds Google/Granola provider switching and calendar sign-in fixes; logging,
native launch and core lifecycle source files are unchanged. Revision 3 adds the
new auth paths to privacy/inventory acceptance. A complete Git archive of this
head is frozen at `/var/tmp/of-logging-review-20261024/source-round-3`; reviewers
use that source export rather than a potentially moving working tree. Existing
untracked audit documents and other task output are preserved.

## Round 3

Revision 3 SHA-256:
`d03de6ad0917964270c531ed77ed4284601291e3e9713d7eb8e3342c971b8495`.
Source archive SHA-256:
`591cce5bf32fbd9e6c91d0698ba7cc1b0d25ca45584643bfd9863812b15bdb48`.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native service | Converged | No substantive findings or optional suggestions |
| Native process ownership | Converged | No substantive findings or required optional changes |
| Native privacy and storage | Incomplete | No completed round-3 response recorded; superseded by a fresh round-4 review, not counted as approval |
| Claude CLI | Changes required | Cross-isolate ownership ordering/classification, desktop pending-quit UI, presentation flushing before forced exit |

Claude confirmed all five previous substantive findings resolved. Its full
successful CLI result and complete text are retained in `round-3/`. The three
new findings were verified against the frozen source and accepted:

1. **Worker ownership outcome:** acquisition happens inside ApplicationService
   in the Domain worker, and the old failure tuple preserves only contention.
   Revision 4 gives the worker one reserved, bounded, non-credit ownership
   decision on its diagnostics port; the writer alone applies role/protection
   after classifying buffered cross-producer errors. Close cannot race ahead of
   classification without the logging deadline expiring. The operational failure
   tuple gets a closed kind while existing exit/status/retry behavior stays
   unchanged. Tests explicitly reorder frontend errors, ownership and close.
2. **Pending desktop quit:** replacing a synchronous exit with an asynchronous
   adapter lets `start` finish and its finally render the null failure/Retry
   screen. Revision 4 adds a quitting state/progress view and disables start,
   Retry and socket binding until exit, including calendar-auth forwarding.
3. **Presentation before exit:** explicit Dart exit can truncate pending stdout/
   stderr. Revision 4 flushes MCP transport and intentional presentation output
   during ordered teardown, before starting the final 500 ms logger budget.
   Closed/broken output sinks retain their existing error policy. Complete final
   response/error bytes are required under a stalled logger.

Optional findings incorporated: trace-enabled test harnesses retain this run's
JSONL/health alongside captured subprocess output; Dart-launched helpers receive
canonical launch-level overrides separately from native environ; resolved Dart
isolate configuration preserves legacy alias precedence; package 0 must execute
the compiled forced-exit/blocked-FFI/destructor fixture on supported toolchains.

## Round 4

Revision 4 SHA-256:
`725c5936e153b5c7bbff9608c68d780f441e4258f6b14ea9ee005fa38e0ef40f`.
The final three native reviewers received no parent conversation history and
did not consult peer/Claude reports. Initial inherited-context review tasks were
interrupted and replaced before their results were used.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native service | Converged | No substantive findings |
| Native process ownership | Converged | No unresolved substantive findings |
| Native privacy and storage | Converged | No substantive findings or optional suggestions |
| Claude CLI | Changes required | One early-worker-failure decision/termination gap; all round-3 findings resolved |

Claude's report explicitly notes it did not reopen AGENTS/CONTRIBUTING during
this round. This limitation is retained; no review approval is inferred from
that invocation. The next prompt requires both source-export instruction files
to be read and their relevant requirements identified.

### Revision 5 dispositions

The remaining finding is verified: environment installation,
`acquireInstallationLock`, and `retainLocalServiceOwner` can fail before
`acquireServiceProfileLock` is called. A guard only at the latter call leaves a
healthy writer waiting for a nonexistent decision and unnecessarily takes the
500 ms forced-exit path.

Revision 5 registers the guard before worker spawn, enters it before worker
environment/profile setup, and threads its bounded callback to the actual lock
site. Controlled pre-lock failures emit `failed_before_lock`; an already sent
decision is never replaced. Worker failure/exit/unregister without a decision
promptly finalizes an unknown candidate, preserving natural exit with a healthy
writer. Session-owned reserved control records survive data-producer unregister
and are processed before final-close acknowledgement; controlled completion is
ordered on the same control port. `other` without acquisition never grants owner
failure protection. Acceptance adds installation-update lock refusal, environment
and local-owner setup failure, and unregister-before-control-consumption cases.
Existing presentation, status/exit code and cleanup behavior remain required.

## Round 5

Revision 5 SHA-256:
`81e0140a6391564ca678c56d01847cb8a4d944dbbd6722c0ddf870560b90ed17`.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native service | Converged | No substantive findings |
| Native process ownership | Converged | No substantive findings or optional changes |
| Native privacy and storage | Converged | No substantive findings or optional suggestions |
| Claude CLI | Changes required | One parent-side pre-spawn guard placement clarification; all worker-side round-4 cases resolved |

Claude read both exported instruction files in this round and identified the
applicable gates and evidence rules in its report. The remaining finding is
accepted: frontend `privateRuntime` and `retainLocalServiceOwner` run before
`Isolate.spawn`; a guard installed merely just before spawn can miss them.

Revision 6 explicitly registers the guard at entry to
`IsolatedApplicationService.start`, before all runtime, host/port and local-owner
setup, and encloses setup currently outside the original try. Parent-side throws
before successful spawn promptly finalize a non-owner candidate without waiting
for worker notifications. A session that never begins a launch/guard has no
pending ownership decision. Frontend-site fault injection is required alongside
worker-site tests. This clarifies placement of the existing mechanism; it adds
no new authority or channel. Optional CONTRIBUTING reminders name
`pytest-exclusions.json`, discovery and Dart temp/teardown helpers.

All five relative links/anchors and whitespace checks passed. The final source
export was verified file-by-file against its archive: 1,488 files/symlinks match.
These are document/source integrity checks, not application test execution.

## Round 6

Revision 6 SHA-256:
`c5a480bc07d2eb78e550a3e9a9eab263e3bf34f63caea1942474137010392337`.
Source remains `ae9170830ca115cb40a44ad7e9ade8714a170bec`, with the same
source archive/export identified above. All four reviewers read the complete
revision and report no unresolved substantive findings on these frozen bytes.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native service | Converged | No substantive findings |
| Native process ownership | Converged | No substantive findings or optional changes |
| Native privacy and storage | Converged | No substantive findings or optional suggestions |
| Claude CLI | Converged | Prior finding resolved; no substantive contradictions or gaps |

Claude read both instruction files and identified the required gates in its
final report. Its read-only tools still cannot compute a hash; the coordinator
verified its supplied frozen plan hash before/after review and against the final
repository file. This is not a claim of independently executed hashing by Claude.

Claude's sole optional wording note needs no design revision: the ownership
decision/unknown-candidate discussion is scoped to service candidates. Desktop
and MCP sessions have no service-ownership decision; their errors follow the
ordinary lazy admission policy. Implementation must preserve this distinction.
The reviewed plan remains byte-for-byte frozen rather than changing it after
approval for an editorial clause.

The six-round review process has converged. Full final reviews are retained in
`/var/tmp/of-logging-review-20261024/round-6/` as
`native-service-review.txt`, `native-native-review.txt`,
`native-privacy-review.txt`, and `claude-review.txt`; complete CLI stdout/stderr,
prompts, per-round plans/hashes and source archive remain alongside them.

Only the plan and this review record were created by this task. No implementation,
build, application test suite, real model/audio/GPU, macOS acceptance, issue/PR,
commit, push or deployment was performed. Document links/anchors, whitespace,
frozen hashes and source-export integrity were checked; those checks are not
runtime acceptance.
