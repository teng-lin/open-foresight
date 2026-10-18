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

The owner explicitly deferred service-process Keychain ACLs and their signing
prerequisites. This PR therefore retains the existing `/usr/bin/security`
credential store, original item namespace and existing private-file fallback
behavior. It introduces no protected namespace or credential migration. The
native Security.framework store and the disposable-Keychain principal fixture
have been removed from the final change.

A future credential-isolation change needs an agreed runtime-integrity boundary:
the ad-hoc package disables library validation, allowing a same-user writer to
change bundled code or resources without changing the service executable CDHash.
Sealing ambient and private-handoff code-path overrides is retained as independent
hardening, but does not establish trust in mutable bundled code. A signature
precheck also leaves a verification-to-load race.

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

1. Import a normal PDF and RTF through the installed app; run the packaged parser
   sandbox probe on an unrelated fixture and verify file/network access denial.
2. Reveal `.command` and `.terminal` source links and verify Finder shows the file
   without executing it. Confirm normal document links also reveal files.
3. Inspect service-launch argv for absence of configured API-key values and
   confirm the private startup handoff disappears after consumption.

Hosted Apple CI and the retained parser/startup acceptance checks must pass
before this PR is ready to merge. Linux tests cannot establish these macOS properties.
