# Recording audio presentation

`audio_presentation.dart` is a public, read-only value boundary for service and
client code. `persistence/audio_queries.dart` projects those values from a single
schema-guarded read snapshot. This layer performs no filesystem I/O or capture.
The service must supply the independently bound `AudioStore` to advertise usable
media. An unbound reader preserves recording history but cannot advertise play,
export, or transcript seek availability.

`AudioCaptureActivity` is supplied by the current physical capture owner, never
constructed from a database capture state or an old recording object. Its acquired
extent is a monotonic session offset, not elapsed wall time. Old sessions with
pending recognition remain physically idle. Paused time is excluded using shared
span playback anchors; outages inside a span retain their timeline duration.

`AudioQueries.meeting` aggregates all sessions. `sessions` uses an id keyset and
`clips` a source/sequence keyset, with independently bounded pages. Aggregates use
SQL across the complete recording rather than silently using the first page.
`transcriptSeekTarget` requires an explicit saved audio ownership link and usable
media covering the linked source sample. Text timestamps alone cannot create a
seek target. Commands must revalidate this target at execution time.

Availability is independent of transcript existence: a silent clip remains
playable. Preallocation alone is pending, never a fabricated playable clip.
Retained bytes select one validated published representation per logical chunk,
preferring Opus. Staging bytes are the remaining known published or
purge-pending representation bytes. Their sum is metadata-accounted managed
media; these are not fresh disk measurements. Missing or restored media does not
become playable because its old byte length is known.

Recognition backlog unions pending/running/retry/blocked/failed owned sample
ranges, the durable open speech range, and acquired samples beyond the durable
segmentation cursor. It intersects these ranges with actual source chunks and
merges duplicates before summing durations. It excludes ASR context overlap,
completed/abandoned jobs, already-scanned silence, and unacquired outage time.
Capture errors, source recognition errors, compression work, and exports have
independent fields; a worker progress notification cannot erase a capture error.

Export eligibility requires a sealed terminal session, current media authority,
and some usable audio. Partial exports require a visibly labeled client choice
and an explicit `allowIncomplete` command argument. Eligibility is a presentation
hint; the service still performs admission checks and reader fencing when a
command executes. Pause/resume actions similarly require the current live owner.

The desktop `MeetingAudioPlayer` receives prepared values and a service command
port. Meeting detail exposes it with paginated session selection. The transcript
selection menu offers listening to a saved section while preserving complete
transcript selection/copying. Selection offsets choose a transcript identity;
`recordings.transcript_target` and `recordings.seek_transcript` resolve and
revalidate its immutable link in the service. UI offsets never become timestamps.

Media reads use the typed `recordings.read` boundary because the desktop SQLite
worker has no independent media binding or physical acquisition authority. The
feature read model coalesces requests and fences selected meeting, client
session, lifetime, and workspace epoch. These new operations require an explicit
workspace epoch even though historical operations retain their legacy behavior.

`AudioApplicationPort` is injected into Application as `recordingAudio`. The
parent runtime supplies actual playback/export/capture workers. Without that
adapter the service returns historical metadata with `supported:false`; the view
states that playback is unavailable and shows no pretend working controls.

Export first opens the native save picker. Existing output files require an
explicit replace choice. The attached desktop alone may invoke
`recordings.authorize_export_destination`, which returns an opaque one-use token.
Only that protected operation receives a chosen OUTPUT path; no caller chooses
input media paths. The concrete broker must bind session, workspace epoch, actual
service-side caller identity, output identity, chosen format, overwrite and
partial choices. The subsequent export request cannot widen the grant.
ApplicationService passes the actual socket identity through a request-local
scope, never through a decoded argument or a per-request cancellation closure.

The view does not supply decoding, file creation, capture authority, or the
concrete destination broker. Synthetic integration and widget checks do not
qualify real audio playback, filesystem overwrite races, or codec exports. Those
remain runtime/platform acceptance requirements.

## Native playback output


The additive output extension is version 1; the lifetime API remains version 2.
The declarations and bounded JSON schema are in `native/foresight_native.h`.
Creation publishes an owner immediately and prepares the backend asynchronously.
The owner starts paused; `poll.start_token` acknowledges preparation. The caller
prefills PCM before `resume_async`.

PCM is 48 kHz stereo, interleaved signed PCM16. Every count is **frames**, with
exactly two samples per frame. A push accepts at most 4,800 frames. The fixed
queue holds 76,800 frames (1.6 seconds; 307,200 PCM bytes). A push returns the
exact accepted prefix, including zero when full; the caller retains its tail.
Negative returns admit nothing. Ordinary producer calls are serialized outside
realtime callbacks. The consumer uses preallocated storage, fixed copies and
lock-free atomics; it performs no allocation, locking or file IO.

Every push carries a positive int64 seek generation. Pause/flush immediately
blocks producer admission, then uses the owned executor to pause the backend,
fence software callback access, discard queued PCM, advance the generation and
reset counters. Only the operation ACK permits the next generation. Stale
pushes are refused. Finish forces backend stop and callback ownership release;
it does not require the queued tail to play. Retire retains the resource until
its actual cleanup ACK. Unexpected cleanup exceptions quarantine ownership.

`rendered_frames` counts PCM consumed by the backend callback. Underrun silence
does not advance it. `underruns` counts callbacks that lacked requested PCM;
`buffering` describes the most recent enabled callback. These counters reset on
flush. Snapshot fields are independent atomic observations, not a device-clock
transaction. No hardware-audible position, audible-tail limit or physical
latency bound is claimed by a software ACK.

macOS uses an AVAudioSourceNode and an AVAudioEngine. Conversion to the graph's
float channel buffers occurs in the render callback; engine/device work is off
realtime. Callback and notification gates retain their own lifetime through
stop. Linux uses the already required optional PipeWire >=1.0.5 native stream
API, now for bounded output and backend-consumption feedback as well as capture.
Explicit node targets prohibit fallback/reconnection to another device. Missing
PipeWire support produces a visible unavailable output, without an external
player fallback or executable arguments.
