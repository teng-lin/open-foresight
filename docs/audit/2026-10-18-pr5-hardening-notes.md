# PR 5 hardening implementation notes

This branch implements PR 5 of `2026-10-18-implementation-plan-2.md` on top of
PR #109. The user explicitly deferred PR 3 and authorized independent PR 5 work.
PR 4 must land before this branch is rebased and merged.

## Scope and dependencies

The PR 1 carryovers N-4, N-3 R4/R5 and N-2 were already implemented in PR #109:
interrupted-meeting indexing, separate capture telemetry, stale-summary marking
and the native model-probe deadline. They are preserved here.

PR 5 adds native exception/rollback guards, safe stdin framing, cancellable helper
reconfiguration, checked audio writes, warning coverage and descriptor-bound
LiteRT loading. Application and helper databases enable secure deletion; clear
performs best-effort application checkpoint/VACUUM after committing local erasure.
Native release builds disable crash/delay fixtures. Dart release configuration
requires explicit compile-time opt-in before forwarding test-hook variables.

Dart changes cover bounded balanced meeting evidence, HTML meta encodings,
time-windowed helper recovery, Unicode-safe truncation, structured local edits
(schema 11), validation counters, cached FFI bindings and observed edit futures.

Independent approval hardening highlights risky flags and rate-limits repeated
identical prompts. Requester labels explicitly say their identity is unverified.
The following remain deferred with PR 3, as authorized by the user:

- OS-verified requesting peer identity and process-name attribution.
- Distinct trusted desktop capture gestures and host approval-flow redesign.
- Opening allowlisted local files under typed, revocable import grants. Until
  that model exists, local source links reveal files instead of executing their
  default handlers.

## macOS changes and evidence still required

macOS uses service-process Security.framework calls with a current-process
Keychain ACL, a separate protected item namespace and verified legacy migration.
Protected-store errors throw instead of enabling plaintext fallback. Background
queries forbid Keychain authentication UI. This does not establish stable signing
identity across ad-hoc updates; actual packaged update behavior must be recorded.
Injected-store unit tests establish migration ordering, not macOS ACL security.

Review also identified a runtime-integrity prerequisite for this credential
boundary: the ad-hoc package disables library validation. A same-user writer
can change a bundled library or resource without changing the service executable
CDHash. Sealing ambient and private-handoff code-path overrides closes that
injection route, but does not establish that mutable bundled code is trusted.
The owner signing decision remains pending; a successful ACL fixture alone must
not be presented as proof of packaged credential isolation. A signature precheck
would also leave a verification-to-load race.

The PDF/RTF helper reads one bounded regular input into memory before applying a
fail-closed sandbox. Parsing then has access to required system resources, with
user files and networking denied. The Apple integration fixture exercises real
PDF/RTF extraction and explicit unrelated-file/network denial.

Service configuration travels through a consumed 0600 file in a private runtime
directory; only its path appears in LaunchServices arguments. Default macOS
socket paths use the private per-user TMPDIR. Local source links reveal files in
Finder. Question-model acquisition requires configured genuine publisher terms
and a digest-scoped acknowledgment before download. No publisher license has
been inferred: absent `FORESIGHT_QUERY_TERMS_URL` intentionally disables this
automatic download.

The frontend consumes the launch handoff once and explicitly installs the
resolved map in its worker. Startup and control commands resolve the same
effective custom profile. A real service subprocess and worker regression
checks this path. Packaged code paths always come from the executable's own
runtime manifest; development executables retain explicit overrides.

The following manual evidence is **pending**, not passed:

1. Use a disposable account/profile to sign in through the packaged service.
   A Terminal `security find-generic-password` against the protected namespace
   must not return the refresh token silently. Do not paste tokens into logs.
2. Upgrade or re-sign the service and verify credential continuity, or a visible
   fail-closed reauthorization requirement. Confirm there is no Keychain dialog
   blocking the background domain indefinitely.
3. Import a normal PDF and RTF through the installed app; run the packaged parser
   sandbox probe on an unrelated fixture and verify file/network access denial.
4. Reveal `.command` and `.terminal` source links and verify Finder shows the file
   without executing it. Confirm normal document links also reveal files.
5. Inspect service-launch argv for absence of configured API-key values and
   confirm the private startup handoff disappears after consumption.

Hosted Apple CI and the disposable-Keychain contract must also pass before this
PR is ready to merge. Linux tests cannot establish these macOS properties.
