# ADR 0002: Policy after an unclean service shutdown (D2)

| | |
|---|---|
| Status | Accepted 2026-10-19; implemented in fix plan step 0 (item 0.2) on `open-foresight-services` |
| Deciders | Repository owner |
| Source | [Service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md), decision D2, finding SL-8 |

## Context

An unclean shutdown leaves the endpoint record in place with the profile lock free. Two launchers observing the same state behaved differently: one that saw the closing reply threw "released ownership without clean shutdown", while one that saw EOF launched a replacement. A startup failure after the record was published left the same state. The error was one-shot anyway, because the reconnect one second later launched.

## Decision

Always recover. Once a launcher acquires the lock in `_profileOwnerAvailable`, it proceeds whether or not the record exists. The replacement adopts the recorded runtime, which `ApplicationService._start` already did for a healthy helper left at that endpoint. When the record exists, log that the previous owner left its endpoint record and the replacement adopts its runtime.

If startup fails after this attempt published a record that did not exist before, delete it before releasing the lock. If the record existed before (adoption), leave it, because it points at the adopted runtime.

Rejected: fail every launcher consistently and require a manual recovery step.

## Consequences

- One outcome for every launcher: exactly one launch, and all attach to the replacement.
- The "released ownership without clean shutdown" `StateError` is gone. The `closingOwner` parameter of `_profileOwnerAvailable` stays: a closing refusal observed without this profile's lock file now ends in `AnotherProfileServing` (ADR 0005, fix-plan step 4), not in a relaunch.
- Adoption has exceptions. An invalid record, or one that names another profile's live runtime, is set aside (quarantined, at most three kept) and the owner starts in its own runtime. A starting owner claims the record by renaming it to `.claimed` right after taking the lock, adopts the runtime it names, and restores the record if startup fails.
- "Record present" now means the owner is live, draining, or crashed; [ADR 0003](0003-structured-closing-refusals.md) tightens the order so the record is deleted after the public socket.
