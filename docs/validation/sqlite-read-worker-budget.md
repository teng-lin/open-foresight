# SQLite read-worker ownership and native deadline seam

This seam is not yet wired into service/desktop entrypoints, package runtime
selection or every direct-Store test. Those owners must establish the explicit
startup gate before adoption. A missed gate intentionally fails closed.

## Explicit early owner gate

Embeddings call the startup-only public capability:

```dart
initializeSqliteRuntime(supportLibrary: validatedAbsoluteRuntimeSupportPath);
```

The embedding must already have validated that exact runtime artifact through
its ownership/package trust contract. The SQL seam does not invent a selector,
consult an environment override, search a basename, inherit a preload variable
or load the heavyweight application native image. It requires an absolute
selection and remembers that exact selection/original mapping. Repeating it
reuses the same pinned code; a changed selection is refused. Package and
entrypoint owner review is required before integration.

The separate `foresight_sql_support` image has only system dependencies.
Diagnostics-off does not remove the SQL deadline requirement and does not make
SQL load the diagnostic DSO/child. Its sole exported startup operation uses
`pthread_once` to join concurrent early callers, checks ABI/size and every code
entry's image base, and retains the already mapped image. This loader-owner
operation must precede any application connection/locks and worker creation.
Failure is permanent for that image. Worker handoffs include no initializer.

Each private handoff contains only the validated ready/begin/end code addresses,
not a SQLite connection, database pointer or native context pointer. Binding in
a worker performs only the pure atomic ready check; it never loads a path or
performs a fallback lookup. Missing handoff and changed-image binding refuse
before application SQLite is opened. Direct library/Store users must bootstrap
explicitly too. The gate is not hidden in a generic temp-directory helper.

## Statement and context lifetime

One lazy read isolate owns its read-only connection. The original
`package:sqlite3`2.9.4 mapping and its progress-installer address are retained and
resolved before any application database opens. A foreign prior initialization
that prevents capturing that actual mapping refuses owner-local controls.
Owned sessions construct their budget eagerly. No read snapshot/BEGIN performs
a support-image or SQLite-symbol lookup. `Database.handle` stays in its owning
isolate and is supplied only to this synchronous native registration.

The native callback checks `CLOCK_MONOTONIC` every1,000 SQLite VM instructions,
without entering Dart, allocating, locking, calling SQLite, or using the loader.
The default job budget is5s, internally configurable in(0,30s]. Suspend accounting
follows the platform monotonic clock; this is not a wall-clock SLA. The existing
50ms busy timeout is separate. SQLite instruction callbacks do not bound blocked
VFS/filesystem calls, native extensions, or Dart projection CPU.

The C image has64 process-lifetime static slots, no per-job heap allocation and
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

A worker retains at most16 requests including its running job, internally
configurable in1–64. It dispatches exactly one command. Excess admission returns
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
SQL admission; a5s attach deadline closes a child whose owner disappeared before
that monitor was installed. Owner-exit shutdown waits behind synchronous SQL.

## Evidence and unfinished adoption gates

The unchanged earlier e5/972 immediate-main-return negative remains retained.
The independent CLI review of prototype972 read all56 packet files, with a
separate audited ledger. It found the C mechanism sound within its owner
contract and required the early/pure-ready split, complete original-image table,
eager SQLite symbol resolution, diagnostics-independent image and NDEBUG-safe
native fixture implemented in this seam.

Focused seam tests explicitly bootstrap their native fixture in test main
before the first DB/spawn. The fresh-isolate missing-handoff oracle remains a
refusal even though native code is already mapped in the process. The same
private code-only handoff succeeds with the application-native path absent.
Tests preserve the earlier generation/queue/cancel/close oracles and add actual
immediate-main teardown with no production preload.

Native fixture checks are explicit CHECK calls, including in Release/NDEBUG.
They cover eight concurrent early initializers, retained/no-pin NOLOAD controls
before DB creation,64slots/65th refusal, actual long SQL expiry, stale-lease ABA,
next-job/other-connection independence and four concurrent distinct owners.

Root full CTest, broad direct-Store/core/desktop test bootstrap, service/Desktop
entrypoints, validated runtime selection, install/sign/package receipts and
owner review are still required. Compiled/AOT startup/teardown, full coverage,
compiled service, oldest/macOS15 and embedding hot-restart/reclamation lanes
remain distinct acceptance gates. No full-product or whole-F23 completion is
claimed by a focused SQL/native seam fixture.
