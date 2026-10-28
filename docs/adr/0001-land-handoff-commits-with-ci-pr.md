# ADR 0001: Where the seven service handoff commits land (D1)

| | |
|---|---|
| Status | Superseded by events on 2026-10-20: the commits reached `main` through PR #150 (`1d28c0fa`). |
| Deciders | Repository owner, 2026-10-19 |
| Source | [Service lifecycle fix plan](https://github.com/teng-lin/open-foresight/blob/52bdd39778f31d632d434ada3fca7b165b9c6336/docs/plans/2026-10-19-service-lifecycle-fix-plan.md), decision D1 and item 0.1 |

## Context

PR #150 (`codex/ci-restructure`) carried seven service commits (`2250d0ba` … `151878f1`) that changed service shutdown handoff behavior alongside CI work. The lifecycle audit found SL-8 in that code, and the fix plan needed a base to build on. A CI PR should not carry service lifecycle behavior, and merging the unclean-shutdown `StateError` only to reverse it in the next PR wastes a review.

## Decision

Recommended: split the seven commits out as PR 0 off `main`, together with only the D2 policy change, and keep PR 1's other fixes separate so PR 0 stays under the ~1,500-line review guideline.

Outcome: PR #150 was ready before step 0 finished. Its service files were byte-identical to the seven picks, so it was squash-merged as `1d28c0fa`. The integration branch was rebased onto it, and step 0 now holds only item 0.2 and its review fixes.

Rejected: resume #150 as is, then land the fixes as follow-ups.

## Consequences

- `main` is the source of truth for `service.dart`; any service hunk left on #150's successors is dropped rather than resolved.
- The `invalidArgument` classification for a malformed status reply is pre-existing client behavior and stays with PR 3 ([ADR 0003](0003-structured-closing-refusals.md)).
