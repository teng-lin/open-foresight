# ADR 0005: Linux default runtime directory (D5)

| | |
|---|---|
| Status | Accepted 2026-10-19; implemented in fix plan step 4 (item 4.3) |
| Deciders | Repository owner |
| Source | [Service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md), decision D5, finding SL-7 |

## Context

On Linux every profile defaulted to the same runtime directory, `$XDG_RUNTIME_DIR/open-foresight`, and status did not say which profile answered. A client could attach to another profile's service, `--stop` could SIGTERM it, and a second owner could delete the first owner's live socket as stale. macOS already used a per-profile runtime, `$TMPDIR/of-<id12>`.

## Decision

Per profile, as on macOS: `$XDG_RUNTIME_DIR/open-foresight/<identity12>`, or `$data/runtime/<identity12>` when `XDG_RUNTIME_DIR` is unset, plus the identity check. `ProfilePaths.identity` (the 24-hex SHA-256 of the canonical data path) is exposed in status as `profile_id`; clients and the CLI refuse an owner whose identity differs and never launch over it. Owners never delete a socket path that still accepts a connection.

Rejected: identity check only, keeping the shared default. It stops the wrong attach but not the shared-directory collisions.

## Consequences

- Migration is free: an older owner records its runtime in the endpoint record, so new clients still find it, and the next owner uses the new path.
- Every consumer of the old default (`tools/installed_runtime.py`, `tools/integration_gates.py`, the shortcut test tools, packaging and docs) is audited for an explicit runtime.
- A missing `profile_id` from an older owner is accepted only while this profile's lock is held, and on Linux only if `/proc/locks` lists that owner's pid as the holder of this profile's lock file, matched by inode; if `/proc/locks` or the stat is unavailable, the owner is refused. macOS has no `/proc/locks`, so there any lock holder counts.
- Another profile's live owner at this endpoint makes startup fail at once with `AnotherProfileServing`, not at the deadline.
- Path rules: an empty or relative `XDG_RUNTIME_DIR` is treated as unset; the parent `$XDG_RUNTIME_DIR/open-foresight` must be private, while the `$data/runtime` fallback is not parent-checked; a socket path of 108 bytes or more on Linux is refused; a link at a socket path is removed as a link, never followed.
- Accepted residual: on macOS a live listener whose backlog never drains refuses like a dead socket and is replaced; the probe retries three times within its bound, which covers a live owner, and the residual applies only to explicitly shared runtimes.
