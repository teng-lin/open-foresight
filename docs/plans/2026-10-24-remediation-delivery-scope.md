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

## Current delivery

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
