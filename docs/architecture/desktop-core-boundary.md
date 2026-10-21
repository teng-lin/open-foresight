# Desktop core API

Production desktop features import `package:foresight_core/desktop.dart`.
This curated API exports `DesktopConnection`, its read-only `StoreReader`, immutable
helper/recording/persistence values, typed read queries, RPC operation/error values,
and the existing UI algorithms and asset-download utilities. It exports no writer
Store, Domain, Helper, native handle, generated gRPC client, helper transport,
credential store or service transport. Only `main.dart` imports
`desktop_bootstrap.dart`: startup resolves the profile, prepares its private
directories and connects through `connectDesktop`, whose result is a
`DesktopConnection`. Feature controllers never receive that profile object.

`DesktopRuntimeSettings` snapshots only the resource paths used by model setup
and notification presentation. Web-content availability is a boolean; the API
does not export credentials or a mutable process environment. Model destinations
come from the connection's two `DesktopModelAssets` directories. The old desktop
files that forwarded entire core implementation libraries have been removed.
Tests and developer tools that intentionally own writers or workers import core
implementation/test-support modules explicitly.

The connection owns events, transport, helper presentation and its core reader.
Call `initialize()`, subscribe to `changes`, flush pending note saves before
`close()`, then await `closed`. Helper status contains state only. The desktop
never constructs helper channels or performs migrations. Cheap synchronous read
adapters remain during the core-to-feature transition; search, statistics and
graph loads already use the core read worker. Work package 7 replaces remaining
render-time queries and temporary `toRow()` adapters with owned view models.

The source-boundary and resolved-export checks in
`packages/foresight_core/test/desktop_boundary_test.dart` run in the ordinary core
suite. They inspect production imports/exports and resolve both curated public
namespaces, preventing a proxy export from silently restoring implementation
capabilities. The bootstrap entry point is admitted only in `main.dart`.

## Pinned helper transport workaround

`helper_channel.dart` subclasses gRPC's internal `Http2ClientConnection` and owns
the outgoing request subscription. `helper_transport.dart` presents a successful
transport-disconnect notification while preserving read errors and EOF, so
discarded completion futures in the upstream stack cannot escape as unhandled
write errors. Both are qualified against exactly `grpc: 4.3.1` and `http2: 2.3.1`.
`helper_dependency_compatibility_test.dart` checks the exact pubspec pins and the
resolved versions in **the core package's** lockfile. It does not inspect a
different package's lockfile or authorize an upgrade.

Keep the workaround until an upstream fix has been verified with
`helper_channel_test.dart` and `helper_transport_test.dart`, including peer EOF
before queued writes, synchronous and asynchronous sink failures, reentrant
cleanup, cancellation, headers/compression and normal half-close responses.
The local [upstream report draft](../upstream/grpc-helper-eof-report-draft.md)
records the search and reproduction scope. No upstream message has been sent.
