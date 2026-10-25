# Native diagnostic queue checkpoint

This leaf implements the native queue and additive ABI, not application
activation. Runtime severity negotiation, producer adoption, original-image
pinning and the credited Dart consumer remain integration work. A queue unit
pass does not qualify those paths or the full application.

The C ABI version is 1. Records are exactly 64 bytes, containing only registered
event/component/category/outcome values and fixed numeric fields. Failure
records occupy the 1,000-record priority lane; capture state records occupy the
3,000-record ordinary lane. Total queue storage, including synchronization,
consumer identity, counters and metadata, is 256,072 bytes on Linux x86-64.
Compile-time assertions enforce a 256 KiB ceiling and trivial destruction.
The queue has constant initialization and no allocator or shutdown destructor.

Every operation makes one attempt to acquire the gate. A producer that loses
that attempt drops its record and sets a lock-free precision-loss flag. Returned
drop counters are saturating lower bounds; the flag explicitly identifies
unquantified contention loss. A successful drain returns and resets counters
and flags under the gate. A concurrent later loss remains for the next drain.
No exact-count claim is made under contention. The producer does not spin,
allocate, format text, access native handles or invoke another runtime.

The sole consumer uses a never-reused process-local numeric token. Its
caller-owned buffer accepts 1–64 records, at most 4 KiB, plus a 32-byte batch
receipt. Wrong ABI, sizes, token, flags, null pointers or capacity fail without
changing the queue or caller outputs. A busy operation similarly makes no
progress and must be retried on a later existing consumer tick. Public
operations neither configure severity nor access model/capture/Domain handles.

Normal draining merges the lane heads by admission sequence. When only reserved
priority credits remain, priority-only draining leaves ordinary records intact
and deliberately overtakes them. Consumers must validate increasing native
sequence separately for each lane, accepting older ordinary sequences after a
priority drain. The final schema 2 writer sequence remains a separate globally
increasing append sequence.

Focused tests exercise default-off/filtering, closed-value validation, invalid
and busy operations, independent lane limits, priority overtaking followed by
older ordinary records, mixed merge ordering, saturating loss and token/sequence
overflow. Four real producer threads attempt 80,000 records while a consumer
drains. The same unit runs under ASan/UBSan and fatal TSan; qualification reports
must identify the exact source checkpoint and execution platform. Full native
CTest, application Dart/desktop/service suites, coverage and actual macOS
execution remain required before integrating this feature for delivery.
