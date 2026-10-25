# Logging endpoint protocol component

`native/diagnostic_endpoint.c` adds process-local request ownership to the bounded
shared-page transport. The eventual native process owner retains this private C
state; Dart must not mirror its pointers or layout. Initialize it once for a
fresh mapping whose kernel type, identities and ownership the process owner has
already validated. This component does not authenticate a HELLO body or grant
filesystem authority.

The child publishes one HELLO at request ID zero. The parent then sends INIT at
ID one. Each subsequent command has one matching RESULT before another command
can begin; RETIRE requires RETIRED instead. IDs increase monotonically, with the
maximum positive 63-bit ID reserved for final retirement. Because HELLO consumes
one reply publication, ordinary commands stop at MAX-2. Trying the next ordinary
command returns EXHAUSTED without mutation; RETIRE can still use the last reply
sequence. Peer attempts to bypass that boundary permanently poison both local
directions.

Partial chunks retain native cursor ownership. A complete matching reply clears
the outstanding command; EMPTY, PARTIAL, EXHAUSTED and errors do not. The caller
must not decode partial bytes and must discard them after an error. Payload and
JSON-schema validation remain separate requirements. Local poison does not prove
that a peer exited or release any queue charge held by the eventual owner.

Strict C11 component builds and execution passed on Linux x86-64 and HanSolo
Apple Silicon macOS 26.6 with deployment target 15.0; Linux ASan/UBSan passed.
The fixture covers 8 KiB INIT chunking, 4 KiB APPEND chunking, matching replies,
single outstanding ownership, malformed ordering/IDs, sticky poison, coherent
seeded 63-bit exhaustion and final retirement. A real fork and shared anonymous
mapping exercise both endpoints in separate processes. Both parent and forked
child have independent fixture alarms.

Native-peer and Claude source reviews converged on the endpoint implementation.
The full repository-root native test suite for the integrated candidate,
spawn/exec ownership, build/nonce authentication, child watchdog, Dart worker,
storage authority, packaging and full application suites remain separate gates.
These results do not establish whole-logging or minimum-host acceptance.
