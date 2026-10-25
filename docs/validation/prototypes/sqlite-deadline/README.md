# Native-independent SQLite deadline prototype

This is a private feasibility prototype over `e5a258b0`, not application wiring.
The e5 running-VM checkpoint and its original negative output remain unchanged.
The C image has no SQLite or ForesightNative dependency. Its only runtime
platform dependency is libc/libSystem. The Dart overlay uses the public pinned
sqlite3 2.9.4 `Database.handle` only in that connection's owning isolate and
passes the `sqlite3_progress_handler` address from the original retained SQLite
mapping. No database handle or pointer crosses a port.

## Executed result

The unchanged immediate-main-return fixture still exceeded its bound when this
tiny image was preloaded but its callback was unused. With only the private
native-budget overlay and early initialization, the same synthetic billion-row
query reached a C monotonic deadline and the process exited normally on both
Linux and Mac. No Dart callback is invoked by the C progress handler.

Test-only C counters at normal process exit distinguish this result from
ordinary cleanup: two jobs began, the warm job ended normally, the long job
expired, and its lease remained retained (`begun=2 ended=1 expired=1 live=1`).
During main/VM teardown Dart did not execute the second `finally`. The code and
context therefore stay valid until process death; neither is reclaimed based
on a subscriber timeout, VM disappearance, or a guessed statement outcome.
This proves bounded teardown of the CPU-query fixture, not execution of Dart
cleanup after VM loss.

The native fixture also passed on Linux and Mac: 64 active slots, refusal of a
65th, expiry of real SQL, normal unregister and slot reuse, stale-token refusal
at the reused address, independent subsequent job/other connection, and calls
after the original `dlopen` caller dropped its reference **before** opening any
database. The process-owned reference keeps the image callable. The fixture
reports `begun=65 ended=65 expired=1 live=0`. Linux ASan/UBSan passed.

The private derivative of the e5 running-VM suite passed 46 tests on Linux, with
four macOS-only selection skips. On Mac its first run passed 49 and failed one:
private preload inheritance injected an arm64-only image into the system's
arm64e `/bin/chmod`, which failed. The unchanged environment/model fixture then
correctly detected a non-executable runner. An actual private chmod probe
confirmed the architecture error. A universal arm64+arm64e **private injection
artifact** fixed chmod; the failed fixture then passed 1/1 and the whole reader
module passed 15/15, zero skips. No test assertion was weakened. This is an
additional reason preload environment variables are unsuitable for production.
The original exact e5 Mac suite separately remains 50/50 plus preflight31/31.

Full source hashes, commands, original failed output, counters and logs are
retained at `/var/tmp/of-sql-native`; Mac mirror/source is
`/private/var/tmp/of-sql-native-proto`. This is Mac26.6 execution, not minimum15
acceptance. No model, app-native rebuild, full product or package gate is
claimed by these private fixtures.

## Lifetime and allocation contract

`deadline.c` has 64 process-lifetime static slots and no heap allocation per job.
A monotonic unique nonzero lease identifies each registration. Tokens never
wrap: exhaustion refuses further jobs. Only the owner of the SQLite connection
may call begin/end; concurrent use of the same SQLite connection is outside this
internal API contract. Native tokens are not security capabilities and must
never become production RPC arguments.

Begin checks the monotonic clock and a positive budget at most30s, retains one
slot, and installs the callback through the caller's actual SQLite mapping.
The progress function performs only a clock check and scalar writes. It does
not enter Dart, allocate, lock, call SQLite, resolve symbols, or load a library.
The `OF_SQL_DEADLINE_PROOF` counters/destructor are private test instrumentation;
the ordinary artifact omits them.

End is called only after synchronous SQL returns. It unregisters the handler
before releasing the slot. An expired callback may still run during SQLite's
unwind, so its context cannot be freed or reused earlier. An old lease cannot
unregister a replacement job, even if the static slot address is reused. A lost
VM leaves a bounded retained slot; it is never recycled without unregister.
A process which survives repeated VM destruction can eventually refuse new
jobs rather than reusing uncertain context. This prototype does not implement
such an embedding's independent connection-retirement/reclamation protocol.

