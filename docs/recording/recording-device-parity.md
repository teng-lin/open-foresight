# Recording device parity follow-up

This follow-up starts from PR #9 (`9568e1612eee419a67828d509b8ddc745f1bfb6c`).
It fixes an original macOS recovery mismatch and two reproduced Linux capture
failures. Controlled virtual capture is distinguished from physical hardware
acceptance throughout.

## Original macOS configuration recovery

Target: installed Foresight `1.0.0.28.20261005`, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
The shared original IDA Pro database was reused in the existing REA/IDA workflow;
these additional bounded captures were obtained directly through that IDA RPC
session. No Hopper, original profile/cache, credentials, or OS permission changes
were involved.

- `InputRecorder.handleConfigurationChange`, `0x100393238`, checks recording
  ownership and returns without restarting if the engine is still running.
- For a stopped engine, it cancels the previous work item and schedules its
  replacement **150 milliseconds** later (`0x100393528`). Repeated stopped-engine
  notifications therefore postpone the pending restart.
- Its delayed closure, `0x1003935c0`, weakly reacquires the owner and rechecks
  recording state before invoking `restartCapture` at `0x1003938ec`.
- `restartCapture`, `0x100393918`, releases engine state, recreates the engine and
  calls `start` with the retained event sink, buffer size and echo preference.
- The closure checks a local restart counter against three, but `start` resets
  that counter at `0x10038fa6c`. This is **not evidence of a cumulative three-loss
  retry budget** across successfully restarted capture sessions.

Previously, the port marked every configuration notification as an invalid
format/device change and applied its generic one-second device retry delay.
It now separates engine notifications from invalid PCM, ignores notifications
while the engine runs, debounces stopped-engine notifications for 150 ms, and
recreates the session directly after that deadline. Stop/Pause still owns and
cancels the session. Explicit device loss, format changes and the existing
health checks retain the port's separately documented retry policy; no claim
is made that those additional policies are identical to the original.

Raw captures are retained locally under ignored
`test-results/reference-functions/ida/audio-configuration-*.json`, alongside
`audio-configuration-trace.log` and the previous `audio-restart.json`/`audio-start.json`
evidence in the investigation worktree. Deterministic native tests cover healthy
notifications, the 149/150 ms boundary, replacing a pending deadline, one-shot
restart, and inactive-owner cancellation. They do not open an audio device.

## Reproduced Linux failures and fixes

A dedicated Ubuntu 24.04 AMD64 container ran PipeWire **1.0.5**, its Pulse bridge
and WirePlumber on a private DBus/runtime directory. `/dev/snd` was absent, and
no host PipeWire socket or physical audio device was mounted. The source mount
was read-only; native output, the Dart 3.9.2 runtime, generated tones, models and
profiles lived inside the disposable container.

