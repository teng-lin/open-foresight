# SQLite read-worker ownership and native deadline seam

This seam is not yet wired into service/desktop entrypoints, package runtime
selection or every direct-Store test. Those owners must establish the explicit
startup gate before adoption. A missed gate intentionally fails closed.

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

Focused seam tests explicitly bootstrap their native fixture in each test main
before that suite's first DB/spawn. A multi-suite test runner may run those mains
in separate isolates while another suite already owns a database; that batch is
not proof of a process-wide pre-lock loading order. The public embedding regression
holds a real parent transaction while a fresh worker binds the inherited opaque
record, refuses an alternate existing absolute support image before loading and
executes SQL through the original code. The fresh-isolate missing-handoff oracle remains a
refusal even though native code is already mapped in the process. The same
private code-only handoff succeeds with the application-native path absent.
Tests preserve the earlier generation/queue/cancel/close oracles and add actual
immediate-main teardown with no production preload.

Native fixture checks are explicit CHECK calls, including in Release/NDEBUG.
They cover eight concurrent early initializers, retained/no-pin NOLOAD controls
before DB creation,64slots/65th refusal, actual long SQL expiry, stale-lease ABA,
next-job/other-connection independence and four concurrent distinct owners.

The separate test-only `sql_support_proof.c` image includes the exact production
C implementation and forwards its original installer/callback through native
witnesses. It does not change the production ABI or add a production hook.
Its CTest case requires observed registrations/interrupts and zero retained
contexts after normal completion. For private actual-VM-loss evidence, compile
the reporter with an already open controller-owned regular descriptor and its
exact device/inode. The initializer marks that descriptor CLOEXEC; the exit
report writes only if its identity still matches, without opening/closing a
pathname or printing to application stderr. Nested helpers cannot inherit it.
The ordinary test image has no report descriptor or exit output.

Linux source8c focused52pass/4macOS-only skips and Mac sourceaeee focused56pass/0skips
execute the native path. Linux standalone component CTest passed2/2; the Mac
sourceaeee component run passed1/1, and the second witness CTest was not executed
on Mac. These are component results, not root native/application qualification.
Independent private native counters on each host recorded normal
`started=39 ended=39 expired=7 live=0`. The normal counters exclude the separate
owner-exit child processes: their reporter descriptor is close-on-exec and
identity-checked. Each host's separate immediate-main fixture recorded
`started=2 ended=1 expired=1 live=1` once and exited0. The warm request was awaited
successfully, so the expired retained registration is inferred to be the
subsequent long request. This proves an observed expiry callback and a retained
registration at process exit; statement return before exit was not independently
witnessed. It does not prove normal unregister or that Dart finally ran. Dispatch
before immediate shutdown can race, so these exact snapshots are individual
observations, not a deterministic teardown count guarantee. Counter snapshots
are inspected at quiescence/process exit; independently sampled totals are not
transactional while jobs concurrently start/end. No environment preload was used.

Root full CTest, broad direct-Store/core/desktop test bootstrap, service/Desktop
entrypoints, validated runtime selection, install/sign/package receipts and
owner review are still required. Compiled/AOT startup/teardown, full coverage,
compiled service, oldest/macOS15 and embedding hot-restart/reclamation lanes
remain distinct acceptance gates. No full-product or whole-F23 completion is
claimed by a focused SQL/native seam fixture.
