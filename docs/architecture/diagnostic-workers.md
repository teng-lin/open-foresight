# Diagnostic worker ownership

Diagnostics are local, bounded metadata. They do not own the application,
database, models, capture, profile lifecycle or requested command output. The
[user guide](../diagnostics.md) covers configuration, files and support actions;
this guide describes the runtime boundary in `lib/src/diagnostics` in the core
package.

## Entrypoint and producer authority

One process entrypoint owns `LoggingSession`, retains it across startup retries,
and passes explicit producer bootstraps to worker isolates. A producer cannot
choose files, resolve profiles, spawn a writer or close the session. The entrypoint
supplies the resolved profile; its normal ownership decision separately classifies
the session. Merely attempting service startup does not make a candidate an
acquired service failure.

Resolve the effective log configuration, including the validated macOS startup
handoff, before loading diagnostic support and before application/profile/SQLite
locks exist. Explicit `off` creates no writer, ports, native consumer, mapping or
child. Enabled but cold, transient or pre-profile sessions do not start a storage
child. Missing or unsafe support disables persistence with a closed health reason;
it never permits a late library load while application locks are held.

The event catalog is closed: registered components, events, operations, categories
and bounded numeric fields. No arbitrary messages, entity IDs, transcript/audio,
paths, URLs, credentials, environment values or child stderr enter records. Optional
stack projection accepts bounded trusted text or registered numeric locations;
production logging does not invoke an arbitrary `StackTrace.toString()` for it.
Preserve existing user-facing fatal/error policy independently of persistence.

Level checks, available credits and a producer's reentrancy guard precede field
builders and encoding. Sixteen live producer slots use monotonically increasing
generations. Queued records retain their original kind/slot/generation snapshot;
a late completion cannot refund credits to a replacement producer. Revocation
requires acknowledgement after its builder unwinds, or a causally ordered actual
isolate-exit barrier. Uncertain retirement quarantines the slot and its resources.
Drop counters saturate; pressure and health notifications coalesce instead of
creating a message per dropped event.

## Exec storage boundary

Regular log-file operations run in a separate owned storage process. This is a
lock-safety boundary: opening and closing an unexpected alias in the application
process can release that process's POSIX database locks. The logger must not
inspect rejected regular-file candidates by opening them in the business process.
The child receives no application/database/native-model handles and cannot create
another diagnostic session.

`diagnostics/startup.dart` recognizes only the exact internal grammar:

```text
--diagnostic-storage-worker PARENT_PID --diagnostic-native-support ABSOLUTE_PATH
```

Malformed or combined internal modes fail before configuration, profile, database
or application initialization. The public support path is validated code selection;
the profile, role, session and records travel through the private mapping, never
argv or environment. Native spawn uses a closed `LANG=C`, `LC_ALL=C` environment,
working directory `/`, bounded arguments and sanitized descriptors. It does not
inherit PATH, loader overrides, credentials or application configuration.

Compiled and packaged hosts select the dedicated `foresight-diagnostic-worker`
from the validated installation or build. They do not restart the service, stdio
MCP or the GUI. The macOS worker lives in `Contents/Resources/bin`; Linux uses
the bundle's `bin` directory. Source/JIT/kernel runs use explicit pinned Dart,
package configuration and source/build context. There is no PATH search, ambient
wrapper fallback or packaged environment override for the worker or support image.
The native launcher starts the diagnostic child directly; normal application
service launch through LaunchServices remains a separate path.

Both the system-only diagnostic support library and diagnostic launcher are
required products. They do not link application-native, SQLite, gRPC or inference
constructors. A dedicated spawn isolate receives only an opaque native context
identity and code addresses from the original already-loaded support mapping.
The coordinator retains that context through writer/spawn-isolate failure and a
late spawn return. A timeout never proves that an unknown child stopped.

## Channel and storage protocol

One fresh fixed-size kernel mailbox supplies the private control/request/reply
channel. There is no diagnostic stdio bootstrap or application-held AF_UNIX data
socket. The 16 KiB shared object is charged for both process mappings. Atomic
close-on-exec descriptors and a fixed child descriptor whitelist prevent unrelated
profile/database/lease descriptors from reaching the exec worker.

The authenticated protocol checks the selected Dart worker identity, native
support identity, catalog, schema and parent/session identity before file admission.
INIT is a closed binary body with raw session bytes and bounded UTF-8 profile;
decoding INIT grants no file authority. ADMIT separately acquires storage.
Classification is acknowledged before corresponding records append, and only
actual acquired ownership promotes a service role or protects its failure.

