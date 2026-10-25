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
