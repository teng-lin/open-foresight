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
  is not accepted. The dependency fix must receive its own final verification.

Implementation logs, frozen review inputs and original CLI results are under
`/home/blackmyth/.cache/open-foresight/ci-implementation-2026-10-20/`. HanSolo test
logs are under `/var/tmp/ofc1/` and `/var/tmp/ofc2/`; the private Python environment
is `/var/tmp/ofci/venv`. No successful dependency cache has been deleted.

## Review and qualification limits

Claude's first implementation review found actionable owner-selection, metrics,
snapshot-integrity and DMG error-reporting issues; fixes require another review
on the corrected source. Native cross-review also found stale readiness and
qualification-namespace issues. Passing unrelated checks do not verify fixes.

Agy's first implementation review exhausted its account quota and returned an
error with no review verdict. This is an incomplete review, not agreement. Its
stdout, stderr and reset diagnostic are preserved. No billing or account
settings were changed.

The Linux account cannot access the Docker daemon, and non-interactive sudo is
unavailable. Mocked transport tests cannot establish real Docker execution;
corresponding hosted checks remain required. Local lint uses actionlint 1.7.7
with ShellCheck 0.11.0 explicitly on PATH.

A single final GitHub merge cannot retroactively supply reviewed-main evidence
for new producer paths. Existing checks and guarded publishers stay in place
until actual replacement qualification passes. New activation paths must fail
closed; isolated qualification cannot become production validation or release
bytes. Two real nightlies, Arch drift and the four-green-week acceptance-narrowing
gate remain requirements. Implementation, final combined verification, GitHub
PR creation, hosted qualification, activation and merge are not yet complete.
