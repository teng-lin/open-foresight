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
| Automatic questions | `QueryDetectorOnDevice`, `TranscriptManager`, `TranscriptBuffer`, `TextDeduplicator`, `QueryDispatcher`, `Query detected, advancing history cursor.`, and `Questions detected during the conversation will be answered here.` | The original buffers transcripts, runs local query detection, deduplicates, dispatches and advances a processing cursor. Exact prompts, thresholds and model behavior remain unresolved. |
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

The application service now owns a durable pipeline from finalized captured
speech to local question detection, deduplication, retrieval, and a cited answer.
It stores a processing cursor and question jobs per meeting. Starting a meeting
does not replay its previous transcript; restarting the service resumes pending
work. Detection accepts only questions copied from the supplied transcript and
rejects invented text. Case, punctuation, and whitespace normalization prevent
duplicate jobs within the meeting.

Generation waits while another model job is busy. Disabling Automatic answers
retains queued questions and cancels only the pipeline's own request. Cancelling
while indexing, retrieving, or generating prevents subsequent generation and
orphan answer writes. Each answer is saved with its exact request and meeting
ownership. A failed question does not block later questions; the UI exposes retry
actions and displays grounded answers, citations, and current-meeting status.

These are tested reconstruction decisions. The original's exact detection
prompt, buffer window, overlap, thresholds, scheduling, and retry policy have
not been established from function-level evidence. In particular, detection
currently batches six final transcript rows; questions split across batches
remain a known quality limitation to investigate.

Verification after this implementation:

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
