# Remediation delivery scope amendment

This amendment records the user's request to defer broader security work and
open the single remediation PR soon. It takes precedence over the delivery
requirements of the original combined plan for the deferred items below. The
original plan remains historical scope, not a claim that these items are done.

## Deferred security additions

- New MCP read-consent policies, expiring/revocable client grants and additional
  result provenance/untrusted-content tagging (F13).
- Broader import traversal/sandbox hardening, additional helper identity and
  approval-display hardening beyond safety needed by the current changes (F13/F21).
- New capability-file and secret-store/access-token migration work (F21).
- New security-scanner coverage/triage automation and release governance:
  CODEOWNERS, protected release environments, GitHub App permissions, stronger
  attestations/manual receipts and new signing/notarization/repository-signing
  arrangements (security-related portions of F10/F11/F17/F20).

These remain follow-up work, outside this PR's completion claims. Existing
security, privacy, artifact-trust, test and release gates are not relaxed.
Existing owner review for changes to trust code or publishing workflows remains
required before merge. This amendment does not authorize a release or changes
to external permissions/secrets/settings.

## Deferred Keychain verification

On 2026-10-25 the user also deferred the isolated macOS Keychain test from F12
to speed delivery. Its actual Security -25308 failure (user interaction was
disallowed in the test session) remains recorded as failed, not passed. Keep
the existing opt-in fixture and gate; do not weaken or delete them. Further
Keychain execution is outside this PR's merge requirements. The remaining
first-run, logging, restore and Mac verification stays in scope.

## Current delivery

### Additional deferrals approved October 25

The user approved these five follow-up areas to bring the current PR to closure:

- Exact logging memory certification against the 512 KiB outstanding-traffic
  budget and the strict 5% median / 10% p95 overhead measurements. Keep bounded
  queues, producer/observer limits, privacy protections and existing tests. The
  numerical targets remain unverified follow-up requirements, not passing claims.
- Additional frontend bridge and background-job correlation. Finish the
  reproduced client defect that loses diagnostic events when calls occur outside
  their creation context; preserve existing protocol, retry and cancellation
  semantics. Do not expand the tracing implementation to close the original
  plan's entire correlation matrix in this PR.
- New dependency-assurance work: package reproducibility comparisons, Linux
  builder snapshots and new ICU pinning. Keep the existing pins, package
  integrity checks and publishing/trust requirements. Unintegrated proposals for
  these additions do not need to land with this PR.
- New native coverage reporting and clang-tidy infrastructure. Preserve the
  existing native tests and sanitizer gates. Additional report infrastructure
  that has not reached the accepted branch belongs in follow-up work.
- The separate broad Python import/entrypoint conversion (the 128-file batch).
  Keep the current supported entrypoints and fix actual packaging/test failures
  needed by the retained changes; the broad cleanup is not a completion gate.

These are explicit scope deferrals, not completed work or waived failing tests.
Retain failed output and document qualification limits. Do not weaken existing
test, coverage, privacy or artifact-integrity checks. Keep completed fixes that
are needed by the retained implementation; avoid speculative rewrites solely to
meet a deferred measurement or expansion. Final merge still requires working
logging and restore integration, data-safety fixes, actual Mac functional
verification, applicable existing checks, and resolved reviews and CI.

Prioritize the reviewed recording, persistence/indexing, runtime/lifecycle,
unified logging, documentation and already-started tooling changes. Fix data
integrity, ownership and privacy faults required by those changes. Preserve
existing authorization, retry/exit behavior, resource cleanup and coverage gates.
Do not expand into unrelated hardening or start additional cleanup before the
current implementation is stabilized for review.

Open one draft PR from the reviewed integration branch after executing the
applicable pre-push checks. The draft is a reviewable checkpoint, not acceptance
of unintegrated logging/runtime work. Add those units to the same PR only after
local review and appropriate Linux/Mac checks. Clearly list remaining merge
blockers and actual failed/skipped/unexecuted gates; do not wait for the deferred
security program to open or finish this PR.

Final merge still requires the accepted in-scope implementation, CI/review
resolution, necessary owner review and verification that the PR reached main.
