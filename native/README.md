# Native runtime

The C ABI in `foresight_native.h` exposes owned generation, speech and capture workers. Build through the root CMake project, then run CTest for lifecycle and cancellation checks.

Generation supports explicit llama.cpp and LiteRT-LM workers. Local Gemma grounded requests use the versioned `x-foresight-grounded-request` schema annotation, consumed by `services/inference/main.cpp` and the citation checker in `services/inference/grounded.h`. It selects evidence units, composes text, checks source citations and numeric fidelity, and performs a separate support check. The configured context is 4096 tokens with a token-aware output reserve. Verification is fallible; failed drafts get one repair attempt followed by a labelled source fallback.

Capture uses PipeWire on Linux and Core Audio on macOS; speech uses whisper.cpp on mono PCM. Workers own their subprocess groups, cancel them on request, and reap them before releasing resources. Model assets and executable paths must be registered explicitly. Deterministic lifecycle tests do not establish real-model quality; real-model tests are opt-in.


### Explicit macOS system audio setup

`fs_audio_request_system(timeout_ms)` (or `foresight-audio --request-system`)
explicitly starts and destroys a private Core Audio tap/aggregate using the same
backend as meeting capture. The realtime callback discards buffers before
inspecting samples; setup saves no PCM or transcript. Call this only after an
explicit user action, from the application service rather than a Flutter/MCP
adapter process. Discovery and capability queries never request consent.

Apple documents that the first recording start on an aggregate containing a tap
requests system audio permission. This uses `NSAudioCaptureUsageDescription`;
it never calls ScreenCaptureKit or a screen-recording authorization API:
https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

The returned owned JSON must be released with `fs_string_free`. A request waits
at most 30 seconds and reports `pending` while Core Audio awaits macOS consent;
late completion owns and tears down its session. Repeated clicks share one
in-flight request. Successful tap startup reports `unknown` and request phase
`completed`, with `permission_verified: false`: Core Audio has no public
permission preflight, and successful IO or silent audio does not prove access.
A documented device-permission error reports `denied`; other startup errors
report `unavailable`, with the OS status. Neither implies a known TCC toggle.

Direct the user to System Settings → Privacy & Security → Screen & System Audio
Recording → System Audio Recording Only (wording varies by OS), enable the app
or service macOS lists, and retry. Applications cannot insert a TCC entry or turn
its switch on themselves. The OS determines the responsible identity; launching
from a terminal/agent may attribute consent to that host. `requesting_bundle_id`
identifies this executable's bundle, not a claim about macOS's responsible
identity. Developer ID/Finder-first and MCP-first attribution still require real
installed-app checks. Do not edit the TCC database or request broader screen
capture access as a workaround.

The macOS `foresight-model-crypto` helper stores dedicated detector assets in the
recovered Tink/AES-256-GCM format using only Open Foresight’s own Keychain entry.
Its `--self-test` uses temporary keys and fixed vectors without accessing Keychain.
The application opens private plaintext leases and removes them after their owned
worker has exited.

Live speech uses `foresight-whisper-worker`, installed beside the diagnostic Whisper CLI. Recording retains native speech handles across segments; microphone and playback handles share one serialized model worker. The final handle releases the worker at recording shutdown. Explicit external installations can set `FORESIGHT_WHISPER_WORKER`; CLI-only installations retain compatibility with the per-request diagnostic path.

## Verifying native changes

- Build and test through the repository-root CMake project. The standalone
  `native/` and `services/helper` projects omit root-only tests, including the
  probe-failure and inference tests; run those too, reusing verified dependency
  libraries and tools.
- Point the Dart core and desktop suites at the freshly built library and helper
  (`FORESIGHT_NATIVE_LIBRARY`, `FORESIGHT_HELPER`) so their native integration
  tests run rather than skip.
- When data moves between argv and stdin, update and exercise every runner
  fixture and consumer, not only the C++ side.
- Capture fixtures must honor the production output protocol: `pw-record` writes
  raw PCM to its owned FIFO while stdout carries diagnostics.
- When worker shutdown depends on stream errors or exception state, check both
  libc++ and libstdc++.
- Test development hooks both disabled (the default) and explicitly enabled.
  Dart compile-time defines may need a source-compiler test invocation, because
  an ordinary kernel test run may not inherit the define. Release builds must
  stay hook-free even when a cached development option was enabled earlier.
