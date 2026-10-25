# Desktop core API

Production desktop features import `package:foresight_core/desktop.dart`.
This curated API exports `DesktopConnection`, its read-only `StoreReader`, immutable
helper/recording/persistence values, typed read queries, RPC operation/error values,
and the existing UI algorithms, model catalog/cache values and remote acquisition interfaces. It exports no writer
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
never constructs helper channels or performs migrations. Named read projections
run through the core read worker; feature-owned read models prepare the values
used during rendering. The snapshot path opens an explicit read-only SQLite
connection and shares read-only model, label, graph, answer-scope and passage
queries with service persistence. It does not import `Store`, mutation helpers
or schema migrations.

`clientSessionGeneration` is an opaque identity token for the adopted RPC client.
Every actual client adoption changes it and emits `changes`, including replacement
at an unchanged socket path, epoch and status. Ordinary data/capture changes retain
it. Feature publications capture it alongside their own lifetime, epoch and request
identity. It does not authorize a mutation or cancel already dispatched work;
ordinary RPC settlement and replay rules are unchanged. The authoritative SQLite
reader identity and worker remain separate and may survive a client replacement.

`ReadQuery` keeps immutable scheduling arguments separate from an optional
dispatch-argument factory. The existing coordinator calls that factory only when
starting an actual read and deeply freezes its result. Default queries keep their
fixed arguments. `outputStats(now:)` remains a fixed snapshot query;
`outputStatsForPeriod(period:, clock:)` keeps one calendar/zone scheduling entry
while sampling an exact cutoff at each dispatch. `OutputStatsPeriod` captures the
five Monday boundaries, label dates, effective zone and next Monday; the worker
uses those absolute boundaries rather than reinterpreting the caller's timezone.
A changed calendar period refuses dispatch, so its owner must retire the old watch
and replace it. The later feature migration owns timers, awake timezone detection
and label publication; this core seam does not provide those UI lifecycle hooks.

The source-boundary and resolved-export checks in
`packages/foresight_core/test/desktop_boundary_test.dart` run in the ordinary core
suite. They inspect production imports/exports and resolve both curated public
namespaces, preventing a proxy export from silently restoring implementation
capabilities. Only the two entry files are direct analyzer roots; referenced
libraries still participate in complete transitive export linking. The separate
recursive desktop import scan and every capability assertion remain. Both desktop
and MCP adapter closures include conditional import/export alternatives and reject
service authority, native capture/runtime and mutation modules. The deliberate
read-only SQLite snapshot path remains named and tested. The bootstrap entry point
is admitted only in `main.dart`. `service_client.dart` exposes remote transport and
startup; `service_server.dart` exposes service-only composition.

## Logical widget libraries

Collection/preview, workspace/header, recording and summary renderers receive
immutable presentation values and explicit callbacks. Source collections, tiles,
note editor/review and graph scene/inspector renderers follow the same boundary.
Editor, transform and scroll handles stay with their existing controller owners;
renderers receive only those explicit UI handles. Async saves, retry keys, dialog
retirement, selection and workspace/session identity checks remain in controllers.
Remaining meeting assistant/note/AI parts and source action/layout/interaction
parts still count against their controller's logical library; extracting the
renderers does not claim that all remaining coupling is removed.

`desktop_logical_library_test.dart` follows every `part` recursively when counting
physical source lines and AST decision nodes. The default ceiling is 1,000 lines
and 200 decision nodes per logical desktop library. Residual meeting, source and
settings owners have explicit ceilings of 3,000/425, 3,000/400 and 2,000/200
respectively. At the guard's introduction, these owners measured 2,462/360,
2,163/306 and 1,558/155 including their parts. These are measured debt ratchets,
not a PR file-count rule. The guard also rejects transitive controller/read-model
imports and `part of` coupling in the extracted renderer libraries.

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
