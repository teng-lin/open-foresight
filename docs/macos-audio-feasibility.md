# macOS service-owned audio implementation and evidence

Reference: [Apple Core Audio tap capture documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps); API/format contracts were also checked against the installed macOS 27 SDK headers.

The native service library uses AudioQueue input capture and private Core Audio process taps through a private aggregate device for system audio. Supported floor: macOS 15. No Flutter window or plugin owns capture. Input and output use the existing separate native handles/event channels. Targets are Core Audio device UIDs; `auto` follows the current default input/output; explicit UIDs never fall back. System capture taps stream 0 of the selected output rather than silently capturing all outputs.

Audio callbacks write mono float samples into a bounded single-producer/single-consumer ring without allocation, mutexes or logging. A service worker resamples continuously, converts to little-endian signed 16-bit mono, computes levels and emits 40ms frames. Overflow emits a gap. Device removal/default changes cause a gap and bounded reconnect attempts; a stable stream resets the retry budget. Stop waits for callbacks, drains the ring and emits a partial final frame. The additive `fs_capture_finish` stops capture while retaining queued events; clients must drain those events before releasing with `fs_capture_stop`.

## Permission and launch identity

`fs_audio_capabilities` returns owned JSON (release with `fs_string_free`); discovery never requests access. Microphone states are `not_determined`, `authorized`, `denied`, and `restricted`. `fs_audio_request_microphone` is an explicit setup operation returning 0 for granted and 1 otherwise. It can block on a system dialog and must run away from the service event loop. A denied/unrequested microphone fails capture with actionable setup guidance. Core Audio has no public system-tap permission preflight: its capability is `permission_checked_on_capture`. Zero PCM is never proof of permission or a working recording.

The **responsible capture service executable** needs `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`, stable bundle identity and signing. The standalone `foresight-audio` probe embeds its own Info.plist, but permission granted to the probe does **not** prove authorization of an independently identified Dart service. The installed service must call the FFI permission operation itself. Core Audio tap initialization can wait on permission UI; initialization is independently owned so cancellation returns promptly and a late completion destroys its capture resources. A 30-second unresolved initialization reports `capture_permission_pending`.

`foresight-audio --list-devices` emits JSON `[{id,label,playback}]`. `--capabilities` reports permission/purpose-string status. `--request-microphone` explicitly requests probe identity access. `--probe microphone|system [uid]` performs a three-second capture, prints lifecycle events to stderr and a JSON count of captured/nonzero bytes to stdout. It does not print audio payloads. These commands are diagnostics, never MCP stdout adapters. An explicit absolute executable `FORESIGHT_CAPTURE_RUNTIME` selects the subprocess PCM adapter for controlled tests; absent this setting, Mac capture always uses Core Audio. An invalid override is rejected. This fixture hook is never a successful real-audio acceptance result.

## Executed evidence (2026-10-15)

Actual machine: Apple Silicon, macOS 26.6, Xcode 27 / AppleClang 21.0.0.21000334. Built with a macOS 15 deployment target:

```
cmake -S native -B /tmp/foresight-audio-build -DBUILD_TESTING=ON
cmake --build /tmp/foresight-audio-build --target foresight-audio macos_audio_test -j4
ctest --test-dir /tmp/foresight-audio-build -R macos_audio_contract --output-on-failure
```

CTest passed bounded-buffer overflow/order, concurrent producer/consumer order, no-prompt discovery, and canceled-capture checks. Actual device enumeration returned MacBook Air Microphone (`BuiltInMicrophoneDevice`), MacBook Air Speakers (`BuiltInSpeakerDevice`), and BlackHole 2ch (`BlackHole2ch_UID`) input/output. Capabilities identified both embedded purpose strings and microphone `not_determined`. Microphone probe returned `microphone_permission_required` and zero PCM without requesting access.

Ran `foresight-audio --probe system` while playing `/System/Library/Sounds/Glass.aiff` through `/usr/bin/afplay`. The tap emitted capturing and returned **256000 captured PCM bytes, 54046 nonzero bytes**, 48kHz mono. This is real system playback capture without Flutter, under the unsigned development probe's identity. Initial no-playback capture returned zero-valued PCM and was not counted as audio-content validation.

## Remaining physical/release gates

This evidence does not establish signed installed-service permission attribution, microphone content, actual meeting transcription, MCP-first signed capture, permission revocation, Bluetooth changes, sleep/wake, a fresh user, macOS 15 hardware, or notarization. Those require the installed runtime and actual interaction. Record results separately; compilation and synthetic buffer tests cannot satisfy those gates.
