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
