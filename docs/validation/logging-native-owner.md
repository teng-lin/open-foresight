# Diagnostic native owner component

This checkpoint implements the process-local native owner, not the complete
storage worker or application logging integration. `diagnostic_support.c` links
only system APIs and the diagnostic kernel/protocol/endpoint/inherited-FD code.
Its current CMake target is a test executable; no product is installed yet.

Exactly one attempt can reserve a static context smaller than 4096 bytes. A
rejected attempt also consumes that slot. Opaque generation 1 is the only valid
handle; callers never receive a mapping address, descriptor or mirrored context
layout. The bounded context and mapping remain retained until process exit, so
late FFI returns cannot access reclaimed or reused memory. Composition must
retain the original loaded support image for that lifetime.

Parent reservation copies at most 16 arguments/2048 bytes (1024 per argument)
and checks the native identity and fixed launcher prefix. It opens no path.
Command/anchor validation and the early library-load gate remain composition
requirements, not guarantees supplied by this parser. The writer prepares the
fresh kernel page and random nonce/challenges. A separate spawn owner invokes
the blocking spawn API. Linux uses `pidfd_spawn` and its birth handle for
nonblocking exit observation and `waitid(P_PIDFD)`; it never looks up the child's
PID through procfs. Darwin registers the birth PID's kqueue watch before
publishing PROBE; only the fresh mailbox ACK binds that watch. Darwin never
signals or waits on a PID. An unbound watch remains unknown unless registration
itself proved ESRCH. NOT_LIVE and REAPED are distinct observations.

The child arms its parent-death watch before inherited descriptor scanning.
Caller orchestration must start and positively acknowledge an independent Dart
watcher isolate before mapping or file operations. The native watch checks a
one-second bootstrap budget, five-second parent-heartbeat lease and five-second
active-operation budget. FORCE acknowledges in the private page and calls
`_exit(66)` independently of the storage main thread. Bootstrap expiry uses 65;
unsafe mapped identity uses 67. These are scheduling targets, not guarantees
against an uninterruptible kernel or a stopped process.

The endpoint bridge copies at most 4056 bytes per call and exposes frame
metadata only on COMPLETE. HELLO alone cannot admit INIT: the coordinator must
first observe the fresh watch-binding ACK. Protocol/body validation, the binary
INIT codec, file authority and retaining event charges until final ACK remain
required in the future Dart worker/proxy.

The actual-process C fixture checks normal HELLO/INIT/RETIRE/exit, FORCE while
the main thread is blocked, mismatched Dart identity, malformed argument
framing, cancellation before preparation, cancellation after preparation,
bootstrap expiry and active-operation expiry while parent heartbeats continue.
It also checks wrong-generation calls, single-attempt refusal and INIT refusal
before observed binding. Linux and HanSolo Mac 26.6 passed these eight cases
with strict C11 warnings; Mac compilation targets 15.0, which is not evidence of
a Mac 15 runtime run. Evidence is under `/var/tmp/of-support` and
`/private/var/tmp/of-support-1025`. Early Mac missing-header, missing fixture-base
and overly long unbound-observation failures are retained; no production
deadline, CTest timeout or coverage gate was increased to repair them.

The fixture uses a native pthread watchdog. It does **not** prove the actual Dart
watcher can retire a child held in file FFI. No full root CTest, composed Dart
core/desktop/service run, product packaging, minimum-host, signing, CPU/RSS or
512 KiB traffic-accounting acceptance is claimed by this checkpoint.

## Review repair and Dart-watch checkpoint

The initial `09e88036` native-peer and Claude reviews did **not** converge.
Required repairs serialize nonblocking birth-handle polling with a try guard,
preserve FORCE across concurrent spawn publication, retain a closed Linux exit
classification, and keep fixture assertions active under `NDEBUG`. Additional
repairs stage FORCE until watch registration, refuse commands after cancellation,
publish reservation only after validation, bound both challenge values without
kind-bit overflow, and retain the bootstrap deadline through INIT consumption.
Wrong-generation bridge calls are refused without poisoning the valid context.
Darwin watch-registration failure requests private self-retirement without
granting authority through an unbound PID.

