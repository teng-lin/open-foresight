# Recording audio persistence contract

Schema 24 adds durable recording metadata, publication authority, segmentation,
recognition and transform jobs. The service retains its existing exclusive
profile ownership and sole mutation boundary. This module does not acquire audio
devices, perform filesystem publication or run models/codecs.

## Independent media authority

Construct `AudioStore` with the current workspace-epoch callback and a
`mediaGeneration` callback supplied by an independently verified profile-owned
media-root binding. The database's generation/admission row is insufficient:
`Store.audioStore` without that independent callback supports metadata operations
but refuses capture creation, media reads, worker admission and orphan adoption.
Metadata inventory remains readable so unavailable recordings remain visible.
Playback/export use `usableRepresentations`, rather than assuming that every row
returned by the historical `representations` inventory is usable.

The media owner must bind the physical live database identity and media generation
outside database-only snapshots before admitting work. A missing, mismatched or
rewound binding must fail closed. Once it has exclusive profile ownership it
reclaims prior process leases, invokes
`rotateStorageGeneration(metadataOnly: true)`, and updates its independent binding.
This preserves session/span/chunk/link history, marks media unavailable and jobs
blocked, and assigns a new generation. `admitNewRecordingStorage()` permits new
recordings only; it never rebinds old files. The existing strict migration restore
protocol and byte-identical snapshots are unchanged.

All managed media must live beneath
`recordings/<generation>/<session>/` within the protected profile. This layout is
an admission requirement of the storage owner. It makes a durable erasure intent's
session/generation pair sufficient to remove its subtree after fences release.
User-authorized final exports outside the profile are user-owned; profile cleanup
does not remove them. Metadata-only migration snapshots do not back up audio.

## Capture, publication and timelines

`createSession` establishes an immutable UUID, meeting association, workspace epoch
and media generation. `startSpan` stores session-monotonic capture microseconds,
compact playback microseconds and a separate wall-clock display anchor. A resumed
span follows the previous compact playback end; paused time is omitted. Source
sample positions remain continuous per session/source. Stop is terminal and
idempotent; resuming creates a span in the same nonterminal session.

Before accepting frames, commit `preallocateChunk` with its chunk UUID, source,
sequence, span, private relative path and publication token. It deliberately needs
no sample count, rate or final duration. After the native publisher has validated,
synced and atomically published the file, `publishPreallocatedChunk` commits its
actual format/timing/count/length/checksum and initial lossless representation.
Publication may finish after the span is sealed if all frames precede its fence.
Identical delivery is harmless; different immutable metadata is refused.
`reserveChunk` is the convenience variant when finalized metadata is already known.

The initial native format is conditioned 48 kHz mono PCM16 in the writer's
196-byte `recording-wav-v1` container. Raw representation metadata distinguishes
this from a standard 44-byte WAV or headerless PCM. File integrity, conditioned
capture processing, native identity/header binding and OS durability belong to
the native/storage owner; metadata tests do not establish those properties.

`mayAdoptChunk` accepts only a surviving preallocation, matching token, live
session/workspace and current independent storage generation. Filename/checksum
alone never authorizes adoption. Published/missing/quarantined media and raw
representations awaiting purge cannot be adopted again.

