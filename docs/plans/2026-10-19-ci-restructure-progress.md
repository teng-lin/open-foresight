# CI restructuring execution record

The specification is [the restructuring plan](2026-10-19-ci-restructure-plan.md).
The starting main commit is `b62e5e020825f18ef596e40524ef5333866f94ea`.
This record distinguishes implementation from hosted proof; an unverified gate
remains incomplete even when its local fixtures pass.

| Workstream | Current implementation | Remaining proof / dependency |
| --- | --- | --- |
| WS-P | Documentation-only [PR #149](https://github.com/teng-lin/open-foresight/pull/149) merged; required CI green | Complete |
| WS0 | Platform execution audits; weekly acceptance; merge-base diff; statistics and frozen 20,776-line baseline | Enabled hosted Docker fixture, five hosted before/after runs |
| WS1 | Probe before cleanup; storage diagnostics; PR cancellation; bounded own-head or compatible trusted-main waits; contracts in Quality; duplicate removal; explain/selection artifact | Hosted workflows, five-run measurements |
| WS-Na | In-run aggregate, isolated issue exercises, one failed-job retry in original run, independent preview concurrency; recovery code deleted | Hosted issue open/close, retry, two green nights, release/nightly overlap |
| WS-Nb | Scheduled consume-only sanitizers and daily Arch drift, tracked failures; verified compiler-work restoration before current configure/build/tests | Hosted own-path Arch run and scheduled consumption; remove temporary PR trigger after proof |
| WS2-0 | Consumer-scoped trust table; current producer identities and integrity checks preserved | Hosted checks and merge |
| WS2a | Separate worktree implementation underway | Coverage benchmark, Docker split-runner handoff, shadow parity and timings, archive/fork-SDK cases |
| WS2b | Not implemented | Successful shadow evidence before switch; acceptance in-run; dedicated publishers |
| WS2b-2 | Not implemented | Package contracts on in-run bundle |
| WS4 | Preimplementation in an isolated worktree | WS2b-2 dependency; consolidated Mac job with qualified SDK roots; real Mac/hosted evidence |
| WS5b-1 | Not implemented | On-demand tested release candidates, source floor, legacy transition, candidate receipt |
| WS5b-2 | Not implemented | API/attestation-backed publish gate and upgrade acceptance |
| WS5b-3 | Not implemented | Two successful candidates-only runs (or one plus a release), then remove per-merge candidates |
| WS5a | Not implemented | Per-job identical-tree receipts, sweep reconciliation, tracking and cache freshness |
| WS2c | Not implemented | Two green nightlies and one green Arch run before removing PR Arch/stage caches |
| WS3 | Not implemented | Explicit union rules, closure, live full label, local tier and last-50-PR replay |
| WS7 | Deferred by plan | Measure marginal benefit after main pipeline changes |
| WS8 | Deferred | Legacy expiry dates; explicit SDK-promotion decision and remaining-wait audit |

## Reuse and validation evidence

All original core, LiteRT, Whisper and macOS component fingerprints remain
unchanged in the foundation. Activating the existing legacy-query host tests
requires the pinned SentencePiece Python wheel. `requirements-dev.lock` is an
actual Linux SDK image input, so only the assembled Linux SDK image identity
changes (`3903ef9e…` to `2cd14951…`). Its core, LiteRT and Whisper components must
reuse their verified artifacts; this is not a justification to recompile them.
Live probes verified all six unchanged component artifacts, including the original
macOS runtime from run `39177548843`. The new assembled Linux image identity has
no qualified retained artifact. A necessary image assembly must restore those
verified parents and change only its Python environment/image layer. No SDK build
has been manually dispatched.

The final combined Python coverage gate at `fa018ee2802a82313575d5e482d69396e025ec87`
passed 2,908 tests on Linux (28 skips, 96.09% coverage) and 2,916 on SkyWalker/macOS
(20 skips, 96.27% coverage). Both enforce the existing 95% threshold from complete
tracked source exports without `.git`. Linux's production host runner passed
268 tests with four expected skips. A fresh-JUnit audit of the full Mac run
confirmed every assigned host-contract file executed; the production Mac runner
also passed 309 tests with 12 expected skips at `e0419026`.

The trust refactor and compiler-work helper passed their artifact tests from complete source exports under a
different PR ref, main ref and no ref. All workflow lint runs use actionlint 1.7.7
with ShellCheck 0.11.0 present. Ruff, mypy (126 source files), timeout lint,
clang-format 22.1.8, Dart 3.9.2 formatting (414 files) and actual protobuf binding
regeneration with protoc 35.1 passed using existing tools and cached packages.

SkyWalker's `fa018ee2…` export has SHA256
`da22190468062cbd7ce37bfaee09f383f91136a6771d8df2763ecbaf41c52060`;
all 987 tracked source files remained byte/link-identical after execution.
It uses cached Python wheels, the existing pinned Flutter checkout, Bash 3.2 and
Make 3.81, without touching the user's existing Mac source workspaces.
Real DMG mount, codesign, Mach-O rewriting and Darwin filesystem contracts passed.
The absent compiled application/service/MCP binaries mean their actual subprocess
integration probes remain hosted requirements; their expected skips are retained.
Docker runtime checks remain hosted because the local Linux Docker socket is
inaccessible. Measurements and green hosted runs will be recorded as they exist;
no projected savings count as measured results.

The new Arch drift job first searches retained, verified native compiler work,
including the original payload `12214226069` and its small receipt `12213701343`
from run `39305527517`. The shared restoration helper preserves original producer
proofs and checks actual compiler, SDK bytes, packages, workspace, configure
arguments and unknown flags. Only proven Dart test/scheduling/reporting settings
are excluded from compiler compatibility; successful test identities still bind
them. A miss records concrete incompatible fields, and unresolved API searches
fail. Current configure, incremental build and every test always run afterward.
Real Make/Ninja fixtures verify unchanged objects survive. No dependency caches
were removed. A redundant helper-only full run hit the host's temporary-storage
quota; its failure log is retained and the passing final Linux gate above reran
every affected test from a private disk-backed temporary directory.

At `66cb3f3`, the foundation deletes 1,438 lines and adds 5,436, including safety/provenance
fixtures. Its counted CI code is 23,760 lines versus the frozen 20,776 baseline;
the planned net reduction remains pending deletion of the replaced pipelines.

## Review disposition

Agent-team, Claude CLI and Agy CLI reviews found retry, concurrency, tracking and
trust-table gaps. Valid findings were fixed together before the implementation PR:
release serialization; original failed/cancelled producer retry and recovery;
retry-safe uploads throughout the called workflow closure; compatible trusted-main
producer waits; scoped trust consumers and receipt tiers; latest actual drift
results; explicit main-ref/event writer guards; issue persistence before optional
metadata; isolated exercises; obsolete preview documentation; and selection of the
Docker fixture's real consumer. Agy's compare-pagination concern was rejected
after live page-1/page-2 API responses proved pagination works. Review did not
authorize weakening any artifact checksum, original producer or attempt proof.

Actual original-artifact probes caught a historical compatibility regression:
producers predating the new trust table were incorrectly required to contain it.
The fix allows absence only when the immutable old controls do not reference that
table; all required recipe inputs and present-file bytes/modes remain verified.

## Hosted foundation rollout

[PR #150](https://github.com/teng-lin/open-foresight/pull/150) opened at head
`846073c`. Six unchanged component jobs reused their verified originals. The new
Linux image assembler in run `39330591028` was preserved. Its first acceptance
consumer failed early because a skipped same-name registry alternative appeared
before the actual PR archive job. The consumer-only wait correction ignores that
placeholder and retains the source, identity, original-attempt and checksum
checks. Every SDK producer-control file remains byte-identical to the running
producer; the fix does not require another SDK assembly. Run `39330591028` then
finished successfully and produced artifact `12225415661`. A live small-receipt
probe qualified that original image under the corrected consumer without
transferring its 1.28 GB payload. The complete Linux export at `66cb3f3` passed
2,924 tests (28 skips, 96.10% coverage). The new waiter/export fixtures passed
60 tests under each inherited PR/main/unset ref. Mac source `17d22f8` passed 2,931
tests (20 skips, 96.28% coverage) with only one stale CLI-name assertion; the
corrected assertion's entire 23-test file passed at `66cb3f3`, with both source
integrity manifests preserved and the host execution audit passing. Hosted checks and
reviews remain pending until their actual results are recorded.

The next PR #150 review batch reduces consumer polling from ten status/scope
requests to two fully paginated scope requests every 60 seconds. Older active
runs remain visible after completed pages. Linux and Mac consumers perform one
last qualified pull when a producer finishes between artifact and job reads,
including the first poll; API/provenance errors remain fatal. Debian 13 testing
now runs independently of the BuildKit fixture, and the frozen snapshot command
includes `headRefName`. Focused validation passed 147 tests and 99 subtests,
including both completion races, the original context/checksum path, pagination,
and independent Debian execution. Independent team review found no residual
issue and confirmed all 11 original SDK producer-control bytes and modes again.
The pre-existing internal `ci_artifacts.pull(wait>0)` completion race is tracked
for the already planned shadow transport change after this foundation merges:
changing that producer control before the original producer's final source is
approved would invalidate reusable SDK evidence. Consumer waits in this PR use
`pull(wait=0)` plus the corrected qualified polling wrapper.

The corrected WS2a source `3e8a701` also passed its complete Git-free export:
Linux 3,009 tests / 28 skips at 95.55% coverage; SkyWalker Mac 3,017 tests /
20 skips at 95.71%. Mac's production host runner passed 364 tests (11 skips,
one Arch-owned notice test deselected) and its full-suite inventory audit.
All 1,000 tracked entries remained unchanged on both hosts. This pre-PR Mac run
caught BSD/GNU tar exclusion differences and Make 3.81's whole-second comparison
in a changed-source fixture. The corrected source copy preserves the verified
seed, tracked `.coveragerc`, nested source directories and transferred Dart cache;
a real Dart import from that restored cache passed without dependency resolution.
Actual Docker runtime and five hosted shadow measurements remain pending.
