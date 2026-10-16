# Missing-function reconstruction

The new implementation worktree is `open-foresight-missing-functions`, branch
`feature/missing-functions`. It starts from the export, Markdown preview and
meeting-conversation fixes, and includes remote main `d15a096`.

The task still includes speaker attribution/echo handling, automatic meeting
answers, web fallback, and further reference checks. Completing recording
controls does not complete the full task.

## Shipped reference evidence

Target: installed Foresight `1.0.0.28.20261005`, main executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
The packaged helper was extracted into ignored `test-results/reference-functions/`
for static inspection. Selected executable strings and prompt fragments are also
retained there. No account credentials or profile contents were extracted.

| Feature | Static evidence | What it establishes and what remains unknown |
| --- | --- | --- |
| Recording controls | `meeting_transcription_paused`, `meeting_transcription_resumed`, `Transcription paused`, `Transcription is paused. Would you like to resume?`, `Full screen`, `Exit Immersive View` | Pause/resume and immersive-view contracts exist. Exact gesture mapping, elapsed-time accounting and capture-handle ownership need live comparison. |
| Echo cancellation | `InputRecorder` logs starting with voice processing (AEC), falling back to standard recording on failure, and toggling voice-processing bypass; native methods include `setEchoCancellationEnabled` | The Mac original uses an operating-system voice-processing path with fallback. It does not establish cancellation quality, defaults, or Linux behavior. |
| Speaker labels | `SpeakerIdManager`, `speaker_id_manager.dart`, microphone/system/unknown label getters, and generated-note instructions distinguishing generic audio channels from real speaker names | A speaker-label layer exists. These findings alone do not prove a particular diarization model or accurate individual-speaker identification. |
| Automatic questions | `QueryDetectorOnDevice`, `TranscriptManager`, `TranscriptBuffer`, `TextDeduplicator`, `QueryDispatcher`, `Query detected, advancing history cursor.`, and `Questions detected during the conversation will be answered here.` | The original buffers transcripts, runs local query detection, deduplicates, dispatches and advances a processing cursor. IDA and snapshot-pool tracing establish the detector prefix, normalization, thresholds and rolling filters; real-model behavior and timing comparisons remain incomplete. |
| Web fallback | `enable_web_search`, web-search-toggle events, `google_search` function schema, and meeting-assistant prompt instructions | Search is switchable. The assistant is instructed to call Google search for factual queries outside its meeting context and cite tool results using `[Source:N]`. Endpoint, credential handling and complete orchestration need further inspection. |

Further native investigation uses REA with IDA Pro. See the
[IDA search investigation](ida-search-investigation.md) for the current provider
attempt, timeout, and configuration questions. Earlier UI observation failed
with `cgWindowNotFound`. These limits have not been treated as proof of behavior,
and static findings have not been relabeled as runtime observations. No OS
permissions were changed.

## Recording-control implementation

The shared `Recording` owner now supports Pause and Resume. Pause stops native
producers, drains queued PCM, flushes voiced segments, and destroys both capture
handles. Already queued ASR work finishes normally. Resume opens the same routes;
if either route fails, all partially reopened handles are released and the
recording remains paused for retry or Stop. No audio is acquired while paused.
Transcript offsets continue on the captured-sample timeline, excluding the gap.

The application service exposes `meetings.pause` and `meetings.resume`, with an
optional meeting ID to reject stale controls. Paused recording remains an active
profile owner, prevents model replacement, survives client disconnects, and does
not trigger inactivity auto-stop. Service snapshots carry paused state and
elapsed active milliseconds; pausing freezes the recording clock.

The desktop pill has Pause/Resume controls. Double-clicking its waveform opens
the immersive meeting view; an explicit Full screen button also opens it.
Escape, Exit Immersive View, or All meetings restores normal navigation without
stopping the recording. Gesture detection is confined to the waveform so it does
not delay Pause or Stop clicks. The immersive view uses the application window;
native OS fullscreen and the original's exact gestures are not yet verified.

MCP exposes `pause_recording` and `resume_recording` through the same service.

These lifecycle decisions are reconstruction choices consistent with the known
contract; they are not a claim that the original has identical native call order.

## Validation

- Core Dart suite: **36 passed**; analysis reports no issues.
- Desktop Flutter suite: **164 passed, 10 existing opt-in skips**; analysis reports
  no issues.
- New native ABI tests use a compiled C++ capture/ASR fixture that never accesses
  audio hardware. They verify pre-pause PCM draining, zero acquisition during
  pause, resumed offsets, partial-route failure cleanup, retry, and stopping
  while paused.
- Service tests check meeting ownership, persisted state, frozen elapsed time,
  model-replacement refusal and remote snapshot interpretation.
