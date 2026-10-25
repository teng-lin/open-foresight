# Native diagnostic writer adapter

The production `NativeLibrary` observer negotiates optional queue ABI 1 only
inside an already loaded, compatible application image. The source isolate
pins that original mapping and installs the resolved canonical log level before
native work seals configuration. Unsupported old libraries disable optional
native logging; required environment keys keep their existing fail-closed
behavior. An inherited log-level string alone does not prove configuration was
installed before sealing. Helper launches receive a separate canonical override;
the raw Dart environment and legacy transport-alias precedence are preserved.

The existing service frontend connects its reserved domain producer before
running the application worker. Connecting installs the observer in that VM.
Only immutable code addresses cross to the writer. The writer never resolves a
library path, touches an application handle, or enters the native resource
registry. It receives one ordinary `nativeDrain` producer slot bound to the
writer VM. Admission uses the same producer count, byte, and record pools as all
other producers. A full producer table retains one bounded pending reservation
and retries when a slot retires.

Every native drain has writer credit before FFI removes any record. The adapter
uses a tested 256-byte encoded-event bound and the existing conservative charge
formula; each tick removes at most 64 native records. Priority-only drains use
reserved priority credit and preserve older ordinary records for later drains.
The binding validates sequence order per native lane. The final schema 2
sequence remains assigned by the writer at append and increases globally.
The adapter adds no periodic timer: it uses the writer's existing drain and credit
ticks. Its ordinary producer connection uses the existing one-shot registration
deadline.

Native numeric counters wider than the schema's existing INT31 range are
clamped. An unrepresentable signed field is omitted. The genuine event remains
and carries `precisionLost: true`; health and a bounded summary also report
approximation. Gate contention never invents an exact drop count. A rejected native batch also
marks loss inexact because its drain already consumed traffic and counters. Off logging
creates neither a queue consumer nor a native producer slot.

Close stops native polling before producer-credit revocation. The last native
self-messages precede the writer's causal close marker. A busy native close
retains its consumer and buffers and retries on the existing credit tick; it
never frees live FFI storage. Native producer retirement precedes final writer
close. Every busy-close retry re-enters the serialized flush chain, so it cannot
overtake an outstanding storage request or newly arrived counter summary. A
later old library cannot disable an already accepted consumer. A requested
consumer that never obtained a producer slot cannot report its pending queue
flushed. Unproved pending native traffic prevents a flushed claim.

Focused tests cover shared credits, full-table recovery, actual queue overflow
metadata, lane ordering, wide-field projection, canonical configuration, old
libraries, off mode, and busy-close retry. The process probe
`test/fixtures/native_queue_application.dart` uses the public logging start API,
production `NativeRuntime`, a fresh application native library, a real owned
capture child routed to `/usr/bin/false`, and the exec storage child. It checks
schema 2 identity and sequence, protected failure classification, canonical
configuration, and physical writer/child close. It needs no model, audio device,
or permission prompt. It does not establish physical audio acceptance.

Producer and writer byte accounting scans UTF16 code units without allocating a
UTF8 output buffer. It matches the standard encoder, including replacement of
unpaired surrogates. This avoids the SDK's three-times input-size temporary plus
output copy merely to count bytes. An external VM-service probe pauses actual
producer encoding inside SDK JSON and UTF8 phases and collects heap snapshots
after GC. On pinned Linux Dart 3.9.2, all 15 event shapes with maximal registered
fields/correlations/eight frames yielded 45 phase snapshots; the largest
attributed phase was 7648 bytes, below the 8192-byte per-producer allowance.
These measured encoder phases do not establish the complete process bound.

Native queue storage is independently measured at 256072 bytes. The Dart traffic
512 KiB physical bound, including encoding and control/object metadata, remains
an explicit open acceptance item; logical ledger counters alone do not prove it.
Full root native CTest, matched core/desktop suites, core coverage, compiled
service/MCP, and desktop integration remain integration gates.

Native health publication also uses a bounded channel: one report awaits its
coordinator acknowledgement, with later changes coalesced in fixed fields.
Identical final states are not resent after intermediate drain-state changes.
Final close may publish one additional latest state before the existing closed
message, so final health is preserved without relying on a late acknowledgement.
The paused-coordinator qualification uses a real exec storage child and sixteen
producer slots while ordinary credits are exhausted; the native health mailbox
must remain bounded as the native drain continues using priority-only credit.
