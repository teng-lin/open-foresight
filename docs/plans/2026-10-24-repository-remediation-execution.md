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
| A1 | Recording start/stop/error-path cleanup, persistence retry and indexing ownership: F1/F6, persistence part of F9 | Baseline; coordinate final indexing contract with A3/A4 | Committed locally as `65bfb275`; dependent A4 scheduling and qualification remain |
| A2 | RPC duplicate ownership, model acquisition deadlines, capture temp root and install-lock interoperability: F5/F7/F8 | Baseline; owns relevant native FIFO/lock surfaces | Committed locally as `9e4bdaaa`; legacy upgrade guard follow-up in progress |
| A3 | Application backup/restore/erasure, history retention and SQLite transactional/busy-timeout fixes: F2/F20, part of F23 | Baseline; coordinate generated transcript handling with A4 | Local commits `065690b3` and Darwin fix `99f3224c`; focused Linux/Mac checks passed; independent review pending |
| A4 | Incremental helper indexing and remaining speech/drain performance: F3, remaining F9 | Coordinate A1/A2 ownership; helper schema/protocol compatibility | Native/protocol unit `9681e096` committed; application integration in progress in separate worktree |
| B | Complete logging steps 0–4 and safe RPC errors, including nonthrowing reporter before new exports | Integrate after A runtime changes; independent foundation may develop earlier | Foundation in progress in separate worktree |
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