- Desktop tests exercise service Pause/Resume, failure/retry, waveform double
  click, immersive exit/Escape, and 640/1280-pixel layouts.

Physical audio quality, actual OS capture reauthorization, and reference-native
gesture/timing comparisons remain required before claiming full recording parity.

## Automatic meeting answers

The application service now owns a durable pipeline from captured
speech to local question detection, deduplication, retrieval, and a cited answer.
It stores a processing cursor and question jobs per meeting. Starting a meeting
does not replay its previous transcript; restarting the service resumes pending
work. Detector wording is no longer required to be a transcript substring.
Blank, excluded-prefix and exact duplicate outputs are discarded; questions
then pass through the original's rolling hash and prefix/similarity filters.
The current JSON detector prompt still requests copied wording, pending the
original control-token generation/output integration.

Generation waits while another model job is busy. Disabling Automatic answers
retains queued questions and cancels only the pipeline's own request. Cancelling
while indexing, retrieving, or generating prevents subsequent generation and
orphan answer writes. Each answer is saved with its exact request and meeting
ownership. A failed question does not block later questions; the UI exposes retry
actions and displays grounded answers, citations, and current-meeting status.

These include tested reconstruction decisions. Subsequent IDA evidence is
recorded in [proactive-reference-trace.md](proactive-reference-trace.md).
Detection now uses growing finalized history rather than six-row batches,
retains its cursor on empty results, and limits model input to the last 200
whitespace units. Snapshot-pool recovery now binds the splitter to whitespace
runs and the join separator to one space; input preparation uses both. Input versions prevent rerunning an unchanged empty window;
new speech arriving during detection remains eligible for the next pass.
Durable cursor recovery across restarts remains a reconstruction extension.

Interim capture hypotheses now feed detection alongside retained finalized
history, with one hypothesis per capture channel. Interim preparation excludes
the changing final five units before taking the 200-unit tail; at most five
units produces no model call. Finalization removes the corresponding hypothesis,
and pause/stop/reset clears it. A question detected before any finalized speech
has a nullable transcript origin rather than a false link to an older row; a
transactional schema migration preserves existing job IDs and answer links.

Repeated interim detection windows use a five-second timestamp filter that
refreshes on suppressed repeats and allows input at exactly 5,000 ms. Final
input bypasses suppression. Both the window and question filters now hash the
normalized Dart string, matching the recovered String.hashCode dispatch.
Normalization uses the pool-bound lowercase, leading timestamp, ASCII
punctuation and whitespace rules.

Question dispatch applies its separate five-second layer followed by the
original twenty-second prefix/similarity state. Exact equality refreshes prefix
state when it reaches that layer; expansions replace older entries; shorter
revisions are suppressed without refreshing them. Jaccard (0.7), token-set
ratio (0.8) and partial ratio (0.9) combine by OR and include threshold equality.
The expiry comparison is resolved to greater-than-or-equal: exactly 20,000 ms
expires. A transactional migration removes per-meeting lifetime uniqueness
while preserving existing questions, IDs and answer links.

New input is checked before queued answers, allowing an expanded question to
supersede queued work. Completed answers are retained as the reconstruction's
durable history; the inspected original stream consumer does not establish
answer-card deletion. The UI identifies superseded queued questions. Short
interim input and failed newer detection do not strand earlier queued answers.
SQL failure rolls back both job changes and rolling-filter eligibility.

The original ctrl1 detector generation/output integration, history boundary
overlap, exact scheduling (including the post-dispatch delay), provisional
answer context, and real-model/runtime comparisons remain outstanding.

Initial pipeline verification, before the later IDA integrations:

- Core suite: **49 passed, 1 opt-in test skipped**.
- Desktop suite: **165 passed, 10 existing opt-in tests skipped**.
- Core and desktop analyzers: no issues.
- A separate opt-in run using the real local Gemma 4 E2B model passed English
  and Chinese question extraction and a statement-only negative case.
- Capture-to-answer integration uses a compiled native capture fixture and
  deterministic retrieval/generation doubles. This verifies service wiring and
  cancellation, not physical capture quality or real-model answer accuracy.

The model run covers detection only. Full real-audio, retrieval, and answer
comparison against the original remains outstanding.

Subsequent IDA tracing established material differences in the first automatic
Q&A reconstruction: the original uses rolling five-second duplicate suppression,
a further twenty-second prefix/similarity filter, interim transcript input, and
advances the history cursor only after nonempty detection. Those history and
filter rules are now integrated; the initial lifetime uniqueness and six-row
batching have been removed. See [the function-level trace](proactive-reference-trace.md)
for remaining model, scheduling and runtime differences. Full proactive-Q&A
parity remains unproven.

## macOS echo processing

