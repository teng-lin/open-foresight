# Repository remediation and unified logging review record

Current status: combined revision 6 converged, 2026-10-24. Execution is tracked
in [issue #179](https://github.com/teng-lin/open-foresight/issues/179) and the
[execution record](2026-10-24-repository-remediation-execution.md).
The [implementation plan](2026-10-24-repository-remediation-plan.md) now contains
the complete repository remediation and logging design in one active plan.
The user explicitly lifted the 100-file limit and requested the fewest PRs;
the delivery target is one implementation PR with ordered commits/stages.

The sections through “Historical revision-4 validation and limits” below record
the previous remediation-only review and its former file-cap assumption.
Those approvals/hashes remain historical; they do not approve the combined
revision. No application implementation or runtime acceptance is implied.

## Baseline and method

- Audit source: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`.
- Planning checkout: `ae9170830ca115cb40a44ad7e9ade8714a170bec` (#178 delta rechecked).
- Preserve pre-existing untracked audits and unified logging plan/reviews.
- User constraint: minimize PR count, while respecting roughly 100 files per PR.
- Three native reviewers independently inspected runtime/privacy,
  architecture/quality and verification/release sources before drafting.
- Full frozen plans, prompts and Claude CLI stdout/stderr are retained privately
  under `/var/tmp/of-rplan-1024`; no raw product/user data is involved.
- Each round reviews the entire immutable plan. Convergence requires explicit
  agreement from all three native reviewers and Claude CLI on one revision/hash.
- Native reviewer messages are retained with their dispositions here; source
  inspections and this record are not executed application test evidence.

## Preliminary source review

Accepted requirements from the native team: protect every recording persistence
failure path; keep capture settlement separate from background indexing; add
backup before the history migration; preserve erasure across backups; require
real generation/teardown ownership; budget architecture and Python imports;
reuse logging stages inside fewer PRs; extend existing pins; enforce manual
receipts through reuse/waiver paths; respect TSan's actual probation date and
both LSan configurations; verify external authority separately; preserve the
excluded distribution-credential topic and CI transitional-mechanism rules.

## Round 1

Revision 1 SHA-256:
`882c02c0007338d94b1af69ff6459fed1d6fc628b32e9d48a901e9ed9977d9bd`.
Claude CLI 2.1.309 (`claude-opus-5-5`) read the entire frozen plan and relevant
source, returned changes required, and exited 0 with no tool denials. Full JSON
and stderr are retained in `round-1/`. The native team's preliminary source
reviews informed the draft, but a turn interruption ended the team before
complete frozen-round verdicts were returned. No missing native verdict is
counted as approval; a new team reviews revision 2 in full.

### Revision 2 dispositions

All six Claude findings were checked against source and accepted:

1. Resolve B/C's circular dependency with A → B → C merge order, explicit shared
   native spawn/FD surface ownership and logger poller retirement before unload.
2. Pin the concurrently revised logging design at revision 3, SHA-256
   `d03de6ad0917964270c531ed77ed4284601291e3e9713d7eb8e3342c971b8495`.
   Its separate convergence is required before B; changes require reconciliation.
3. Include the audit, its cited source reviews and logging documents with the
   first implementation documentation commit. Reverify against code; do not
   rely on untracked requirements or omit link targets from the eventual PR.
4. Cover the separately versioned helper database set, protocol/build handshake,
   ordered migration and derived-index rebuild/downgrade/erasure. Add a fixed
   2.5 maximum processed-content ratio for doubling the append workload.
5. Ship the accepted microphone repair if any other A acceptance is unfinished;
   enumerate Linux lock scriptlet/package generators and their tests explicitly.
6. Exempt excluded distribution-credential tools/tests/value-supply paths from
   mechanical Python/config/helper rewrites and completion denominators.

Coordinator review also made transcript retry and user-history limits concrete,
and required safe, bounded long-query cancellation with actual SQL settlement.
These are proposed implementation policies, not executed runtime results.

Initial document checks passed: relative file links and referenced anchors,
whitespace and exactly one traceability row for each F1–F25. Application builds,
unit/integration suites, Docker, macOS, real models/audio/GPU and release
acceptance have not been run for this documentation-only task.

## Round 2

Revision 2 SHA-256:
`5f2789cc6ba48de81f0a7d88c129a5292ab7b38eea2952d9aafbd9c0e7c90f37`.
All three native agents read the entire 653-line frozen plan and verified its
hash. Claude CLI read the entire plan, resolved all six prior findings and
returned one new finding; exit 0, no tool denials. The coordinator verifies
hashes before/after reviews because Claude's restricted tools cannot compute
them. Complete responses are retained in `round-2/`.

| Reviewer | Verdict | Substantive findings |
| --- | --- | --- |
| Native runtime/privacy | Changes required | Retention omitted the fifth history entity, `meeting_tasks` |
| Native architecture/quality | Changes required | Shared C ABI reporter/fallback can throw while handling an exception |
| Native assurance/release | Converged | No substantive planning issues |
| Claude CLI | Changes required | F19 client-facing RPC exception text was outside persisted-log sanitization |

### Revision 3 dispositions

All three new findings were verified in current source and accepted, without
additional delivery groups or PRs:

1. Derive retention coverage from `ContentHistory.entities`, including
   `meeting_tasks`; add repeated task/manual-status/restore and full erasure
   acceptance alongside the other four entities.
2. Harden reporter/fallback/error retrieval before expanding `ffi_barrier` use;
   require simultaneous operation/reporting failure and sustained-allocation
   tests, preserving cleanup, sentinel and nonthrowing boundary guarantees.
3. Assign client-facing `RpcError.from`/helper/wire sanitization explicitly to B,
   retaining vetted typed guidance, codes and reasons. Test sensitive canaries
   through desktop and MCP tool errors; document text compatibility separately
   from the existing typed wire contract.

Revision 2 document links/anchors, whitespace, F1–F25 traceability and equality
with its frozen bytes passed. No application validation has been executed.

## Round 3

Revision 3 SHA-256:
`55f27c9bcd34547c37c537b8edbd9ab28c3e46d6beb900879852e728b5d273bf`.
All three native reviewers read the complete 683-line plan and converged.
Claude CLI read the entire plan, confirmed the prior three findings resolved,
and reported one remaining cross-document conflict; exit 0, no tool denials.
Complete responses are retained in `round-3/`.

| Reviewer | Verdict | Substantive findings |
| --- | --- | --- |
| Native runtime/privacy | Converged | No substantive planning issues |
| Native architecture/quality | Converged | Nonthrowing reporter requirements resolve its finding |
| Native assurance/release | Converged | No substantive planning issues |
| Claude CLI | Changes required | RPC sanitization conflicts with logging's preserved raw presentation/tail wording |

### Revision 4 dispositions

Verified the detector, extractor, audio-discovery and open-URI StateError paths.
Accepted Claude's finding: explicitly give B's safe RPC policy precedence over
logging's presentation-preservation rows for product RPC errors, classify those
failures at their origins, add tail/path/URI canaries and preserve underlying
tool protocol/deadline/direct diagnostic-CLI contracts. This requires no new PR.

The independent logging task advanced to revision 4 during these reviews. Pin
its complete immutable snapshot, SHA-256
`725c5936e153b5c7bbff9608c68d780f441e4258f6b14ea9ee005fa38e0ef40f`,
and incorporate its ownership-classification, pending-quit and output-disposition
refinements. Its separate convergence remains a prerequisite to B; these
reviews do not grant it approval. Pre-existing logging documents are untouched.
No tracked application source changed during planning.

Revision 3 document checks passed: nine relative links including anchors,
25 finding rows, whitespace, pinned logging snapshot identity and exact equality
with its frozen plan bytes. No application validation has been executed.

## Round 4: converged

Revision 4 SHA-256:
`7c8909f753ac32d507c3ab3ca9813f07b5c9af5e58150a8d1536482c66a352af`.
All four reviewers read the complete frozen plan and explicitly reported no
unresolved substantive planning issues on this revision. Native reviewers and
the coordinator verified the plan/dependency hashes; Claude reviewed their
specified paths with read-only tools and correctly reported that it could not
compute hashes. Claude CLI 2.1.309 (`claude-opus-5-5`) exited 0, `is_error=false`,
with no tool denials. Full responses and CLI stdout/stderr are in `round-4/`.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native runtime/privacy | Converged | Entire plan and logging dependency checked; no substantive findings |
| Native architecture/quality | Converged | RPC/presentation precedence and ownership/quality requirements adequate |
| Native assurance/release | Converged | Consolidation, source/byte identity, owner boundaries and acceptance adequate |
| Claude CLI | Converged | Prior conflict resolved; no substantive issues in the complete revision |

Claude's nonblocking implementation reminder is retained without changing the
accepted plan: include notification capability failures and Linux sandbox/
AppArmor failures in B's error inventory. The existing general typed-error
policy covers them; preserve safe permission/AppArmor guidance and never relay
raw helper JSON/stderr or ProcessException text into product RPC messages.

## Historical revision-4 validation and limits

- The final plan matches its frozen revision-4 bytes and SHA-256 above.
- Document checks pass: relative file links and referenced anchors, whitespace,
  and exactly 25 finding-traceability rows. Evidence:
  `/var/tmp/of-rplan-1024/round-4/document-checks.json`.
- The planning checkout remains `ae9170830ca115cb40a44ad7e9ade8714a170bec`.
  No application code, tests, workflows, permissions or release settings changed.
- No application builds or unit/integration suites, Docker, macOS, real models,
  physical/virtual audio, GPU, hosted CI, signing or release acceptance were run.
- Six delivery groups minimize fragmentation; the actual PR count remains
  conditional on the required file inventories and approximately 100-file limit.
- The pinned logging design's independent convergence, implementation inventories,
  owner protections/bot/signing setup and real platform acceptance remain
  implementation prerequisites. This plan's convergence does not qualify them.

The plan was not edited after these final full-revision verdicts. Nothing was
committed, pushed, opened as a PR or published by this planning task.

## Combined revision 5

Inputs: remediation revision 4
(`7c8909f753ac32d507c3ab3ca9813f07b5c9af5e58150a8d1536482c66a352af`)
and independently converged logging revision 6
(`c5a480bc07d2eb78e550a3e9a9eab263e3bf34f63caea1942474137010392337`).
Exact source documents, prior review records and an input hash manifest are
retained under `/var/tmp/of-merge-1024/`.

The combined revision incorporates all logging requirements and acceptance,
including parent/worker early-failure guards and session-owned terminal decisions.
It reconciles RPC redaction directly in the routing table, uses A → B → C as
commit/checkpoint order, preserves D/E integration and owner controls, and makes
the former logging path a superseded pointer. One PR is the default; only an
urgent shipping dependency or genuinely blocked safe implementation can justify
an extra PR. File count is visibility only; F24's proposed size gate is waived
by the user's explicit instruction. Historical review records are retained.
Complete-plan independent review and final document checks are pending.

### Combined review round 1

Revision 5 SHA-256:
`9a267a7e80fc104e15f4ab5d3ea54a6b8142d583a656c83009031d62e815f6e9`.
Three native reviewers read both complete inputs and the full combined plan,
and converged. Claude CLI read all inputs/instructions and the entire combined
plan; it returned two findings, exit 0, no tool denials. Full outputs and the
logging merge diff are retained under `/var/tmp/of-merge-1024/`.

Accepted for revision 6: keep the repository-wide PR-size-check recommendation
explicitly open and not passed while honoring this delivery's size waiver;
state that focused-only checkpoints are local and every pushed branch head
requires its applicable full AGENTS before-push checks. The user subsequently
authorized execution by parallel worktree teams, HanSolo Mac qualification,
local integration and one final GitHub PR through its merge to main. Revision 6
records that workflow without weakening owner review or acceptance requirements.

### Combined review round 2

Revision 6 SHA-256:
`6e1ad7f091caf781a199cc5c063a5109728984ec069c81cc029f151ec654d1a7`.
All four reviewers read the complete frozen revision and reported no unresolved
substantive planning issues. All native reviewers checked both instruction
files/current source and honored the user's size waiver. Claude read all 1,468
reported lines and instruction files; it verified the two previous corrections
and the worktree/HanSolo/final-merge workflow, exited 0 with no tool denials.
Claude's tools cannot compute hashes; the coordinator verifies frozen bytes.

| Reviewer | Verdict | Result |
| --- | --- | --- |
| Native runtime/privacy | Converged | Entire revision consistent; no substantive findings |
| Native architecture/ownership | Converged | Entire revision consistent; no substantive findings |
| Native assurance/release | Converged | Entire revision consistent; no substantive findings |
| Claude CLI | Converged | Both prior findings resolved; no substantive gaps |

Exact inputs, the logging-merge diff, prompts and complete responses/CLI output
are retained under `/var/tmp/of-merge-1024/`. The single active plan contains all
25 findings and full logging requirements; the separate logging path is a
superseded pointer. This task changes planning documents only through this
checkpoint; subsequent implementation evidence belongs in the execution record.
No application test/build or platform acceptance is claimed by this convergence.
