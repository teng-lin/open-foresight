# CI reliability and runtime plan reviews

This record tracks independent review of the [implementation plan](2026-10-20-ci-reliability-and-runtime-plan.md). Plan convergence means no unresolved actionable planning findings; hosted implementation and performance qualification remain separate gates.

The source baseline is reviewed main `896596f8515166296c93938142a340088a0ff95f`. The [20 PR baseline](../platforms/2026-10-20-ci-review-baseline.csv) preserves the per-PR measurements and authoritative merge/head tree comparisons used by the plan.

## Review method

Three native agents review trust and required gates, runtime and tooling, and validation and rollout. Claude Code CLI 2.1.304 and Agy CLI 1.4.2 review independently against repository source. Each substantive round freezes the plan bytes and SHA256 before reviewers start. All five complete before the author revises it. Every actionable finding is checked against source and either incorporated or rejected with a reason.

Original CLI stdout, stderr, prompts, status and frozen plan copies are retained under `/home/blackmyth/.cache/open-foresight/ci-plan-review-2026-10-20/`. Failed CLI invocations are retained and do not count as reviews.

## Round 1

Plan revision 1 SHA256: `e644ee6b9c3401acf549556dfbcdb54a0c7c1bbfa04c0381c8d5776b2746ffe6`.

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native trust reviewer | Converged | No unresolved actionable findings |
| Native runtime reviewer | Converged | No unresolved actionable findings |
| Native validation reviewer | Changes required | R1 NV1 |
| Claude CLI | Changes required | R1 C1 through C7 |
| Agy CLI | Changes required | R1 A1 through A7 |

### R1 NV1 Shared fixture process ownership

Accepted. `ServiceLauncher.stopAll()` currently verifies a recorded PID by checking whether its command contains the build's kernel path. Sharing that path across tests weakens the ownership check and could allow stale-PID cleanup to signal another test's service. P7 must require a private launch identity independent of shared compilation, an adversarial same-kernel PID-reuse fixture, and disposal of shared compilation only by its job-level owner after all consumers finish.

### CLI findings and dispositions

| Finding | Disposition in revision 2 |
| --- | --- |
| C1 Existing workflow tests exclude required Arch and count Linux contracts once | Accepted. P1 names both conflicting tests and retains exactly one host-contract owner per Ubuntu/Arch environment during rollout. Removing Arch execution before qualification was rejected as a fix; the native validation reviewer confirmed the distinct-environment correction. |
| C2 Queued publisher eviction and preview caller | Accepted. P3 inventories all three entry paths, moves publication out of application validation, and reconciles missing still-needed identities independently of the evictable publisher group. Native follow-up also identified document Flutter/model outputs and inherited preview write permissions; all receive explicit migration requirements. |
| C3 macOS-only changes need a separate DMG gate | Accepted. P4 defines separate selection, expected outcomes, aggregate membership and no Linux-package closure for macOS-only changes. |
| C4 ci:full is planned rather than implemented | Corrected. P9 explicitly implements the label and tests live metadata/rerun activation. |
| C5 Metrics collector already deduplicates rerun jobs; output destination unspecified | Clarified. P2 preserves the existing behavior, names the actual deltas, and specifies normalized inputs/reports under docs/platforms/ci-evidence. |
| C6 Observer location and read permissions unspecified | Accepted. P5 names the standalone main-only observer, event guards, trusted source and explicit read permission set. |
| C7 Dispatch schema and sweep selector missing | Accepted. P6 names the touched workflow/helper paths, boolean input, run-name, concurrency, current-head guard and explicit application-tier selection. |
| A1 Quiet-period fallback can exceed the two-hour tracking objective | Accepted. P6 adds independent half-hourly reconciliation and heartbeat/delay reporting. The proposed hard scheduler guarantee and blanket assertion about workflow_run suppression were not adopted; see the evidence note below. |
| A2 Missing sweep dispatch plumbing | Duplicate of C7; addressed by the same explicit contract. |
| A3 Tier must reach the gate checker | Clarified the existing tier-aware requirement with an explicit CI_TIER/--tier interface and release-skipped Arch expectations. |
| A4 live-services scheduled cache saves omitted | Accepted after verifying actions/cache in live-services.yml. P3 explicitly makes that drift consumer restore-only and audits all workflow/action saves. |
| A5 Split DMG job must remain aggregated | Duplicate of C3 with an additional aggregation detail; P4 now explicitly names platform-checks.needs and check_gates. |
| A6 Superseded marker needs a concrete evidence check | Clarified. P6 writes an explicit boolean in ci-selection.json and verifies its producer, checksum, false value and actual selected-job success. Missing/all-skipped evidence fails closed. |
| A7 Trust-table path must be explicit | Clarified the existing producer-row requirement by naming tools/ci_producer_trust.py in P3's touch list, retaining the seed-current migration and frozen legacy row. |

