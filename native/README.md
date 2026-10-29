# Native runtime

The C ABI in `foresight_native.h` exposes owned generation, speech and capture workers. Build through the root CMake project, then run CTest for lifecycle and cancellation checks.

`foresight_sql_support` is a separate system-only shared image for mandatory
SQLite read deadlines. It does not link SQLite, models, audio, the application
native image, or optional diagnostics. Embeddings must call the startup-only
`initializeSqliteRuntime(supportLibrary: validatedAbsolutePath)` capability before
any application SQLite connection or worker. It pins the originally selected
image and validates its complete versioned code table. The entrypoint also
freezes SQLite's resolved physical path, code anchor and source identity before
connections. Read owners bind that original handoff and refuse path selection;
their SQLite loader requires the frozen mapping to be already present. The Dart
guard is isolate-local, so embedding owners must pass the handoff to every owned
isolate and prohibit path initialization in arbitrary unbound isolates.
See [SQL worker ownership](../docs/architecture/sqlite-read-workers.md).

Generation supports explicit llama.cpp and LiteRT-LM workers. Local Gemma grounded requests use the versioned `x-foresight-grounded-request` schema annotation, consumed by `services/inference/main.cpp` and the citation checker in `services/inference/grounded.h`. It selects evidence units, composes text, checks source citations and numeric fidelity, and performs a separate support check. The configured context is 4096 tokens with a token-aware output reserve. Verification is fallible; failed drafts get one repair attempt followed by a labelled source fallback.

Capture uses PipeWire on Linux and Core Audio on macOS; speech uses whisper.cpp on mono PCM. PipeWire FIFOs use a validated absolute `TMPDIR` (or `/var/tmp` when unset), private operation-owned directories and descriptor-anchored cleanup. Unsafe/symlinked temporary paths refuse capture instead of falling back silently. Workers own their subprocess groups, cancel them on request, and reap them before releasing resources. Model assets and executable paths must be registered explicitly. Deterministic lifecycle tests do not establish real-model quality; real-model tests are opt-in.


### Durable recording capture

The optional recording exports in `foresight_native.h` retain conditioned 48kHz
mono PCM16 independently of legacy PCM event polling. A single producer hands
frames to a preallocated 64-block SPSC writer (4800 frames/block: at most 6.4s,
614400 PCM bytes/source). Each source targets 240000-frame (5s) WAV chunks.
Exclusive synced `.intent` identities precede admission; media is written to
`.partial`, length/header validated, contents synced, renamed without replacing
an existing file, then directory synced. Files are 0600 in an owned 0700 session
directory; every path component is opened without following symlinks. UUIDs and
sequence/source/session/generation are immutable. The 196-byte WAV header includes
an `fsid` chunk; source flags preserve interrupted recovery and `gap_before`.
Checksums and manifest transactions belong to the service.

Initial reservation sync runs on the native capture worker before devices start.
Replenishment runs on an owned operation lane. Finish fences acquisition, joins
capture and the writer, and leaves metadata available until the service polls it
and retires the owner. `reserved_chunks` counts unused publication identities;
`ready_chunks` counts publication notices before that poll drains them. Overflow,
missing reservations and storage failures stop capture with a persistent error;
ordinary ASR/event-queue pressure cannot discard retained PCM. Filesystem sync
has no finite OS deadline, so finish can remain pending with ownership retained.

macOS preserves AVAudioTime/AudioTimeStamp host times through the native ring and
resampling. Forward acquisition discontinuities split a chunk and set
`gap_before`; backwards time interrupts capture. The 23us algorithmic tolerance
covers one canonical frame plus integer conversion on synthetic fixtures; actual
device alignment bounds remain a separate platform qualification requirement.
Linux retained recording requires the direct PipeWire API and libpipewire-0.3
>=1.0.5 development files at build time. CMake refuses Linux configuration when
pkg-config or this dependency is missing or too old. This production dependency
preserves per-buffer clock provenance that `pw-record`'s raw FIFO discards.
Packaging declares the corresponding runtime library and minimum version.
`pw-record` remains available for legacy capture and diagnostics. The RT process callback only
copies PCM and timestamps into 64 preallocated blocks of at most 4,800 frames
(614,400 PCM bytes). Queue duration depends on graph quantum: 64 blocks at 1,024
frames hold about 1.365 seconds; 4,800-frame blocks hold at most 6.4 seconds.
Overflow interrupts recording and preserves the already accepted prefix.

