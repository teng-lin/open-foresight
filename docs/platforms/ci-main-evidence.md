# Main validation evidence

`main-evidence.yml` observes main pushes and completed main platform runs, and
reconciles on a half-hour schedule or manual dispatch. Its observer has read-only
repository permissions. Direct main platform validation remains enabled.

The observer records a proposed decision and actual main execution independently.
An equal final PR/main tree is necessary but insufficient: the latest required
checks must belong to GitHub Actions App 15368 and the expected workflow/check
suite; each application owner must have successful actual execution or compatible
predecessor evidence. Retained Arch and external DMG child jobs are checked
individually. Missing evidence, skipped selected jobs, incompatible control
inputs, foreign/Dependabot promotion or changed readiness require fresh validation.

The predecessor receipt is an index. Its original uploading job, upload window,
attempt and ZIP checksum are qualified, and each original validation job's latest
readiness is re-read. Rerunning a failed macOS job does not turn an earlier
selection upload into an attempt-2 artifact. Source identity includes Git modes,
workflow/toolchain controls and installed Markdown notices; editorial docs do not
invalidate the conservative shared input closure.

Observation artifacts use `ci-main-observation-*`. Production receipt artifacts
use `ci-main-validation-*` and cannot chain from observations. Production
coordination remains disabled without independently verified hosted qualification
from `ci_rollout.authorize(..., capabilities=('main_receipts',))`. No environment
flag waives that proof. This evidence never authorizes PR/preview application
bytes as release bytes, and it does not claim a new compilation.

Manual `exercise_sweep` dispatches a current-main application-tier sweep without
stamping or the Linux installer matrix. The first classification step validates
the dispatch identity and writes explicit `superseded`. Queued duplicates cannot
mutually skip; completed duplicates must qualify their actual selected execution.
The dispatch namespace is bound in both the run title and selection artifact.
Exercise sweeps cannot satisfy production receipts or suppress a production sweep;
the production namespace additionally requires independent rollout authorization.
Sweep execution excludes the application `publish-caches` job. Retained
main-ref native stages keep their existing guarded cache behavior until the
replacement publishers qualify; an exercise namespace is not a claim that every
legacy main-only cache save has already been removed. Ordinary
manual dispatch, preview and release selection keep their existing semantics.

Activation still requires the reviewed plan's real hosted observation parity,
dispatch/reconciliation exercises, replacement-route nightlies and drift gates.
Local tests establish verifier behavior, not that those hosted gates passed.

## Lifecycle performance observation

The post-#162 Mac baseline ran the full core suite with pinned Dart 3.9.2 and
qualified current native/helper outputs: 1,318 passed, 14 expected skips, zero
failures; elapsed time was 72.77 seconds on the local warm host. The observed
hosted core phase was 555 seconds on a different configuration. These are not
matched before/after samples. They justify retaining current fixture ownership
and concurrency until comparable measurements demonstrate a safe improvement.
The socket-reset/backlog regressions and full coverage/process gates stay enabled.
