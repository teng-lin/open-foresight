# Diagnostic producer lifetime checkpoint

This unit builds on `8e2a00cd`. It changes the session producer/coordinator and
credit protocol. The direct storage backend remains an unaccepted baseline;
this checkpoint does not establish storage-worker or whole-logging acceptance.

## Pinned VM exit ordering

The Linux fixture SDK reports Dart3.9.2, revision
`a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd`, matching the peeled upstream3.9.2
tag. Source copies and SHA256 receipts are retained with the qualification packet.

* [Paused spawn](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/lib/isolate.cc#L920-L1010)
  installs the paused state before notifying the parent of successful creation.
  The helper therefore installs the exit listener before resuming user code.
* [Listener and resume controls](https://github.com/dart-lang/sdk/blob/3.9.2/sdk/lib/_internal/vm/lib/isolate_patch.dart#L609-L632)
  use the same out-of-band control port. Their queue preserves posting order.
  A late independently installed listener may miss a previous exit and grants
  no right to recycle that reservation.
* [VM shutdown](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/vm/isolate.cc#L2355-L2369)
  posts the registered response during low-level shutdown after Dart execution
  ends. The serializer at lines105–115 uses normal priority. Ordinary producer
  sends use normal priority too, as shown by
  [SendPort.send](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/lib/isolate.cc#L110-L128).
* [PortMap](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/vm/port.cc#L141-L157)
  forwards each post under its lock. The destination
  [message handler](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/vm/message_handler.cc#L122-L155)
  enqueues normal messages in one queue, and
  [MessageQueue](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/vm/message.cc#L98-L115)
  appends ordinary posts at the tail. The
  [ReceivePort adapter](https://github.com/dart-lang/sdk/blob/3.9.2/sdk/lib/_internal/vm/lib/isolate_patch.dart#L71-L78)
  dispatches synchronously. Thus the direct exit response follows that
  producer's earlier record/terminal posts to the writer mailbox.

The direct helper is enabled only for the qualified Dart3.9.2 version; other
versions retain quarantined reservations rather than asserting this proof. The
closed product build still verifies the actual trusted SDK identity separately.
These source facts support the pinned runtime path; real isolate tests exercise
natural exit, exit before registration and stale bootstrap replay. They do not
prove behavior on a different VM revision.

## Protocol and owner APIs

The coordinator and writer each retain16 current slot entries. A slot's positive
63-bit generation never wraps. Every producer message carries slot/generation
and a credit epoch; epoch0 denotes the immutable lifecycle barrier covering both
credit classes. Normal and priority credit epochs are independent so reclaiming
idle normal credits cannot block a synchronous warning using priority credits.

`LoggingSession.spawnProducer` creates a paused isolate, binds registration to
that VM's control-port identity, installs its private direct exit response, then
resumes it. A bootstrap copied into a different isolate receives no credits;
the transferable capability cannot install an exit listener for another VM. Startup does not await diagnostic readiness.
`reserveProducerForSpawn` supports preflight cancellation only before its
bootstrap capability is exposed. Its `spawn` method binds that same reservation
without publishing the capability first. A failed paused spawn never ran an encoder;
a potentially executing producer requires an actual terminal or VM barrier.
Legacy `producerExited` is a bounded owner hint and may quarantine the slot.
It never independently refunds an encoder or releases its scratch reservation.

Cooperative close/revoke acknowledgements run after a synchronous builder
unwinds. They include final sequence, both credit epochs and unused leases.
The writer settles those leases and acknowledges retirement to the coordinator
before reuse. Queued records hold immutable kind/slot/generation snapshots and
the charged producer string; later completion frees only the independent queue
charge and cannot credit a replacement occupant. Stored schema1 retains its
legacy `kind:slot` grammar. This unit invents no schema2 identity.

Excess/off/closed registrations reuse an inactive handle and have no builder
authority. Registration refusal is one saturating health counter with at most
one acknowledged notification edge outstanding. No historical producer list or
unbounded exited-ticket set remains.

## Accounting and remaining qualification

The logical event ledger includes unused local leases plus queued/inflight
charges: normal64KiB/160 tickets and priority128KiB/64 tickets. The reserved
scratch144KiB, IPC160KiB and controls16KiB complete the512KiB envelope;32 internal
tickets complete the256-event ceiling. Native256KiB remains separate.
`inspectBudgetForTesting` observes these reservations, not measured object sizes.

Actual8KiB encoder-temporary and16KiB control-footprint proofs remain open,
including first-use allocation, adopted builders and both pinned VMs. They must
not be inferred from numeric credit bounds. Native drain/IPC overlap, child
storage ownership, final close/owner settlement, build identity, platform and
installed acceptance remain separate integration requirements.

The fixtures preserve16 synchronous warnings under normal saturation and add
120 sequential cooperative completions,120 actual VM exits, pre-registration
exits, stale/duplicate capabilities, exposed cancellation refusal,32 failed
spawns,20 scoped SQL readers/32 failed opens, positive63-bit exhaustion, a
catalog-small cold100 trigger and old-generation queued attribution/credits.
Focused check counts and original failures accompany each frozen commit.

## Async storage handoff assumptions

The current synchronous storage/flush composition remains the baseline. The next
async backend must retain each queued/inflight record's charge until its actual
write ACK or definitive disposal. Producer retirement releases only unused local
leases, never a record already debited into the independent queue. That record's
later completion calls the global ledger without consulting a slot occupant.

Serialize the one storage request, retain immutable producer attribution across
its await, and remove only the acknowledged queue prefix. New producer events
may append while I/O is pending; a pending/unknown request cannot authorize
clearing their charges or the in-flight copy. The legacy synchronous `_discard`
call must not become an unconditional release of an async in-flight request.
The existing250ms writer tick remains; the100ms credit timer is writer-local,
not an application/coordinator heartbeat. Final child/owner settlement and the
bounded500ms result are owned by the storage integration, not proved here.