The first real run failed before PCM: `pw-record --raw` is unsupported by this
PipeWire version. Removing it exposed another failure: `pw-record` prints
`stream node ... error/unconnected` messages to stdout on device loss. The
adapter interpreted 74 diagnostic bytes as **37 microphone samples**. The
waveform inspector detected fabricated extra-frequency tokens in that segment.
The upstream implementation confirms both stdout error paths in
[PipeWire 1.0.5 pw-cat.c](https://github.com/PipeWire/pipewire/blob/1.0.5/src/tools/pw-cat.c).

Production capture now gives `pw-record` a separate `.raw` FIFO destination,
using its supported libsndfile raw-file path. The FIFO is mode 0600 inside a
mode 0700 owned temporary directory. Stdout diagnostics no longer share the
PCM channel. No text-pattern filtering, extra dependency, or user configuration
is needed. The explicit external capture override retains its stdout PCM
contract and is not counted as real capture acceptance.

The adapter observes process exit independently of FIFO EOF, handles `ECHILD`
when Dart has already reaped the native child, and reports that unavailable
exit status as `-ECHILD` rather than inventing a successful exit code. It drains
queued PCM only after the producer is terminal during Stop/Pause, then closes
and removes the FIFO and directory. Native regression fixtures check permissions,
exact PCM bytes despite stdout diagnostics, cleanup, and child exit without ever
opening the FIFO.

## Executed controlled capture

`packages/foresight_core/test/recording_pipewire_test.dart` is opt-in and drives
the production Dart `Recording` owner and native `pw-record` path. It creates
separate private virtual microphone and output routes. A waveform inspector
replaces Whisper; this checks captured/resampled PCM and lifecycle ownership,
not speech recognition accuracy.

The final run verifies:

- Concurrent 437 Hz microphone and 997 Hz playback tones remain in their own
  transcript channels. The inspector checks mono signed 16-bit 16 kHz resampled
  WAV, bounded fixture amplitude, sufficient samples and independent frequency
  energy. No stdout/header data is accepted as a speech segment.
- Pause releases both handles and freezes their sample counts. A distinct
  1699 Hz tone played on both routes only during Pause is absent from every
  final segment after Resume and Stop.
- Removing the selected virtual microphone emits a gap. Its sample count stays
  fixed while a different default source remains available and the peer playback
  channel continues capturing. The pinned microphone does not fall back.
- Recreating the same selected route resumes real PCM and final output. Stop
  completes and preserves the pre-interruption and post-return segments.
- Private default routes before and after the test match. All test-created
  players/modules are released. At review handoff the owned container remains
  available for an independent rerun; the reviewer owns its final stop/removal.
  No host default route is modified.

Run only on a dedicated hardware-free server/container with an owned runtime:

```sh
cd packages/foresight_core
FORESIGHT_PRIVATE_PIPEWIRE=1 \
PIPEWIRE_RUNTIME_DIR=/tmp/recording-runtime \
XDG_RUNTIME_DIR=/tmp/recording-runtime \
FORESIGHT_NATIVE=/out/libforesight_native.so \
FORESIGHT_PIPEWIRE_REPORT=/out/recording-report.json \
dart test test/recording_pipewire_test.dart --reporter expanded
```

The test requires `/dev/snd` to be absent and an explicit private PipeWire
runtime. It is skipped by ordinary unit-test runs. Install `pipewire`,
`pipewire-pulse`, `wireplumber`, `pulseaudio-utils`, Python 3 and a C++20 compiler
in the disposable Ubuntu container, start those three daemons under a private
`dbus-run-session`, and build `native/foresight_native.cpp` as the shared library.
Use a writable copy of the core package for `dart pub get`; do not modify the
source-mounted checkout.

Reports/logs remain in ignored `test-results/recording-device-parity/`.
The passing run finished in approximately 13 seconds; microphone counts were
102400 at Pause and 154624 at device loss, with no acquisition during the paused
or post-gap absent-device intervals. Later final microphone segments contained
only `tone_437`; playback contained only `tone_997`.

## Remaining physical checks

Read-only macOS inventory found built-in and USB microphone routes, built-in
and external outputs, and BlackHole. Microphone authorization was
`not_determined`; no permission request or microphone recording was attempted.
No physical Linux audio device was available. The following remain explicit
acceptance gates, rather than being inferred from synthetic capture:

- Acoustic echo suppression and simultaneous local/remote speech against the
  original, with consented microphone content and known playback.
- Real macOS microphone Pause/Resume and device removal/default changes;
  Bluetooth format changes, sleep/wake, and signed-service permission identity.
- Equivalent real-device checks on Linux, including suspend and hardware/device
  server restart. Virtual route recovery does not establish those outcomes.

## Final regression checks

- Ubuntu native ABI suite: 18 tests, 17 passed and one macOS-only skip.
- macOS native ABI suite: 18 tests, 15 passed and three Linux-only skips.
- macOS audio policy CTest: passed.
- Focused Dart recording/permission suite: nine passed; the private Linux test
  is skipped on macOS and passes when explicitly enabled in the container.
- New Dart test analysis, Python syntax checking and `git diff --check`: clean.