The microphone now uses AVAudioEngine, matching the original native route.
With echo cancellation requested, it initializes both I/O nodes, enables voice
processing, disables AGC, unmutes input, and selects advanced ducking with the
minimum ducking level. Invalid format discovery retries five times at 150 ms;
voice-processing engine startup retries three times at 50 ms. Failed processed
startup destroys that engine and its tap before creating a fresh standard engine.
Standard startup has one attempt. The default setting is off, matching the
inspected native defaults; an application-level override in the original has not
been established.

An already processed engine toggles bypass without restarting. Enabling on an
already standard engine reports that a recording restart is needed. The service
persists the requested preference and separately publishes actual processing,
pending, fallback, and restart status. Paused/stopped capture never reports active
processing. Pause/resume keeps the requested preference and reopens the same
routes. Linux and external capture workers do not claim native AEC support.

The tap retains a shared PCM ring rather than the capture-session owner, keeping
late callback memory valid through stop/fallback. The microphone selects the
first source channel for mono, matching the original converter's channel map;
the preexisting system-tap downmix and continuous output resampling remain.
Device/engine configuration changes enter the existing gap/reconnect path.

The original native functions and REA evidence IDs are recorded in the
[IDA investigation](ida-search-investigation.md). Apple's documentation confirms
that [voice processing can be enabled only while the engine is stopped](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled%28_%3A%29?language=objc)
and that [automatic gain control is enabled by default](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingagcenabled?language=objc),
which is why the reproduced path disables AGC explicitly and uses bypass for
live toggling.

Validation: **51 core tests passed, 1 opt-in skip; 165 desktop tests passed,
10 existing opt-in skips; both analyzers clean; 2 native CTest tests passed**.
New coverage verifies processed-engine disposal before fallback, fallback failure
propagation, channel conversion, bypass/pause/resume state, explicit restart
status, and continued recording after an AEC failure. These tests use native
policy/PCM fixtures and the recording ABI fixture; they do not measure physical
echo cancellation, microphone hardware startup, or the original's tap watchdog.
Those reference and hardware checks remain outstanding.

### Interim integration verification

- Core suite: **65 passed, 1 opt-in test skipped**; analyzer clean.
- Live Q&A desktop test: **1 passed**.
- Capture/ASR ABI fixture verifies interim speech automatically schedules
  detection and an owned cited answer before any finalized transcript row.
  Imported fixture context provides grounding; provisional speech itself is
  not silently inserted into the durable transcript or retrieval index.
- Unit coverage includes five-unit exclusion, exclusion before the 200-unit
  cap, retained history plus two capture channels, suppression timestamp
  refresh and exact boundary, final bypass, stale-hypothesis cleanup, and
  preservation/idempotence of the nullable-origin schema migration.

These deterministic fixtures do not establish physical microphone behavior,
original model output quality, or full dispatcher parity.

### Rolling dispatcher integration verification

- Core suite: **91 passed, 1 opt-in test skipped**.
- Desktop suite: **165 passed, 10 existing opt-in tests skipped**.
- Both analyzers: no issues; git whitespace check clean.
- Boundary tests independently exercise each similarity threshold while the
  other two strategies do not match, exact five/twenty-second limits, timestamp
  refresh, shorter-prefix suppression, Unicode normalization and wall-clock
  adjustment behavior.
- Service tests cover recurring questions after expiry, queued expansion,
  retained completed answers, meeting isolation, reset, short/newer-failed
  detection, excluded output, SQL rollback and migrations from both older
  required-origin and nullable-origin schemas. Existing cancellation and
  request/answer ownership tests still pass.

These are deterministic reconstruction tests; they do not establish physical
capture or end-to-end behavior of the original model.

### Dedicated query detector protocol

Further tracing identifies a separate MODEL_TYPE_QUERY_DETECTOR (type 4)
native model, not the selected chat model. Its generation prefix and raw
ASCII-output postprocessing are implemented in reference_query_detector.dart
and tested through the service callback. The production application still uses
its generic chat/JSON detector: a compatible dedicated native model/decryption
backend must be reproduced before switching it. The original postprocessor
strips non-ASCII detector output; captured transcripts are unaffected.

Current core validation: **97 passed, 1 opt-in model test skipped**; analyzer
clean. See the latest section of proactive-reference-trace.md for the exact
native paths, output rules, evidence and remaining integration requirements.
No physical audio or original detector generation was observed in this pass.

### Search transport and callback protocol

The recovered search client and callback are implemented in `web_search.dart`.
Eleven focused tests cover the request and result contract; the full core suite
passes 108 tests (one opt-in skipped), with clean analysis. This is not yet wired
into production answers: native page summarization, tool/citation integration
and release credential provisioning remain. No separate user project setup was
added. See [the search evidence](ida-search-investigation.md) for exact recovered
constants, IDA addresses and runtime limits.
