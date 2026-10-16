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

The UI observer currently returns `cgWindowNotFound`. REA reports retained
Hopper resources from the earlier Apple Events authorization failure and refuses
another target until cleanup is confirmed. These limits have not been treated
as proof of behavior, and static findings have not been relabeled as runtime
observations. No OS permissions were changed.

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
