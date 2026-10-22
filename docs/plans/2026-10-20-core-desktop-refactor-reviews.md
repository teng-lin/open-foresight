# PR 6 and PR 7 plan review record

The user requested refreshing both planned refactors, a comprehensive execution plan, and repeated review by the native agent team and Claude CLI until convergence. This record concerns planning review, not implementation verification.

Current refresh: revision 11, October 21, 2026, uses freshly fetched main
`3fb259243a99137e3cba1d5e795c44100f42e688` (#168, after release 0.1.3). Rounds 1–8 and their validation
statements below are historical snapshots; the latest requested review and verdicts are in rounds
9–12 at the end. Planning convergence never substitutes for changed-source implementation gates.

Documents under review:

- [Execution plan](2026-10-20-core-desktop-refactor-plan.md).
- [Refreshed audit plan 3](../audit/2026-10-18-implementation-plan-3.md), PRs 6 and 7; PR 8 remains deferred.

Original code baseline (revisions 1–3): ADR-0007 integration `codex/pr159`, full commit `fea1fe93ea1a2b65145bd3a46a811cc62ee6aa56`, ADR revision 7. Main baseline: `02d572fbd66022bb125d188dfa296ba7f2bf85bc`. That original reconciliation prerequisite is superseded by the moved-main refresh recorded below.

Three native reviewers independently audited core contracts, desktop boundaries and verification/data integrity before the draft. Claude CLI 2.1.304 reviews independently through Read/Glob/Grep only, with shell, editing and MCP tools unavailable. No external comments or reviews are published. Native reviewers independently verify hashes; the author freezes and checks hashes before/after Claude's review, and Claude is not credited with computing a hash.

Raw prompts, frozen documents and verbatim reviews are retained at `/tmp/foresight-pr6-pr7-review-y6m24hf6/`. This temporary directory is supporting session evidence; durable revision hashes and dispositions are recorded here.

## Round 1

| Document | SHA256 |
| --- | --- |
| Execution plan revision 1 | `62a70af2d2a0d2420fe4a53797599c85dbba683b947db3e13dab553dc1a7bb18` |
| Refreshed audit plan | `5271fec31396ac08d11ad8cad3717f0dd4e0dfa27e7ddb7830d93965f211be04` |

| Reviewer | Verdict | Actionable findings |
| --- | --- | --- |
| Native core | Changes required | C1: define cross-connection snapshot identity. C2: preserve persisted raw-argument idempotency digests through typed decoding. |
| Native desktop | Changes required | D1: define authoritative connection-local revision ownership, consistent multi-query snapshots and revalidation. |
| Native verification | Changes required | V1: bootstrap the migration guard from verified reviewed-main source, then use the main manifest; define location-only relocation. V2: UI prerequisite must name the pinned Flutter SDK CLI. |
| Claude CLI | Changes required | Eleven actionable findings, summarized below; one optional historical-reference note. |

All native findings are accepted. Claude's actionable findings are also accepted:

1. Freeze migration-private copies of historical helper closures so live label/query changes cannot alter old migrations, with an executable trusted-input guard.
2. Decide validation/approval ordering explicitly and test malformed requests without approval events.
3. Preserve raw idempotency fingerprints and replay pre-upgrade key records.
4. Correct the Flutter CLI variable, add root native and host Python stages, pin the coverage interpreter and retain container dependency/software-rendering settings.
5. Assign the service split to an explicit step with lease/lifetime/relay characterization.
6. Choose `NoteEnhancementCoordinator` to distinguish it from existing Domain enhancement code.
7. Define registry membership by dispatch owner, allowing application implementations of service-owned streams.
8. Use existing `tools/pins.json` and resolved grpc/http2 lock versions.
9. Preflight all helper databases read-only before writes, and cover profile migration tools/contracts.
10. Distinguish the service read worker from the desktop's direct read-only reader isolate.
11. Spell out `packages/foresight_core/bin/` in literal guards.

The optional note is accepted: retained PR 8/process/Windows references are historical until that work resumes. PR 8's retained body is unchanged.

Revision 2 uses verified reviewed-main **source** for the first manifest bootstrap, migration-private helper copies, canonical historical bodies with checked symbol/location mapping, then main-manifest prefix enforcement after merge. This resolves the guard contradiction without Claude's suggested extra manifest-only PR or a semantic hash override. Historical fixture behavior and preserved canonical executable bodies are both required; neither alone is treated as sufficient proof.

Native reviewers provisionally checked prepared corrections before the formal second pass. Claude completed 121 turns of source/plan inspection; its first pass also consulted the companion review record, so this round was independently source-checked but not blind to native findings. It did not run a shell, compute hashes or execute tests. The author verified frozen revision-1 hashes unchanged after all reviewers finished.

## Round 2

All reviewers receive the same complete revision 2 and refreshed inventory. Claude receives only its own previous review and the revised documents/diffs, with an explicit instruction not to read the companion record or other reviewers' reports.

| Document | SHA256 |
| --- | --- |
| Execution plan revision 2 | `d6297b7739dcd9648b31c719d47cdc147d529d4cca9269a63cee52da19e6cf6a` |
| Refreshed audit plan | `be0d9689cfb43b55ca24eedc344c4694f1fd7db188dfdb41a2d1764e51b192dc` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete docs read and hashes independently verified; C1/C2 resolved; no actionable core gaps. |
| Native desktop | Converged | Complete docs read and hashes independently verified; D1 resolved; no actionable desktop gaps. |
| Native verification | Converged | Complete docs read and hashes independently verified; V1/V2 resolved; no actionable verification/data gaps. |
| Claude CLI | Changes required | All first-round findings resolved; four new planning gaps, accepted below. |

## Round 2 dispositions and round 3

Claude confirmed all first-round findings resolved, including the alternative source-bootstrap and location-independent historical-body design. Its second pass found four remaining issues, all accepted:

1. A discard-on-every-token-change reader can starve during recording/autosave. Revision 3 separates identity safety from freshness: same-identity consistent previews publish after one completed read, are not cached as current, and schedule one coalesced refresh. Identity mismatches still discard. Tests require final current data once writes stop, bounded caller deadlines, tracked underlying reads and no overlapping replacement workers.
2. Hash units are per schema version and its historical closure, including inline and shared switch cases; registry/version-loop/current-maximum metadata is excluded.
3. After first introduction, CI executes the reviewed-main extractor/canonicalizer against candidate code. Tooling changes must pass the old checker and negative tests; initial-tool bootstrap review limits are explicit.
4. The service split is required consistently in both the step and acceptance wording.

Accepted optional clarifications include historical DTO/palette dependencies, CI resolving the trusted source SHA, and replay remaining after authorization. Paragraphs are now wrapped for complete inspection by review tools; the deferred tail is unchanged.

| Document | SHA256 |
| --- | --- |
| Execution plan revision 3 | `692b5ddaf129547667bd7fe2697fe37b564247c146338f08a65fa68ea26e3a52` |
| Refreshed audit plan | `676f92c9fd03bf283f47f50f229d34ea05f89b203d3ae510df7cd889fd76aa65` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete docs read; hashes verified before/after; no actionable core gaps. |
| Native desktop | Converged | Complete docs read; hashes verified before/after; no actionable desktop gaps. |
| Native verification | Converged | Complete docs read; hashes verified before/after; no actionable verification/data gaps. |
| Claude CLI | Converged | All round-2 findings resolved; complete documents and dependent source contracts checked; no actionable gaps. |

The native desktop reviewer suggested naming a stable scheduling key separately from versioned cache tags as optional implementation clarity. The existing sustained-write requirement of one active/one pending refresh already enforces that distinction; it is not a deferred correctness blocker.

## Validation status

Documentation-only task. No implementation builds, application tests, CI dispatches, artifact publication or merges have been performed. Document validation passed: all 12 relative links/anchors resolve, no trailing whitespace, the executable shell example passes `bash -n`, the retained deferred PR 8/process/Windows body is byte-identical to the first frozen revision, and revision-2 hashes remain unchanged. `git diff --exit-code` confirms no tracked source/workflow changes; pre-existing unrelated untracked documents remain. Final revision-3 validation repeats these checks successfully. All four reviewers converged in round 3. The author verified the final document hashes unchanged after Claude completed; all three native reviewers independently verified them before and after their complete reviews.

## Completion

Revision 3 converged after three formal rounds with three native reviewers and Claude CLI. All report no unresolved actionable planning findings on execution-plan SHA256 `692b5ddaf129547667bd7fe2697fe37b564247c146338f08a65fa68ea26e3a52` and inventory SHA256 `676f92c9fd03bf283f47f50f229d34ea05f89b203d3ae510df7cd889fd76aa65`. Claude's final pass took 10 turns, read both documents completely, and checked dependent source contracts; its read-only tools did not compute hashes or run tests.

Claude's optional implementation notes cover the historical rows adapter, proving any future digest-format conversion against verified bodies, explicitly naming the existing busy wire code, and an alternative late-read preview policy. They are not convergence blockers; revision 3 keeps the stated late-reply policy and no digest-format change is authorized by default. Native optional scheduler-key wording is likewise covered by the required sustained-write concurrency tests.

Deliverables are the refreshed PR 6/7 inventory, the comprehensive execution plan and this review record. No application implementation, dependency rebuild, runtime acceptance, external publication, commit or push is claimed. The full CI/platform matrix remains mandatory when implementation begins.

## Main refresh — 2026-10-21, revision 4

The user requested updating the implementation plan for moved main and explicitly reaffirmed native
team plus Claude CLI review and revision. `git fetch --no-tags origin main` resolved current remote
main to `c28a1561b5091645718462169bc6c0cfd0040943`; the working checkout remained at
`053673dd` to avoid changing shared application files. All new code facts were checked against a
complete immutable `git archive` export of the fetched commit at
`/tmp/foresight-refactor-main-refresh-xxen4ash/source`, not against the older checkout. This is
source inspection in a Git-free export, not an executed archive test suite.

Source delta since the original ADR baseline: ADR-0007 merged in #164, CI routing/cache work #163,
Summary #165, meeting AI workflows #166 and release 0.1.3/GPU policy #167. All three native reviewers
first audited their relevant deltas. Required plan corrections are incorporated:

- Remove the completed ADR reconciliation prerequisite and pin reviewed main as implementation
  source, with a fresh-main check before implementation.
- Freeze migrations 1–15, retain already delivered 14/15 tables/data transforms, allocate the next
  free version from 16, and note the architecture migration table's lag behind code.
- Count all Application parts and the new desktop AI view part; add independent Summary/workflow
  ownership while preserving generation reservations, foreground yielding, owned-child cancellation,
  atomic accepted outputs, manual tasks, cache identities and scoped-answer privacy.
- Expand descriptors, narrow readers, UI extraction and regression anchors for shipped Summary,
  Actions, Preparation, Enhanced Notes, Live Q&A and scoped Chat; characterize unproven stale-dialog
  and scope/clear/reconnect races separately from mechanical moves.
- Preserve existing runtime gate commands (three runner scripts are byte-identical), enforce
  Python 95% and Linux core/desktop 90%, and account for #163's real test owners/routing.
- Preserve #167's default physical-GPU requirement and explicit per-invocation waiver without
  weakening automated installer/byte/provenance acceptance or performing release work.

| Document | SHA256 |
| --- | --- |
| Execution plan revision 4 | `77e87f558bcb5cf54d2155b9f80da249a90f7596aed9618964bcb179ff94562d` |
| Refreshed audit inventory | `1630b9b26c1a72addbc0e6515be2b994d080f562f0e8d929fdff64b02064ec2c` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents/source delta checked; hashes verified before/after; no actionable gaps. |
| Native desktop | Converged | Complete documents/source delta checked; hashes verified before/after; no actionable gaps. |
| Native verification | Converged | Complete documents/source delta checked; hashes verified before/after; no actionable gaps. |
| Claude CLI | Changes required | Four source-grounded corrections; dispositions below. |

Prompts, baseline metadata, source export, before/after documents and full reviews are retained at
`/tmp/foresight-refactor-main-refresh-xxen4ash/`. Claude has Read/Glob/Grep only and is instructed
not to consult the companion record or native reports. Planning review is not runtime validation;
no application builds/tests, CI dispatches, merges, publication, commits or pushes were performed
for this refresh.

Refresh document checks passed: 11 relative links/anchors resolve, no trailing whitespace, the
shell example passes `bash -n`, both revision-4 hashes remain frozen, and the deferred
PR 8/process/Windows tail is byte-identical to revision 3. No tracked source/workflow files changed.
Revision-4 document checks passed; its four new findings are resolved in the next revision below.

### Refresh revision 4 findings and revision 5 dispositions

Claude independently inspected the frozen plan and current source and found four corrections that
all native reviewers had missed. All are accepted and checked against the cited current code:

1. Preserve internal `questions` generation as a distinct generic transcript-window/plain-artifact
   path, owned by the meeting coordinator with its existing gating. It gets no Summary checkpoint,
   manifest or derived source and remains absent from MCP's narrower schema.
2. Source deletion is soft deletion/revision bump. Preparation cache rows remain physically stored;
   captured revision/content keys and source deleted/revision revalidation prevent reuse. Workspace
   clear removes the rows. Correct the plan and note the architecture prose discrepancy; adding
   purge-on-soft-delete is a separate product/privacy decision, not a refactor.
3. Preserve task-key presence through DTOs: owner/due absent retains stored values, null clears;
   task null falls back to stored text while key presence still marks a manual-details edit.
   Status-only edits retain details. Explicit request/row fixtures cover these cases.
4. Migration 15 normalizes every legacy action-items artifact, whether edited or unedited; preserve
   both upgrade paths.

Optional wording now distinguishes the transcript plus four derived artifact source IDs, and names
Granola in integration acceptance. The source is unchanged, so follow-up reviews reuse prior source
evidence while checking the complete revised plans and dependent contracts.

| Document | SHA256 |
| --- | --- |
| Execution plan revision 5 | `b61331649dc7564bee66aa29985e039a685723d7f079c4c3e8ea754aace9a7e0` |
| Refreshed audit inventory | `9e4bdddcfafbac3fe15379cf73c34eb57f0990d4f1438276f871ed4a4973fe41` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents and corrected source contracts checked; hashes verified before/after; no actionable gaps. |
| Native desktop | Converged | Complete documents and corrected source contracts checked; hashes verified before/after; no actionable gaps. |
| Native verification | Converged | Complete documents and corrected source contracts checked; hashes verified before/after; no actionable gaps. |
| Claude CLI | Converged | All four revision-4 findings resolved; complete documents and dependent source checked; no actionable gaps. |

### Refresh completion

Revision 5 converged after two refresh review rounds, with all three native reviewers and Claude
CLI reporting no unresolved actionable planning findings. This supersedes revision 3's source
baseline and implementation scheduling, while retaining its still-valid design contracts. Claude's
follow-up checked the complete revised documents and targeted source in 14 turns; it did not hash
files or execute tests. The author rechecked both frozen document hashes after Claude completed;
all native reviewers independently verified them before and after review.

The three unchanged gate-script claims were also independently rechecked by the author with direct
byte comparison of `git show fea1fe93:<path>` against the pinned c28 source export. SHA256 values:

| Script | SHA256, identical at both baselines |
| --- | --- |
| `tools/build_dart_gates.sh` | `abaa382b4163b4f7139780d1ef23cb74ee9b88c973aaed0fa7d8189cbeb24fa4` |
| `tools/build_service_gate.sh` | `82601e8cc78b70fb7f8721e5910d705e37984f33c4bd211586d2f830034639d3` |
| `tools/linux_container_test.sh` | `23f08672f0f017f96015d0c9cb009a28e4299882807ec22e80ec299c8b7d65f6` |

Final document checks cover links/anchors, whitespace, shell syntax, frozen hashes and unchanged
PR 8/process/Windows text. The shared application checkout is unchanged. No runtime tests, builds,
SDK rebuilds, CI dispatches, release waivers, publication, commit or push is claimed. All runtime,
coverage, native/process/UI and hosted platform gates remain implementation requirements.

## Combined-delivery review, 2026-10-21

The owner authorized full work packages 6 and 7 as one PR, exact-source HanSolo Mac testing,
separate native-team and Claude CLI implementation review, and driving the PR to merge. This
round reviews that revised execution plan before implementation. Fresh fetch and remote-ref
checks still identify main as `c28a1561b5091645718462169bc6c0cfd0040943`; the complete immutable
source export from the prior refresh remains valid. No production changes or runtime validation
are claimed here.

### Revision 6

Reconciled the execution plan and audit inventory: one integration branch/PR, core-before-desktop
commit order, both acceptance sets, exact tested Linux/Mac source identities, and postimplementation
review distinct from planning approval. Removed the stale intervening-merge requirement.

| Document | SHA256 |
| --- | --- |
| Execution plan revision 6 | `0a344eba73aa6b84ecfd964dfd25c46068f85b44efa54b5275d60c92cbfec75a` |
| Audit inventory | `b93ee9a4fbf2f231358e5d07b85e96349659d34260477b6772c0563b5c7fab59` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents and relevant source checked; hashes verified before/after. |
| Native desktop | Converged | Complete documents and relevant source checked; hashes verified before/after. |
| Native verification | Converged | Complete documents and relevant source checked; hashes verified before/after. |
| Claude CLI | Changes required | Two actionable findings, accepted and independently checked against source. |

Full frozen documents, prompt, raw Claude stream/stderr, all native reports and document validation
are retained at `/var/tmp/foresight-plan-r6-review-_g3wk3lt/`. Claude had Read/Glob/Grep only and
was instructed not to consult other reviewers or this record.

Accepted findings and revision-7 corrections:

1. A combined PR's final head does not identify an independently tested core completion point.
   Revision 7 requires a post-main-refresh `core_acceptance_sha` after 6A–6E, with the complete
   applicable Linux matrix before 7A production extraction. Later rebase/main integration
   invalidates that checkpoint until the updated core completion commit passes again. The final
   combined head requires the complete Linux and HanSolo Mac matrices; Mac is not required at the
   intermediate checkpoint. Record both source identities and their evidence.
2. The broad cancellation wording could unintentionally exempt `meetings.cancel_enhance` from
   helper readiness. Source `operations.dart` excludes only the two new cancel operations, and
   `ApplicationService._execute` uses that policy. Revision 7 names those exemptions explicitly
   and preserves `cancel_enhance`'s requirement under parity.

All six optional clarifications were also checked and incorporated: former branch names are
historical; migration-guard bootstrap refers to the initial combined PR; service transport and
desktop reconnect policy retain their respective owners; descriptors distinguish activity
stamping from in-flight busy accounting; `workspace_controller.dart` is explicit in the part
inventory; label-column removal uses a portable transactional table rebuild with integrity tests
and actual SQLite version evidence rather than assuming newer SQLite support.

### Revision 7

| Document | SHA256 |
| --- | --- |
| Execution plan revision 7 | `45a518f1aa1f02ab22d37ec8add1dd8b8ae5bd696f1f388819003e92adf718dd` |
| Audit inventory | `37f2a90a0321c867601c9de8bec962433f3749153571ac4cf0d61aaf2e3d8358` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents/dependent source checked; hashes verified before/after. |
| Native desktop | Converged | Complete documents/dependent source checked; hashes verified before/after. |
| Native verification | Converged | Complete documents/dependent source checked; hashes verified before/after. |
| Claude CLI | Changes required | Prior corrections verified; one low-severity lifetime test/change-note gap. |

Raw complete reviews, frozen documents and validation are retained at
`/var/tmp/foresight-plan-r7-review/`. The additional finding is accepted and directly verified:
`ApplicationService._execute` currently calls `_dispatch` before `Application.call`, whose
idempotency/handler decoders can fail. `_dispatch` stamps eligible agent activity, and `_settle`
stamps it again. Moving decoding into admission intentionally changes malformed-agent activity;
it is not merely preservation of ADR-0007 behavior.

Revision 8 explicitly records this intentional lifetime change, requires a
`service_lifetime_test.dart` regression for `invalidArgument`, no `_dispatched` entry and unchanged
activity at dispatch/settlement, retains valid-request activity tests and requires a PR change note.
ADR-0007's definition of stamping when work starts remains intact.

Optional clarifications are incorporated with the hosted-gate suggestion narrowed to actual host
limitations: record loaded SQLite library identity/version for host tests, bundled Linux and Mac;
name the exact workspace-controller class/back-reference ownership; list Linux gates genuinely
unavailable locally as pending final-head hosted obligations while retaining every runnable local
checkpoint gate. Lack of a PR never turns a runnable sanitizer/container/installer check into a
hosted-only gate.

### Revision 8

| Document | SHA256 |
| --- | --- |
| Execution plan revision 8 | `f19cb665ade217cded11911c73a4af9c46c997de88d9acfab913bf7aae322db3` |
| Audit inventory | `db48252132cf939be965c5c4d509d3a068ea3e09c81ef0837a1fffe9afda26be` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents and dependent source checked; hashes verified before/after. |
| Native desktop | Converged | Complete documents and dependent source checked; hashes verified before/after. |
| Native verification | Converged | Complete documents and dependent source checked; hashes verified before/after. |
| Claude CLI | Converged | Complete documents and affected contracts checked; no actionable planning gap. |

Raw evidence is retained at `/var/tmp/foresight-plan-r8-review/`. The author verified both input
hashes again after Claude completed. Claude's restricted read-only follow-up reused verified
unchanged source facts and traced the affected admission, dispatch, settlement, ADR and test paths;
it did not hash files or execute tests.

Claude's three optional test elaborations are retained as implementation notes, without changing
the frozen converged revision: include the streaming admission branch when exercising malformed
requests; assert malformed activity leaves desktop grace armed; preserve dispatch/stamping for a
structurally valid request whose reused idempotency key has changed arguments. These fit the
existing per-operation decoder, lifetime and authorized-dispatch/writeOnce contracts. They are not
unresolved planning findings or permission to suppress activity for every `invalidArgument`.

### Combined-delivery review completion

Revision 8 converged after three rounds (revisions 6–8). All three native reviewers and Claude CLI
reviewed the same frozen final documents, with no unresolved actionable planning findings. Source
remains reviewed main `c28a1561b5091645718462169bc6c0cfd0040943`, confirmed again with a fresh
remote-ref check. The complete core and desktop scope, PR 8 deferral and existing integrity gates
remain intact.

Document validation passed: all 11 relative links/anchors resolve, shell syntax passes `bash -n`,
no trailing whitespace, frozen input hashes unchanged and the PR 8/process/Windows tail
byte-identical to revision 5. The reviewed plan/inventory/record are synchronized into the isolated
`refactor/core-desktop` worktree. Production code remains unchanged. No runtime tests, builds,
SDK rebuilds, CI dispatches, HanSolo execution, commits, pushes, publication or merges were
performed for this planning review. Implementation, its required runtime gates, postimplementation
review and PR merge remain outstanding under the owner's execution objective.


## Renewed native-team and Claude CLI review: round 9

The owner again requested a native-team plus Claude CLI plan review. A fresh fetch confirmed
reviewed main unchanged at `c28a1561b5091645718462169bc6c0cfd0040943`. Implementation paused at
the new-foundation boundary: production dispatch/admission, Store/helper migration opens and
versions, and desktop consumers remained unswitched. Baseline and new-foundation evidence informs
feasibility; none is final implementation acceptance.

All four reviewers read the complete same frozen revision-8 plan and inventory independently.
Native reviewers checked hashes before and after; the author checked Claude's input hashes before
and after. Claude CLI 2.1.304 had only Read/Glob/Grep, no shell/edit/MCP tools, and did not read
native reports or this record. Verbatim reports, prompt, immutable inputs and manifest:
`/var/tmp/foresight-plan-r9-review/`.

| Input | SHA256 |
| --- | --- |
| Plan revision 8 | `f19cb665ade217cded11911c73a4af9c46c997de88d9acfab913bf7aae322db3` |
| Inventory | `db48252132cf939be965c5c4d509d3a068ea3e09c81ef0837a1fffe9afda26be` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | No actionable planning gap. |
| Native desktop | Changes required | D9-1: preserve diagnosed Hyprland-environment and socket-path prerequisites in concrete gate commands. |
| Native verification | Changes required | V9-1: executable no-mutation WAL/hot-journal qualification; V9-2: durable label order and frozen-v9 preservation limit. |
| Claude CLI | Changes required | Seven findings covering labels, read-schema/preflight safety, helper crash recovery, guard dependencies/bootstrap and desktop-departure grace. |

Revision 9 dispositions:

1. **Accepted V9-1 and Claude 3/4.** Whole-set preflight checks live file/sidecar identities before
   writable opens. Healthy rollback paths may inspect read-only only when non-mutating; genuine
   hot journals require conservative bounded header/applicable original-page-1 qualification, then
   SQLite alone recovers originals. Actual attached commit-boundary and hidden-future tests are
   permanent requirements. WAL qualification uses a stable private DB+WAL snapshot with private
   SHM and cleanup, including WAL-mode images without sidecars. Application writer/tooling opens
   share the protection. Private scratch is outside the original profile file set rather than
   Claude's suggested inside-profile directory, so refusal cannot create a profile entry. Immutable
   is limited to a source-stable sidecar-free qualified image/private snapshot; live query
   connections retain ordinary WAL. Every read-worker transaction checks schema before queries;
   a future schema returns a typed failure, retires coordinator/cache and joins actual settlement.
2. **Accepted V9-2 and Claude 2; accepted Claude 1's historical-loss concern with a different merge
   policy.** Durable ordering is explicit and all label/graph projections order deterministically;
   reorder/VACUUM/reopen tests are mandatory. Frozen v9 remains JSON-authoritative and lost rows
   cannot be resurrected. Claude's JSON-only membership recommendation is rejected because it
   deletes surviving structured-only records/manual metadata. The specified intentional policy
   preserves JSON first-occurrence order and appends available structured-only records, preserving
   matching metadata and adding JSON-only manual labels. The PR must disclose that union behavior
   and historical recovery limit. No restoration of pre-v9 lost rows is claimed.
3. **Accepted Claude 5.** Guard tooling may promote already resolved packages to exact-pinned
   direct development dependencies without lock-version upgrades; record the PR justification.
4. **Accepted Claude 6.** CI's independently resolved current main is authoritative; recorded
   bootstrap ancestry is checked. A changed migration set/closure fails with a refresh/rebase
   diagnostic; the PR cannot select an older source field as authority.
5. **Accepted Claude 7.** Malformed-agent rejection must preserve an armed desktop departure and
   its scheduled exit as well as avoiding dispatch/stamping. Structurally valid changed-argument
   keyed refusals remain authorized/dispatched activity. The lifetime change note includes grace.
6. **Accepted D9-1 and author A9-1.** Use short private disk-backed temporary paths fitting generated
   sockets, unset host Hyprland state for widget/private-display subprocess trees, specify Linux
   X11/private display/D-Bus isolation, and invoke tracked 100644 Dart/service scripts with `bash`.
   Qualified task-local Xvfb is an equivalent fallback, not a skipped real-UI gate.
7. **Accepted optional clarifications.** Cover privacy maintenance with idle versus active readers
   and update schema documentation with shipped 15/new versions and persistence module boundaries.

The original infrastructure failures and corrected baseline reruns remain logged. Root baseline
ASan/UBSan subsequently passed 29/29 after private namespace-home/Python-runtime corrections;
new guard final-hardening tests passed 18/18. These are separately recorded execution facts, not
reviewer-run tests or changed-head acceptance. Final Linux/HanSolo/hosted obligations remain intact.


## Round 10: revision 9 and dependent corrections

All four reviewers read complete frozen revision 9 and its refreshed inventory, independently of
one another. Same source c28, native before/after hash checks and author before/after checks for
Claude; no source mutations. Inputs/reports/raw CLI output and manifest:
`/var/tmp/foresight-plan-r10-review/`.

| Input | SHA256 |
| --- | --- |
| Plan revision 9 | `a86b7eb29d466722741fc78555b5115747dc3abe47fbc5f76f974d910d67bef4` |
| Inventory | `ce59baa5f3b53dcf77ff9c94044af23b76d03e60cc4548fd9f67e34af2786161` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | No actionable planning gap. |
| Native verification | Converged | V9-1/V9-2 resolved; no actionable gap. |
| Native desktop | Changes required | D10-1: extend new schema guard to coordinator authoritative identity/epoch and synchronous facade paths, which can fail before/after worker reads. D9-1 resolved. |
| Claude CLI | Changes required | All seven earlier findings closed; preserve saved graph-force signatures through order-only label migration. |

Revision 10 accepts both findings. Every application-reading connection guards schema and dependent
identity/projection in the same short snapshot before application-table SQL, including dispatch and
acceptance identity reads and retained sync adapters. Opaque revision tokens remain sampled at
autocommit boundaries; no identity transaction spans a worker await. Actual identity-table changes
are exercised before dispatch, before acceptance and before sync reads; every path yields the same
typed retirement without generic internal errors, retained rows or reissue loops.

Graph signatures are persisted representations, not merely transient projection strings. The
migration captures old validity and membership, then canonicalizes saved `label_set` only for
previously valid layouts with unchanged per-document `(name,source)` membership, atomically with
labels. Saved positions/vectors/identities stay intact. Already-stale state remains invalid even
if its old string accidentally matches the new canonical string; obsolete force entries may be
removed without discarding positions. Real membership changes retain existing invalidation/
acknowledgement policy. Fixtures require complete valid-layout preservation, stale state, real
membership change and rollback. This additionally prevents the naive suggested acknowledgement
from accidentally blessing stale layouts.

Claude's optional allocator and privacy-retry clarifications are accepted: the new migration uses
frozen migration-private allocation in its manifest closure, and privacy maintenance retains
capped-interval retries without an attempt cap, restart intent and owned-timer disposal. No runtime
behavior change is authorized by correcting that prose.


## Round 11: convergence at c28, followed by a moved-main refresh

All four reviewers read the complete revision-10 plan and inventory. Native reviewers checked
hashes independently before/after; the author checked Claude's frozen inputs before/after. Full
reports and manifest: `/var/tmp/foresight-plan-r11-review/`.

| Input | SHA256 |
| --- | --- |
| Plan revision 10 | `4bc069b263f32b1ed559c2f7e975b5933dbef5563ec7938182543100fb174be9` |
| Inventory | `1a8d83e0772fd71594b15ffde33d62d7bf887f0e90c63efb9c9017f51260cd7e` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | No actionable gaps. |
| Native desktop | Converged | Complete read-path schema correction resolved D10-1. |
| Native verification | Converged | Read/graph/allocator/privacy corrections consistent with source. |
| Claude CLI | Converged | Graph correction and dependent clarifications closed; no actionable gaps. |

Claude's optional parsed-membership suggestion is implementation precision, not an unresolved
finding. Retain actual baseline-validity semantics plus the separate membership-equality check;
using membership alone must not bless an already-invalid layout. The migration's complete frozen
closure covers signature encoding/selection as well as its allocator. Exercise malformed/stale
and accidentally matching signatures in implementation fixtures. No further revision-10 edits
were made after review.

The final fetch caught a new reviewed main commit before completion was recorded:
`3fb259243a99137e3cba1d5e795c44100f42e688`, PR168, owned-DMG attachment recovery and restored
parallel contracts. Convergence above is valid for c28; it was not presented as review of 3fb.
Revision 11 refreshes the baseline and affected CI/installer preservation obligations.

## Main delta and revision 11 inputs

Complete immutable new-main source export, actual patch and machine-readable identity proof:
`/var/tmp/foresight-plan-main-3fb25924/{source,main-delta.patch,main-delta.json}`. The new export
contains the complete source without `.git`. Fifteen Git tree/blob identities including modes
were compared: complete core, desktop, native, services, CMake and protocol trees; root CMake,
AGENTS, pins and relevant runtime/host gates. All match c28 exactly. Existing frozen migrations,
operation/consumer inventories and line metrics remain code facts; c28 builds, runtime pass counts
and measurements remain labeled c28 and are not recast as 3fb compilation or acceptance.

Twelve changed files affect owned-DMG cleanup, tests, CI selectors/workflow ordering and release/CI
documentation. The DMG fixture now depends only on changes and builds its own signed fixture,
independently of the Mac application job; both classifiers remove the forced DMG-to-Mac edge.
Application acceptance remains separately required. Recovery only normally detaches the exact
newly created image with current owner/unambiguous outer GUID, within the existing bound, and
retains checksum/unchanged-byte verification and unrelated attachments.

Author-side focused tests on the complete new source export: 163 passed, 4 Apple-only skipped,
97 subtests passed (`changed-contract-tests.log`). They cover changed portable DMG/CI contracts;
real Apple contracts, full Quality coverage and final Linux/Mac gates remain unexecuted at this
new source. No workflow/source implementation edits were made to apply this plan refresh.


## Round 12: convergence against refreshed main 3fb

All three native reviewers and Claude CLI reviewed the complete same frozen revision-11 plan and
inventory against the new main export and actual delta. Native reviewers independently verified
before/after hashes; the author verified Claude's inputs before/after. Source-only Claude tools
and independence restrictions remain unchanged. Full frozen inputs, prompts, raw CLI output,
verbatim reviews, document validation and report-hash manifest:
`/var/tmp/foresight-plan-r12-review/`.

| Input | SHA256 |
| --- | --- |
| Plan revision 11 | `039cef935ac8e49404bb1f21abb7144fe288b8e7a84e690606f28f4573342358` |
| Inventory | `29fbbf912ba00d73398f5790f7db2d878a574bd69a4ff12450415ea0f896e3c9` |

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native core | Converged | Complete documents/actual delta checked; unchanged application contracts and exact-source acceptance preserved. |
| Native desktop | Converged | Baseline labels, independent DMG/app acceptance and prior reader/environment fixes consistent. |
| Native verification | Converged | Ancestry, all changed/unchanged identities and both complete 1170-file exports/modes checked against Git objects; no actionable gaps. |
| Claude CLI | Converged | New baseline/CI/owned-DMG clauses match source; all prior closures stand, no actionable planning gaps. |

Claude noted optional precision: the new owned-cleanup DMG fixture is mandatory through the
runner's complete-count/zero-skip enforcement, rather than its smaller named-required set.
Preserve that effective runtime contract; no extra source change is needed for planning convergence.
HanSolo's full Xcode toolchain currently exits 69 pending the owner's license review/acceptance;
the owner has already been notified. CLT tools work, but no full Mac pass is claimed. Docker daemon
access is unavailable locally. These remain explicit execution obligations, not inferred waivers.

A fresh follow-up fetch still resolved main to
`3fb259243a99137e3cba1d5e795c44100f42e688`. The isolated `refactor/core-desktop` integration
branch was fast-forwarded to that source; its existing tracked foundation patch remained
byte-identical (`fcab2c4d22dfd605fce82f438d0db87717f6890a07ead8145dbe8acfe127ea28`). The original
checkout's tracked HEAD remained 053673dd. Reviewed plan/inventory/record copies are synchronized
between checkouts. Validation passes all 11 relative document-link instances, shell-block syntax,
whitespace, frozen input equality and unchanged deferred PR8/process/Windows inventory tail.

**Planning verdict: converged at revision 11/current main 3fb.** This closes the renewed plan-review
request after rounds 9–12, including the caught main movement. It does not establish implementation
completion, the core acceptance checkpoint, final-head Linux/HanSolo gates, CI/PR approval or merge.

## Incremental implementation review, core before checkpoint

The planning verdict above remains revision11 at main3fb. Implementation review
is a separate activity and does not replace the complete frozen-source gates.
The first incremental Claude source snapshot is
`/var/tmp/foresight-core-implementation-review-r1/source`, with source manifest
SHA256 `c6ae190fcefb85fdf183e1f842e7e54503dcdc8afc0f7f0afa2bcda92e43a69c`.
Raw output and verbatim result are retained there as sibling `claude.jsonl` and
`claude.md`. Claude used only Read/Glob/Grep; it ran no tests or source mutations.

Native implementation review identified and reproduced three issues before fixes:
Questions could accept a completed response after cancellation during close;
automatic pre-native retrieval lacked an actual-producer shutdown join; and a
foreground-yielded Notes run could schedule a new retry after workspace clear and
meeting-ID reuse. Root corrections now retain cancellation through acceptance,
join actual automatic producers separately from fast queue cancellation, and
require the original Notes mapping identity before retry. Seven permanent tests
pass, including ordinary retry/happy paths and no late change events. Verbatim
native handoff: `core-contracts/root-owned-review.md` under the implementation
evidence directory `/var/tmp/foresight-core-desktop`.

Claude's one actionable finding was a shutdown delay: a held embedding adoption
RPC could retain its configuration reservation until a30-minute timeout, while
helper close waited behind Application close. The suggested approach skipped the
configuration join. We accepted the finding and instead made ModelRegistry own
and cancel only its adoption ResponseFuture on stop, preserving the reservation's
actual-future join and subsequent helper shutdown ordering. A real held-gRPC test
passes: close finishes without releasing the server gate, the call reports
cancelled, no late registration/indexing occurs, and an unrelated same-channel
retrieval remains live. Evidence: `core-contracts/embedding-shutdown-held-rpc.log`.

Claude also noted existing ProactiveQuestions SQL under the persistence boundary.
Although listed as polish, the reviewed6D.5 requirement makes this mandatory.
The team extracted named typed queries for ProactiveQuestions, Domain and Google
connections, as well as the typed conversation/model/source projections. The
scheduler, source queue, account/network work and lifetime authorities retain
their owners. Raw maps remain only at wire/JSON/unchanged algorithm adapters.
A structural application persistence guard rejects feature SQL, raw rows and DB
access; it passes after Application composition uses Store's named query factory.

Optional busy-message wording remains unchanged for compatibility. Additional
characterization suggestions remain assessable at the complete gate/review; no
optional note waives ownership, schema or responsiveness acceptance. The final
combined implementation still requires independent native-team/Claude review
and complete Linux/HanSolo evidence after the desktop work package.


## Core implementation review round 2

Claude CLI independently converged on core6A–6E at frozen commit
`f225633b8c0eff18470bc883c9c9433f2ff3d030`. The full verbatim result and raw
Read/Glob/Grep-only transcript are retained in
`/var/tmp/foresight-core-implementation-review-r2/`. It verified the owned
embedding RPC cancellation plus actual configuration join, the three native
review corrections, typed persistence/JSON identity preservation, Application
schema error mapping, explicit bindings and structural limits. It ran no tests.
This verdict covers core implementation review, not the complete Linux checkpoint
or the final combined implementation.

Its optional inter-child reservation suggestion was accepted as useful coverage:
three permanent tests hold the actual scheduling gap after a native child settles,
prove valid foreground/configuration peers are refused, then verify eventual
reservation release and exactly one artifact for Summary, Actions and Preparation.
These and the recovery-readiness fixture pass9 tests.

The optional streamed-schema error-code observation was promoted to a correction
because6C requires actionable unavailable RPC errors. A real service/socket test
also reproduced an uncaught future-schema failure in idle-policy reads during
request settlement. The correction preserves the last verified normalized idle
policy and monotonically retires only unsupported policy reads; the same service
still owns activity, departure/grace, timers and close. Both epoch and no-epoch
stream cases retain unavailable errors, settled dispatch accounting, compatible
preference refresh, retired policy after database restoration and grace-driven
shutdown while preferences are incompatible. These and existing lifetime/handoff
regressions pass87 tests with one existing Mac-only skip. Narrow source review
and full exact-candidate gates for these post-f225 changes remain required.


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


## Core implementation delta review round 3 and external fixtures

Claude CLI converged on the complete post-f225 correction set at
`405e13f7fddca2369e35162c98ecf13b81416a89`. Its verbatim independent static
review is retained in `/var/tmp/foresight-core-implementation-review-r3/claude.md`.
It confirmed schema-read retirement, error mapping, real readiness joins,
between-child ownership tests, desktop readiness and archive inventory behavior.
It ran no tests and did not approve the remaining full Linux checkpoint.
Its optional architecture-document clarification is now incorporated.

The complete 405e core gate passes 1,823 tests with 12 expected skips and 92.06%
coverage; Python Quality passes 5,172 tests with 31 expected skips and 95.87%.
Both source-hook modes and fresh service/MCP compilation pass. An independent
Debug-cache-ON to actual Release build keeps the cached option ON, passes the
helper hook scan and all 30 root CTest targets. Those results remain bound to 405e.

The real compiled process gate then found two external fixture migrations missed
by the author: the service facade probe still used removed raw/writer/lifetime
APIs, and the actual desktop integration fixture dynamically called reader.rows.
Its complete result is 30 passed/two failed, with no full process acceptance.
A repository-wide inventory of 26 external Dart consumers also located 47 stale
raw-row accesses in the meeting workflow integration target.

The correction batch uses curated typed readers and connection-owned cleanup.
The service probe now explicitly rejects missing writer capability without side
effects, observes an actual persisted change, and compares note IDs/content/
revision across reconnect; Python retains all OAuth/reconnect assertions and
requires the new no-mutation-replay result. Its targeted real subprocess passes.
Desktop integration retains all 59 observed service/MCP/approval/capture/restart
expectations in a passing real UI run. Meeting receipts use a narrowly named
private read-only inspector against the explicit disposable profile, preserving
whole-table/orphan cardinality and exact graph/label/artifact assertions. Its
controlled fixture writer owns one short transaction and closes immediately.

Independent native cross-review caught source metadata loss in the initial
summary-to-document projection. The final fixture merges summary metadata with
full document fields; the reviewer verified the saved fix and converged on the
batch. Integration analysis, actual meeting target compilation and eight real
SQLite diagnostic assertions pass. These live-fixture diagnostics explicitly
reuse 405e binaries; a new frozen-source full checkpoint remains required.

The [native teardown follow-up](2026-10-21-native-close-follow-up.md) records the
measured pre-existing P2-4 residual, rather than claiming it repaired. Independent
verification checked raw timings, active native state, source/blob equality,
binary/harness digests and limitations; its review converged. It does not replace
warm RPC comparisons, native cleanup tests or final Linux/HanSolo acceptance.


## Renewed plan review round 13, implementation findings

The owner renewed native-team plus Claude CLI plan review. Fresh main remains
`3fb259243a99137e3cba1d5e795c44100f42e688`; the code reviewed is frozen
`4bd2c75d5890399f03d57ce8a46788da2dfcc623`. The three native reviewers and
Read/Glob/Grep-only Claude independently reviewed the complete revision-11 plan,
progress and relevant implementation/evidence. Frozen inputs, hashes, original
findings, CLI prompt/command/transcript and narrow follow-up proposals are retained
in `/var/tmp/foresight-plan-r13-review/`. Planning verdict: changes required.
The preceding round-12 convergence remains historical.

| Finding | Disposition in revision 12 |
| --- | --- |
| Native core C1: journal-exists probe rule absent from normative prose | Accepted. Existing journals, including empty ones, require private read-only DB+journal probes across all three implementations; original checksum/version/identity checks remain strict. Architecture prose now matches production. |
| Native verification V13-1: canonical schedule and resource profile | Accepted. Next acceptance uses existing default schedule1; record actual CPU/cgroup/memory/swap/concurrency/load. Schedule0 is also parallel and its failed local results remain separately identified. No resource cause is assumed. |
| Native verification V13-2: failed4bd and keyed label assertions | Accepted. Full counts/downstream NOT RUN and isolated diagnostics are recorded. Correct keyed associations, per-document position and both deterministic global ID orders, preserving all metadata/revision/cascade assertions. |
| Native desktop D13-1: connection versus feature worker ownership | Accepted. Connection owns coordinator/actual-read joins; features own requests/subscriptions/publication resources. No duplicate scheduler or shared-reader close on feature disposal. |
| Native desktop D13-2: stable Stats identity versus actual-dispatch time | Accepted. Complete the additive core seam before the freeze; retain exact now cutoff, captured labels/period, calendar/DST/timezone/resume and settlement tests. |
| Native desktop D13-3: same-path/same-epoch client replacement | Accepted. Observable opaque client-session generation retires feature work; distinguish it from authoritative SQLite read identity. Complete before feature fakes/moves and the core freeze. |
| Native desktop D13-4: bypassed legacy query spies | Accepted. Typed read/watch admissions and worker projections are counted separately from feature notifications/builds; equal immutable projections do not notify. Preserve semantic and real-worker/process assertions. |
| Claude1: full-schedule-only failure protocol | Accepted in part: failed canonical gate remains failed; record isolation/full-command timing/resource evidence and require complete semantic parity for context changes. Rejected parse-only namespace replacement and mandatory stage relocation: neither is needed to preserve the analyzer contract, and a custom parser would expand/alter it. No timeout, assertion, coverage or canonical concurrency relaxation. |
| Claude2: consumer seams before core freeze | Accepted for session and Stats prerequisites and a new full checkpoint if later core contract/ownership/scheduling work is needed. Rejected conflating client generation with SQLite ReadIdentity or requiring a new full checkpoint for every test-support edit; affected checks/final full acceptance and original source labels remain mandatory. |
| Claude3: fixture order | Accepted as above. Complete keyed sets and ordered per-document assertions remain, with deterministic cross-document fixtures. |
| Claude4: Mac readiness/substitution/cache misses | Accepted prerequisites and explicit HanSolo requirement; verified misses may require private pinned component compilation under AGENTS. Prepare setup alongside Linux work. Rejected an arbitrary new pre-7B readiness gate; final actual HanSolo acceptance remains required and owner license cannot be accepted by an agent. Hosted Mac checks do not silently substitute. |
| Claude5: standalone note editor ownership | Accepted. Move editor/New Note request-key ownership into Sources/Notes before Sources extraction, rebinding composition drain/reset and preserving exact retry/epoch assertions. |
| Claude6: run downstream after each failed gate | Optional diagnostic only, not a new mandatory run of already-superseded candidates. Follow AGENTS: inspect/retry failed cases first, batch valid related fixes, preserve all failures and require one complete passing acceptance driver. |

Claude's narrative inferred the default schedule from repository code; the actual
4bd local adapter explicitly selected0, as the native verification inspection
established. Both are parallel. Its broad statement that all earlier failures
were load-only is not accepted: the root journal case was a reproduced metadata
mutation with an implemented fix. Settings' existing revision tag uses week start;
the exact-time key gap is in StoreReadQueries/ReadQuery. These corrections do not
dismiss the valid scheduling/consumer-seam findings.

Revision12/progress/architecture amendments will be frozen together for complete
round14 review. No core acceptance SHA, desktop extraction or runtime approval is
established by this planning work. The final combined implementation still needs
native-team/Claude review and Linux/HanSolo/PR/merge acceptance.


## Round 14: revision 12 corrections and bounded final amendments

All reviewers read the same frozen revision12 at
`/var/tmp/foresight-plan-r14-review/`: plan SHA256
`6220abe10fbf9e4417b47786349b6b138b0b8ea5cac538192669701bc3f412e8`,
progress `e8df480e96c1da0272c5ead3e98f1c82dcdd409b505980ec057a74949a220ffa`,
schema documentation `3206437b7341a0d13caeea0f132dee63f5a595001282533fbf80937a69ba6788`,
and unchanged inventory `29fbbf912ba00d73398f5790f7db2d878a574bd69a4ff12450415ea0f896e3c9`.
Native core and desktop converge. Native verification and Claude identify only
bounded remaining amendments; revision12 is not claimed converged.

| Finding | Disposition in revision13 |
| --- | --- |
| Verification V14-1: next-Monday/resume misses timezone change in an awake app | Accepted. Require observable timezone/calendar invalidation or bounded identity recheck, rearm calendar boundaries, reject held old-period replies and test no-resume/no-service-event replacement/coalescing. Keep the same core coordinator. |
| Verification V14-2: missing historical audit-input links | Accepted. Three references become plain dated provenance; authoritative tracked links remain. Old original-workspace validation did not prove those targets existed in the frozen export. Importing unrelated historical audits is unnecessary. Deferred PR8/process/Windows content is unchanged. |
| Claude1: leftover instruction to add Stats seam during7B | Accepted. 7B consumes the seam already landed in6E; if insufficient, stop and apply the explicit renewed checkpoint rule. The implementation is still pending, not retrospectively approved. |
| Claude2 optional: inventory6.5 summary omits seams | Accepted. One summary sentence aligns opaque session generation and Stats scheduling/dispatch prerequisites with6E. |

Document checks on revision12 preserve the actual failure: its three historical
inventory targets were absent. Changed plan/progress/architecture links, shell
syntax, whitespace and frozen hashes pass; revision13 reruns exported-link checks
after the narrow provenance correction. Author and all native reviewers verify
input hashes; Claude's read-only tools cannot compute them, so its verdict does
not claim independent hashing. Native and Claude reviews ran no runtime gates.
The graph fixture's separately authorized host/root diagnostics remain labeled
as live test-only evidence, without changing frozen review inputs or acceptance.

The complete revision13 inputs are next submitted to all reviewers. Full Linux
checkpoint, pre-freeze consumer seams, feature extraction, final HanSolo/combined
implementation review, PR and merge remain outstanding.


## Round 15: revision 13 planning convergence

All three native reviewers and Claude CLI converge on the same complete frozen
revision13. Inputs, hash manifest, independent reports, own-prior-report Claude
prompt, restricted CLI command/transcript and complete Git-free review overlay
validation are preserved in `/var/tmp/foresight-plan-r15-review/`.

| Input | SHA256 |
| --- | --- |
| Plan revision13 | `eee299d12483f30ad1c8fca12f4230976ab321d45f935e698af4944f3be61e21` |
| Progress | `9b59fd5a9d93665517bea33e98dded6e70f0c078965287f674ab944d9171c3cb` |
| Schema documentation | `3206437b7341a0d13caeea0f132dee63f5a595001282533fbf80937a69ba6788` |
| Inventory | `53735af9a13cc67f8d2af912254c49b33a85c2d1be4c880893f52340527dbccd` |

| Reviewer | Verdict |
| --- | --- |
| Native core | CONVERGED FOR PLAN REVIEW |
| Native desktop | CONVERGED FOR PLAN REVIEW |
| Native verification | CONVERGED FOR PLAN REVIEW |
| Claude CLI | CONVERGED FOR PLAN REVIEW |

Native/author before-and-after SHA checks pass for every frozen input. Complete
Git-free overlay links, shell syntax, whitespace and unchanged deferred tail pass.
Main was fetched again and remains3fb. Claude confirms every prior disposition;
its restricted tools do not independently compute SHA256 or read main. Its broad
grep incidentally matched report/record lines; it states those opinions were not
opened or used. Its graph diagnostic count rests on the progress record, while
the author/native verifier separately inspected the real7/7 host/root evidence.
These limits remain distinct from the full plan-text review verdict.

Planning convergence resolves the renewed review request after rounds13–15.
Implementation continues with the required pre-freeze6E session and Stats seams,
then the complete exact-source Linux checkpoint before7A. No core acceptance SHA,
feature extraction, final Linux/HanSolo acceptance, combined implementation review,
PR or merge is complete. Earlier failed full gates and all scoped diagnostic
results retain their original source/producer identities.


## Core consumer-seam delta: independent native reviews

After revision13 convergence, the client-session and Stats seams land before the
core freeze as required. Independent verification review converges on the session
delta; the session author independently cross-reviews and converges on Stats.
Exact source SHA manifests, assertions, command output and limitations are in
`/var/tmp/foresight-core-desktop/core-contracts/session-seam-implementation/`
and `stats-seam-implementation/`. Session real-socket13, unchanged RemoteDomain54,
desktop fixture9 and Stats57 pass with no skips; the public calendar import change
passes its affected1 case and the strengthened public namespace guard passes2.
The reviewer did not rerun tests or upgrade focused evidence to full acceptance.

Schema/status decode failure during client adoption is covered by source reasoning
through the existing retire/notify catch, not a newly injected adoption failure
test. Stats calendar capture is exercised in real TZ/DST subprocesses; actual
feature timers, awake timezone monitoring and replacement publication remain7A/B.
Source fakes/test harnesses do not establish completed feature migration.
The new frozen-source Claude review, complete Linux checkpoint and final combined
implementation review remain required.

## Claude consumer-seam delta review, round7

Frozen source `1ac62bb038b6a124c909ba949b1390f06f25ec1b`, compared with4bd,
receives **CONVERGED FOR CORE CONSUMER-SEAM DELTA REVIEW**. Claude independently
inspected session adoption/notification/late-settlement semantics, actual-dispatch
admission and immutable arguments, captured calendar SQL boundaries, both graph
fixture orderings, analyzer namespace linking and fixture compile reachability.
No actionable defect remains in that delta. Focused evidence limits and the need
for the full current-source matrix are explicit in the report. Subsequent actual
default-schedule1 core namespace failure remains unresolved and is not overridden
by this review. Final combined implementation review remains a separate gate.
Report and exact-source receipt:
`/var/tmp/foresight-core-implementation-review-r7/{claude.md,result.json}`.

## Namespace compiler-bundle delta review, round8

Frozen source `27887f8ecdec002a443c8435a4befaa9c4e61005`, compared with1ac,
receives **CONVERGED FOR NAMESPACE CACHE DELTA REVIEW** from Claude CLI; the
independent native review also converges. These reviews cover private invocation
ownership, actual semantic linking and assertions, compiler-bundle invalidation,
natural warmer exit, unchanged coverage/runner behavior and meaningful real cache
regressions. Both distinguish focused evidence from complete acceptance. The
internal analyzer API remains a pinned test-tooling maintenance obligation.
The documentation signature wording and an explicit zero-hit corruption assertion
are accepted nonblocking follow-ups.

The subsequent complete 278 run passes the original semantic guard but fails the
new compound cache regression at its existing timeout. That failure is preserved;
neither review overrides it. Splitting independent cache behaviors into separate
fresh-fixture tests requires affected checks, independent delta review and another
complete frozen-source run. No checkpoint acceptance or feature extraction is
claimed. Reports and exact-source evidence:
`/var/tmp/foresight-core-implementation-review-r8/{claude.md,result.json}` and
`/var/tmp/foresight-core-desktop/core-contracts/namespace-cache-implementation-review-native.md`.

## Cache-test granularity review, round9

The independent native review converges on the four-case split and verifies the
raw six-test focused events and log hashes. Claude CLI reviews frozen
`63fc4a80546a5d856bc11fb5aeca620984f674f1` and finds no blocking defect, but withholds
convergence for an actionable cleanup issue: teardown revalidates already-flushed
cold entries after the corruption case deliberately damages them. If a primary
assertion fails, that can add a misleading disk-write error. The accepted fix
tracks only writes still awaiting independent disk verification, keeping the
complete write-history assertions and existing bounds.

The later metadata-only finalization script was also absent from the retained
evidence directory. Its recovery/reproducer must be explicitly preserved without
rewriting the failed original driver or repeating the old passed runtime. The
next complete run must record actual durations for all four cases; an idle/load
ratio is not a causal explanation or proof of timing margin. No full 63fc
canonical run was launched. Its seven static commands pass, and the subsequent
test-only correction still requires affected checks and native/Claude review.
Report: `/var/tmp/foresight-core-implementation-review-r9/{claude.md,result.json}`.

## Revision14 owner coverage amendment: review pending

Revision13's whole-plan convergence remains scoped to its frozen document bytes.
The owner subsequently requests a95% coverage target while retaining the90%
enforced minimum. Revision14 applies that target to Dart core at the core
checkpoint and both Dart suites at final combined acceptance, without changing
Python's95% gate, coverage exclusions, native requirements or real platform/skip
obligations. Current-source reports drive meaningful additional behavior tests;
historical coverage is labeled by its actual source. Native/Claude review of this
amendment and the pending-write correction remains pending.