Each span/source starts with `unavailable` source-clock evidence and null
uncertainty. `recordSourceClock` appends immutable revisioned transitions from
actual acquisition observations; unknown uncertainty stays null. Supported quality
values distinguish hardware host time, pipe-drain estimates, Linux PTS, PipeWire
header PTS and PipeWire graph-cycle time. Graph-cycle time is not a hardware
acquisition timestamp; see the [native capture clock contract](../../native/README.md#durable-recording-capture). A
recovered WAV supplies no new evidence. Export snapshot hashes include applicable
clock provenance and transitions, and creating an export freezes prior clock
history against late rewrites. The controller must drain actual clock observations
along with final publication notices before declaring a source sealed.

Closed-session duration, transcript seek and frozen assembly inputs use
`AudioPlaybackTimelinePlanner` and `shared-spans-sample-exact-v2`. A continuous
source run quantizes its acquisition anchor once onto the 48 kHz frame grid;
later chunks add exact source-sample deltas, including one-frame tails. Each
shared span includes every known acquired source end, including missing or
quarantined chunk geometry. Unused preallocations establish no acquisition.
Intentional pauses compact between shared spans; source outages remain gaps.
Ambiguous overlapping runs refuse assembly while preserving original audio.

The planner reads at most 128 chunk rows per page and caches bounded span plans
and scalar durations, never an entire recording's chunk list or PCM. Frozen
transform inputs retain exact start/count and geometry hashes; the manifest and
pager revalidate them before use. Transcript seek carries the exact optional
`playbackFrame`, with `playbackUs` retained for older clients. The internal
`AudioQueries.clips` projection still uses microsecond acquisition/span anchors
and can differ for irregular chunks or repeated pauses. Production recording
reads, playback, export and transcript seek use the sample-frame planner; this
does not make every clip projection sample exact. The [worker protocol](audio-worker-protocol.md)
defines the frozen wire geometry and bounded descriptor paging.

## Durable segmentation and recognition

`initializeSegmentation` freezes source/span settings and model revision. Its
initial cursor cannot skip known source frames. `admitSegments` atomically advances
the cursor, retains bounded cross-chunk context/lookback, and freezes owned ASR
ranges and chunk dependencies. Silence advances without creating a transcript
job. Coverage cannot cross unpublished/missing media or purged first-pass PCM.
A work unit spans at most 256 chunk rows, 64 ranges and 64 KiB of context. A closed
span flush commits once, after its full range is scanned and context released.

`pendingJobs` pages eligible work. `claimJob` acquires a generation lease and pins
lossless input representations. `recoverLeases` is only valid after exclusive
profile ownership; it reclaims old owners without changing frozen ranges/models.
Failures use bounded exponential backoff and five attempts, then require explicit
retry. Blocked jobs remain visible. Explicit abandonment requires the worker to
have released its input; it does not pretend a failed job was transcribed.

`commitAsrResult` commits final transcript rows, immutable source-range links,
meeting revision, the existing transcript-index journal and job completion in one
transaction. It invokes no callbacks. Duplicate results return existing identities
without replaying text edits or deleted rows. Service-owned post-commit work must
use the durable index journal independently of the original recording controller.
A text correction can retain its link; split/merge owners explicitly invalidate
unverifiable links. This module does not infer audio offsets from edited text.

## Background transform jobs and cleanup

`createTransformJob` freezes ordered input representation identities/checksums,
codec/container, settings revision and canonical settings. Identical requests
return the same job. Compression owns one chunk; the explicit-input convenience API admits at most
256 representation identities per call. `createExportJob` freezes a whole sealed
recording in SQLite, hashing bounded pages of identities and shared timeline
metadata. `transformInputs(afterPosition: ..., limit: ...)` pages its immutable
snapshot; a meeting has no 256-chunk duration cap. Claiming an export pins its
entire snapshot in SQLite without building an unbounded Dart list. An unavailable
range requires explicit `allowIncomplete` admission and remains identified in
recording history; the export owner must visibly identify its incomplete output.

`pendingTransformJobs`, `claimTransformJob`, `failTransformJob` and
`retryTransformJob` use the same durable lease/backoff discipline. Pending,
blocked and failed jobs pin inputs until completion or explicit abandonment.
Compression `commitTransformResult` validates the frozen target and atomically
publishes its validated representation with job completion. Export completion
records a validated immutable output identity, length and SHA-256. Authorized
output destinations, worker binary provenance, timeouts, full decoder/EOS checks
and filesystem publication remain the service/codec owners' responsibilities.

Both job claims acquire media reader references. Successful/failure completion
releases them. The scheduler **also calls `releaseAsrLeaseReferences` or
`releaseTransformLeaseReferences` in `finally`, after the actual worker has
returned or crossed its cancellation fence**, including stale callbacks. Merely
invalidating a lease never proves a file reader stopped. The release is idempotent.

`beginRawPurge` checks a validated complete replacement, segmentation cursor and
retained context, closed-span flush, all ASR and transform dependencies, and active
reader references in one transaction. It commits `superseded_pending_purge` before
any unlink, excluding new readers. The filesystem owner unlinks outside SQLite,
then calls `completePurge`. Startup resumes `pendingPurges` idempotently; a crash
at either side of unlink cannot resurrect raw media or remove logical chunk timing.

Deletion requires actual worker/reader fences. A SQL trigger refuses session or
meeting-cascade deletion while readers/workers remain, then stores a durable
erasure intent in the deletion transaction. Workspace clear rotates generation
and preserves erasure intents independently of workspace content. Cleanup removes
the deterministic session subtree before acknowledging `completeErasure`.

### Filesystem publication and teardown

Compression stages output in the managed session directory. A validated receipt
binds the job, input identity, storage generation and complete output identity,
length, hash and decoded extent before publication. Recovery reads that exact
receipt and revalidates staged or published bytes; it never adopts an unvalidated
partial. A failed database commit retries publication without requiring another
encode. Compression failure retains raw audio. Raw purge still requires every
dependency and actual-reader fence described above, plus a validated complete
replacement; receiving a codec result alone is insufficient.

Export destinations use the [protected publication protocol](audio-export-publication.md).
An unused one-use grant belongs to the actual caller and expires or invalidates
on disconnect. Once consumed and bound to a durable job, its service-owned work
is independent of the original request's settlement. Frozen settings include
the exact grant identity. User-owned final outputs and displaced overwrite
copies are preserved whenever publication or identity is uncertain.

After fencing scheduler/player admission and joining actual workers, the runtime
calls `AudioExportDestinations.closeBoundLeases`. Normal shutdown closes bound
descriptors while preserving durable receipts and staging for startup recovery.
A queued lease with no transform fence has never exposed its output descriptor;
a fenced lease without actual-worker-close evidence refuses teardown. Destructive
clear uses `discardUnpublished:true`; selected recording deletion also supplies
its session identity. Only exact unvalidated authorized staging is discarded.
Validated, published or uncertain outputs and displaced user files remain intact.
This barrier runs before removing jobs or receipt directories.

`AudioMediaErasure.eraseSession` drains the selected durable tombstone in bounded
batches, yielding and rechecking authority between batches. Success requires its
managed directory and intent to be gone. Unsafe entries preserve the intent and
fail the request; an unrelated older refused tombstone cannot strand the selected
deletion behind a global page limit. Cleanup assumes the verified private staging
area has no other legitimate writers. Identity-check-then-unlink is not an atomic
conditional unlink against arbitrary same-UID mutations; uncertainty preserves
bytes rather than authorizing deletion.

### Retention and user controls

`retain_lossless` belongs to each session and requires current independent media
authority to change. “Keep remaining originals” first commits the keep flag and
gates new purges, then joins active purge/read owners. Bounded
`restoreRetainedOriginals` pages validate each surviving raw file's full hash and
embedded WAV identity before transactionally cancelling its pending purge.
Already absent originals are not recreated; corrupt or uncertain files retain
their purge fence. Backup refuses incomplete remaining-original recovery.

Audio-only deletion requires terminal capture and actual capture, publication,
worker, player, export, backup and filesystem reader fences. It preserves transcript
text and removes audio links/jobs with the session, then awaits targeted erasure.
User-owned final exports and complete backup copies remain outside managed erasure.

Explicit transcription and compression retry keep each job's frozen model and
settings. A missing frozen model can block again visibly; retry cannot silently
retarget another installed model. Read capabilities for playback, supported
export formats, retention, deletion and retry default unavailable and are supplied
by the service owner, independently of transcript presence or historical file
metadata. Complete backup scope and new-profile restore are documented in
[database and audio backups](audio-backups.md).

### Storage headroom presentation

Meeting status carries nullable `estimatedRemainingRecordingUs` alongside the
existing retained and additional-representation byte totals. This is an advisory
profile-wide estimate, never recording admission authority. A fixed OS `df -Pk`
probe runs with a minimal C-locale environment, bounded output and one observed
child. Status and capture do not await it. Attempts are coalesced and throttled to
five seconds; samples older than fifteen seconds, failed queries and changed
workspace/media generations yield unknown. Timeout includes process launch;
late launches remain owned and are terminated/reaped. Shutdown/clear require
actual child retirement, refusing boundedly if that ownership is unconfirmed.
Probe failure alone cannot interrupt capture or replace capture/worker errors.

The estimate subtracts the native writer's 64 MiB reserve and assumes 192080 bytes
per second: two 48 kHz mono PCM16 sources plus two 196-byte headers per five seconds,
rounded up. It assumes no compression savings. Filesystem metadata, frequent
partial chunks, quotas and other writers can consume additional space; the
estimate is not a guarantee or a substitute for native pre-admission/per-chunk
free-space checks. Unknown is distinct from zero estimated headroom.

## Qualification boundary

Focused metadata tests cover restart, duplicate publication, cursor/result/transform
rollback, model/settings freezing, stale leases, pause timing, user edits,
segmentation/purge races, deletion fences, workspace clear and restore admission.
Native bytes/durability, codec fidelity, live capture, desktop playback and Linux
qualification require the integrated product gates in [CONTRIBUTING](../../CONTRIBUTING.md)
and the [native verification guide](../../native/README.md#verifying-native-changes).
A passing metadata fixture is not evidence for those execution paths.

## Saved-audio segmentation owner

`AudioSegmentationOwner` in `audio_segmentation.dart` takes an admitted AudioStore,
a service generation and a bounded `PublishedPcmWindowReader` port. The reader
returns exactly the requested frames from an anchored, validated
`recording-wav-v1` file; no file path or complete recording is transported through
this port. Each read is at most 4,800 mono PCM16 frames (100 ms). Each advance
processes at most twenty windows (two seconds), with at most one window of PCM
held in memory and a bounded metadata page. Reader references remain held through
the real asynchronous read and subsequent metadata admission, including failures.

The frozen VAD configuration preserves normalized RMS greater than .003 as its
starting threshold, with 100 ms of preroll, one second of trailing silence and a
maximum twenty seconds of owned audio per ASR job. A long voiced interval cuts at
a deterministic minimum-energy window within the final 200 ms, carrying the
unowned suffix into the next job. Adjacent ownership stays sample-contiguous;
first-pass audio overlap defaults to zero. Optional overlap is capped at 250 ms
and refused unless the backend explicitly supports timestamp-based owned-range
result cropping. Plain transcript text cannot establish that capability. These
sample guarantees do not prove recognition accuracy at word boundaries; real
backend qualification remains necessary.

Full settings and bounded versioned state are persisted before the first file
read, so an initial read failure cannot lose the settings behind an opaque hash.
Restart reconstructs the same threshold, open segment, bounded lookback and
recent energy windows. Cursor/job/context changes commit together; concurrent
owners or interrupted admissions cannot produce duplicate jobs. No PCM is stored
in the segmentation context.

A native `gap_before` marker flushes the preceding owned prefix and resets all
lookback at that boundary, including a partial 100 ms window. Source samples can
remain contiguous while shared capture time jumps; the gap is not filled with
invented acquired frames or removed from the recording timeline. Unflagged jumps
beyond actual persisted source-clock uncertainty are blocked. The 23 microsecond
canonical frame/rounding allowance is an algorithmic bound, never a measured
physical uncertainty or a reason to infer gaps from pipe-drain jitter. An unknown
uncertainty stays unknown; normal chunk rollover alone is not gap evidence.

`advance(..., sourceSealed: true)` is a service-owned assertion that native finish
has acknowledged acquisition stop and every final publication/clock notice has
been committed and drained, or startup reconciliation has established that same
fence. A closed span row alone is insufficient: valid preallocated chunks may
still publish afterward. Only that assertion permits the final partial window
and the exactly-once durable span flush.

Missing media, source-sample holes or invalid clock continuity never advance the
cursor across missing audio. If a pass already read a valid prefix, it schedules
and commits that prefix with a durable segmentation error and returns
`blockedReason`. With no valid progress it persists the error and refuses the
pass. Successful recovered admission clears the error; speech-worker status
messages cannot do so. Captured-prefix playback and other sources/sessions remain
independent of the blocked range. Capture inactivity and automatic-stop policy
continue to observe newly acquired audio, not segmentation progress.
