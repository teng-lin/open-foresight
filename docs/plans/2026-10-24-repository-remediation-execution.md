# Combined remediation and logging execution

Status: stage 0 active, 2026-10-24. Implementation issue:
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

## Initial work units

| Unit | Ownership | Integration prerequisites | Status |
| --- | --- | --- | --- |
| A1 | Recording start/stop/error-path cleanup, persistence retry and indexing ownership: F1/F6, persistence part of F9 | Baseline; coordinate final indexing contract with A3/A4 | Pending worktree dispatch |
| A2 | RPC duplicate ownership, model acquisition deadlines, capture temp root and install-lock interoperability: F5/F7/F8 | Baseline; owns relevant native FIFO/lock surfaces | Pending worktree dispatch |
| A3 | Application backup/restore/erasure, history retention and SQLite transactional/busy-timeout fixes: F2/F20, part of F23 | Baseline; coordinate generated transcript handling with A4 | Pending worktree dispatch |
| A4 | Incremental helper indexing and remaining speech/drain performance: F3, remaining F9 | Coordinate A1/A2 ownership; helper schema/protocol compatibility | Pending |
| B | Complete logging steps 0–4 and safe RPC errors, including nonthrowing reporter before new exports | Integrate after A runtime changes; independent foundation may develop earlier | Pending |
| C | Ownership, compile boundaries, service operations and local security | A/B contracts | Pending |
| D/E | Verification/release/dependencies/docs and Python tooling quality | Independent files may progress alongside runtime; final consumers integrate together | Pending |
| F | Final distribution trust, update notice and recovery | D's controls and actual external identities/acceptance | Pending prerequisites |

## Preflight observations

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
No implemented unit or acceptance lane is complete at this initial checkpoint.