`pipewire_header_pts` identifies an actual SPA Header PTS. Graph adapters can omit
that metadata even after an explicit request. `pipewire_graph_time` instead
preserves `pw_buffer.time`, the graph-cycle CLOCK_MONOTONIC stamp assigned before
buffer dequeue; it is not a hardware acquisition timestamp. Neither mode uses
callback arrival time. A change of provenance interrupts capture. Physical
uncertainty remains null until route qualification; graph timestamps must not be
used to promise precise audio/text alignment. Graph phase detection uses one block duration plus 23us as an algorithmic
tolerance; this is not a measured device accuracy bound. Independently, matching
per-buffer graph-tick snapshots detect missing quanta, so even a single missing
block sets `gap_before`. Duplicate/backward ticks, mismatched snapshots and rate
changes interrupt capture. Source PTS uses the 23us synthetic tolerance.
The legacy Linux raw FIFO has drain estimates with unknown uncertainty; its
scheduling jitter is never labelled acquisition gaps or hardware clock accuracy.

The manual `native_pipewire_capture_graph_test <foresight_test_sink> <mode>` probe
accepts only an explicitly named private synthetic sink, with `smoke`, `overflow`,
`dual` and `recording` modes. The recording mode exercises the production shared
library through its owned capture ABI and validates sealed silent PCM extents. Start an isolated PipeWire/WirePlumber instance using private
XDG directories first. The dual probe compares shared null-sink graph cycles;
it cannot qualify physical microphone/playback delay. Physical loopback,
route changes, real devices and the Gigabyte platform gate remain required.
Intentional pause boundaries remain distinct from accidental acquisition gaps.

Recovery uses a device-free owned worker, an exact caller-authorized identity
list and matching durable intents, with no filename-only adoption. The service
must validate surviving SQL reservation tokens and the current media generation
before admission and again before committing results. Recovery re-syncs validated
WAVs and seals only complete PCM frames from interrupted partials. Reported sync
flags describe those new operations. `recover_join_async` waits without
cancellation; ordinary capture finish requests cancellation even after a join
was queued, and checks it between files. On Linux, file and directory `fsync`
success are required. macOS requires file `F_FULLFSYNC` without a weaker fallback
and separately reports directory `fsync`; synthetic syscall success does not
establish a tested power-cut guarantee.

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

## Zoom speaker observer (Linux)

`zoom_observer_linux` reads Zoom's accessibility tree through libatspi and speaks
the [observer protocol](../docs/architecture/speaker-observer-protocol.md) on
stdin/stdout, on top of the protocol core shared with macOS
(`foresight_zoom_observer_core`). It is built only on Linux and only when `atspi-2`,
`gio-2.0` and `dbus-1` development files are found; otherwise CMake prints a status line and
skips the target, so the application and recording build and start without it. The
Linux parser and `Source` always build on Linux and are tested with synthetic
fixtures in `tests/fixtures/zoom_observer_linux`; the `zoom_observer_protocol`
CTest drives the built helper with a scrubbed environment (no session bus or
display), so it never touches the developer's desktop. Real Zoom trees and
participant names must not be committed. The shipped rule set enables nothing until
a recorded Linux Zoom snapshot justifies a rule. See
[the Linux helper notes](../docs/architecture/zoom-observer-linux.md).

## Asynchronous application cleanup

Generation and recording use native-owned completion tokens for probe, worker
join and retirement. Their synchronous Dart close/dispose methods revoke work;
await `closed` for actual cleanup before releasing dependent resources. The
legacy C destroy/probe entrypoints remain synchronous for C++/Python callers.
See [native retirement ownership](../docs/architecture/native-retirement.md) for
the capability contract, complete consumer dispositions and qualification limits.

## Verifying native changes

- Build and test through the repository-root CMake project. The standalone
  `native/` and `services/helper` projects omit root-only tests, including the
  probe-failure and inference tests; run those too, reusing verified dependency
  libraries and tools.
- Point the Dart core and desktop suites at the freshly built library and helper
  (`FORESIGHT_NATIVE_LIBRARY`, `FORESIGHT_HELPER`) and set
  `FORESIGHT_TEST_HELPER` to `build/services/helper/ForesightHelperTest` from
  the same repository-root build, so the controlled indexing test also runs
  rather than skips. The core build gate exports all three paths. The test
  helper is separate from production-helper/model acceptance; use the normal
  Release build with `BUILD_TESTING` enabled to produce it.
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
