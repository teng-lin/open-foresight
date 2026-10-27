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
compile-time context, a selected SDK root/public identity, and a pinned
Dart/package/script-or-kernel tuple; the executable cannot select its own trust
anchor. Installed entries ignore embedded source-fixture selections. Source/package files, the pinned SDK and an explicit
selected build output directory have separate physical metadata anchors; custom
`FORESIGHT_BUILD_DIR` outputs need not reside inside the repository. That build
root is compile-time context, never an ambient child/support selector.

Parent selection uses metadata only and walks every physical ancestor outside
and within the selected anchor. Symlinks and foreign/writable directories are
refused except the exact reviewed root:admin0775 `/Applications`, root:staff02775
`/usr/local` and physical root-sticky temp directory rules. A sticky ancestor
requires its next descendant to be private. All consumed Linux statx fields
(TYPE/MODE/NLINK/UID/GID) must be present. No symlink, hardlink, foreign owner
or writable ordinary candidate is admitted. It does not open or hash source/command files.
The validated system DSO is the sole early regular-file load. Early selection
checks only that image and its physical ancestor chain. Launcher, worker, SDK,
package-config and argv metadata are checked only by the lazy owner callback
when persistence becomes eligible; no regular candidate is opened or hashed
then. The callback retains immutable context and the early-selected image path,
not a loader callback. UTF-8 argv must
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

Linux selector tests executed twenty-two cases, zero skips, and targeted
analysis/format passed. These include real symlink/hardlink/writable files,
compiled service/MCP path selection, finite argv and SQL independence from off
or missing diagnostic identity. One regression maps an actual controlled FFI
image while service/launcher candidates are absent; the previous early full
resolver fails that oracle. This proves support-only mapping and deferred
command checks, not a production worker load. The remaining tests are metadata
fixtures, not loaded-product,
Darwin FFI, compiled service worker, native owner, shutdown or installed-package
acceptance. Full startup/session wiring, native product identities, source
verification, build/package/consumer integration and combined Linux/Mac gates
remain pending.


`src/diagnostic_bootstrap.dart` is the normal application composition adapter;
worker code never imports it. It maps diagnostics only when enabled/available,
and independently initializes mandatory selected SQL support for service and
desktop before application authority. MCP remains a client and opens no SQL.
Session creation passes the early original function table to the native owner,
with command selection retained as a lazy metadata-only callback. This adapter
is now wired into normal service/MCP/desktop entrypoints. Service dispatches
internal diagnostic/model worker modes before it; MCP/desktop refuse internal
modes before normal bootstrap. The service frontend uses the owned-isolate
producer API, SQL original-code bootstrap at slot4, diagnostic bootstrap at slot5
and independent profile-ownership reporter at slot6. Classification is reported
at the actual profile-lock acquisition boundary; diagnostic close follows
application/native cleanup. Startup-only desktop Quit retains explicit exit,
while normal workspace lifetime keeps its existing owner. Full qualification
and the frozen B2 event/error adoption integration remain pending.


The normal composition checkpoint adds actual compiled current-service controls:
invalid/internal-without-identity modes produce only closed exit codes64/65 with
no stdout/stderr or profile/runtime directories, and the model worker retains
its framed response without SQL/log bootstrap. A real frontend test serves a
status request and proves the accepted Domain producer retires only with its
actual application VM. It uses the explicitly reused, source-identical qualified
SQL component, not a newly built application-native library. A mutation routing
that production call through unadopted Isolate.spawn must fail the retained-slot
oracle. Desktop tests prove early runtime failure remains visible and Retry
runs its gate before profile/configuration/connection authority. These focused
checks do not replace root CTest, full core/desktop/service/display or installed
acceptance; production WorkerID and source verification are still pending.