The new actual-spawn race fixture interposes C11 atomic publication only inside
its own translation unit. It holds the exact old load/store publication window,
calls FORCE concurrently, and verifies FORCE remains final after spawn returns.
The identical fixture against original `09e88036` fails that oracle after
retiring/reaping its child; the repair passes. No product hook or sleep is added.
The eight ordinary process cases now assert closed exit classifications on
Linux too; wrong-identity exit comes from the actual watcher, not fixture exit.
Both fixtures execute with `-DNDEBUG` and strict C11 on Linux and HanSolo Mac.

`storage_worker_native.dart` adds the bounded FFI bridge and original function
address handoff. Its explicit private Dart fixture runs prepare and spawn on
separate owned isolates and awaits their actual exits. The child positively
acknowledges an independent Dart watchdog before inherited mapping. A test-only
C function publishes RESULT from inside the same FFI call that then blocks for
30 seconds. FORCE retires that child while its Dart main isolate remains in
the call; active-operation expiry also works while parent heartbeats continue.

All six JIT/AOT normal/FORCE/operation-deadline cases passed on each host after
the repairs. FORCE observation was about 100–110 ms; operation expiry about
5.1 seconds. Linux observed/reaped normal class 1 (OS exit 0) or retirement
class 66 as appropriate; Darwin
reports no-live-child and unknown/unconsumed status, never a reap claim. Analysis
and pinned formatting passed for the two added Dart files. Commands and source
hashes are in `/var/tmp/of-support/fixed-matrix` and the remote same-named folder
under `/private/var/tmp/of-support-1025`; mirrored Mac report is
`/var/tmp/of-support/mac-fixed-report.json`. Earlier successful probes remain
historical and do not qualify the repaired bytes.

This proves the private native/FFI/watch boundary, not a storage child opening
diagnostic files or an accepted product. The production load gate, owner/proxy,
binary codecs, storage dispatch, schema-2 records, package/runtime selectors,
full application gates and resource proofs remain unfinished. Repeat independent
reviews of the repaired source are still required before convergence.

## Writer/coordinator integration checkpoint

`LoggingSession` accepts an additive `DiagnosticWorkerFactory`. The coordinator
invokes it once, outside the writer, at the first eligible persistence request.
Off, transient, no-profile and cold short sessions never invoke it. The factory
returns its owner before any prepare/spawn call and receives only immutable
session metadata, an actual writer-exit future and one bounded prepare callback.
`DiagnosticStorageCommand` is a pure immutable descriptor; composition supplies
an already validated original native table and a lazy validated command. This
foundation never loads a library path or opens command candidates. Selected
worker `dartId`, rather than the parent VM mode, supplies schema-2 `build_id`.

Preparation runs synchronously on the actual writer after the coordinator owns
the context. The dedicated spawn isolate receives original function addresses,
the opaque native generation and completion ports. Its returned result and its
actual VM exit are distinct barriers. The coordinator does not run blocking
prepare/spawn FFI. Only the existing writer 250 ms tick supplies the native
heartbeat; no coordinator idle keepalive is added.

The writer has one outstanding request. Queued records retain their original
producer representation and immutable kind/slot/generation. A matching final
APPEND acknowledgement removes only that prefix; records appended during the
await stay queued. A failed Future does not refund unknown in-flight credit or
replay the record. Confirmed disposal permits a drop/refund. Unsent suffixes can
be dropped during close, while unknown in-flight data stays charged until the
writer exits. Summary counters reset before yielding a summary, so newer
counters cannot be erased by an older summary acknowledgement. One pending
summary is retained across a retry, using the internal writer reserve.

The final phase starts only when the caller invokes close after business
cleanup. It retains the shared 500 ms budget and 300 ms FORCE transition. A
settled writer and unsettled prepare/spawn owner are reported separately through
`LoggingCloseResult.ownerSettled`. Only unsettled parent work requires explicit
same-code process exit. Child-only unknown health, an unconsumed Darwin status
or a quiescent retained mapping does not. A matching RESULT/RETIRED still in the
retained page is consumed before classifying an observed child exit as a lost
reply. Observer ports remain non-keepalive and survive the external deadline
until an actual late writer exit can settle ownership.

