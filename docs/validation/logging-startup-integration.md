# Logging startup integration candidate

This worktree combines accepted root `66c23c9e` with B1 `b245cab0`, reviewed
identity generator `5411c40e`, launch metadata `fc5f4921`, and SQL support
`7d1913b9` / private handoff `aeeebf1d` as development dependencies. A successful
text merge is not integration acceptance. No products have been shipped.

Merge resolution preserved the accepted native application and C1 lifecycle,
latest persistence APIs, frozen migrations and all original persistence tests.
Native CMake retains both C1 and diagnostic component tests. Scoped-FD helpers
gain only B1's explicit minimum-descriptor, filesystem and lease primitives;
backup readers/writers are not redirected into the logging process.

`diagnostics/startup.dart` is system-only: it imports no profile, SQLite,
platform-services or application authority. The parser recognizes every
diagnostic internal prefix and accepts only four exact arguments. Invalid or
mixed invocations cannot reach profile resolution or an image loader. The A2
transport worker remains a separate early branch.

Composition calls `DiagnosticStartup.beforeApplication` once, before any DB or
application lock. Off and unavailable worker identities produce no diagnostic
image, owner, page or child. Mandatory SQL selection is independent of logging
configuration. Command resolution selects the installed service, never MCP,
the GUI or an environment wrapper. Source selection needs explicit public
compile-time context and a pinned Dart/package/script-or-kernel tuple.

Parent selection uses metadata only, with no symlink, hardlink, foreign owner
or writable candidate admitted. It does not open or hash source/command files.
The validated system DSO is the sole early regular-file load. Lazy owner
resolution retains immutable metadata, not a loader callback. UTF-8 argv must
fit sixteen entries, 1,024 bytes per entry and 2,048 bytes total. Source JIT uses
three identity defines and one closed public path descriptor, not an ambient
`-D` vector or profile/session data. Kernels carry compiled identities/context.

The root-owned runner uses `loadDiagnosticChildStartup(invocation, host: ...)`.
Its result supplies `functions`, `expectedParentPid`, `nativeId`, `dartId`,
`catalogId` and `verifyBeforeHello`. Only syntax/compiled IDs and the trusted
early DSO selection/load occur before the watcher. The executor must invoke
the optional callback after a positive watch ACK and fixed-kernel map, before
HELLO/private INIT, under the unchanged native bootstrap/operation deadlines.
The current source callback refuses: no reviewed source/SDK input-manifest
verifier or production worker ID has been activated. Declarative `-D` equality
does not establish source-byte identity.

Initial Linux selector tests executed sixteen cases, zero skips, and targeted
analysis/format passed. These include real symlink/hardlink/writable files,
compiled service/MCP path selection, finite argv and SQL independence from off
or missing diagnostic identity. They are metadata fixtures, not loaded-product,
Darwin FFI, compiled service worker, native owner, shutdown or installed-package
acceptance. Full startup/session wiring, native product identities, source
verification, build/package/consumer integration and combined Linux/Mac gates
remain pending.
