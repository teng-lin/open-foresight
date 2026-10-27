# Incremental meeting transcript indexing

The application commits transcript rows before it releases capture. A final-index
intent records the meeting, workspace epoch and transcript revision synchronously.
A tracked producer owns the helper work independently of callers waiting for its
result. Closing the application cancels producers before joining recording drain;
service shutdown then joins Domain mutation/channel settlement before the helper
and application database are closed. Paused producers count as background work.

Application migration 22 follows the frozen migrations through 21. Generated
meeting sources store an empty `sources.content` cell. `source_contents` derives
requested bodies from authoritative final transcript rows in stable row order;
metadata listing and append indexing do not assemble those bodies. Source reads,
read-only clients, consent snapshots, lexical fallback and graph reads use this
view. Historical sources without capture rows keep their existing committed body.
An explicit manual source edit keeps ordinary source ownership and history.
Deleted sources are never recreated by replay.

A row-change journal projects only new or edited rows. Current derived pieces have
stable, non-reused local IDs, a speaker channel and at most 64 KiB of UTF-8 text.
Large imported rows split at UTF-8 boundaries; one authoritative row is limited to
16 MiB, matching the service framing bound. Projection processes at most 32 rows
and normally 1 MiB per pass (one larger bounded row may exceed that pass budget).
One helper delta contains at most 64 upserts, 64 deletes and 512 KiB of piece text.
The helper separately checks its 1 MiB wire limit and publishes a complete delta
atomically. Immutable segments keep independent helper chunks and parent-source
citation identities.

The privacy denominator includes **current authoritative transcript text plus the
current derived piece cache**. The cache is a linear duplicate, not a revision
history. Editing or deleting a transcript immediately removes its old cached text;
source deletion/manual ownership transfer and workspace clear remove associated
cache and recovery records. SQLite backup erasure/compaction applies to these
same application database pages. Generated append updates do not create content
history. The outbox stores identities, channels, hashes and transaction revisions,
never raw transcript text. It has one row per meeting, a 16 KiB metadata cap and a
24-hour replay age; row-change and delete journals each compact at 4,097 entries,
leaving at most 4,096 retained identities between passes. Expired/invalid work
resets from current rows and pieces rather than replaying a stale payload.

Before retrying an uncertain request, the producer reconstructs its exact bytes
from unchanged current pieces and validates its saved digest. A missing/changed
piece forces a reset. Acknowledgement records the confirmed helper cursor.
Startup/model-ready replay pages meetings in bounded groups and verifies generated
source cursors even when the application's previous success is current. Missing,
restored, independently advanced or replaced helper state resets/replays current
pieces without rereading already projected transcript bodies. Workspace epochs
and producer generation checks prevent old acknowledgements from updating a
cleared/reused workspace. Manual source ownership and tombstones remain decisive.

Manual and historical stored sources that remain pending before model readiness
retain their intent and release the producer. Readiness/resume signals admit a
later retry. Saved batches require the matching helper workspace epoch; cursor
conflicts trigger at most three reconciliation retries before leaving durable
work for a later owner. A producer rechecks projection ownership after waits so
coalesced capture is included before completion.

`meeting_incremental_projection_test.dart` instruments actual application row-body
reads, piece writes and canonical request serialization for fixed 64/128-append
workloads; each ratio must be at most 2.5. It also exercises durable uncertain
outcomes, restart, restored/missing cursors, edits/deletes, source history,
read-only reads, bounded compaction, expiry and cancellation. The native helper
CTest independently measures actual tokenizer, embedding, content and immutable
snapshot construction work. `meeting_incremental_native_test.dart` connects the
real application producer to explicit `FORESIGHT_TEST_HELPER`, including parent citations,
edits/deletes, process restart, independent helper-state loss and erasure. Its
model is explicitly deterministic test machinery, separate from the production
`FORESIGHT_HELPER` qualification; these checks do not qualify
production models or physical capture behavior.


