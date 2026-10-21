# CI improvements execution

The user authorized three implementation batches in separate worktrees, testing
on HanSolo, native-team plus Claude/Agy review, local integration merges, and one
final GitHub PR driven through merge. The reviewed implementation requirements
remain in [the plan](2026-10-20-ci-reliability-and-runtime-plan.md). The original
checkout and unrelated untracked documents are preserved.

## Branches

All work started from merged #162, `02d572fbd66022bb125d188dfa296ba7f2bf85bc`.

| Work | Branch | Linux worktree |
| --- | --- | --- |
| Integration | `codex/ci-improvements` | `/home/blackmyth/src/open-foresight-ci-integration` |
| Batch 1 gates, metrics, DMG | `codex/ci-batch1-reliability` | `/home/blackmyth/src/open-foresight-ci-reliability` |
| Batch 1 tooling and cache ownership | `codex/ci-tooling` | `/home/blackmyth/src/open-foresight-ci-tooling` |
| Batch 2 evidence and sweeps | `codex/ci-batch2-evidence` | `/home/blackmyth/src/open-foresight-ci-evidence` |
| Batch 3 selection and qualification | `codex/ci-batch3-activation` | `/home/blackmyth/src/open-foresight-ci-activation` |

Batch branches go to the Mac Git remote for testing, not to separate GitHub PRs.
Integration happens only after the applicable testing and review. Parallel
implementation does not establish dependency closure: each final batch snapshot
must include its prerequisites and pass from that exact source.

## Evidence collected so far

- HanSolo, macOS 26.6, pinned Flutter 3.35.7 / Dart 3.9.2: at gate/DMG head
  `2c9a0da3df8d34d33c4d3d39320b9c108c7ff617`, both actual Apple DMG contracts
  passed in 29.2 seconds, including signatures, mounting, previous-version
  upgrade and SQLite retention. Fresh JUnit was produced.
- The same head passed 106 affected Python tests under a task-private Python
  3.13 environment installed from hash-locked requirements. Initial environment
  failures (missing PyYAML and missing `python` on PATH) are retained in logs;
  only the corrected run counts as passing.
- The Mac full core baseline passed 1,318 tests, with 14 expected skips and zero
  failures, in 72.77 seconds. Native/helper artifacts were reused with matching
  SHA256 checks. This warm-host sample is not a matched comparison with hosted
  CI and justifies no speculative fixture or concurrency change.
- The authoritative selector snapshot includes 50 merged PRs, all paginated
  changed-file counts checked, including the known historical escapes. It is
  frozen with a SHA256 alongside implementation logs.
- A Mac batch-2 snapshot at `95edae94` passed 125 tests but had eight native-work
  fixture errors, revealing missing retained-helper dependencies. That snapshot
  is not accepted. The corrected `03d982c9` snapshot passed 282 affected Python
  tests on HanSolo. Follow-up sweep/review fixes at `0e276bc2` passed 49 tests
  and 28 subtests on HanSolo and Linux.
- Reliability head `ceecb9b7` passed the exact full Python gate from source and
  a complete export without `.git`: 4,497 passed, 29 skipped, 95.67% coverage
  in each. Export fixture checks passed under inherited PR, main and unset refs
  (467 tests plus 97 subtests in each context). HanSolo passed both actual Apple
  DMG contracts and 357 affected Python tests on that head.
- Tooling head `ed8dd1bd` and evidence follow-up `0e276bc2` received a converged
  native implementation review. The review independently reran 71 tooling tests
  and 49 evidence tests plus 28 subtests. Final composition and CLI reviews are
  still required; these results do not certify later changes.

Implementation logs, frozen review inputs and original CLI results are under
`/home/blackmyth/.cache/open-foresight/ci-implementation-2026-10-20/`. HanSolo test
logs are under `/var/tmp/ofc1/` and `/var/tmp/ofc2/`; the private Python environment
is `/var/tmp/ofci/venv`. No successful dependency cache has been deleted.

## Current implementation checkpoints

| Scope | Reviewed source | Validation |
| --- | --- | --- |
| Tooling and dedicated cache ownership | `14e3dcad` | Native review converged; full source and complete archive each 4,624 passed, 29 skipped, 95.78% coverage; HanSolo 380 tests plus 843 subtests; archive PR/main/unset contexts also passed |
| Gates, metrics and DMG follow-up | `fbf83ef1` | Native review verified the precision predecessor `0d873105`; final source focused suite 567 tests plus 97 subtests passed; Claude review converged; complete-export PR/main/unset checks each 567 tests plus 97 subtests; HanSolo both actual Apple contracts and 567 tests plus 97 subtests passed |
| Main evidence and receipt owners | `c7ffa7d0` | Native review converged; frozen export 57 tests plus 44 subtests passed; integrated authorization reviewed with the activation batch |
| Dynamic qualification and production activation | `be2d1b62` | Native review converged; full source and complete archive each 4,710 passed, 29 skipped, 95.69% coverage; HanSolo 779 tests plus 139 subtests; archive PR/main/unset contexts each 448 tests plus 139 subtests passed; Claude findings require follow-up |

