# CI restructuring execution record

The specification is [the restructuring plan](2026-10-19-ci-restructure-plan.md).
The starting main commit is `b62e5e020825f18ef596e40524ef5333866f94ea`.
This record distinguishes implementation from hosted proof; an unverified gate
remains incomplete even when its local fixtures pass.

| Workstream | Current implementation | Remaining proof / dependency |
| --- | --- | --- |
| WS-P | Documentation-only PR #149; agent, Claude and Agy findings addressed | Required CI and merge |
| WS0 | Platform execution audits; weekly acceptance; merge-base diff; statistics and frozen 20,776-line baseline | Mac combined run, enabled hosted Docker fixture, five hosted before/after runs |
| WS1 | Probe before cleanup; storage diagnostics; PR cancellation; bounded same-head waits; contracts in Quality; duplicate removal; explain/selection artifact | Combined Linux/Mac checks, hosted workflows, five-run measurements |
| WS-Na | In-run aggregate, isolated issue exercises, one failed-job retry in original run, independent preview concurrency; recovery code deleted | Hosted issue open/close, retry, two green nights, release/nightly overlap |
| WS-Nb | Scheduled consume-only sanitizers and daily Arch drift, tracked failures | Hosted own-path Arch run and scheduled consumption; remove temporary PR trigger after proof |
| WS2-0 | Consumer-scoped trust table; current producer identities and integrity checks preserved | Combined checks and merge |
| WS2a | Separate worktree implementation underway | Coverage benchmark, Docker split-runner handoff, shadow parity and timings, archive/fork-SDK cases |
| WS2b | Not implemented | Successful shadow evidence before switch; acceptance in-run; dedicated publishers |
| WS2b-2 | Not implemented | Package contracts on in-run bundle |
| WS4 | Not implemented | Consolidated Mac job with qualified SDK roots; real Mac/hosted evidence |
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
No SDK build has been manually dispatched.

The WS1 isolated full Python gate passed 2,799 tests with 95.96% coverage; its
complete source export passed 286 focused tests and 856 subtests. The trust
refactor passed its artifact tests from complete source exports under a different
PR ref, main ref and no ref. The nightly helper's focused branch coverage is
97.95%; drift tracking is 95.95%. All workflow lint runs use actionlint 1.7.7 with
ShellCheck present. Final combined results supersede these component checks.

The combined Linux and SkyWalker/macOS checks use complete source exports without
`.git`. SkyWalker's export at `2b068e5f…` has SHA256
`0f367a59d59311e99bff6cee5f5d65a3bd7bb3c7627a0efe9f92adf244517363`.
It uses cached Python wheels, the existing pinned Flutter checkout, Bash 3.2 and
Make 3.81, without touching the user's existing Mac source workspaces.
Docker runtime checks remain hosted because the local Linux Docker socket is
inaccessible. Measurements and green hosted runs will be recorded as they exist;
no projected savings count as measured results.