Search after Stop captures at most 64 already-accepted, actively owned stopped transcript jobs
and waits at most five seconds for their current workspace/revision to become
indexed and their verification job to retire. It reads only metadata, never
joins the Domain mutation queue, and owns no producer. Caller cancellation and
workspace clear dispose the waiter; deletion/manual replacement/live capture
retire the affected target. A newer still-stopped revision, captured producer failure or deadline returns a
typed busy refusal with retry guidance for that call. Subsequent searches omit
failed or unstarted durable backlog and can return ordinary indexed documents.
Active IDs are filtered before the SQL limit, so stale backlog cannot hide an
active producer. Active helper verification deliberately waits for the current
helper cursor even when an older indexed flag remains. Later jobs
never extend the snapshot. Paused or explicitly unconfigured indexing adds no
wait. The normal indexed-source allowlist and post-retrieval revision checks
remain authoritative. Stop still commits and releases capture independently of
helper indexing. The same 64 bound limits concurrent readiness waiters.


## Fixed-workload resource measurements (2026-10-26)

The [portable numeric record](incremental-indexing-measurements-2026-10-26.json)
contains the existing fixed 64/128 append workloads and unchanged processed-content
ratio limit of 2.5. Application row/byte/piece/request work doubles; actual
controlled helper token/embedding work doubles and snapshot construction is 2.25x.

| Observed measurement | N = 64 | N = 128 |
| --- | ---: | ---: |
| Application transcript bytes read | 7,936 | 15,872 |
| Helper tokenized plus embedded bytes | 9,728 | 19,456 |
| Application process CPU ticks (100 Hz) | 133 | 222 |
| Owned helper child CPU ticks (100 Hz) | 15 | 30 |
| Sum of whole-index settlement durations (microseconds) | 5,083,652 | 9,924,924 |
| Application DB / WAL physical bytes | 389,120 / 4,132,392 | 417,792 / 4,144,752 |
| Actual source-history content bytes | 0 | 0 |
| Sampled pending jobs / changes | 1 / 1 | 1 / 1 |

The record includes every whole-index and helper RPC duration, all four pending
counts, native DB before/after/delta bytes, and the existing close observations.
Application close plus Domain drain after completed indexing took 9,787
microseconds. Helper shutdown is explicitly its existing SIGKILL plus authoritative
wait, not graceful drain. These timings are observations, with no new latency gate.

CPU baselines follow fixture setup. No loop samples or numeric startup constant
are excluded. Application durations include pending-query instrumentation. Pending
high-water values are sampled after append, immediately after index start, and
after settlement; they are not continuous peaks. The native N128 parent follows
N64 in the same warm helper/database, so absolute database sizes are not an
independent doubling experiment. JSON serialization bytes are separate from actual
history-content bytes. The controlled model proves processed-content scaling,
not production-model CPU latency, physical audio, GPU, or statistical performance.

Run the existing public cases with the qualified mandatory SQL fixture and the
separate test-helper target:

```sh
cd packages/foresight_core
dart test test/meeting_incremental_projection_test.dart \
  --plain-name 'producer append work and serialization scale linearly without source history'
cd ../..
cmake --build build --target helper_transcript_index_test --parallel 2
ctest --test-dir build --output-on-failure -R '^helper_transcript_index$'
```

Keep `FORESIGHT_TEST_SQL_SUPPORT_LIBRARY` pointed at the qualified SQL product
and `FORESIGHT_TEST_HELPER` separate from production `FORESIGHT_HELPER`. Use a
short private directory with mode 0700 under `/var/tmp` for `TMPDIR` and
`FORESIGHT_TEST_TEMP_ROOT`; preserve raw output and source/product identities.
The full Core qualification on `5e672a72` passed 2,889 tests with 16 skipped and
91.04% coverage against 90%. The following `8c4807cb` changes only the output
label and passed the exact focused case; it is not another full-suite run.