APPEND carries final schema-2 JSONL of at most 4,096 bytes including newline.
Producer payloads are at most 2,048 bytes. The child validates the build ID,
session, logical parent PID, increasing sequence and closed event/body fields.
Schema-2 producer identity is `writer:0:0` or a registered kind/slot/generation;
legacy schema-1 records are not decoded using an unrelated current catalog.
Bounded shape/token checks precede JSON decoding; duplicate keys, unsupported
versions, excess depth, malformed fields and oversized frames are refused.

Log roots, permanent lease/admission files, ten slots, bounded manifests and
segments use anchored no-follow private filesystem operations in the child.
Live or uncertain leases are not reclaimed. Corrupt or unsupported manifests with
data remain occupied rather than becoming empty retention candidates. Storage
failures preserve existing bytes and incomplete tails and disable persistence;
they cannot change a business result, retry an operation or print onto its protocol.

## Resource bounds

The traffic contract is 512 KiB and 256 event tickets across producers, writer and
storage channel. Its reservations are distinct:

| Reservation | Ceiling |
| --- | --- |
| Producer grants and queued/in-flight event charges | 192 KiB; 224 tickets |
| Shared mappings, native copies, poll/spawn and descriptor preparation | 160 KiB |
| Sixteen producer encoders plus one writer encoder | 144 KiB |
| Registration, ownership, correlation, rate and health controls | 16 KiB; 32 internal tickets |

The event pool reserves 128 KiB and 64 tickets for warning/error traffic; ordinary
traffic has 64 KiB and 160 tickets. A record is conservatively charged as four
times its encoded producer bytes plus 256. Moving it to the cold or in-flight
queue does not refund that charge. A grant's unused capacity returns only through
the acknowledgement/retirement protocol, never an assumed delivery.

Native application diagnostics have a separate 256 KiB queue budget. Storage/IPC
metadata has a separate combined 128 KiB working-set budget; neither is permission
to add an event queue outside the traffic ledger. VM, allocator, stack and process
baselines are not claims about the traffic bound or total RSS. Physical resource qualification
must include simultaneous copies, encoding scratch, mappings and native polling;
logical counters alone do not establish a physical memory bound.

Native queue consumption requires writer credit before removing records, with at
most 64 records per tick. Priority-only credit cannot drain ordinary traffic.
The observer pins the original compatible application image, negotiates optional
queue ABI support and installs canonical log level before native configuration
seals. It passes immutable code capabilities, never application object pointers.
Unsupported old images disable optional native logging without weakening required
native runtime admission. Wide counters are clamped with explicit precision loss;
contention never invents an exact loss count.

## Retirement and failure

An operation result, cancellation request or isolate kill is not actual native
retirement. Linux tracks the original spawned child through its birth pidfd;
Darwin binds an exit watch to a fresh acknowledgement from the original child.
A guessed or reused PID never authorizes signalling or a successful close claim.
Private probe/force retirement remains separate from regular-file FFI in the child.

Close stops native polling, orders its final messages before producer revocation,
and joins actual producer/native/storage ownership. Busy native close retains its
buffers and consumer; retry stays in the serialized flush chain. The entrypoint
finishes application/client/native cleanup and intentional output disposition
before the diagnostic close deadline. `LoggingCloseResult.requiresExplicitExit`
reports parent work that can still keep the VM alive; the logger itself never
calls process exit. Standalone entrypoints preserve their exit code when an
explicit final process exit is required. Child-only failure is not proof of an
unsettled parent, and unconfirmed cleanup cannot be reported as flushed.

## Build identities and verification

`tools/diagnostic_build_identity.py` and `tools/diagnostic_build_inputs.json` define
separate native-component and Dart-worker identities. The native identity covers
the launcher/support sources, protocol, target and toolchain inputs. The worker
identity covers its reviewed source/compiler/mode/catalog closure. Version numbers,
Git revision strings and matching `-D` text alone are not source-byte verification.
Arbitrary environment or distribution secrets are excluded from both identities.

`tools/build_diagnostic_worker.py` emits and verifies the worker build receipt in
`build/application/diagnostic-worker-build.json`. Root native products and the
service/desktop build context must agree on native, worker and catalog identities.
Source closure changes require a matching rebuilt or verified worker context;
native reuse must still satisfy its own exact receipt. Packaging verifies both
products and their matching identities rather than treating a stamped file as a
fresh build. Hashing follows the [diagnostic SHA-256 contract](diagnostic-sha256.md).

Run the catalog generator's `--check`, diagnostic startup/protocol/storage/native
adapter tests, root native CTest and the current service/core/desktop gates from
[CONTRIBUTING](../../CONTRIBUTING.md). Test actual compiled and packaged consumers
with the matched products, including off mode, missing/skewed identities, unknown
retirement and preserved stdio. Fixtures do not establish minimum-platform,
filesystem, signed macOS bundle or physical device acceptance.
