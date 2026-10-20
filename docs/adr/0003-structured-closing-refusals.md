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
- The server sends every in-flight lease a terminal `outcomeUnknown` frame at the start of `_close`, then drains. The isolated frontend refuses new connections with `closing` while draining and removes the public socket before the record is deleted.
- Clients resend once on `closing` or `notSent` before any result frame, and never on `outcomeUnknown`.
- A bare EOF happens only on a crash.

Rejected: declare EOF the protocol and drop the closing-reply special case. Callers need "refused, safe to retry" to differ from "lost, may have committed".

## Consequences

- The closing text stays byte-identical, because v0.1.0 to v0.1.2 clients match on it; an `unavailable` error without `reason` whose message matches either legacy text is treated as `closing`.
- Idempotency keys ([fix plan 5.2](../plans/2026-10-19-service-lifecycle-fix-plan.md)) become the recovery path for `outcomeUnknown`.
- [ADR 0007](0007-service-lifetime-and-desktop-agent-boundary.md) depends on these reasons to let the service exit under an idle agent safely.
