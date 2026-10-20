# ADR 0004: Protecting editor-held IDs after a workspace clear (D4)

| | |
|---|---|
| Status | Accepted 2026-10-19; implemented in fix plan step 5 (item 5.1) |
| Deciders | Repository owner |
| Source | [Service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md), decision D4, finding SL-5 |

## Context

`notes.save` with an ID that no longer exists reported success and wrote nothing. After `workspace.clear`, SQLite `INTEGER PRIMARY KEY` tables reuse IDs, so a stale editor (a desktop or agent that missed the clear, for example because its reply was lost) could overwrite an unrelated new note.

## Decision

A persistent workspace epoch. A random 128-bit token is stored in `preferences` under `workspaceEpoch`, created on first start and regenerated inside the `workspace.clear` transaction. Status returns `workspace_epoch`. The desktop sends it with every ID-based mutation, and the service rejects a mismatch with `notFound`. MCP tools accept it as an optional argument. Independently, every RPC that mutates an existing row by ID requires `updatedRows == 1` or throws `notFound`.

Rejected: `AUTOINCREMENT` on `notes` and `meetings` through a table-rebuild migration. It fixes ID reuse but not the lost-clear case, and it costs a rebuild migration for no schema benefit.

## Consequences

- No schema change is needed for the epoch. `workspaceEpoch` cannot be set through `preferences.set`.
- Keyed creates carry the epoch too: a keyed retry after a clear is rejected with "nothing was saved" instead of replaying into the new workspace.
- The epoch check runs before approval, so a stale request never prompts the desktop.
- `changed` events carry `workspace_epoch`, so clients learn of a clear without polling status.
- A desktop whose `workspace.clear` ended in `outcomeUnknown` refreshes status and runs its UI reset if the epoch changed ([fix plan 5.3](../plans/2026-10-19-service-lifecycle-fix-plan.md)).
