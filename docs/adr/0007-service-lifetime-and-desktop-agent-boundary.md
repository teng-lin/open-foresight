# ADR 0007: Service lifetime and the desktop/agent boundary

| | |
|---|---|
| Status | Proposed (2026-10-20). Referenced as **D7** by the [service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md). |
| Deciders | Repository owner |
| Depends on | [ADR 0003](0003-structured-closing-refusals.md) (fix plan PR 3: `closing`, `notSent`, `outcomeUnknown` reasons and resend-once) |
| Supersedes | The desktop-disconnect shutdown timer in `ApplicationService._accept` |

## Context

The application service is shared by the Flutter desktop and the MCP adapter. Its lifetime is today a side effect of desktop disconnect events, which produces inconsistent behavior: an agent-only service never exits, while the same agent work is cut off one second after a desktop happens to close. The details are in "Current behavior" below.

## Decision

The desktop pins the process; agents get an idle timeout. The service exits when no desktop is attached, nothing is in flight, and no agent request has completed within `serviceIdleMinutes` (default 10). Desktop close keeps its 1 s reattach grace. An agent connection by itself never pins the process. Explicit stop is authoritative for everyone. The desktop owns approvals, recording and its indicator; the service owns storage, agent operations, models and Google timers.

## Consequences

- Agent-only services stop leaking: they exit after the idle period, and the models go with them.
- Agent work in flight is no longer cut off when the desktop closes; the service waits for it and then applies the idle rule.
- An idle agent may find its service gone and relaunches on its next call. This is safe only with PR 3's structured closing reasons, so this ADR cannot land before PR 3.
- Google reminders still stop when the service exits, as they do today when the desktop closes. A resident-but-unloaded mode is out of scope.

---


## Current behavior, verified in code

Lifetime is driven entirely by `_desktopClients` and the `_desktopShutdown` timer in `ApplicationService._accept` (`service.dart:755-773`):

- A connection joins `_desktopClients` only through `status` with `desktop: true` and the capability token (`:656-673`) or `security.attach_desktop` (`:596-600`).
- When the **last** desktop connection closes and no approval host remains, a 1 s timer calls `close()`. Nothing else ever starts that timer.
- `close()` cancels every lease (`_close`, `:934-942`). Until PR 3 lands, in-flight agent requests get a bare EOF; after PR 3 they get `outcomeUnknown` and undispatched requests get a `closing` refusal.
- MCP's `ServiceConnection` sends a plain `status` (`:272`), so an MCP connection is never a desktop client and never starts the timer.
- Host detach, by request or by EOF, stops recording at once (`:601-614`, `:736-744`; [ADR 0006](0006-stop-recording-on-host-disconnect.md)) and fails pending approvals (`AgentAccessGate.detach`).
- Approval-requiring calls with no host fail with `denied`, "Open the desktop app to review this operation" (`agent_access.dart:155-160`).
- The only idle rule in the code base, the `inactivity` preference (`application.dart:2126`), stops a **recording** after 15 minutes without audio. It is not a service idle rule.
- `service.stop_if_idle` (`:812-870`) already has the right idleness predicate for an installer: no active or finishing recording and no in-flight lease other than `status`.

| Situation | Today |
|---|---|
| Agent only, no desktop ever | The service runs until `--stop`. Leftover services with no clients are the observed symptom. |
| Desktop and agent connected, desktop closes | 1 s later the service exits, even mid-request. The agent's next call launches a replacement, so nothing is saved. |
| Desktop closes, agent calls later | A fresh service that now lives indefinitely, because no desktop ever attached to it. |
| Agent disconnects, desktop stays | No effect. Correct. |
| `--stop`, `--stop-if-idle`, SIGTERM | Everyone is closed. Correct. |

The comment at `:759-760` states the intent: "Once the desktop has gone, agent connections must not keep its helper/models alive forever." The current rule misses that intent in the agent-only case and overshoots it in the desktop-plus-active-agent case.

## Decision D7

| # | Decision | Status | Recommended | Alternative | Affects |
|---|---|---|---|---|---|
| D7 | When the service exits | **Proposed** | **The desktop pins the process; agents get an idle timeout.** The service exits when no desktop is attached, nothing is in flight, and no agent request has completed within `serviceIdleMinutes` (default 10). Desktop close keeps its 1 s reattach grace. An agent connection by itself never pins the process; the agent reconnects on its next call. | (b) Every connection pins the process, and only models unload on idle. Rejected: long-lived MCP hosts keep a process per profile open for days, and an agent host that never sends EOF (a hung host) pins it forever. | Follow-up PR after the lifecycle PR merges |