The author also added explicit P2/P9 rollback, the exact 95% Python coverage command, the frozen baseline link and the consecutive-nightly condition. No implementation validation result is inferred from these text changes.

### Event and scheduler evidence

Agy's useful fallback-latency finding does not establish that a token-dispatched run can never emit a completion event. GitHub documents workflow_dispatch/repository_dispatch exceptions to [GITHUB_TOKEN recursion restrictions](https://docs.github.com/en/actions/concepts/security/github_token); the actual downstream workflow_run behavior remains a hosted exercise. GitHub also documents that [scheduled jobs may be delayed or dropped](https://docs.github.com/en/actions/how-tos/troubleshoot-workflows). Revision 2 therefore uses nominal half-hourly reconciliation plus measured heartbeat delay, manual fallback and a two-hour operating objective, without claiming guaranteed scheduler delivery.

### CLI invocation corrections

The first Agy invocation used a flag order that its print parser rejected. A subsequent read attempt produced no review because a headless command permission was denied. Both outputs were retained. The corrected invocation uses plan mode and an explicit read-only review instruction, without changing persistent CLI settings. Neither failed invocation counts toward convergence.

## Round 2

Plan revision 2 SHA256: `3da962daaad0ae099a48611bdcfc73f526ea06ff8f041ff4740ac46dd0921096`.

All reviewers re-read the complete revised plan. The external reviewers may use their own preceding review and source analysis; they do not receive the other reviewers' output. Production/workflow/test sources remain unchanged.

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native trust reviewer | Converged | No unresolved actionable findings |
| Native runtime reviewer | Converged | No unresolved actionable findings |
| Native validation reviewer | Converged | No unresolved actionable findings |
| Claude CLI | Changes required | R2 C1 and C2 |
| Agy CLI | Converged | All preceding findings resolved; no unresolved actionable findings |

### Findings and dispositions

- R2 C1: accepted. The missing-marker rule needed to cover ordinary PR evidence as well as sweeps. Revision 3 establishes an explicit false marker in P1 before P5 consumes ordinary selections, then sets true only for superseded sweep exits. P5/P6 main-validation evidence requires the marker; legacy selection artifacts require fresh application validation. SDK and frozen dependency-seed contracts are explicitly unchanged.
- R2 C2: corrected. P6 extends the observer introduced in P5 rather than describing a second creation of main-evidence.yml.

## Round 3

Plan revision 3 SHA256: `3ec353c63bb402b676e3b35cee1cc15706b2fad7613e01a5583ac43eaabdb5ab`.

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native trust reviewer | Converged | Read and independently hash-verified the complete revision; no actionable residuals |
| Native runtime reviewer | Converged | Read and independently hash-verified the complete revision; no actionable residuals |
| Native validation reviewer | Converged | Read and hash-verified the complete revision; no actionable residuals |
| Claude CLI | Converged | Both round 2 findings resolved; complete plan rechecked; no remaining actionable findings |
| Agy CLI | Converged | Both revision 3 corrections verified; no actionable gaps or contradictions |

