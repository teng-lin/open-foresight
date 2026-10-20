# ADR 0003: What clients see while an owner closes (D3)

| | |
|---|---|
| Status | Accepted 2026-10-19; implemented in fix plan steps 3 and 5 |
| Deciders | Repository owner |
| Source | [Service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md), decision D3, findings SL-3, SL-4, SL-6, SL-9 |

## Context

A lost reply and a refused request were both reported as `unavailable`. Retrying a non-idempotent operation after an ambiguous failure duplicated it (`notes.save` without an ID committed twice). Requests in flight at close got a bare EOF even after committing, and a reply cut off by EOF surfaced as `FormatException`, which MCP mapped to `invalidArgument` and told the agent its arguments were wrong. The production `IsolatedApplicationService` destroyed peers at once on SIGTERM, while the handoff tests' fake owner sent a closing reply.

## Decision

Closing is a structured protocol, not EOF:

- `RpcErrorReason { closing, outcomeUnknown, notSent }` on `RpcError`, additive on the wire.
- **`closing`:** refused before dispatch; safe to retry after handoff.
- **`outcomeUnknown`:** dispatched or written to the socket, no terminal frame; may have committed. Never resent automatically.
- **`notSent`:** client-local; never reached a live socket; safe to retry.
- At the start of `_close` the server sends each dispatched lease a terminal `outcomeUnknown` frame; leases still waiting for approval or helper readiness get the `closing` refusal instead, so they may be resent. Terminal frames are flushed with a 2 s bound. The isolated frontend refuses new connections with `closing` while draining, refuses a desktop lifetime reservation while closing, and removes the public socket before the record is deleted.
- A peer cannot send `notSent`: it is dropped on decode and remains client-local. The legacy closing-text match applies only to frames without a `reason` key. An `outcomeUnknown` reply to the startup status probe hands off like `closing`, not like a transport loss, because the probe is read-only.
- Clients resend once on `closing` or `notSent` before any result frame, and never on `outcomeUnknown`.
- A bare EOF happens only on a crash.

Rejected: declare EOF the protocol and drop the closing-reply special case. Callers need "refused, safe to retry" to differ from "lost, may have committed".

## Consequences

- The closing text stays byte-identical, because v0.1.0 to v0.1.2 clients match on it; an `unavailable` error without `reason` whose message matches either legacy text is treated as `closing`.
- Idempotency keys ([fix plan 5.2](../plans/2026-10-19-service-lifecycle-fix-plan.md)) become the recovery path for `outcomeUnknown`.
- Startup and stop mechanics that landed with this decision, recorded here as implementation detail: a launcher writes a startup status file (`failed`, `contended` when the child lost the lock race, or a launch lease) that the launch loop reads instead of waiting out the deadline; a launcher makes a single lock attempt per launch and at most three launches; the status probe is capped at 30 s; and `--stop` reports success only after the profile lock is released, up to 30 s after the connection closes, so callers should allow at least 60 s plus recording finalization.
- [ADR 0007](0007-service-lifetime-and-desktop-agent-boundary.md) depends on these reasons to let the service exit under an idle agent safely.
