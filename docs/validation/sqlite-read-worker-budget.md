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

One lazy read isolate owns its read-only connection. The process entrypoint
eagerly initializes `package:sqlite3` 2.9.4 before connections or workers. It
captures the actual mapping's physical absolute path, image base, progress
installer address and SQLite source identity, retains it with `RTLD_NOLOAD`,
and registers that canonical loader name before any database locks. A foreign
prior package initialization that prevents capturing the actual mapping refuses.
At this seam, an earlier package loader override can still select the initial
image before capture; owning that selector and refusing production basename
fallback remain part of the validated-selection integration gate.
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

Both counter sets above are historical 8c results. They were not re-run on the
current optional-marker C source or with the frozen SQLite mapping seam, and
are not current qualification.

The initial frozen-mapping follow-up (46b) binds only its 23 listed inputs:
Linux focused 54 pass / 4 macOS-only skips and Mac focused 58 pass / 0 skips.
Both hosts built the current unmarked direct SQL C component and passed its two
CTest cases. Linux used a synthetic module-only CMake project. Mac used the
real standalone `native/` project, freshly compiled SQL and application-owned
SQLite from the verified archive, after reconfiguring a cache left by a missing
SDK dependency. The original missing-SQLite-target configure failure was
reproduced first. These are component results, not a fresh full native build.

The later physical-file follow-up binds 37 explicitly allowlisted SQL code and
dependency files before and after both hosts' runs, including budget, snapshot,
coordinator, store reader, Store, runtime configuration, schema/backup helpers,
and the owner-exit fixture. Those 37 hashes match across hosts; this does not
claim identity of the wider application/credential graph. Linux focused 55 pass
/ 4 macOS-only skips and Mac focused 59 pass / 0 skips. Analyze passed on both;
Linux checked package formatting, while Mac checked the three changed
overlaid Dart files. Native C/header/recipe bytes were unchanged and the preceding verified
unmarked components were explicitly reused, with no fresh-compile claim.

The subsequent refusal follow-up binds 54 named SQL/persistence inputs,
including the query/store helpers and snapshot VFS omitted from the earlier
37-file binding. These hashes match before/after and across both hosts. This
is an explicit allowlist, not an import-closed application graph: application,
service and other wider imports remain outside this binding. Linux again passed
55 focused tests with four macOS-only skips; Mac passed 59 with zero skips.
Both AOT replacement scenarios also assert that an unloaded SQLite copy is
refused and remains unmapped according to a second NOLOAD probe, and that a
mismatched progress anchor is refused. The lock-oracle extension also closes the
real read worker before an independent process requires `SQLITE_BUSY` from
`BEGIN IMMEDIATE`, while the parent still holds its transaction. Analysis/format scope and explicit reuse
of unchanged native artifacts remain as described above.

Two Linux-only prior-resolver negatives use the exact 1ba public bootstrap,
support and SQLite resolver: one reaches the direct-isolate oracle, and one
runs the real reader without an injected package-loader override. Both fail
against the changed alias; both use the same unmarked support image as the
positive follow-up. The optional marked product/recipe qualification remains
separate. Historical counter and sanitizer logs retain their original
source/host labels; old sanitizer output without recorded flags/hashes is not
current qualification. These runs qualify the seam and its AOT fixture, not the
full application.

Root full CTest, broad direct-Store/core/desktop test bootstrap, service/Desktop
entrypoints, validated runtime selection, install/sign/package receipts and
owner review are still required. Compiled/AOT startup/teardown, full coverage,
compiled service, oldest/macOS15 and embedding hot-restart/reclamation lanes
remain distinct acceptance gates. No full-product or whole-F23 completion is
claimed by a focused SQL/native seam fixture.