Production without a worker factory reports `storageWorkerUnconfigured` and
stays memory-only; it cannot call `DiagnosticStorage.admit` in the application
PID. The old synchronous sink path is available solely through the explicit
`startForTesting(sinkFactory: ...)` fixture injection and retains schema 1.
Worker records use schema 2 with authenticated logical application PID, selected
build ID and producer generation, expanded under one writer scratch permit.

The added protocol/session controls hold a committed APPEND acknowledgement,
append another record, recycle its producer slot, and distinguish unknown work
from confirmed disposal. They cover ownership arriving during close, summaries
updated during a write, absent factories and throwing owner controls. The FFI
ownership fixture holds the actual writer or spawn isolate, requires an
unsettled result at the external deadline, releases it and then proves actual
VM exit and natural harness exit. Its third mode publishes a final RETIRED while
also reporting exit, exercising acknowledgement ordering. This is a controlled
native backend: it creates no OS storage child and proves no filesystem or
production process ownership.

Local focused results, failure controls and initial failed output are retained
under `/var/tmp/of-log-owner`. They do not qualify a product native image,
actual storage child, SDK-container/Mac/full application matrix, packaging,
resource ceilings or physical capture. Those remain separate required lanes.

The existing 100 ms credit timer also drives one coalesced status edge to the
coordinator; it does not renew the child lease or add a timer. The coordinator
polls only the original native owner. Exactly one probe/ACK may be outstanding,
and no per-probe Future listener attaches to writer exit or owner close. An idle
child exit becomes closed health without waiting for another record. Observed
not-live also disposes an earlier unknown APPEND without replay. A currently
active RPC first consumes any matching final ACK before its remaining queue can
be disposed. A disabled APPEND ACK drops/refunds only its known failed prefix;
newer unsent records remain bounded in memory. Initial idle-observation and
failed-prefix controls are retained alongside the passing followups.


The real-session fixture additionally compiles the current system-only native
support and launcher with an explicit private fixture identity, then starts a
fresh caller VM for each scenario. Its child is the shared storage executor,
not a test implementation of that executor. Normal operation verifies two
ordered schema-2 records, logical application PID/session, selected worker build
ID, producer generation, protected service manifest and typed RETIRED response.
Idle FORCE uses the original native context rather than a PID signal and is
observed through the existing coalesced status edge. Final shutdown checks actual
writer/parent ownership and observed child exit separately; Darwin need not
claim reaping or a known exit class.

The reverse-alias scenario holds a real SQLite write transaction, hardlinks its
database to the diagnostic admission filename, and probes POSIX locks from a
separate process before and after rejected admission. Shared-child admission
must preserve the parent's lock. The explicit legacy same-PID test sink must
release it, proving the fixture reaches the unsafe open/refuse/close path rather
than refusing an earlier directory. Business database cleanup precedes logger
close. Compiler/source/binary hashes and child output are retained in the test
log. These are actual fixture-child/filesystem controls, not installed-command,
package, product-image or physical resource-ceiling acceptance. SDK-container,
Mac and complete product gates must be reported for their exact source and
execution environment separately.

Worker requests validate their closed type and byte limit before making a copy;
the owned byte view is read-only so later caller mutation cannot change an
in-flight command. Its regression retains the formerly mutable-view failure.

Implementation clarification: the coordinator drives the bounded nonblocking
native request/reply cells at 1 ms only while its single request/bootstrap is
pending. The writer owns queue/credit ordering and initiates those requests;
it runs the existing 250 ms heartbeat/flush tick and coalesced 100 ms status
edge. This supersedes the earlier design draft's statement that the writer
itself pumps the cells. Neither idle coordinator polling nor another keepalive
is added. Active-pump CPU/wakeup and physical allocation measurements remain
part of B4 acceptance; cadence alone proves no scheduler latency bound.

A held CLASSIFY acknowledgement can overlap a newly expected ownership decision
and close. After that acknowledgement, classification rechecks the pending
decision, and deferred close retains its existing 100 ms ownership deadline.
It cannot flush/discard the candidate failure or cancel that deadline early.
The acquired decision promotes/protects service records before their append;
the regression retains the premature-close failure and the corrected result.
