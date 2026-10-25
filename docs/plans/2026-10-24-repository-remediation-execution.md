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