The support image is retained by an early `RTLD_NOLOAD` reference whose resolved
initializer is checked against the already mapped image base. There is one
intentional process-owned reference and no ordinary successful-path close. The
initialization must occur before any application database locks are held. A
late initializer is not an acceptable production fallback.

SQLite VM instruction callbacks do not bound uninterruptible filesystem/VFS
work, native extensions, or Dart projection CPU. Those existing limitations
remain. Subscriber cancellation still withdraws only undispatched requests;
running work remains tracked until actual SQL settlement.

## Proposed production integration — required before adoption

1. Put the C API into a small support image, potentially the same deliberately
   early-loaded support component as the diagnostic owner. It must not depend
   on or force loading the heavyweight application-native image or link/open a
   second SQLite library.
2. The trusted launcher/frontend mapping gate must map and pin that exact owned
   image before any application connection opens. Use the existing artifact
   identity/provenance contract. Resolve an ABI-versioned function table from
   that mapping and verify all entries belong to it. Do not adopt this
   prototype's global-symbol assumptions as identity/authentication proof.
3. Make that already mapped API available to each read owner at bootstrap,
   before connection creation. A deliberate process-global mapping can use
   `DynamicLibrary.process()` without path reopening; a private authenticated
   bootstrap may instead carry only validated code/API identity. It must never
   carry a borrowed SQLite connection. Any ownership/identity contract for this
   bootstrap needs independent review with the support component.
4. Remove private `LD_PRELOAD`/`DYLD_INSERT_LIBRARIES` use entirely. Never inherit
   such an injection variable into system helpers. No new environment override,
   late `dlopen`, alternate SQLite path, debug RPC, SDK input, or artifact-trust
   bypass is proposed.
5. Own one synchronous native registration per actual job. Keep the exact e5
   bounded queue, generation/actual EOF, queued withdrawal, active reservation
   and normal-close behavior. A lost-VM retained registration is distinct from
   a normally completed and unregistered job.
6. Wire Linux/Mac build/install/package inputs deliberately, update the ABI and
   notices as applicable, and add the native fixture to root CTest. Before push,
   execute all required freshly built native, core/desktop, coverage and compiled
   service gates. Repeat the real teardown regression in JIT and compiled/AOT
   product startup contexts. No production adoption/oldest-host gate is waived.

The production mapping, bootstrap, packaging and whole-worker integration are
unfinished. Root owns the diagnostic support actor; this prototype does not edit
that worktree or its API.

## Reproduction sources

`pool_test.c` takes the private DSO path. Build the DSO with strict C11,
`-Wall -Wextra -Werror -O2 -fPIC -shared` on Linux (`-ldl`) or `-dynamiclib` on
Mac. Add `-DOF_SQL_DEADLINE_PROOF` only to the private counter artifact. The C
fixture links the intended original SQLite library; the DSO does not.

`prepare_private.py BASE_CORE NEW_PRIVATE_CORE NATIVE_BUDGET_TEMPLATE` copies an
already resolved e5 core package into a new private destination, preserves
package locations, and adds early support initialization to the private worker
and fixture entrypoints. It refuses an existing destination. The supplied
`native_budget.dart.txt` is an overlay template, not an application library.
Run only under a short private disk-backed temp root. The sibling test-support
path must resolve to that base's own package.

Copy `plant_probe.dart.txt` into a private `.dart` file and run it with the
private package config and a new private database path. It refuses an existing
database or an accessible parent directory and plants only synthetic SQL. The
existing `sqlite_reader_owner_exit.dart DB immediate-main-return` fixture is the
regression. The old package and private native overlay must use identical
synthetic DB/SDK/SQLite bytes. The prototype driver preloads the tiny image at
process start, initializes its process-owned pin before opening the database,
and binds it via `DynamicLibrary.process`. This preload is a private proof
mechanism only; it is not the production mapping proposal above.