Rationale for (a) over (b): the desktop is a visible UI whose presence is a user statement; an open MCP stdio pipe is a session artifact. Exiting under an idle agent is safe only because PR 3 gives the agent a `closing` or `notSent` reason it may retry on, and `ServiceConnection.stream` resends once on those (fix plan 3.5). That is why this cannot land before PR 3.

## The rule

The service holds one timer, `_lifetime`, that reevaluates a single predicate whenever a lease changes, a request completes, or recording state changes, and at most every 30 s otherwise.

**Exit when all of these hold:**

1. `_desktopClients.isEmpty && !access.hasHost` (no desktop lease).
2. At least `desktopGrace` (1 s, the existing `desktopDetachGrace` parameter from fix-plan test 8) since the last lease change.
3. No in-flight lease other than `status` (the `stop_if_idle` predicate).
4. `captureState['active'] != true && captureState['finishing'] != true`.
5. No source indexing or deletion job running, and no model configuration or acquisition in progress.
6. `now - lastAgentActivity >= serviceIdleMinutes`, where `lastAgentActivity` is the completion time of the last non-`status` request from a non-desktop connection, or service start if there was none.

Conditions 3 to 5 are "busy"; the timer rechecks when they clear. Condition 6 is "idle". A desktop-only service still exits 1 s after the desktop closes, because `lastAgentActivity` is service start and condition 6 is already true once the service has been up for ten minutes; for a short-lived desktop session it waits out the remainder of `serviceIdleMinutes`. If that is unwanted, condition 6 can read "no agent ever connected, or idle for the period" so a desktop-only service keeps today's instant exit. Pick one and pin it with a test.

`serviceIdleMinutes` is a `preferences` row, editable in desktop Settings next to the recording inactivity setting, and `0` disables the idle exit (the service then exits only on desktop close, explicit stop or crash). The timer is injectable for tests.

The exit path is the existing worker-initiated `close()` with no acknowledgement client, the same path `service.stop_if_idle` uses, so the frontend relay's draining and refusal behavior from fix plan 3.4 applies unchanged.

## What each client owns

| Capability | Owner | When the owner leaves |
|---|---|---|
| Approval host (`security.*` decisions, import-root grants) | Desktop | Pending approvals fail; new approval-requiring calls fail at once with `denied`, reason `needsDesktop`. Unchanged except the added reason. |
| Recording and its on-screen indicator | Desktop | Recording stops immediately (D6). Transcription of what was captured finishes in the service. Unchanged. |
| Process lifetime pin | Desktop | 1 s grace, then the exit rule applies. |
| Storage, search, notes, meetings, answers, imports within granted roots | Service | Served to agents until the exit rule fires. Agents see `closing`/`notSent` and resend once; `outcomeUnknown` is never resent. |
| Helper and loaded models | Service | Go with the process. A separate unload-but-stay-resident rule is out of scope here; see "Not in this change". |
| Google refresh timers and reminders | Service | Stop when the service exits. Already true today when the desktop closes; unchanged. |
| Explicit stop (`--stop`, `--stop-if-idle`, SIGTERM) | Operator | Authoritative for everyone. An agent's next call may launch a replacement; that is acceptable because the agent asked for work. |

## Lifecycle table for `application-service.md`

Replace the "Shared operation and lifecycle" paragraph that begins "Launching either client attaches" with this table and one sentence pointing at `serviceIdleMinutes`.

| Who is connected | Who started it | What keeps it alive | Exits when |
|---|---|---|---|
| Nobody yet (just launched) | A launcher | The idle period | No desktop attaches and `serviceIdleMinutes` pass with no agent request |
| Desktop only | Desktop | The desktop lease | 1 s after the desktop's last connection closes |
| Agent only | MCP | Recent agent requests and in-flight work | `serviceIdleMinutes` after the last agent request completes, with nothing in flight |
| Desktop and agent | Either | The desktop lease | Desktop closes: recording stops and approvals close at once; the service stays while agent work is in flight or recent, then exits by the agent rule |
| Any | Any | — | `--stop`, `--stop-if-idle`, SIGTERM, or a crash |

## Changes