The reliability `33e20c2e` full source/archive checks reached 95.68% coverage
but failed one retry-safety structural assertion. That assertion was corrected
to recognize immutable attempt-specific artifact names. These runs are retained
as failures, not counted as final passing gates. Earlier activation full runs
also exposed stale helper-mocking targets and isolated CLI fixtures; the final
combined gate must verify their corrections.

Review fixes include the actual preview DMG job name, conservative legacy owner
selection, retained failed-attempt DMG evidence, exact metrics cohort boundaries,
newer sweep readiness versus verified no-op duplicates, original qualification
uploader identity, actual Docker recipe selection, nightly recovery windows,
and receipt/aggregate ownership after qualified Arch retirement. The final
reliability follow-up also preserves a minimum of both existing Apple contracts
while accepting future inventory growth.

Scheduled cache reconciliation remains read-only toward shared caches and
dispatches dedicated main publishers. Missing language/model keys warm
independently. Registry work is bounded by actual current-source publisher
readiness and 24-hour freshness, with a 30-minute active-producer limit.

Agy's latest implementation retry also returned an account-quota error and no
verdict. Its reset diagnostic was approximately 70 hours; no account, billing,
model or permission settings were changed. Native/Claude convergence cannot be
reported as a completed Agy review.

Physical deletion of bootstrap Arch stages and legacy publisher code remains
deferred: the single-PR delivery needs those implementations before hosted
qualification and for conservative rollback. Runtime retirement is evidence-gated
and executable without another activation code PR. Net CI code deletion is not
an achieved target. Matched runtime/error-rate improvements are also unmeasured
until at least five comparable ordinary hosted observations exist.

## Integrated review and validation

All three batches are locally merged into `codex/ci-improvements`; no separate
GitHub batch PRs were created. Integrated head `aa46f12b` additionally includes:

- A post-queue publisher readiness check before Docker or SDK work. Successful
  no-op jobs do not renew cache freshness; actual publication must succeed.
- Structural checks against the composed command modules, preserving every
  prerequisite that standalone batch review could not verify.
- Explicit required identities for both existing Apple DMG contracts, timestamp
  exclusion evidence, and separate reconciliation/publication metrics cohorts.

Native review converged on these integrated follow-ups. HanSolo passed both
actual Apple contracts at `aa46f12b`, with zero skips, in 30.184 seconds. The
Linux and Mac complete exports had the same SHA256,
`1b299834a9178f49e7be6ce3d77dae900b3c87081cdb08be2b38ddf023d3d6d8`.
All seven SDK component identities matched reviewed main `02d572fb`; no SDK
recompilation or toolchain input change was necessary.

The `aa46f12b` full source and archive runs each had 4,865 passing tests,
29 skips and 95.81% coverage, but failed the same stale selector expectation.
Mac and all three inherited-ref export contexts exposed the same assertion.
The production selection correctly retained broader transitional checks;
these runs are failures, not passing gates.

Activation follow-up `0ba60865` (integrated as `285a3b36`) corrects that assertion,
expands optional API outages to broader checks, resolves qualification decisions
once per changes job, recovers broad sweeps after retirement proof expires, and
documents proof renewal. Independent native review converged; its initial focused
suite passed 259 tests plus 141 subtests. Full combined verification is pending.

Claude's component reviews found real defects in dependency composition,
readiness, metrics, selector ownership, DMG inventory and acceptance replay.
Fixed component findings require review of the composed source. The acceptance
replay follow-up must use original historical failed-step evidence and exact
source ranges; a zero-miss selector replay alone is insufficient. Its frozen
baseline and bounded hosted refresh remain under implementation and review.
The final integrated Claude review is still running. No missing verdict counts
as convergence.

Agy implementation review was attempted repeatedly but returned an account quota
error and no verdict. The latest reset diagnostic was approximately 70 hours;
original stdout, stderr and immutable inputs are retained. Its implementation
review remains incomplete. No account, billing, model or permission settings
were changed.

The Linux account cannot access the Docker daemon, and non-interactive sudo is
unavailable. Mocked transport tests cannot establish real Docker execution;
corresponding hosted checks remain required. Local lint uses actionlint 1.7.7
with ShellCheck 0.11.0 explicitly on PATH.

A single final GitHub merge cannot retroactively supply reviewed-main evidence
for new producer paths. Existing checks and guarded publishers stay in place
until actual replacement qualification passes. New activation paths must fail
closed; isolated qualification cannot become production validation or release
bytes. Two real nightlies, Arch drift and the four-green-week acceptance-narrowing
gate remain requirements. Final combined verification, GitHub PR creation, hosted qualification, activation
and merge are not yet complete.
