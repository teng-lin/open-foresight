# Recording interruption and recovery

The capture handle remains owned by `Recording` while the native service
reopens an audio device. A live handle therefore does not establish that the
microphone engine, levels, or echo processing are currently active.

Device gaps now clear the interrupted channel's level and interim hypothesis.
Microphone gaps mark echo processing inactive and pending until a new native
`echo_cancellation` event confirms the reopened engine. Terminal capture errors,
`failed`, and `stopped` events clear pending processing as well. Ring-buffer
overflow clears the interrupted hypothesis but preserves the active processing
state because the engine continues running. The other audio channel remains
independent.

Each interim ASR job carries its channel's hypothesis generation. Gap and pause
events advance that generation, so a slow pre-interruption job cannot restore
stale interim speech after reconnection or pause/resume. Final speech segments
remain queued and are committed normally, including audio drained before a
terminal capture event.

These changes correct service-state reporting and prevent stale interim input
from reaching automatic question detection. They do not establish physical
device recovery.

## Original microphone startup watchdog

REA/IDA traces of the installed original establish the following native policy:

- `InputRecorder.__allocating_init` at `0x10038f45c` initializes the tap buffer
  size to 1,024 and the watchdog interval to **1,500 milliseconds**.
- `scheduleTapWatchdog` at `0x100390bd8` cancels the prior item and schedules
  a weakly owned one-shot check, retaining a wall-clock deadline as well as its
  dispatch deadline.
- Its closure at `0x100391110` acts only while recording is active and the tap
  converted-buffer count is zero. Successfully handled PCM satisfies startup,
  including silence; a callback with an invalid format does not.
  Dispatch lateness **greater than 0.5 seconds** rearms the full interval;
  equality does not defer.
- With echo cancellation enabled, the zero-buffer check disables it, cleans
  up the engine, creates a new standard engine and rearms the watchdog. A
  standard zero-buffer timeout instead sends an input error through the sink.

Retained traces are `audio-input-constructor.json`,
`audio-watchdog-schedule.json`, `audio-watchdog-closure.json`,
`audio-watchdog-error-body.json`, `audio-watchdog-error-message.json`, and
`audio-tap-callback-tail.json` under the ignored
`test-results/reference-functions/ida/` evidence directory.

The port now implements this startup watchdog on the capture worker. The tap
increments an atomic counter after valid mono PCM handling in its shared ring,
retaining the existing safe ownership of late callbacks. The worker uses a
steady dispatch deadline and a
wall-clock lateness deadline. Processed timeout disposes the session before
opening the same route with standard capture, without entering the separate
device-retry backoff. The new standard engine receives its own watchdog.
Fallback metadata explicitly distinguishes no callbacks from a Core Audio
startup error.

The original error is `{type: error, source: input, message: "Microphone audio
stream stalled (no buffers received)."}`. The inspected closure only invokes its
event sink. The port preserves that message, adapts the error to its existing
terminal failure protocol, and releases the session;
the original's higher-level error consumer and physical behavior are not yet
established. This is a startup check, not a watchdog for later callback stalls.

Validation uses the compiled capture/ASR ABI fixture, which never opens audio
hardware. Eight recording tests pass, including controlled late ASR completion
after device loss and pause/resume, device gap and processing recovery,
overflow, peer-channel independence,
failure-state retention, PCM preservation, and existing pause/reopen ownership
checks. Native deterministic tests verify the production 1,500 ms interval,
callback satisfaction, inactive cancellation, fallback/failure decisions, and
the exact 0.5-second lateness boundary. The modified Dart source and test analyze
without issues. Physical echo quality, default-device changes, headset
removal/reconnection, sleep/wake, and
comparison against the original remain unverified.

## Device-parity follow-up

The original stopped-engine configuration debounce and the production Linux
PipeWire capture fixes, including controlled overlap, pause exclusion and pinned
route loss/return, are recorded in [recording device parity](recording-device-parity.md).
These controlled results leave physical acoustic echo and hardware recovery as
explicit acceptance gates.