1. **`ApplicationService`:** add `lastAgentActivity`, `_lifetime`, and `_shouldExit()`. Update `lastAgentActivity` in the lease `onDone`/`onError` handlers for non-desktop connections. Replace the `_desktopShutdown` timer body with a call to `_reevaluateLifetime()`; keep the 1 s grace as condition 2. Delete the comment at `:759-760` and say the rule in one line.
2. **Busy predicate:** extract the `stop_if_idle` checks into `bool get _busy` and use it from both `_stopIfIdle` and `_shouldExit`. Extend it with indexing/deletion jobs and model configuration; `stop_if_idle` gains those checks too, which only makes the installer more conservative.
3. **`RpcErrorReason.needsDesktop`:** additive enum value and `reason` on the existing "Open the desktop app" denial. MCP already copies `reason` into `structuredContent.error` after PR 3.
4. **Status:** additive `lifetime` object: `{"pinned_by_desktop": bool, "busy": bool, "idle_since": ms, "idle_minutes": n}`. Tests and `--status` read it instead of sleeping.
5. **Preference** `serviceIdleMinutes` and its Settings row.
6. **Docs:** the table above in `application-service.md`; D7 appended to the fix plan's decisions table; the coverage matrix gains an "Idle exit" column for the desktop and MCP rows.

Wire compatibility: all additions are optional fields. An older MCP (plain `status`, no `reason` handling) against a new service sees the service exit while idle, then reconnects on its next call, which it already does today after any lost connection. An older service against a new client behaves as today.

## Tests

Production code on both sides, timers injected, no sleeps for ordering:

1. Agent-only service: one `notes.save`, then the clock passes `serviceIdleMinutes`. The service exits; `--status` on the socket path fails with "not running"; the next `ServiceConnection` call launches exactly one replacement.
2. Agent-only service with a request in flight at the deadline: it completes with its real result; the service exits `serviceIdleMinutes` after that completion, not before.
3. Desktop and agent: the desktop closes while an agent `answer.stream` is running. Recording (if any) stops at once, the agent stream completes, and the service exits by the agent rule. Resend count on the agent side is zero.
4. Desktop and agent: the desktop closes with the agent idle for longer than the period. The service exits after the 1 s grace; the agent's next call gets `closing` or `notSent`, resends once, and succeeds on the replacement (reuses fix-plan test 7).
5. After host detach, `sources.import` from an agent fails with `denied` and `reason: needsDesktop` before any dispatch.
6. Busy conditions each hold the exit: active recording, finishing recording, a running import, model configuration. The exit fires when the condition clears.
7. `serviceIdleMinutes = 0` disables the idle exit; the desktop rule still works.
8. Existing SAA tests keep passing without assertion changes: `desktop socket closure shuts down service and persists committed data`, `desktop reconnect during grace period keeps service alive`, `ordinary startup status does not reserve desktop lifetime`.
9. `tests/service`: a built MCP twin of test 1 using a short `FORESIGHT_SERVICE_IDLE_SECONDS` test hook that compiles out (same mechanism as `FORESIGHT_SERVICE_GATES`), plus the hook-free release check.

## Not in this change

- **Unloading models while the process stays resident.** `Domain.resetNoteEnhancementService` can release the generator, but `HelperProcess.close` is terminal (`_closing ??=`), and the helper's restart budget and `shutdownVerified` bookkeeping assume close means shutdown. A resident-but-unloaded mode needs a restartable helper stop and belongs with plan 3's native-runtime work (6.3, PR 8). With D7 as proposed, models already go away with the process in every agent-only case, which is what the original comment wanted.
- **Google reminders surviving service exit.** They already stop when the desktop closes today. Keeping them would mean a resident mode, same as above.
- **Changing D6.** Recording still stops the moment the host leaves.

## Scheduling

Land this as its own PR after the lifecycle integration PR merges, not as a sixth step on `open-foresight-services`:

- It changes behavior rather than fixing a defect, and deserves one review with its own description.
- It depends on PR 3's `closing`, `notSent` and resend-once semantics; without them an agent under an idle exit would get a bare EOF again.
- Steps 3 to 5 are under Mac verification now. Editing `_accept` and `_close` on the integration branch would force re-verification of the closing protocol.

Record D7 in the fix plan's decisions table now, with status "Deferred to a follow-up PR", so the final PR description lists it. Expected size: about 300 lines of production code and 600 of tests, two to three days including both verification environments.
