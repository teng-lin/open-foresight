# Combined remediation and logging execution

Status: local implementation and qualification in progress, 2026-10-24. Implementation issue:
[#179](https://github.com/teng-lin/open-foresight/issues/179).
Requirements: [combined plan](2026-10-24-repository-remediation-plan.md), revision 6,
SHA-256 `6e1ad7f091caf781a199cc5c063a5109728984ec069c81cc029f151ec654d1a7`.
Its [review record](2026-10-24-repository-remediation-reviews.md) records convergence.

## Delivery contract

Use parallel, separately owned local worktrees and locally reviewed units.
Coordinate exact-source Mac checks with HanSolo before integrating units, and
qualify the final combined Linux/Mac source. Create one final GitHub PR after
local integration, resolve reviews/CI/conflicts, and stop only after its verified
merge to main. The user explicitly lifted the 100-file limit for this delivery.
Owner review and all other checks remain required. No individual work-unit PR
will be opened on GitHub.

Integration branch: `codex/repository-remediation`.
Initial code baseline: `ae9170830ca115cb40a44ad7e9ade8714a170bec`.
Fetched origin/main still matches that source. The distribution-credential topic
remains excluded. Repository-wide PR-size enforcement remains an open policy
decision, not a passed implementation check.

## Local work units (not GitHub PRs)

| Unit | Ownership | Integration prerequisites | Status |
| --- | --- | --- | --- |
| A1 | Recording start/stop/error-path cleanup, persistence retry and indexing ownership: F1/F6, persistence part of F9 | Baseline; coordinate final indexing contract with A3/A4 | Local head `727a9251`; A4 supplies durable final scheduling; combined qualification remains |
| A2 | RPC duplicate ownership, model acquisition deadlines, capture temp root and install-lock interoperability: F5/F7/F8 | Baseline; owns relevant native FIFO/lock surfaces | Baseline `9e4bdaaa`; guard units `8d5a4cb5` and `843b2bdf`; first Arch activation and broader NSS policy remain open |
| A3 | Application backup/restore/erasure, history retention and SQLite transactional/busy-timeout fixes: F2/F20, part of F23 | Baseline; coordinate generated transcript handling with A4 | Local head `91e92b96`; review fixes implemented; final repeat review and latest Mac cases pending |
| A4 | Incremental helper indexing and remaining speech/drain performance: F3, remaining F9 | Coordinate A1/A2 ownership; helper schema/protocol compatibility | Native/protocol `9681e096`; consumer head `bf7a6cd3`; app head `6a77627d` includes review repairs; canonical combined qualification underway |
| A5 | F9 metadata-only import identity and bounded asynchronous directory enumeration | A4 application migration supplies the URI index; independent code review and platform checks | `bb7666f0`; focused Linux/Mac checks passed and scoped Claude review converged; final indexed production measurement remains |
| A6 | F9 speech queue/execution budgets and owned worker lifecycle | A2/A1 runtime; compatible lifecycle consumers | Head `849c4f26`; Linux/Mac native suites passed; scoped native-agent review converged; latest Dart oracle needs Mac qualification |
| B | Complete logging steps 0–4 and safe RPC errors, including nonthrowing reporter before new exports | Integrate after A runtime changes; independent foundation may develop earlier | Foundation `439af36b` under independent reviews; B2 Dart adoption and safe RPC errors in progress; native adoption remains |
| C | Ownership, compile boundaries, service operations and local security | A/B contracts | Pending |
| D/E | Verification/release/dependencies/docs and Python tooling quality | Independent files may progress alongside runtime; final consumers integrate together | Baseline verification underway; native relay measurement correction under local review |
| F | Final distribution trust, update notice and recovery | D's controls and actual external identities/acceptance | Pending prerequisites |

## Initial preflight observations (historical)

- Plan-only document/merge checks passed: all F1–F25 rows and logging sections
  remain, old PR packaging is removed, bounded resource/early-owner/ABI policies
  are retained, and changed-document relative links/anchors resolve.
- Supported Python 3.13.17 was installed for tooling without changing repository
  SDK inputs. The hash-locked development environment is being provisioned.
- The already present Flutter SDK reports 3.35.7, Dart 3.9.2 and expected framework
  revision `adc9010625`; it can serve independent Dart/widget checks.
- Docker access failed in the inherited process groups. The account is already
  listed in the docker group; a `newgrp docker` child reaches Docker 29.9.2.
  No group membership, host configuration or cache was changed. Only Alpine and
  hello-world images were initially local; verified SDK reuse is being resolved.
- HanSolo resolves on the local network and is reachable by SSH as `tenglin`
  using its existing known `hansolo.local` host identity. Initial wrong alias/
  username attempts failed; no host verification was disabled or key replaced.
- No application build/test, native-backed Dart, compiled service/MCP, isolated
  desktop, Mac, model/audio/GPU, signing or installed acceptance has run yet for
  the implementation. Old installed binaries and historical logs are not fresh
  acceptance evidence.

Private planning evidence: `/var/tmp/of-merge-1024/`.
Private execution/test root: `/var/tmp/of-exec-1024/`; commands export it as both
`TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT`. Retain full failed output.

## Qualification ledger

Record each implemented unit's exact source/commit, owned files, local review,
Linux and HanSolo commands, pass/skip counts/reasons, coverage, binary/model
identity, failed output and unresolved prerequisites before local integration.
The integration branch contains the initial documentation commit `d100ecb7`;
application units have not yet been accepted into it. Commits on unit branches
are implementation checkpoints, not completed findings or final acceptance.

### Checkpoint at 2026-10-24 14:58 UTC

- A1: focused recording/application tests **104 passed, zero skipped**; analysis
  and formatting passed. Evidence: `/var/tmp/of-a1/`. Recording final indexing
  still depends on A4's durable replay, cancellation and close integration.
- A2: affected Python tests **231 passed, seven explicitly skipped**; focused
  Dart admission **45/45**, model source **26/26**, compiled transport **9/9**,
  and compiled internal worker mode **3/3** (31 unrelated cases deselected).
  Analysis, formatting, ruff, mypy and timeout guard passed for the unit.
  Evidence: `/var/tmp/of-a2/`. Linux legacy start-after-preflight protection
  remains open; a marker alone cannot exclude an older running binary.
- A3: exact `99f3224cc78d0d886c6ea0d007bf19c37eb29047` passed **131/131**
  focused persistence cases on Linux and **131/131** on HanSolo, zero skips;
  analysis passed. Mac reran the failed backup cases plus the new VFS tests
  first (**58/58**), followed by the remaining persistence cases (**73/73**).
  The original Mac run on `065690b3` failed because Darwin's Unix SQLite VFS
  refused `VACUUM INTO /dev/fd/N`; its failure logs remain retained. The fix
  uses validated preopened main/journal descriptors through a scoped SQLite VFS,
  preserving rollback journaling and avoiding pathname reopening. Linux evidence:
  `/var/tmp/of-a3/vfs-*`; Mac evidence:
  `/private/var/tmp/of-rem-a3-vfs-1024/`. Mac source archive SHA-256:
  `9c3128e5b08e8c87269abdf620d6eb4257561a451aa81f4480cf77686d0bb89c`.
  The SQLite library was freshly built from `d100ecb7` and reused only after
  confirming A3 has no native-source changes; library SHA-256:
  `191c23fd9b05297f26b83a4e6d42d188114893d44b8edb40751ea48163e485e4`.
  This is persistence/syscall evidence, not final combined native acceptance.
- A4 native/protocol: exact `9681e0969cf7d0321425fde600f3839db29b3d2c`
  rebuilt through the repository-root Release CMake configuration using the
  verified Linux SDK and dependency-reuse guard. The previously failing helper
  preflight passed **1/1**, followed by **9/9 helper CTests**, zero skips.
  Evidence and build outputs: `/var/tmp/of-a4-index/native-iteration-2/`.
  Earlier iteration 1's **8/9** result is retained separately; its negative
  future-schema fixtures were corrected after helper schema v2 was introduced.
  Dart focused checks passed **53 cases**, with **one native-dependent skip**;
  Python focused checks passed **32 cases**. The controlled iteration-1 workload
  processed 9,728/19,456 bytes for 64/128 segments (ratio 2.0); it does not
  establish production-model or final application acceptance. The full Linux
  root native build then passed **32/32 CTests**, zero skips, retaining outputs
  in `root-native.log` and `root-native-results.xml` in the same evidence root.
  HanSolo's exact-source fresh root build passed **35/35 CTests**, zero skips,
  with SDK/dependency/ICU provenance and CMake cache checks, under
  `/private/var/tmp/of-rem-a4-index-1024/`. Its source archive SHA-256 is
  `6d5785b6e975e43701b32e413469de7796d9d86fdd4496e007e90e60dc4dd676`.
- D1: local commit `a461f9b1`. The three baseline native-relay measurement failures were rerun first in
  the same prepared Linux container, alongside transition/refusal/cleanup
  regressions: **7/7 passed, zero skips**. The focused host file passed **155/155**.
  The correction retains exact executable hashing and bounds only an observed
  parent-to-child executable transition. Evidence:
  `/var/tmp/of-exec-1024/d1-container/failed-relay.log` and
  `/var/tmp/of-exec-1024/d1-rpc-tests-1.log`. Ruff, mypy (166 source files) and
  the timeout checker also passed. This unit is not integrated yet.

### Baseline evidence and remaining gates

Before application-unit integration, exact `d100ecb7` passed the Linux root
native suite (**31/31**), core (**2,132 passed, 18 skipped**), desktop
(**563 passed, 17 skipped**) and fast integration (**2/2**). The overall Linux
baseline command failed in its host-Python stage on the three relay measurements
above; compiled service/MCP completion is not established by that run. Preserve
the failed schedule output under
`/var/tmp/of-exec-1024/baseline-linux/evidence/test-results/`.
The independent fresh HanSolo root build passed **34/34 native CTests**, zero
skips, under `/private/var/tmp/of-rem-1024-base/`.

The initial host Python baseline had **5,512 passed, 12 failed, 24 errors,
48 skipped** because CMake/Ninja were unavailable through the chosen PATH.
After correcting tool paths, only the 36 failed/errored and 17 infrastructure
unexecuted cases were selected: **53/53 passed, zero skips**. This recovery is
not a claim that a new full-suite invocation passed. Both failed and corrected
logs remain under `/var/tmp/of-exec-1024/`.

Final combined-source full native, core/desktop, required coverage, compiled
service/MCP, isolated-display integration and applicable Mac checks remain
required. Physical audio/GPU, real models, installed upgrade, signing/notarization,
release authority and owner review have not been qualified by these focused
results. No hosted implementation PR has been opened, pushed or merged.

### Independent review and Mac consumer follow-up

Claude CLI completed the independent A3 static review with `CHANGES_REQUIRED`,
exit zero, no tool denials. Full findings remain in
`/var/tmp/of-exec-1024/a3-review/stdout-2.json`. Verified defects include closing
an extra live-database descriptor and thereby releasing SQLite POSIX locks;
stale/corrupt owned snapshots blocking future migration and expiry; a hard-link
publication crash window; and synchronous full-backup verification/per-delete
VACUUM. The unit remains outside integration while these are repaired and
regression-tested. A3 owns new migration 21 for separate backup-erasure versus
full-clear maintenance markers; A4 application projections move to migration 22.
Committed migration 20 stays frozen. The review also identifies the pending
production `generated: true` producer integration, owned by A4; direct Store
fixtures alone cannot establish that acceptance.

HanSolo's full Dart checks on `9681e096` produced **2,158 core passes, 14 skips,
five failures** and **564 desktop passes, 13 skips, one failure**. Core analysis
and desktop analysis passed. Coverage was not qualified because the core test
command failed before formatting/checking its coverage output. Two core failures
were infrastructure errors caused by the coordinator's temporary path exceeding
the fixture's socket limit; both failed cases passed when rerun individually
under the shorter physical root `/private/var/tmp/of4m24`. The other core failures
exposed compatible protocol fixtures still reporting the old version and an
old cancellation oracle. Follow-up `f75e0f15` updates compatible fixtures while
retaining deliberately incompatible cases, and checks actual server cancellation,
lease settlement, persisted pending content and refusal of a late acknowledgement.

The desktop failure exposed a recording fake missing its new capture-ownership
field. Follow-up `727a9251` supplies the empty owned handle list, retaining all
paused/error/resume assertions; the failed widget passed locally, and targeted
analysis/format passed. The initial missing-import compilation failure and all
original Mac failures remain retained. The combined consumer source `bf7a6cd3`
is now being tested under `/private/var/tmp/of-rem-a4-consumers-1024/` with short
physical temporary storage, failed consumers first. Its source archive SHA-256 is
`822d977560c882ee6c515975856c3e342deaf5408a0616fe155b09fd97f6dba5`.
Native binaries are explicitly reused from qualified `9681e096`: only four Dart
fixture/test files changed, with no native, CMake or protocol input changes.

A5 import unit `bb7666f0` passed **49 focused cases, zero skips**, analysis and
formatting; after making its event-loop test independent of wall-clock timing,
the five enumeration cases passed again. It replaces all-document URI admission
with a limited metadata query and recursive synchronous listing with bounded
asynchronous directory/stat operations. The production URI index is pending in
A4 migration 22; indexed production performance is not yet accepted. Evidence:
`/var/tmp/of-a5-import/`. Independent Claude review is running; no integration,
compiled boundary, real-capture or final coverage result is implied.

### Checkpoint at 2026-10-24 17:10 UTC

This checkpoint supersedes the progress descriptions above; earlier failures and
their evidence remain part of the record. Integration is still documentation
only at `98f92135`. No implementation has been pushed and no GitHub PR opened.

- A3 now ends at `91e92b96`. Review repairs removed the extra live-database
  descriptor, replaced hard-link publication with atomic no-replace rename,
  bounded pruning/restore maintenance, separated privacy debt in migration 21,
  corrected the DELETE-to-WAL transition and performed old privacy cleanup before
  taking a new migration snapshot. The latest focused Linux suite passed
  **149/149**, zero skips. Exact `4e2213ed` passed **147/147** on both Linux and
  HanSolo; the latest two added cases still need Mac execution. A fourth
  independent Claude review is running. Evidence:
  `/var/tmp/of-a3/review-3/`, `/private/var/tmp/of-rem-a3-final-1024/`.
  Preparing a restore copy is implemented; the offline activation CLI and final
  binary/schema compatibility workflow are still pending. Current source-body
  retention and filesystem freeblocks are not claimed to be physically scrubbed.
- A4 app head `6a77627d` includes the reviewed A3, import and transport follow-ups.
  The first independent review found a producer readiness hot loop, cancellation
  state loss, stale workspace-epoch retry and missed coalesced capture mapping.
  Repairs passed **206/206** coherent focused cases, **4/4** readiness subprocess
  checks and **1/1** actual host test-helper regression, zero skips. Analysis,
  formatting and the 21-version migration-prefix guard passed. The host helper
  bytes match qualified `9681e096`, but host system libraries differ from the
  qualified SDK: this is functional evidence, not canonical Linux acceptance.
  Repeat review and canonical Linux/Mac combined-source checks remain.
  Evidence: `/var/tmp/of-a4a/review-followup-handoff.md`.
- The previous Mac consumer run at `bf7a6cd3` reached **2,162 core passes,
  14 skips and one teardown failure**. D2 `45bd2f96` fixes owned helper transport
  settlement while preserving upstream behavior for generic TLS/proxy connectors.
  Its focused Linux suite passed **49/49**, and scoped native-agent review
  converged. The failed Mac run did not qualify coverage or desktop completion;
  those gates must run on the combined repaired source. Evidence:
  `/var/tmp/of-d2-status/fallback-review/`.
- A5 `bb7666f0` passed **49/49** focused cases on Linux and HanSolo, zero skips;
  scoped Claude review converged. This does not close all F9 measurements or
  establish the deferred compiled-boundary/real-capture gates.
- A6 adds distinct speech queue and execution deadlines. Production head
  `fe46fc34` passed full root native CTest **32/32 on Linux** and **35/35 on
  HanSolo**, zero skips. Final test-only head `849c4f26` strengthens the repeated
  running-phase deadline oracle with a failing mutation control; focused Dart
  **37/37** passed and scoped native-agent review converged. Latest Mac Dart
  execution and final compiled-boundary acceptance remain. Evidence:
  `/var/tmp/of-a6-speech/oracle-review/`.
- A2's upgrade-lease guard and separate Arch preactivation artifact are committed
  as `8d5a4cb5` and `843b2bdf`. The actual 83-case package-manager matrix has
  **74 passes and nine negative failures**, zero skips; all **22 preactivated
  Arch cases pass**. Eight unprotected first transitions and same-transaction
  hook activation remain failing evidence. Pacman ignores `.INSTALL`
  `pre_upgrade` refusal; protection requires a previously installed
  PreTransaction/AbortOnFail hook. Files-only NSS restrictions also leave common
  NSS configurations unresolved. F8 is open; these results must not be reported
  as universal installed-upgrade safety. Evidence:
  `/var/tmp/of-a2-guard/unit-report.md`.
- B1 `439af36b` implements bounded diagnostic storage, producer/session ownership,
  catalogs and the nonthrowing native reporter foundation. Its focused
  persistence/diagnostics suite passed **174/174**, zero skips. Exact-source
  fresh native builds passed root CTest **31/31 on Linux** and **34/34 on
  HanSolo**, zero skips. With the fresh Linux native library loaded, compiled
  process diagnostics passed **6/6**. The full diagnostics run as root exposed
  a permissions-fixture mismatch; its failed output is retained. The same failed
  case then passed **1/1** as UID 1000, followed by all **27/27** diagnostics,
  zero skips, with the fresh native library still configured. Ordinary-user
  evidence is under `/var/tmp/of-b1/native-loaded-user/`. Independent native-agent and Claude
  reviews are running. This is the foundation: the 133-site adoption inventory,
  safe RPC errors, native diagnostics integration and final acceptance are not
  yet delivered. B2 implementation is underway in a separate worktree.

Stages C, D/E and F remain substantially incomplete. The final combined-source
native/core/desktop/coverage, compiled service/MCP, isolated-display, security,
sanitizer, release/installed and owner-review gates remain required. Real models,
physical audio/GPU, signing/notarization and external platform settings have not
been qualified by these focused results.
