# ADR 0006: Stopping recording when the host desktop disconnects (D6)

| | |
|---|---|
| Status | Accepted 2026-10-19; no code change (the spurious-disconnect cause was fixed in fix plan step 1, SL-1) |
| Deciders | Repository owner |
| Source | [Service lifecycle fix plan](https://github.com/teng-lin/open-foresight/blob/52bdd39778f31d632d434ada3fca7b165b9c6336/docs/plans/2026-10-19-service-lifecycle-fix-plan.md), decision D6, finding SL-1 |

## Context

The service stops an active recording the moment the desktop approval host detaches or its socket closes, because the on-screen recording indicator is no longer available. SL-1 showed this could fire spuriously: one reply over 16 MiB dropped the desktop's only socket, the service treated that as the host leaving, and stopped the recording. Opening the graph with about 1,000 indexed sources triggered it.

## Decision

Keep the immediate stop, for privacy. Fix the causes of spurious disconnects instead: cap reply frames server-side and fail only the oversized request, and batch graph embedding requests on the desktop.

Rejected: give the recording stop the same 1 s reattach grace that the desktop's process lease has. A microphone that keeps capturing for a second after its indicator disappeared is the wrong trade.

## Consequences

- Transcription of already captured audio still finishes in the service after the stop.
- Disconnecting only the MCP client leaves capture running while the desktop remains connected.
- [ADR 0007](0007-service-lifetime-and-desktop-agent-boundary.md) keeps this rule unchanged: recording is desktop-owned, and only the process lifetime rule changes.

## Visibility correction, 2026-10-28

Window visibility is separate from desktop ownership. An existing recording now
continues when the window is hidden, minimized or covered. Visibility still gates
new recording starts, resumes and agent approvals; hiding the window cancels a
recording that is still starting. Explicit Stop, desktop detach
or disconnect, and application shutdown still finish capture immediately.

A local diagnostic trace showed a clean capture stop at the exact time of a
`security.desktop_visibility` request while the desktop and service kept running.
This correction prevents that visibility transition from ending an authorized
recording, and adds bounded stop-reason and first-failure-stage diagnostics.
