# SQLite read-worker ownership and native deadline seam

Service and desktop entrypoints, packaged runtime selection and direct Store
consumers establish the explicit startup gate before opening SQLite. A missed
gate intentionally fails closed.

## Explicit early owner gate

Embeddings call the startup-only public capability:

```dart
final bootstrap = initializeSqliteRuntime(
  supportLibrary: validatedAbsoluteRuntimeSupportPath,
);
// Pass bootstrap to each owned isolate; bind before its first database access.
// bindSqliteRuntime(bootstrap);
```

The embedding must already have validated that exact runtime artifact through
its ownership/package trust contract. The SQL seam does not invent a selector,
consult an environment override, search a basename, inherit a preload variable
or load the heavyweight application native image. It requires an absolute
selection and remembers that exact selection/original mapping in its isolate.
Repeating it there reuses the same pinned code; a changed selection or a worker
binding refuses before path loading. The process entrypoint owns all path-based
initialization and passes the opaque public bootstrap to every owned isolate.
Those workers call `bindSqliteRuntime`, which uses only the inherited original
code. The Dart latch is not process-global: an arbitrary unbound isolate can
violate the embedding contract by calling path initialization itself. This seam
does not claim to prevent arbitrary embedding code from doing so. Package and
entrypoint owner review must establish the real process-entrypoint/worker order.

The separate `foresight_sql_support` image has only system dependencies.
Diagnostics-off does not remove the SQL deadline requirement and does not make
SQL load the diagnostic DSO/child. Its sole exported startup operation uses
`pthread_once` to join concurrent early callers, checks ABI and every code
entry's image base, and retains the already mapped image. This loader-owner
operation must precede any application connection/locks and worker creation.
Dart separately checks the returned table size, capacity and interval.
Failure is permanent for that image. Worker handoffs include no initializer.

Each private handoff contains only the validated ready/begin/end code addresses,
not a SQLite connection, database pointer or native context pointer. Binding in
a worker performs only the pure atomic ready check; it never loads a path or
performs a fallback lookup. Missing handoff and changed-image binding refuse
before application SQLite is opened. Direct library/Store users must bootstrap
explicitly too. The gate is not hidden in a generic temp-directory helper.

## Statement and context lifetime

One lazy read isolate owns its read-only connection. The process entrypoint
eagerly initializes `package:sqlite3` 2.9.4 before connections or workers. It
captures the actual mapping's physical absolute path, image base, progress
installer address and SQLite source identity, retains it with `RTLD_NOLOAD`,
and registers that canonical loader name before any database locks. A foreign
prior package initialization that prevents capturing the actual mapping refuses.
The entrypoint owns the package-wide loader override, replacing earlier
foreign overrides with its existing Mac or Linux bundle selector. An installed
Linux executable shape with missing layout refuses before fallback. Unbundled
Linux source use retains the pinned package default: executable-linked Flutter
SQLite first, then its existing system basename fallback;
installed products never use it. Broader artifact/path validation remains the
validated-selection integration gate.
The opaque original-code handoff includes this SQLite mapping, never a database
or native context pointer.

A fresh worker does not re-read the SQLite environment, resolve an installation
symlink, search a basename or discover another image. Before its first database,
it requires the frozen canonical name to succeed with `RTLD_NOLOAD` and match the
original anchor/image. Only then may the Dart FFI loader acquire its reference to
that exact already mapped canonical image. The entrypoint has already opened
this exact canonical name before connections. The glibc/dyld loader name match
is verified with NOLOAD and physical replacement tests. Dart's documented
same-file open guarantee alone does not cover a replaced file. A loader that
matched only file identity would leave a NOLOAD-to-open window and is outside
this supported recipe.
The package's function bindings and source identity must match before a
connection opens. These startup refcounts
are retained until process death. The AOT regression changes a fixture-built installation
SQLite alias to a loadable non-SQLite image while a parent write transaction is
held; a second case also renames and replaces the frozen physical file itself.
The replacement bytes are checked independently. An explicit reverse control
proves the discovery alias changed, and a fresh bound isolate reports the original anchor in both cases. The real
read worker returns the committed snapshot while the parent retains its write
transaction. After the reader closes, a separate process must receive
`SQLITE_BUSY` from `BEGIN IMMEDIATE`, independently witnessing that the parent
retained its write lock. Its mapping identity follows from the shared checked loader path,
rather than a separately reported worker anchor. Negative oracles refuse an
unloaded copy without mapping it and reject a mismatched anchor.

Owned sessions construct their budget eagerly. No read snapshot/BEGIN performs
a support-image or SQLite-symbol lookup. `Database.handle` stays in its owning
isolate and is supplied only to this synchronous native registration.

The callback executes synchronously on the OS thread running its SQLite
statement. The owning Dart isolate may migrate between separate FFI calls;
registration, statement and cleanup remain serialized by that owner.

The native callback checks `CLOCK_MONOTONIC` every 1,000 SQLite VM instructions,
without entering Dart, allocating, locking, calling SQLite, or using the loader.
The default job budget is 5s, internally configurable in (0,30s]. Suspend accounting
follows the platform monotonic clock; this is not a wall-clock SLA. The existing
50ms busy timeout is separate. SQLite instruction callbacks do not bound blocked
VFS/filesystem calls, native extensions, or Dart projection CPU.

The C image has 64 process-lifetime static slots, no per-job heap allocation and
unique positive leases that refuse rather than wrap. A slot is reserved before
its fields are initialized, and its usable lease is published only after
registration. Only the connection owner calls begin/end, with no concurrent use
of that same SQLite connection. Tokens are internal ownership IDs, not security
capabilities or production RPC arguments. Distinct owners may use distinct
connections concurrently.

Normal end happens only after actual synchronous SQL returns. It unregisters
before releasing the slot; a stale token cannot affect a replacement at the same
address. The snapshot owner then rolls back on failure. Retirement refusal
quarantines its Dart owner instead of resetting admission. A lost VM may skip
Dart finally: the pure C deadline remains usable and its context/code stay
retained until process death. An embedding surviving repeated VM destruction
may eventually refuse new jobs instead of reusing uncertain context; independent
reclamation of those connections is not implemented by this seam.

## Queue, cancellation and shutdown

A worker retains at most 16 requests including its running job, internally
configurable in 1–64. It dispatches exactly one command. Excess admission returns
busy. Exact owner-local request identity can withdraw an undispatched request
on last-subscriber cancellation, subscriber deadline, or coordinator close.
Running SQL cannot be withdrawn by that interface and stays reserved until its
actual future settles. Cancellation can include the running job's remaining
budget. It is not a promise of immediate SQL interruption.

Each replacement generation has fresh ports, queue, active request and exit
completer. Errors latch failure; actual reservations are not cleared until real
reply/EOF. Old ports and unmatched request IDs cannot complete a new job.
Normal close cancels queued reads, lets active SQL settle, sends shutdown, and
joins real EOF. Its budget+5s timeout reports failure while retaining physical
state, never a successful kill. Owner-exit monitoring is acknowledged before
SQL admission; a 5s attach deadline closes a child whose owner disappeared before
that monitor was installed. Owner-exit shutdown waits behind synchronous SQL.