Claude reviewed the on-disk file through its read tools but did not independently compute its hash because its shell tool was disabled. The author verified the unchanged frozen hash before and after the reviews, and all three native reviewers independently verified it. Agy resumed only its own preceding review conversation. Neither external reviewer received the other reviewers' findings or the companion record.

## Round 4: three-PR regrouping

Revision 4 SHA256: `d52fb551a4bd3292f0e42ffd7e3c0e99330984b05937ea348ab6eb54ade25cc2`. The user requested two or three PRs instead of nine. P1–P9 technical contracts were byte-identical to revision 3; only the delivery grouping and revision metadata changed.

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native trust reviewer | Changes required | Final selector/publisher/preview closure must actually execute before retirement |
| Native runtime reviewer | Changes required | Retained helper/caller migrations must precede nightly/drift qualification |
| Native validation reviewer | Converged | No actionable regrouping findings |
| Claude CLI | Changes required | Publisher switch invalidates earlier retirement evidence; acceptance narrowing still needs four green weeks |
| Agy CLI | Converged | No actionable regrouping findings |

Accepted all actionable findings. Revision 5 moves the qualified production publisher/consumer/trust-route switch to PR 2, after isolated reviewed-main qualification following PR 1. PR 2 also lands retained Git/archive helper migrations and an explicit reviewed-main mode that actually executes the final candidate selector/preview/retained closure through actual scheduled nightlies and Arch drift. PR 3 requires an executable comparison with that qualified closure before activation/deletion. The four-green-week per-phase acceptance observation gate is explicitly inside the post-PR-2 interval. None of these gates is replaced by a shadow decision or synthetic exercise.

## Round 5: corrected grouping and #162 update

Revision 5 SHA256: `0d98985994399406e71752d2551683e1ea6f47b93beb86017128f90157229da0`.

During regrouping, the user reported #162 merged. GitHub metadata and fetched main confirm merge `02d572fbd66022bb125d188dfa296ba7f2bf85bc`, directly after #160. The seven changed files affect service/socket/desktop behavior, regression tests and documentation; CI/tooling source is unchanged. The implementation/P7 benchmark baseline now includes this completed reliability fix. Its successful first-attempt PR platform run is a separate observation; the original 20-PR CSV and denominators remain unchanged. Main push outcomes were unknown at the recorded check. Raw PR/run metadata is retained alongside the review artifacts.

| Reviewer | Verdict | Findings |
| --- | --- | --- |
| Native trust reviewer | Converged | Hash-verified; no remaining regrouping blockers |
| Native runtime reviewer | Converged | Hash-verified; no planned extra merge required |
| Native validation reviewer | Converged | Hash-verified; no remaining delivery/validation blockers |
| Claude CLI | Converged | Both preceding findings resolved; no unresolved actionable contradictions |
| Agy CLI | Converged | No remaining qualification deadlocks or gaps |

All five reviewed the same frozen revision. This scoped round covers the delivery corrections and post-baseline update; the complete technical contracts had already converged in round 3. Claude did not recompute the hash or independently inspect the #162 diff; the author verified both against the frozen file and fetched Git source, and all three native reviewers independently verified the plan hash. No implementation validation is inferred from these reviews.

## Completion status

Revision 5 converged after three full review rounds and two additional scoped regrouping rounds. All five reviewers report no unresolved actionable planning findings on SHA256 `0d98985994399406e71752d2551683e1ea6f47b93beb86017128f90157229da0`. The recommended delivery is three PRs; the documented two-PR alternative requires a staged main-only publisher cutover. Hosted qualification remains mandatory.

Document checks cover frozen plan bytes, relative links, whitespace and unchanged baseline CSV. Source/workflow/test files in the working tree are unchanged. No implementation tests, workflow dispatches, merges or registry writes were performed. Reviewer statements about future verification are assessments, not executed results; the plan's hosted gates and scheduling limits govern implementation.
