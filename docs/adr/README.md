# Architecture decision records

One file per decision, numbered in proposal order. Accepted decisions retain their text; a later record supersedes an earlier one. Source links point to the archived context in Git history.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-land-handoff-commits-with-ci-pr.md) | Where the seven service handoff commits land (D1) | Superseded by events |
| [0002](0002-always-recover-after-unclean-shutdown.md) | Always recover after an unclean service shutdown (D2) | Accepted |
| [0003](0003-structured-closing-refusals.md) | Structured closing refusals and outcome reasons (D3) | Accepted |
| [0004](0004-workspace-epoch-for-stale-ids.md) | Workspace epoch protects editor-held IDs (D4) | Accepted |
| [0005](0005-per-profile-linux-runtime.md) | Per-profile Linux runtime directory (D5) | Accepted |
| [0006](0006-stop-recording-on-host-disconnect.md) | Stop recording when the host desktop disconnects (D6) | Accepted |
| [0007](0007-service-lifetime-and-desktop-agent-boundary.md) | Service lifetime and the desktop/agent boundary (D7) | Accepted and implemented |

Decisions 1–8 of the CI restructuring live in [its plan](https://github.com/teng-lin/open-foresight/blob/52bdd39778f31d632d434ada3fca7b165b9c6336/docs/plans/2026-10-19-ci-restructure-plan.md#8-owner-decisions). Move them here only if they need to change.

## Template

```markdown
# ADR NNNN: Title

| | |
|---|---|
| Status | Proposed | Accepted | Superseded by ADR NNNN | Rejected, with the date |
| Deciders | who |
| Depends on | other ADRs or plan items, if any |

## Context
What forces the decision, with evidence from the code (symbol names, not line numbers).

## Decision
The rule chosen, in a few sentences. Alternatives considered, each with the reason it lost.

## Consequences
What becomes easier, what becomes harder, what is deliberately out of scope.
```
