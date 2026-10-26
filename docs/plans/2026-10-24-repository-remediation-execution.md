# Combined remediation and logging execution

Implementation and validation record, updated 2026-10-26. Current delivery state:
[PR #180](https://github.com/teng-lin/open-foresight/pull/180). Implementation issue:
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
The initial fetch matched that source; the reviewed candidate now includes main
through `de70a24c`. The distribution-credential topic
remains excluded. Repository-wide PR-size enforcement remains an open policy
decision, not a passed implementation check.

## Initial local work allocations (historical, not GitHub PRs)

The allocation statuses and dated entries below are chronological checkpoints.
They preserve failures and earlier prerequisites rather than describing today's
remaining implementation. The delivery amendment and latest qualification
checkpoint govern the retained scope; PR #180 records current CI and merge state.

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

### Review follow-up after the 17:10 checkpoint

A3's fourth review found only a misleading history-size claim: the frozen schema
applies 32 MiB per entity, as the plan requires, rather than profile-wide. Commit
`d395e99b` corrects both documents and adds a real two-note Store regression.
The retention file passed **10/10**, zero skips, and core analysis passed. The
fifth Claude follow-up review returned **CONVERGED**, with no denied reads;
production code and migrations are unchanged. Latest Mac qualification remains
pending, and the final offline restore activation workflow is still open.

B1 remains **CHANGES_REQUIRED** after both independent reviews. The native-agent
review identified a POSIX-lock loss when rejecting a hard-linked logging inode,
producer-ticket lifetime/bounds problems and descendant filesystem qualification
gaps. Claude identified additional rate-table saturation, startup-credit,
retention-crash, missing ownership-decision close and admission-test gaps.
Findings are being verified and repaired together in the B1 worktree; `439af36b`
is not accepted on the strength of its passing focused tests. Review evidence:
`/var/tmp/of-b1-native-architecture-review.md` and
`/var/tmp/of-exec-1024/b1-review-1/stdout.json`.

Canonical A4 combined-source Linux/Mac qualification is running in isolated
exports; its second independent Claude review is pending. B2 adoption continues
in its separate worktree and will consume the repaired foundation. Stage D's
first documentation/link-check unit is now under local implementation; none of
these activities closes the remaining stages or final integration gates.


### Local integration and qualification checkpoint

The integration branch now includes D1 relay measurement fixes (`39267326`),
Linux-only host guards (`ca1529e9`), the reviewed documentation/link unit
(`9bcb796a`), and the persistence/indexing unit (merge of `ca385df0`). No hosted
PR or push has occurred; one final PR remains the delivery target.

- Exact `9bcb796a` passed the full Python suite: **5,587 passed, 31 skipped,
  1,396 subtests passed**, four warnings, exit zero. This precedes the indexing
  merge and does not qualify the new combined source. Evidence:
  `/var/tmp/of-int-d/python-full.log` and `python-full.exit`.
- A4 final Claude round four returned **CONVERGED**, following independent
  consumer review. Core at `ee3a7541`: Linux **2,265 passed / 19 skipped**,
  **94.99%** coverage; Mac **2,269 / 14**, **95.31%**. Final desktop at
  `ca385df0`: Linux **567 / 17**, **93.72%**; Mac **569 / 13**, **93.62%**.
  Linux gates were 90%; Mac desktop was report-only. The final changes were
  desktop fixtures only; 1,401 other Git entries match the core-qualified tree.
  Native inputs were explicitly reused from qualified `9681e096`, not rebuilt
  for that fixture change. Actual skip reasons, failure history and identity
  proofs remain in `/var/tmp/of-a4a/canonical-handoff.md` and its qualification
  directories. Compiled service/MCP, complete desktop integration, physical
  audio and real-model acceptance remain open.
- Exact A3 `d395e99b` passed **150/150**, zero skips, on HanSolo; its fifth
  Claude review converged. Offline restore activation remains pending.
- D-docs final review converged. Its offline link checker checks 314 Markdown
  files. Hash-pinned parser dependencies change the SDK input identity and need
  final pipeline requalification. Combined `9bcb796a` passed actual Mac default
  mypy (167 files), subprocess-timeout checks and three unsupported-host guards.
  This is not a full Mac Python-suite claim.
- B1 original foundation remains unaccepted. Repairs through `b93c64af` address
  producer bounds, reporter settlement, retention, filesystem checks and stack
  privacy. Actual original SQLite/POSIX alias-lock loss was reproduced; safe
  storage therefore requires an owned OS child. Frozen design draft three
  SHA-256 `b7fac942b6b94361448aec1cc2c41b23ec04643580bd3f300c0418a88efbb0b6`
  has converged in both native reviews; Claude round three is running.
  Stable per-UID production staging roots independent of TMPDIR still require
  explicit document incorporation. Worker implementation and accounting proofs
  remain open. B2 broad logging adoption continues separately.
- The coherent native prerequisite `af7cc18d` passed fresh root CTest **33/33
  Linux and 36/36 Mac**, zero skips. New C1 native checkpoint `a9b36f3f` passed
  fresh Linux root CTest **36/36**, zero skips; its matching HanSolo build is
  running under PID 92475. C1 Dart ownership integration remains underway.

These are local unit qualifications. Final merged-source gates, remaining C/D/E/F
requirements, upgrade safety and owner-controlled signing/settings acceptance
remain incomplete. Evidence is retained under `/var/tmp`; no skipped or reused
path is represented as fresh acceptance.


### Helper gate repair and first tooling ratchet integrated

Commit `756c0d01` fixes an integration gap discovered by the full Python run:
`meeting_incremental_native_test.dart` was absent from the skip inventory, and
staged CI did not export or retain its controlled test helper. The core gate now
exports a separate `FORESIGHT_TEST_HELPER`; both exact native-runtime allowlists
retain `ForesightHelperTest`. Production packaging still selects `ForesightHelper`
explicitly. Agent review and Claude review both returned **CONVERGED**. The exact
allowlist addition remains in the final owner-review scope; neither review is
owner approval.

The first combined run retained **30 failures, 24 errors, 5,534 passes and 31
skips**. Most failures came from an unconfigured host CMake shim; the missing skip
inventory was a real source integration defect. With the inventory repaired and
pinned CMake/Ninja on PATH, failed-first verification passed **54/54**. The real
core-gate fixture passed **50/50**, and artifact/stage tests passed **66/66**.
A complete Git-free export passed those **66** cases in each unrelated PR, main
and explicitly unset-ref environment; module origins were asserted inside the
export. Initial ref runs from worktree cwd are retained separately and are not
used as export-only evidence.

The repaired full Python suite passed **5,588 tests / 31 skips**. The separate
required coverage command passed the same counts with **95.82%** combined
line/branch coverage against the **95%** floor. It reported 187 warnings,
including unclosed SQLite connections requiring further ownership investigation;
no warnings were suppressed. Evidence, original failures, input hashes and reports:
`/var/tmp/of-int-a4/`. This was executed as `b41ea253` plus the recorded seven-file
diff, byte-equivalent to the `756c0d01` source tree, before the E merge.

Merge `5a6a92f7` adds reviewed Stage E checkpoint `3cb7a618`: 370 tracked Python
files, 167 production modules, 138 entrypoints, 88 path mutations and 68 dynamic
loader calls are inventoried with caller candidates. The conservative graph has
unresolved computed targets and is not complete semantic import conversion. The
first explicit per-module typing ratchet covers only the standard-library timing
leaf. Existing timing tests passed **6/6**; removing annotations failed the new
ratchet, then source was restored exactly. A failed `strict` shorthand experiment
is retained; explicit supported per-module flags avoid its unintended global
expansion. Native review and Claude follow-up converged. Post-merge ruff, mypy
(167 files), timeout/link checks and timing tests pass. Package/import migration,
remaining CI typing/complexity work, and Stage E completion remain open.

C1 native `a9b36f3f` now has fresh **36/36 Linux and 39/39 HanSolo** root CTests,
zero skips. Exact library/helper hashes are retained under
`/var/tmp/of-c1-a9-native/{linux,mac}/binary-provenance.json`. This is the first
native iteration: subsequent speech-join repairs still require new qualification.

B1 draft-three Claude review found eight remaining design issues, including
staging lifecycle, Darwin descriptor inheritance, concrete IPC scheduling,
enumeration memory, platform floors, executable trust, build identity and
producer-lifetime exhaustion. The author is verifying these against pinned
sources and revising the design; broad storage-worker implementation remains
pending. Earlier native convergence is not substituted for resolving the new
findings. No push or hosted PR has occurred.


### Profile migration connection ownership repaired

Reviewed unit `278c8f10` is integrated locally. Five production SQLite transaction
contexts now commit/roll back and then close explicitly, before backup/recovery
copies. Two regressions retain actual connections to prevent GC from masking
ownership, verify SQL rejects use after close, and assert closure when profile
copies occur on success/failure. The original production source fails both;
repaired bytes were restored exactly. Existing fixture contexts now close too;
SQL, schema ceilings, credential handling and profile transformations are unchanged.

Focused Linux and HanSolo runs each passed **32 tests and 11 subtests**, zero
skips, with warnings treated as errors. Ruff, mypy (167 files) and timeout checks
passed; both independent native-agent and Claude reviews converged. The complete
Linux Python coverage run at the frozen unit passed **5,590 tests / 31 skips**,
**95.82%** against the 95% floor. Warnings fell from 187 to 52; the remaining
warnings are retained and are not suppressed or treated as resolved. This is not
a full Mac Python-suite or completed offline restore-activation claim.
Evidence: `/var/tmp/of-profile-ownership/`, source archive/hash, both negative
controls under `/var/tmp/of-int-a4/migration-ownership-*`, and Mac export
`/private/var/tmp/of-rem-profile-278c8f10`. Existing Mac dependencies were reused
only after exact lock equality, without claiming a fresh dependency installation.

The full run precedes the documentation-only initializer-trust prerequisite note
`543ae3fa`. Its local links passed separately. The initializer/import conversion
itself remains pending: a real initializer must enter SDK producer-control closure
with an explicit historical-absence policy before introducing that new execution
dependency. No hosted PR, push, final owner approval or main merge has occurred.


### First package/entrypoint batch integrated

Merge `1c45995b` integrates `908aac5d` and its documentation/test-only follow-up
`d8fa2ffd`. `tools` is now a real package, and all eight registry workflow calls
use `python -m tools.ci_registry` from an explicit workspace directory. Both
initializer path filters and the exact transport contract change together; the
two historical direct-script snippets remain readable by the current trusted
recipe parser. A regression proves unchanged compiler identities for all seven
SDK components. The standalone direct-script interface remains functional from
an unrelated directory, including an export without an initializer.

SDK producer controls now include the initializer and registry executable.
Historical initializer absence remains absence, never an invented blob or
approval for a present consumer file. Present controls retain verified Git bytes,
modes and regular-file requirements. Three deliberate control omissions/bypasses
failed their regressions, then source was restored exactly. The workflow guards,
permissions, publishing authority and compiler/SDK versions are unchanged.
**Final owner review remains required** for these trust/control/workflow changes;
independent agent/Claude convergence is not owner approval.

The frozen `908aac5d` complete Linux coverage run passed **5,610 tests / 31 skips**,
**95.83%** against the 95% floor, with 52 retained warnings. A complete Git-free
export passed **3,013 tests / one Docker-opt-in skip / 297 subtests** in each of
unrelated PR, main and explicitly unset-ref environments; module origins were
asserted inside that export. Actionlint **1.7.7** with ShellCheck **0.9.0** on PATH,
ruff, mypy (168 files), timeout and link checks passed. Native-agent and Claude
reviews converged. The follow-up changes only historical wording and strengthens
the standalone fixture; all nine affected cases passed. Exact `d8fa2ffd` passed
**286 tests / 97 subtests**, zero skips, on HanSolo, plus ruff, mypy (168 files),
timeout and link checks. Evidence: `/var/tmp/of-e-package/`, including source hashes,
negative controls, ref metadata, original failed legacy-contract regression,
full reports, follow-up equivalence and Mac logs. This is the first package batch;
other primary entrypoints, dynamic/path imports and quality work remain open.

### Native qualification correction and unresolved review findings

Fresh native checkpoint `8fe08fcd` passed root CTest **36/36 Linux and 39/39 Mac**,
zero skips. The team discovered that the inherited Linux `/opt/dev-python` was
actually Python **3.12.3**. Earlier Linux native results remain evidence of their
executed C++/fixture paths, not qualification of the supported Python3.13 tooling
path. The same fresh `8fe08fcd` build was reconfigured using read-only pinned
Python **3.13.17** and site packages, then passed all **36** root CTests again.
Library and both helper hashes were verified unchanged, not described as a
second fresh compilation. Details: `/var/tmp/of-c1-8fe-native/linux/`, including
`python-toolchain-correction.json` and both retained runs. Mac used pinned Python
3.13. HanSolo currently runs **macOS26.6 with SDK27**; these results do not prove
runtime acceptance on the minimum macOS15 host, which remains required.

Claude native review found real shared-executor head-of-line blocking, speech
join/reuse, parent/child cleanup and retained-unconfirmed-state issues. The author
reproduced three counterexamples against immutable `8fe08fcd`, including legacy
admission failure from abandoned async records. Lifetime-v2 corrections are in
progress; neither `8fe08fcd` nor the WIP is accepted as complete C1.

B1 worker draft4 failed independent native and Claude review. Pinned Dart macOS
pipe creation added unaccounted inherited control endpoints; a failed factory
could withhold the process handle before the child watchdog. That expanded
residual was rejected. Native-owned spawn/atomic shared bootstrap and exact
Darwin reaper ownership are being evaluated before another freeze, with no broad
worker implementation yet. A portable probe demonstrated VM reaping interference
and successful-child quiescence on Linux and HanSolo; it does not prove failed
starts or PID-reuse safety. Evidence: `/var/tmp/of-b1-fix/`, including the discarded
candidates and Mac probe. B2's first full core and desktop adoption runs failed;
semantic, CLI, fixture/real-flock and privacy repairs continue with failed output
retained. No hosted PR or push has occurred; the final combined-source and
remaining boundary/security/distribution gates are still open.


### User scope amendment: earlier draft PR and deferred security additions

The user requested deferral of broader security work and an earlier PR. The
[delivery scope amendment](2026-10-24-remediation-delivery-scope.md) is authoritative
for those deferrals. They are unfinished follow-ups, not completed findings.
Existing safety/privacy/tests/trust protections and owner review remain required.
Prepare one draft from reviewed integration, then stabilize accepted runtime and
logging work in that same PR. Do not expand unrelated cleanup before the draft.

### Draft PR checkpoint and first follow-up fixes

The single [draft PR #180](https://github.com/teng-lin/open-foresight/pull/180)
is open from `codex/repository-remediation`, initially at `47dbb0d5`. The draft
lists unfinished logging/native integration, failures and owner review; it is
not merge-ready. Earlier entries describe their historical checkpoints.

At that frozen source, fresh root Linux native CTest passed **32/32**, zero
skips. Its matched library/helpers passed core **2,268 / 17 skipped**, **95.02%**
coverage and desktop **567 / 17 skipped**, **93.72%**, both above 90%. The compiled
service/MCP and isolated-display suite had **33 passed / one failed / zero skips**:
immediate search after stopping capture missed the pending final index. A
separate search-readiness fix is in progress; Stop must not wait for the helper.
Ruff, mypy (168 files), timeout guard, format/analysis and actionlint with the
hosted ShellCheck version passed. Python had **5,609 passed / 31 skipped / one
failed**, from a procfs observation racing with descendant reaping.

The same frozen source was freshly built on HanSolo: **35/35 CTests**, zero
skips; core **2,269 / 14 skipped**, **95.31%** report-only coverage; desktop
**569 / 13 skipped**, **93.61%** report-only coverage. This is macOS 26.6/SDK 27
with deployment target 15.0, not macOS 15 runtime, device/TCC, GPU or real-model
acceptance. Linux evidence is `/var/tmp/of-draft47`; Mac evidence was retained
there under `mac` and remotely at `/private/var/tmp/of-rem-draft47`.

The reviewed test-only follow-up `ca8df0f1`, locally merged as `3284cd96`, uses
the already acquired descendant pidfd to assert alive-before and exited-after
cleanup, preserving the five-second bound and every supervisor/session oracle.
Its focused module passed **155/155**, zero skips; full Python then passed
**5,610 / 31 skipped**. An initial exact poll-mask assertion rejected the valid
POLLIN|POLLHUP result; that failed output was retained before correcting the
readability bit test. Evidence: `/var/tmp/of-draft47/rpc-observation*` and
`/var/tmp/of-rpc-fixed-full`.

Hosted CI's first native-stage failure was repeated GitHub API HTTP 503 during
producer qualification, not permission to bypass artifact trust. Its TSan job
also found an exit-time gRPC thread leak in an intentionally crashed helper;
the existing probation policy allowed the workflow conclusion to remain green.
This individual failure remains tracked. The isolated `49ba48c6` correction
uses actual self-SIGKILL and strict signal-status assertions for abrupt-crash
fixtures, retaining transaction/replay checks and sanitizer log gates. Native
and Claude review converged; fresh Linux failed-first helper tests **2/2** and
full CTest **32/32** passed. Mac, matched application and hosted sanitizer
qualification remain before integration/acceptance.

### Reviewed follow-up integration before the next draft push

The corrected abrupt-crash unit is `1140ddc3`, locally merged as `2ced21ca`.
Both native-peer and whole-candidate Claude review converged. A successful
self-SIGKILL waits in `::pause()` until delivery; an actual kill failure keeps
the strict failing exit-86 fallback. Mac caught the earlier kill/exit delivery
race; the next candidate caught a C++ name-shadowing compile error. Those failed
outputs remain. Final failed-first helper cases passed **2/2** on each platform,
then full fresh root native CTest **32/32 Linux** and **35/35 Mac**, zero skips.
Mac core **2,269 / 14 skipped / 95.31%** and desktop **569 / 13 skipped / 93.61%**
passed. Linux desktop passed **567 / 17 skipped / 93.72%**; its core run had
three old cold-source-child watchdog failures, and compiled service retained
the already identified immediate-search failure. These are failed results,
subsequently addressed by the separate search/fixture unit below. Evidence:
`/var/tmp/of-helper-crash114`, including prior attempts retained separately.

`753a53c5`, locally merged as `fe89c8d0`, fixes the shared test helper's unset
default to physical `/private/var/tmp` on Mac and `/var/tmp` on Linux. Explicit
overrides, private per-test allocation and cleanup are unchanged. Hosted Mac
had **64 core and two desktop failures** from traversing the `/tmp` symlink
during descriptor-anchored backup operations. Actual Mac old-default controls
failed; the new default passed **20 core and seven desktop cases**, zero skips,
with the override deliberately unset. Analysis, formatting and independent
native-peer review passed. Evidence: `/var/tmp/of-temp-default753`; final
combined default-path coverage remains required.

Ordered search commits `7e0fd1f8` and `763e78d2` were locally merged as
`d88b65ae` after whole-candidate native/root and repeat Claude review converged.
Search borrows a bounded snapshot of active stopped index producers, with a
five-second readiness deadline; Stop stays independent. A captured failure
refuses that call, while later searches over ordinary indexed sources remain
available. Inactive durable backlog filters out before the SQL limit. Three
new availability controls fail against the prior reviewed candidate. The old
readiness child now compiles outside its unchanged 12-second operation watchdog;
kill/reap bounds, markers and counters remain intact. The new controlled search
test observes producer settlement before its original reply envelope, without
renewing the production deadline.

Final search-unit qualification passed Linux core **2,288 / 17 skipped / 95.06%**,
desktop **567 / 17 skipped / 93.72%**, and fresh compiled service/MCP plus both
isolated-display native UI cases **34/34**, zero skips. The original immediate
Stop-to-search assertion is unchanged. Mac core passed **2,289 / 14 skipped /
95.35%**, desktop **569 / 13 skipped / 93.61%**. Focused cases passed **24/24** on
both platforms. This explicitly reused qualified root-47 native products after
checking 108 native/protocol/generator inputs; it is not a fresh search-native
build. Earlier timing/path failures and negative-control output remain in
`/var/tmp/of-search-763/qualification/handoff.md` and adjacent evidence.

The next combined-head Linux/Mac matrix will verify these integrated changes
together. Logging worker/adoption, native lifecycle, broader client/service
architecture, remaining tooling and installed-package acceptance are still
in progress; none is closed by these local integrations. Hosted Debian smoke
also failed desktop process identity; its full job output is retained for
reproduction rather than weakening the owned-process check.

The next already-started tooling batch `3cfaa374` is also locally integrated:
profile migration uses normal package imports for the documented module command
and sibling imports for direct-script compatibility, including Git-free exports
without a package initializer. Its two real subprocess regressions supply
conflicting ambient modules and verify schema, digest, user text, model and
attachment bytes, path rewrites and retained backup contents. Migration/rollback
and credential sourcing behavior are unchanged. Native-peer and Claude review
converged; Linux focused checks passed **40 tests / 11 subtests**, and its full
coverage run passed **5,612 / 31 skipped**, **95.85%** against 95%. The same focused
**40 tests / 11 subtests**, zero skips, passed on HanSolo with an exact-lock
development environment. Evidence: `/var/tmp/of-profile-import`. This is one
inventory-derived entrypoint batch, not completion of all Stage E imports.

### Draft checkpoint a8 and readiness-fixture follow-up

PR #180 now contains reviewed checkpoint `a8a3d2f6`. Its fresh combined Linux
native build passed **32/32 CTests**, zero skips; full Python passed **5,612 /
31 skipped**, **95.85%** coverage; desktop passed **567 / 17 skipped / 93.72%**;
compiled service/MCP and both isolated-display UI cases passed **34/34**, zero
skips. Ruff, mypy, timeout guard and actionlint with ShellCheck passed. Linux
core retained **2,287 passed / one failed / 17 skipped**: the controlled search
fixture timed out waiting two seconds for its first producer RPC. The failed
combined-head core coverage gate was not reported as passing.

Fresh a8 HanSolo native CTest passed **35/35**, zero skips. The first core run
retained one service-lifetime timeout (**2,288 passed / one failed / 14 skipped**).
The unchanged failed case passed first in isolation, then only the failed core
lane was repeated: **2,289 / 14 skipped / 95.35%** report-only coverage. Desktop
then passed **569 / 13 skipped / 93.61%**. The original timeout remains evidence;
isolation is not a demonstrated fix. Evidence: `/var/tmp/of-pr180-a8` and the
physical private HanSolo root `/private/var/tmp/of-rem-pr180-a8`.

Reviewed fixture-only commit `52b26eb9`, applied locally as `f15e0df8`, warms the
actual Domain/client/server cursor path before the existing operation clocks.
The unused meeting ID produces no request, cursor, transcript or durable source
change, all checked explicitly. Each subsequent RPC still opens its own owned
channel; this is no connection-reuse claim. Stop, producer-start, search and
reply deadlines and their original assertions are unchanged. Independent native
peer and whole-file Claude review converged. The focused module passed **20/20**,
zero skips, on both platforms; bypassing search readiness still fails the
original ownership assertion. Earlier a8 isolated success alone was not treated
as load acceptance.

Repeating the failed full Linux core lane at frozen `f15e0df8` passed **2,288 /
17 skipped / 95.06%**, enforcing 90%. Format and analysis passed. This explicitly
reused the fresh a8 library/helpers after comparing all **58** native, root
CMake, helper and inference input paths in that source export and build image;
it is not a new native build. Full event output, skip names/reasons and artifact
hashes remain in `/var/tmp/of-pr180-f15/out-core/report.json` and adjacent logs.

Hosted a8 native, address/undefined sanitizer and thread-sanitizer jobs passed.
The platform workflow is still running at this update; its Debian smoke job
again failed the installed desktop identity check. The failed output is retained
in `/var/tmp/of-pr180-deb/job-a8.log`. A green sanitizer workflow is not being
substituted for completed platform or installed-package acceptance. Logging,
native lifecycle and client/service architecture work remain unintegrated and
must still complete review and full qualification.

### Installed startup observation and hosted default-path oracle

The reviewed installed-GUI repair `a2b77878` is locally applied as `afad64eb`.
An actual historical source-47 Debian package reproduced an empty command-line
observation between two Bash-image observations on attempt **372** after **371**
successful native-exec transitions. A first repair also encountered the owned
child's pre-exec Python image and inherited parent arguments. Both failed outputs
remain. The final repair accepts those exact incomplete observations only while
waiting for the same owned child to exec, within the original startup deadline.
Parent image/argument matching uses a bounded private snapshot; argument values
are not persisted. Incomplete observations never grant wrapper cleanup or GUI
approval. Exact native executable, effective-user, coherent wrapper-argument,
approval and termination checks remain required.

Native-peer and whole-candidate Claude reviews converged. Full Python passed
**5,623 / 31 skipped / 95.85%**, enforcing 95%; ruff, mypy (**168** files) and the
subprocess-timeout guard passed. Focused installed-GUI/document tooling passed
**124/124**, zero skips, on Linux and HanSolo, and from a complete Git-free export
under PR, main and unset-ref environments. The Mac source archive hash matched
the frozen export and reused an environment whose development locks matched.
These offline tests are not actual macOS GUI/TCC acceptance.

The final production startup-wait helper passed **500/500** actual installed
native-exec transitions on the historical package, including seven retained last
observations with empty argv. One actual MCP-first GUI onboarding/approval plus
PDF/RTF document probe also passed with the repaired tooling. This is current
tooling against old package bytes, not current-head installed acceptance. The
requested Docker AppArmor profile was not enforced by this host; no host policy
was changed, and these runs do not establish CI AppArmor equivalence. Evidence:
`/var/tmp/of-installed-fix`; original investigation `/var/tmp/fs-inst-t/handoff.md`.

Hosted head `353ee7c7` passed its Debian packaging job but failed both Linux core
and Mac core on one stale test expectation: `test_paths_test.dart` still expected
`/tmp` although reviewed helper `753a53c5` selected physical disk-backed defaults.
Local runs had supplied the explicit override, leaving that branch unexercised.
Fixture-only `68fafd3e` updates the expectation to `/var/tmp` on Linux and
`/private/var/tmp` on Mac, retaining explicit overrides and cleanup assertions.
The original unset-override test failed first; the corrected module passed
**4/4 unset plus 4/4 overridden on each platform**, zero skips. Native-peer review
converged. Repeating the failed full Linux core lane at frozen `68fafd3e` passed
**2,288 / 17 skipped / 95.06%**, enforcing 90%; analysis and formatting passed.
That lane explicitly reused the fresh a8 native products after all **58** native,
CMake, helper and inference source inputs matched. It is not a new native build.
Evidence: `/var/tmp/of-test-root-oracle` and `/var/tmp/of-root-oracle-qa`.

The next hosted head must verify these changes. Logging, native lifecycle and
client/service architecture candidate branches remain separate and unaccepted
by this draft until their remaining implementation, reviews and combined gates
finish. This follow-up does not close the deferred security findings.

### Darwin parallel-gate cancellation follow-up

Hosted `f333f819` passed quality, dependency and sanitizer workflows. Its Mac
source/SDK contracts failed **1 / 511 passed / 12 skipped / 1 deselected**:
`test_cancellation_reaps_owned_branch_and_descendant` encountered `EPERM` when
signalling a retiring process group after its leader was reaped. Full failed
job output is retained at `/var/tmp/of-pr180-f333-macos-job.log` (job
`121042480521`, platform run `40151027601`). This is a tooling cancellation
failure; subsequent Mac application gates did not establish acceptance.

Reviewed repair `f9410366`, applied locally as `140e6eb7`, retries that permission
error only on Darwin after the owned leader exits, for at most one second.
Success still requires actual signal delivery or group disappearance; live or
persistent permission failures remain errors. Cleanup attempts TERM and KILL for
every started group even if an earlier group fails, reaps joinable leaders with
a shared finite deadline, and retains all cleanup errors. A real-process negative
control reproduced the old cleanup leaving the second gate running; the repaired
test verifies that later gate is reaped while the first denial remains a failure.

Native-peer and updated Claude reviews converged. Full Linux Python passed
**5,626 / 31 skipped / 95.85%**, enforcing the 95% combined line/branch gate;
ruff, mypy (**168** files) and the subprocess-timeout guard passed. The focused
runner suites passed **26/26**, zero skips, on Linux and HanSolo Mac 26.6 with
matching source hashes. Initial Linux infrastructure failures selected an
unconfigured Ninja shim; all **36** affected cases passed first after selecting
the already pinned CMake 3.31.6 and Ninja 1.12.1, before coherent full checks.
Original output and the intermediate mypy correction remain under
`/var/tmp/of-pg`. No compiler/SDK input, workflow permission, artifact-trust
selector, test timeout or coverage gate changed. Hosted Mac 15 must still verify
the repair.

Logging allocator and protocol work remains on its separate candidate branch;
its component results do not establish the storage child or application
integration. Native lifecycle/client candidates also remain unaccepted while
their remaining review findings are repaired. This follow-up keeps one draft PR
and does not claim completion of either combined plan.

### Runtime/client integration and parallel work, October 25

The local remediation branch now includes qualified candidate `9199c5fe` by
conflict-free fast-forward from `b0c02559`. This accepts the native lifecycle,
typed client contracts, renderer boundaries, bounded model acquisition and
model-transport cancellation repairs into the local integration branch. The
notes timer fixture also warms its existing fake transport before measuring the
production timer; hosted Mac verification of that fixture remains pending.

Exact-candidate Linux core passed **2,421 / 17 skipped**, with **92.79%** coverage;
desktop passed **583 / 17 skipped**, with **93.48%** coverage. Both enforce 90%.
Mac core passed **2,422 / 14 skipped**, with **93.11%** report-only coverage;
desktop passed **585 / 13 skipped**, with **93.43%** report-only coverage.
Compiled service/MCP passed **37/37** on Linux and **35 / 2 skipped** on Mac;
the two Mac skips require Linux package layouts. Actual desktop integration
passed **1/1 on each host**, with Linux using an isolated display. Fast suites
passed **2/2 Linux** and **1/1 Mac**. Linux Python passed **5,641 / 31 skipped**,
with **95.856%** combined coverage against the 95% gate; ruff, mypy (168 files)
and the subprocess-timeout guard passed.

The application products were freshly compiled for this candidate. Native
products explicitly reuse qualified `c77b6649` after verifying all **137**
native/CMake/helper/protocol inputs and exact product hashes. That earlier fresh
root CTest passed **38/38 Linux** and **42/42 Mac**, zero skips. This is not a
claim of a new native build at `9199c5fe`. Exact skip inventories, commands,
coverage and product provenance are retained in
`/var/tmp/of-c1/919-qualification/final-matrix-report.json`. Model cancellation
peer and repeated Claude reviews converged through `868e17c5`; the complementary
native/client review evidence remains applicable to unchanged source, and the
notes fixture's separate Claude review converged.

Logging identities, socket peer/Claude review and a native-independent SQL
deadline prototype now run in parallel while root owns logging worker
implementation and integration. The storage child/application adoption and SQL
whole-VM teardown gap remain unfinished. Real weights, GPU, physical audio,
cloud credentials and signed installed distributions were not accepted by these
offline suites. This remains one draft PR; these local results do not establish
whole-plan completion or hosted acceptance of the new head.

### Full-scope continuation and CI repairs, October 25

The owner explicitly retained the full combined scope before merge. Only the
broader security additions already covered by the delivery-scope amendment are
deferred. Logging alone does not close the ordinary audit obligations. Runtime
logging, startup/build identity, and SQL/package integration continue in separate
worktrees, with independent native and Claude reviews of frozen checkpoints.

Hosted head `66c23c9e` failed Python, installer/package, native-stage and sanitizer
checks. The failed logs were retrieved before repairs. Installer/package repair
`91025542` is integrated locally as `01cc52a9`: use macOS's fixed physical
`/private/tmp` legacy-lock location while retaining no-follow checks below it;
remove only an empty installation directory after removal-marker cleanup; and
make the RPM lock fixture match the released private mode. The GNU/Linux-only
maintainer-script fixture now has its actual platform prerequisite. Independent
peer review converged for this seven-file repair.

On that integrated source, Python passed **5,644 / 31 skipped**, with skip
reasons retained; ruff, mypy and the subprocess-timeout guard passed. This run
was `pytest`, not a new combined-coverage qualification. Real tiny generated
Deb, RPM and Arch packages passed installation/removal controls, and Mac signed
DMG controls passed **4/4**. These component fixtures do not establish actual
application-package acceptance. Full hosted checks remain pending.

The native failures included an unset private probe-root requirement and a fatal
ThreadSanitizer report for a completed but joinable legacy generation at process
exit. Separate candidate `9b220b2b` supplies a private `mkdtemp` fallback and
nonblocking finalization of completed legacy thread bookkeeping while retaining
the complete object graph. It does not acknowledge owned-v2 retirement. Both
reviewers independently found a capture-publication race in the first candidate;
the follow-up serializes capture thread assignment with its lifecycle mutex.
A real cross-thread probe fails when that lock is removed.

The repaired candidate passed Linux root CTest **38/38**, zero skips, and the
ownership executable passed fatal Clang 23 TSan plus ASan/UBSan with leak
detection enabled. Repeated whole-unit Claude review converged; repeated native
peer review is pending. Mac component checks passed both unset and explicit
private roots after test-only `a6b487ec` makes the capture fixture runtime
absolute. The preceding relative-path failure is retained. This native candidate
is not integrated yet; full Mac native and combined application qualification
remain required. Evidence is under `/var/tmp/of-ci66`.


### Main integration, architecture facts and HanSolo follow-up, October 25

Native repair `a6b487ec` is integrated through `31195f72`; repeated native peer
and whole-unit Claude reviews converged. Fresh root native CTest passed
**38/38 Linux** and **42/42 HanSolo Mac**, zero skips. Exact native source and
product evidence is retained under `/var/tmp/of-ci66/mac-full/` and
`/var/tmp/of-ci66/linux-app-311/`. This supersedes the preceding pending-native
integration statement without claiming hosted CI acceptance.

Current main's merged PRs #185 and #187 are included locally through `9645f24c`.
The model-selection merge retains the service-owned downloader, consent and
metadata-only discovery. Test fixture follow-up `8dc462d3` injects discovery
failures at the new discovery seam. Linux full core passed **2,422 / 17 skipped**
with **92.79%** coverage against 90%; desktop passed after the failed-first
fixture repair and its existing 90% coverage check passed. Earlier failed
attempts and their output remain in the same evidence directory.

HanSolo's exact seven-file application overlay over qualified `9199c5fe`
passed both analyzers, **2,423 / 14 skipped** core tests and
**592 / 13 skipped** desktop tests. Freshly compiled service/MCP passed
**35 / 2 skipped**; both skips are explicitly Linux package-layout controls.
The fast integration suite passed **1/1**, zero skips. Matching native products
reuse the fresh, unchanged `31195f72` native build above; this application run
is not another native build. Source reuse uses metadata links into the prior
qualified source snapshot and seven explicit overlay files, without a new
broad source copy/hash. The initial coverage formatter counted only overlay
files due to canonical source paths: its percentages are incomplete and are
not accepted. Corrected full collection includes both canonical roots and
preserves the existing generated-code exclusion: core **93.10% (19,681/21,139)**
and desktop **93.43% (8,859/9,482)**, both report-only on Mac. The original
unfiltered report is retained alongside the explicit nine-generated-file
exclusion record. The linked Python harness also resolved GUI source to the
older checkout; its GUI result was not accepted for the new source. After
materializing three explicit harness files and 30 platform project files in
the private workspace, both actual current-source GUI checks passed **2/2**,
zero skips, including all **68** named service/MCP observations. The initial
CocoaPods configuration failures and output remain retained. Evidence and full
skip inventories: `/var/tmp/of-ci66/mac-app-8dc/`. Real weights, physical audio/GPU,
account data, minimum macOS 15 runtime and signed installed-product acceptance
are not established by these suites.

Architecture fact repair `6c4e0fec` is integrated locally through `1e2c56f5`.
It corrects schema/tool
facts using the existing schema and operation authorities, with an offline
drift checker and **17/17** mutation/shape tests, zero skips. Ruff and focused
mypy passed. Native coordinator review and two complete Claude reviews
converged; the follow-up removes a proxy frozen-schema count, requires the
schema-version authority and rejects direct unprojected tool declarations.
Full Python/before-push checks for the new combined head remain required.
Logging, startup identities, SQL integration and the remaining ordinary audit
scope remain in progress; no completion or merge-readiness claim is made.


### Reviewed sanitizer and CI cadence integration, October 25

Leak detection unit `b7a862a7` is integrated locally as `1c7ea8b8`.
The shared gate settings enable ASan/UBSan/LSan for tests and children, preserve
fatal report scanning, and permit only individually justified exact CPython
retained-allocation suppressions. The six real controls include a deliberately
unreachable native allocation through the same ctypes host. On the exact
2026/10/18 Arch compiler/ABI profile, all six controls and freshly compiled root
native CTest **38/38**, zero skips, passed without sanitizer reports. The
published instrumented SDK artifact **12152408008** was reused after matching its
pinned archive hash, recipe, compiler/runtime environment and complete **1,632**
file inventory; its original compile provenance is retained. This is a new
repository-native build, not a new SDK build. The earlier Ubuntu experiments
with missing runtime/symbolizer, mixed sanitizer runtimes and an uninstrumented
protobuf closure are failed, retained diagnostic attempts, not acceptance.

Focused Python passed **56/56**, zero skips; Ruff, focused mypy and actionlint
**1.7.7 with ShellCheck 0.9.0** passed. Full-unit coordinator and independent
Claude reviews converged on the frozen unit. Evidence:
`/var/tmp/of-extra-parallel/lsan/arch23/summary.json`, its reports/logs and
`/var/tmp/of-extra-parallel/lsan/review-b7/`. No SDK cache-key input, TSan gate,
workflow permission or publishing/trust selector changed.

CI cadence unit `b148a216` is integrated locally as `fbba3301`. The only workflow
body differences are three cron values: hourly qualification index at :11,
main evidence at :17 and cache reconciliation at :41. Existing event/manual
recovery, write guards and job bodies are retained. The structural scheduled
invocation count falls from 192 to 96 per day, including the scheduled publisher's
index wakeup; this is not a measured runner-minute saving. Recovery tests now
exercise every minute-of-day phase and assert both suppression and dispatch
bounds. Focused tests passed **120/120**, zero skips, with Ruff and matching
workflow lint clean. Coordinator and repeated whole-unit Claude reviews
converged. Documentation distinguishes delivered ticks, dropped schedules,
dispatch timing, queue/execution time and required reviewed-main qualification
renewal. Evidence: `/var/tmp/of-extra-parallel/ci-cadence/`.

The integrated head still requires its full applicable before-push checks.
Native coverage reporting, logging physical/performance acceptance, compiled
worker/package adoption, restore and the other retained ordinary audit items
remain open; these two merges do not establish whole-plan or hosted acceptance.

### Immutable fixture provisioning and parallel completion, October 25

Fixture unit `fd7bf391` is integrated locally through `f6f45c59`. The 14.7 MB
historical evidence archive is removed from tracked source. Its original frozen
baseline still supplies the archive name and SHA-256; explicit provisioning
reads the immutable original-commit asset or an authorized local copy into a
private content-addressed cache. Ordinary test reads remain offline and fail
with an actionable command if the fixture is absent or invalid. Both actual CI
consumers provision explicitly before their historical tests. No original
archive checksum, run/job inventory or negative integrity assertion is removed.

With the source archive physically absent, the provider/history/qualification/PR
workflow group passed **104 tests and 2 subtests**, zero skips. The exact three
historical replay workflow modules separately passed **143/143**, zero skips.
Real explicit immutable-URL fetching to a fresh cache and offline local-copy
provisioning both verified the original digest. Ruff, focused mypy and actionlint
1.7.7 with ShellCheck 0.9.0 passed. Coordinator and repeated Claude reviews
converged; an intermediate review's archive-presence claim was disproved by
filesystem checks and reconciled (its Read tool rejected gzip extensions before
checking existence). Evidence: `/var/tmp/fixtq/` and
`/var/tmp/of-more-agents/fixture-review-current/`. Full combined Python checks
remain required before pushing.

The separate development integration branch contains the logging/runtime,
startup, SQL semantics and package-adoption candidates through `24ff86dd`.
Its fresh native/application matrix is running from a regular copy-on-write
source view, preserving the qualified source snapshot and the credential/source
exclusions. The first attempt's missing Python protobuf dependency is retained
as an infrastructure failure; the failed build is resumed with the existing
locked environment. This is qualification in progress, not accepted evidence.
Independent workers own native numerical reports, offline restore and the
remaining Python import conversion. Runtime accounting also reproduced an
unbounded health-message mailbox with a paused coordinator; a bounded ACK repair
is undergoing its own review/platform checks before integration. These are real
remaining implementation/acceptance gates, not a whole-plan completion claim.


### Reviewed local candidate checkpoint, 2026-10-25

The next candidate integrates accepted branch `6a3a815a` with the closed logging,
SQL and application checkpoints. It remains local: PR #180 is still a draft at
`66c23c9e`. Neither this integration nor the following component results establish
full-plan acceptance or permission to publish installers.

- Preference compatibility repair `36e8f5c0` is integrated as `ed300b86`.
  The nine reproduced regressions now pass; 87 existing focused cases pass with
  no skips. The original malformed-selection/privacy oracles remain unchanged.
  Follow-up `8017005c`, integrated as `069ceac7`, adds all six entity tables to
  the exact service/external-writer revision inventory. Two additional workspace
  clear/rollback cases pass unchanged. Historical migrations and fixtures stay
  frozen. Schema-23 documentation and drift tests are updated in `c4737ae3`:
  the actual registry check succeeds and all 17 tests pass.
- Logging control repair `ab7df69d`, integrated as `d1cf2e77`, passes 105 tests
  each on Linux and HanSolo. Holding the actual writer in controlled C++ prepare
  changes 1,000 profile plus 1,000 ownership messages to zero plus one. This
  proves those control bounds, not the aggregate 512 KiB memory requirement.
- Reader admission and fixture-lifecycle repair `46ca1f28` passed a second whole
  independent review. Its final bytes pass 112 core and 58 desktop-adjacent
  cases, with no skips/failures. The earlier full desktop result, 591 passed,
  17 skipped and zero failed, belongs to the preceding source revision; the
  final reentrant-registration repair still needs the combined full suite.
- Native reporting `6935e924`, integrated as `2c87ccb7`, passed whole review
  after correcting the false unflushed-profile detection claim and adding LLVM
  total-consistency and timeout-output controls. Its 58 focused Python tests
  pass. The actual Clang-23 report retains original build provenance: root CTest
  38/38 and line coverage 7,962/11,140 (71.47%). This is the older native scope;
  current SQL/logging target classification and actual Mac coverage remain open.
- The wire-only closing launcher omission is repaired in `2f114dc8`.
  Accepted updater `c50b2f28` is present as `c8f7643d`; its Linux and Mac results
  remain 39 core plus seven widget cases each, without a live GitHub TLS or
  installed-product acceptance claim.

The accepted branch `6a3a815a` separately passed its complete Python gate:
5,781 passed, 31 skipped, 52 retained warnings and 95.75% combined coverage.
Ruff, mypy (171 files) and the timeout guard passed. Evidence and actual skip
reasons are in `/var/tmp/of-push6a3/report.json`; this does not qualify the
unmerged Python import batch or final combined candidate.

The immutable `2c4bcda2` plus catalog run finished with 2,620 core passes,
17 skips and 13 failures. Its full output and skip metadata remain in
`/var/tmp/of-coherent-final/`. Repairs are staged separately; no passing full
core/coverage claim is made from that failed run. Five skips emitted no reason
and are explicitly recorded that way rather than given invented prerequisites.

Required work remains: production logging readiness and safe transport adoption;
aggregate physical memory and bounded producer capability/health controls;
Step-4 support UI/docs; restore race repairs, shipping bootstrap and Mac cases;
current configuration-port injection; correct-toolchain Python import/caller
qualification; pin/builder/ICU/reproducibility qualification and owner-reviewed
workflow wiring; final first-run review/freshness/Mac cases; and the
complete frozen-source matrix, CI/reviews and verified merge. The synthetic
first-run journey is not real-model, GPU, physical-audio, minimum-Mac-runtime or
final signed-installer acceptance. The scope amendment's deferred security work
remains deferred; existing gates and owner-review requirements remain intact.

The user subsequently deferred isolated Keychain execution as recorded in the
delivery scope amendment. Its Security -25308 failure remains failed evidence;
it is no longer a merge blocker and no further Keychain run is required here.

### Retained-scope verification checkpoint, October 26

The [delivery scope amendment](2026-10-24-remediation-delivery-scope.md)
supersedes earlier remaining-work lists. Exact 512 KiB and strict 5%/10%
logging certification, expanded bridge/background correlation, new dependency
reproducibility/builder/ICU work, new native coverage/clang-tidy infrastructure,
the broad Python import conversion, Keychain execution and broader security
additions remain deferred. Existing bounds, privacy, coverage and trust gates
remain required. The reproduced client lost-emitter repair is integrated.

The reviewed production integration reached `c467a5cc`, including startup,
desktop diagnostic binding/support, restore, first-run, SQL and owned service
configuration. Subsequent fixture repairs passed the second complete core run
except for journal compaction: **2,872 passed, 16 skipped, one failed**.
Core coverage remains **unqualified** because that suite exited nonzero.
The original failed runs remain retained. The third, instrumented run is
diagnostic evidence only; its 4,097 rows, assertions and 30-second timeout are
unchanged. It shows continued indexing progress at the deadline rather than
a deadlock and also records a native-queue short-deadline failure.

The actual `tools/coverage.sh` run on `c467a5cc` passed **6,134 tests**, with
32 skipped, 52 warnings and **95.23% combined line/branch coverage** against
the existing 95% floor. Desktop passed **634**, with 17 skipped and **93.29%**
coverage against 90%. Actual isolated-display Linux integration passed **3/3**
with all 68 named expectations; fast scenarios passed **2/2**. These retain
their exact original source/product provenance, not blanket final-head claims.

Final service-fixture review converged after replacing retired stderr-text
oracles with typed events and actual wire observations. The MCP handoff
fixture now observes its new startup connection, real kernel peer identities,
the exact closing refusal and the held profile lock before releasing the old
helper. The official build gate compiles the required diagnostic Worker before
core tests, verifies it again before hosts, and retains service/MCP compilation
after test and coverage gates. The affected 142 tooling controls pass, including
explicit ambient-coverage controls. Full compiled-lifecycle qualification on
the final matching products remains pending.

Pinned formatting required one continuation-line correction in
`native/diagnostic_protocol.c`, integrated as `297bf7ef`. Although its C tokens
are unchanged, its source identity changes. Fresh root native CTest passed
**51/51 Linux and 60/60 HanSolo**, zero skips, in separate new build roots;
the older native cohorts were preserved. New Linux Native identity is
`c62c8bf91ffa625087626d6c020d99132ccfc5e8ca5c519a94b6dfb2aae54117`.
Matching application products and applicable Dart qualification are pending.
HanSolo runs on macOS 26.6, not the minimum macOS 15 runtime.

Ruff, the subprocess-timeout guard and native formatting pass on the reviewed
`60f62bf6` Git-free source. The document checker checked 334 local links with
zero problems; architecture facts and the generated catalog check passed on
the unchanged corresponding inputs. Actionlint 1.7.7 ran with ShellCheck 0.9.0
and passed. Complete Git-free Python discovery is running in unrelated-PR,
main and no-ref contexts. Four installer cases initially failed because the
container UID and temporary ancestor ownership differed; all four passed in
each context using a private, correctly owned `/var/tmp` root. No validator or
test assertion changed. Original failed output is retained.

This is still local verification. PR #180 remains the older draft at
`66c23c9e`, with historical red CI and merge conflicts. Remaining delivery work
is resolving core failures, matching final products/checks, recording terminal
Git-free outcomes, required owner review, pushing the combined candidate,
resolving current-head CI/reviews and verifying the merge to main. Real models,
GPU/physical audio, signed/installed distributions, minimum-Mac runtime and
external activation observations are not inferred from synthetic fixtures.

### Final retained-scope local qualification, October 26

The final test source is `6b2224f7`. Its production inputs are unchanged from
`8a10945d`; `6923a6a5` and `6b2224f7` add only the independently reviewed worker
and startup contract tests. The worker cases use the existing controlled FFI
backend and actual Dart writer/owner isolates. No production hook, assertion,
timeout, coverage exclusion or numerical gate changed.

The complete Linux core run passed **2,889 tests**, with **16 skipped and zero
errors**, and **91.03% line coverage (24,583/27,006)** against 90%. Full package
analysis and formatting of both added files passed. The journal-compaction
case retained all 4,097 rows and its original 30-second deadline, passing in
7.499 seconds. The explicit `--concurrency=4` schedules the complete suite;
it does not omit tests or change their assertions. The earlier eight-suite
diagnostic failures and the 89.90% floor failure remain recorded as failures.
Shared-VM contention is supported by the scheduling comparison; a VM-wide pause
mechanism was not proven.

Native products explicitly reuse the fresh Linux **51/51** cohort with exact
SHA/mode checks; they are not represented as another native compilation.
The separate fresh HanSolo cohort passed **60/60**, zero skips. The final
source view has its own freshly compiled, source-bound Worker, service and MCP,
all successful, with Worker identity
`51af3904f6aaff9da428894be0f8675af72c2c99f6954b54a059fb5783e47b28`.
Core evidence, skipped reasons and terminal events are retained under
`/var/tmp/of-fin/core-coverage-final/retained-evidence/`.

The matching production/native desktop run passed **634**, with **17 skipped**
and **93.31% coverage (9,083/9,734)** against 90%; analysis passed. Compiled
service/MCP has passing evidence for its exact **35 selected cases**, zero
skips, across the initial 15 passes and the exact 20-case failed-first rerun.
The first run's missing supplementary model-worker fixture is retained as an
infrastructure failure. The corrected fixture came from the same fresh CMake
cohort, with separate provenance; the existing twelve products and application
bytes did not change. These are two commands, not a claimed clean 35-case run.

Git-free ordinary Python discovery completed in all three controlled inherited
ref environments: unrelated PR, main and no ref. Each initially passed **6,131**,
with **32 skipped and 1,398 passing subtests**, and failed the same four installer
cases because of temporary ancestor ownership. The exact four cases passed in
each environment with an owned private `/var/tmp` root, yielding passing
evidence for all **6,135 cases**. No security validator or source changed for
those retries. These integrity runs do not replace the actual **95.23%** Python
coverage result on the unchanged production Python inputs. Full failed outputs,
metadata, node unions and skip reasons are retained in
`/var/tmp/of-fin/gitfree-final/` and the compiled service evidence directory.

Linux isolated-display integration remains **3/3**, with all 68 named assertions,
and fast integration **2/2**, on its recorded unchanged production inputs.
HanSolo functional checkpoints include actual first-run recovery/adoption and
shared-service flow, restore **37/37**, logging lifecycle/health, support-folder
reveal and client correlation. These component results and native 60/60 do not
claim a full current-head Mac application run; current-head hosted Mac CI must
supply that evidence before merge. External activation and explicitly deferred
measurements remain outside the completion claims in the delivery amendment.

Local implementation and applicable pre-push qualification are complete at this
checkpoint. The remaining delivery gates are current-head hosted CI and review
resolution, actual owner review of retained publishing/trust changes, and verified
merge of the single PR to main. Agent/CLI convergence does not supply owner
approval. See PR #180 for their current outcomes rather than treating this dated
checkpoint as a claim that the merge or release publication already happened.

### Current-head CI repair and requalification, October 26

The combined candidate was pushed as `3c2a97c4` and PR #180 marked ready for
review. Its hosted failures were inspected before this repair batch; successful
jobs were not manually rerun. The cancelled Python job was not counted as a pass.

The Arch stage had selected Python 3.14, while the Ubuntu SDK's development
Python was 3.12. Both conflicted with the existing 3.13 diagnostic-tooling
requirement and left runtime receipts unavailable. The repairs explicitly select
supported 3.13 tooling without replacing SDK/model environments or rebuilding
compatible SDKs. Ubuntu build and restored-test containers use the same private
absolute tooling path; actual separate-container CTest changed from a missing
random interpreter path to **1/1 passing in each container**. Existing version,
dependency-hash, directory-ownership and source-identity guards remain enforced.
Arch drift uses the same required tooling selection. The metadata collector now
records real pacman package provenance and ownership on Arch; real GCC/Clang
records pass native and SQL identity consumers. Ubuntu and Mac metadata output
bytes remain identical. The collector's source hash correctly changes SQL IDs.

Sanitizer fixes preserve the diagnostic launcher's closed child environment.
Compiler-runtime RUNPATH resolves instrumented children, build-bound defaults
retain fatal child reports, and the gates collect those reports into their
existing evidence. Four actual ASan, UBSan, LSan and TSan child faults were
captured through that launcher; the real gates rejected all four even when
the enclosing CTests expected the fault. Atomic PID publication removes the
fixture's empty-file race. The user directed “Fix CI error” after presentation
of the precise TSan observation proposal: only Clang-TSan hold/bootstrap checks
allow the additional one-second runtime finalization delay. Ordinary and ASan
limits, other deadlines, physical-reap/exit assertions, race detection and
TSan's default exit delay remain unchanged. Full new root runs passed
**51/51 ASan/LSan/UBSan and 51/51 TSan**, zero CTest skips.

Fresh ordinary root CTest separately passed **51/51 Linux and 60/60 HanSolo**,
zero CTest skips, with all 191 approved source inputs checked after execution.
Other products were reused with exact byte/mode provenance while SQL products
were actually recompiled and verified against the new collector. New SQL IDs
are Linux `11be03ce584c1e17f02696e38ee35122dc0bae3f1fa6ad267efcd96c80d4d3f0`
and Mac `19af92d6e156150bf1f3e8e0092f83395c73dc536c23703960f1fb51d5cc693b`.
Native IDs remain unchanged. These are new SQL products, not renamed old bytes.

Application qualification on `33fa1e38`, with the refreshed SQL binding and
fresh source-bound Worker/service/MCP, passed **2,889 core / 16 skipped / 91.02%**,
**634 desktop / 17 skipped / 93.31%**, and **35/35 compiled service/MCP**, zero
selected-suite skips. Analysis, post-run Worker/receipt verification and all
thirteen artifact checks passed. Later fixture and measurement-tool repairs do
not change those application inputs.

The final Python source `aff34fd5` passed **6,167 tests / 32 skipped** and
**95.23% combined coverage**, enforcing the unchanged 95% floor. Ruff, mypy,
subprocess-timeout checks and matched actionlint/ShellCheck passed. All three
complete Git-free runs on that source passed **6,167 / 32 skipped / 1,402 passing
subtests** in unrelated-PR, main and no-ref contexts, with no failed-first retry
needed. Earlier shim/cache infrastructure failures and stale-fixture failures
remain retained. RPC cleanup keeps its original time limits: kernel SID lookup
replaces expensive host-wide stat reads, preserving pidfd-first signal authority,
birth checks and physical cleanup assertions on the busy test host.

Evidence: `/var/tmp/of-sanitizer-proposal/`, `/var/tmp/of-native-9f9d/`,
`/var/tmp/of-native-33fa/`, `/var/tmp/of-fin/app-33fa/`,
`/var/tmp/of-p95-final/` and `/var/tmp/of-fin/gf-final-{0,1,2}/`.
The same single PR still requires hosted verification of the repaired head,
review resolution, actual owner review of retained publishing/trust changes
and verified merge to main. Scope deferrals and external acceptance limitations
remain those of the delivery amendment; local results do not supply that approval
or release authorization.

The refreshed application cohort also passed all three isolated Linux desktop
integration scenarios, all 68 named expectations, and both fast scenarios,
with zero selected-suite skips. Private Xvfb/DBus/XDG resources were cleaned up,
application products stayed unchanged and post-run Worker/receipt verification
passed. Real models and GPU remain unexecuted. On the pushed repair head
`c0a2705f`, hosted formatting caught the test-only `HeldWorker` destructor;
the follow-up uses clang-format 22.1.8 and the full tracked C/C++ check passes.
That fixture is outside Native, SQL and Worker product identity inputs.
