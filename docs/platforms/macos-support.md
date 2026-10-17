# macOS development and release

The implementation targets Apple Silicon and macOS 15 or later. Flutter is the
desktop shell; the AOT Dart application service owns the profile, model workers,
recording, and writes. MCP and the desktop attach to that service. Closing a
window or an MCP client does not shut down the service.

This document describes the implementation and its build commands. A development
bundle is not a validated public release. The [release gates](#release-gates)
cover Developer ID signing, notarization, physical permission and device tests,
a fresh account, and the actual minimum OS. Keep the results of those gates
separate from automated tests.

## Build

Use Xcode with its command-line tools, Flutter 3.35.7 (Dart 3.9.2), Python 3.13,
CMake, Ninja, Git, and CocoaPods. Enable Flutter's Swift Package Manager support:

```sh
flutter config --enable-swift-package-manager
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
```

Build the pinned static dependency SDK instead of linking current Homebrew
gRPC/protobuf libraries. A bottle built for a newer Mac OS cannot satisfy the
15.0 deployment target merely by setting that target on our executables.

```sh
.venv/bin/python tools/build_macos_sdk.py --prefix "$PWD/build/macos-sdk"
```

Pass the completed SDK prefix to the platform build. The SDK builder's help and
CI workflow specify its source/cache options.

```sh
tools/build.sh --platform macos \
  -DCMAKE_PREFIX_PATH="$PWD/build/macos-sdk" \
  '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local'
```

This builds native code, runs CTest, analyzes/tests the core and desktop, compiles
the service and MCP executables, builds the release desktop, and runs the service
subprocess tests. `FORESIGHT_BUILD_DIR`, `FORESIGHT_PYTHON`, and
`FORESIGHT_BUILD_JOBS` override the output directory, development Python, and
parallelism. Build-time Python and Flutter are not installed-app dependencies.

## Bundle

### Release CI disk image

The release coordinator calls `.github/workflows/macos-release.yml` with an
immutable tag after verifying exact-commit main candidates and creating a draft.
Its tag must match `v` plus the application version, for example `v0.1.1`; see
[Versioning and releases](../../README.md#versioning-and-releases). A tag push,
pull request, or manually published release does not generate a DMG.

Promotion retrieves the tested macOS candidate, preserving executable permissions
and symlinks with `ditto`. Runtime verification, real CPU model tests, and bundled
Google/cloud configuration checks must pass before creating and verifying a
compressed Apple Silicon disk image containing `Open Foresight.app` and an
`/Applications` shortcut. The versioned DMG, checksum, and bundle manifest are
uploaded to the draft without overwriting assets. Actions copies last 14 days.

Downloaded-installer acceptance runs before publication, alongside all Linux
formats. A missing runtime, installer, or acceptance gate leaves the release
unpublished. A failed draft can be rebuilt by rerunning all coordinator jobs;
public releases require a new version. The DMG remains ad-hoc signed and is not
Developer ID signed or notarized. Signed distribution still requires the setup
and release validation below.

### Local assembly and signed distribution

Prepare a relocatable standalone arm64 Python 3.13 prefix, not a virtual
environment or Homebrew Python. Install `requirements-litert-macos.lock` into
that prefix. The lock includes NumPy2.5.1 and SentencePiece0.2.1 for the
reconstructed dedicated CPU query detector. Its three worker/executor/weights
modules are copied beside the existing adapters, and runtime configuration
points to those installed modules and the bundled interpreter. The dedicated
model remains separately registered; original oracle binaries and model weights
are never copied. Build the pinned Whisper runtime described in
[speech-models.md](../models/speech-models.md) for arm64 with deployment target 15.0; retain
its source license. Models themselves belong in the user profile and are not
sealed into the application.

Build the source-pinned LiteRT extension with Bazel 7.6.1 from a checkout at
`b2f686e2ed4718fb84ec398a61dd59ca0f0aff27`. Materialize its
`prebuilt/macos_arm64/*` Git LFS objects first. The builder applies the repository
patch, runs the native regression, limits the C API's exported symbols and writes
a verified wheel/library manifest. The packager overlays that wheel into its
private Python copy; the source Python installation remains untouched. The stock
0.18.0 runtime lacks the native stop sequences required by note enhancement.

```sh
.venv/bin/python tools/build_litert_extensions.py /path/to/LiteRT-LM \
  --output "$PWD/build/litert-extensions"
.venv/bin/python tools/package_macos.py \
  --python-runtime /path/to/standalone/python \
  --litert-extensions-manifest "$PWD/build/litert-extensions/build-manifest.json" \
  --sdk "$PWD/build/macos-sdk" \
  --whisper-runtime /path/to/whisper-cli \
  --whisper-license /path/to/whisper.cpp/LICENSE \
  --output "$PWD/dist/Open Foresight.app"
```

The default signing identity `-` produces an ad-hoc development artifact. For a
development signature only, library validation is disabled because ad-hoc code
has no Team ID to match its Python extensions and FFI libraries. Developer ID
release signing retains library validation and signs every nested binary with
the same identity. The standalone Dart service and MCP executable require
`allow-unsigned-executable-memory` for their embedded AOT snapshot loader, in both
development and release signing. That exception is restricted to those two
executables and the service bundle's executable signature; it is not applied to
Flutter, Python, or native workers. `allow-jit` is not needed. For a
release, supply `--identity 'Developer ID Application: …'`, an existing
`--notary-profile`, and `--archive /path/to/Open-Foresight.zip`. The packager
relocates non-system Mach-O dependencies, audits arm64 and minimum OS metadata,
signs nested binaries before containers, submits notarization, staples the ticket,
and assesses the app. It writes its provenance/verification manifest beside the
sealed app. Release builds require both model runtimes and dependency licenses.
A local full-runtime development bundle does not show that the CI DMG can run
inference.

The AOT exception follows Dart 3.9.2's
[Mach-O snapshot loader](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/bin/macho_loader.cc)
and [Mac memory mapping implementation](https://github.com/dart-lang/sdk/blob/3.9.2/runtime/bin/file_macos.cc):
the loader reserves anonymous writable memory, copies executable snapshot
segments into it, and changes protection to executable. It does not use a
`MAP_JIT` mapping in that path. On this host, baseline and `allow-jit`-only
signatures were killed; the unsigned-memory entitlement alone allowed both AOT
entrypoints to execute. Developer ID notarization remains its own release gate.

`Contents/Resources/runtime.json` records bundle-relative resources, installation
identity, and the source revision. The nested service receives the same runtime
map. Packaged peers reject an incompatible running service rather than mixing
versions. Python workers use isolated mode and suppress bytecode writes. Mutable
models, databases, logs, credentials, and caches stay outside the bundle.

## MCP and profile ownership

An MCP host can execute the installed binary directly without a shell:

```json
{
  "mcpServers": {
    "open-foresight": {
      "command": "/Applications/Open Foresight.app/Contents/MacOS/foresight-mcp",
      "args": []
    }
  }
}
```

Paths containing spaces are single JSON string values. No checkout, developer
Python, Flutter SDK, shell initialization, or `DYLD_*` settings are needed. MCP
stdout carries protocol messages only. Connecting does not request capture
permissions or download models.

The default profile is under
`~/Library/Application Support/Open Foresight`. Explicit `FORESIGHT_DATA` and
`FORESIGHT_RUNTIME` overrides remain supported. Canonical profile identity and a
private data lock prevent duplicate owners even when clients use different
runtime overrides or path aliases. Socket names use a short private per-user
runtime directory to fit the macOS Unix socket limit.

## Install, update, and verify

```sh
.venv/bin/python tools/smoke_macos_bundle.py \
  "dist/Open Foresight.app" --output /tmp/foresight-bundle-smoke.json
.venv/bin/python tools/install_macos.py --help
```

The smoke tool relocates the app into a path containing spaces and starts actual
bundled service/MCP executables in a minimal environment. It verifies shared
ownership, cross-client persistence, restart, and installation-maintenance
exclusion. Its report explicitly distinguishes automated checks from physical
audio, notarization, quarantine, minimum-OS, and fresh-user checks.

The installer defers replacement while the destination is running by default.
Its explicit stop-services option requires verified profile ownership, graceful
idle-only service shutdown, and closed desktop clients. Recording, final
transcription, or another active operation defers the upgrade. A shared installation lock held
through every service lifetime excludes replacement; the installer holds the
exclusive counterpart through staging, atomic exchange, verification, and
rollback. Copying uses `ditto` to preserve quarantine and extended metadata.
Ad-hoc installation requires the explicit development option. Do not replace an
active bundle with an ordinary recursive copy.

Bundled model runners registered by this version retain resource provenance, so
moving the app resolves generation and speech runners in the new bundle. External
runners keep their explicit paths. Older registrations without provenance must be
registered again through model setup; the app never guesses ownership from an
old `.app` filename. Back up the profile before migrating legacy registrations.

If another installation owns the profile, startup reports that conflict visibly.
Stop that owner explicitly after its work finishes, then retry this installation;
clients do not kill an incompatible owner or replay failed mutations.

## Recording and desktop setup

The service owns Core Audio capture, including when started by MCP. Microphone
authorization is an explicit setup operation; attach/status calls do not prompt.
Both quick start and recording an existing meeting guide microphone and system
audio setup before capture. Use **Request access**, enable Open Foresight under
System Settings > Privacy & Security > Screen & System Audio Recording > System
Audio Recording Only, then return and continue. The exact section name varies by
macOS version. A completed Core Audio request does not prove authorization; actual
capture reports failures. Settings also provides explicit access setup actions.

Local source search separately prompts for the 485 MB EmbeddingGemma 2 download.
Selecting a generation model while this embedding model is missing does not start
the combined download until the user chooses **Download models**.

The responsible service bundle includes microphone and system-audio purpose
strings. Permission attribution must be tested on the signed installed layout.
See [Capture](#capture) for the service-owned audio path.

The desktop implements Command-key navigation, app reopen/activation, a global
quick-meeting shortcut, and open-at-login through the native shell. Login starts
the desktop, which attaches to the existing owner. Notifications use a separate
stable helper bundle and explicit authorization. Scheduling remains in the
application service. Google sign-in is explicit; install application OAuth
configuration with `--google-client`, never account credentials or tokens.

The packager copies the full NumPy distribution license hierarchy and the
SentencePiece upstream notice. NumPy extension linkage participates in the same
Mach-O relocation, architecture, minimum-OS and signing checks as other nested
binaries. `tools/test_packaged_query_worker.py --python-runtime PREFIX --model
REGISTERED_MODEL` copies and relocates the actual prefix, runs from a moved path
containing spaces with poisoned working-directory imports, and checks both a
positive and empty detector result. Its output report belongs under ignored
`test-results`; it does not copy the registered model into the test bundle.

## Capture

The native service library owns capture. No Flutter window or plugin does. The
supported floor is macOS 15. Microphone input uses AVAudioEngine. System audio
uses a private Core Audio process tap through a private aggregate device, on
stream 0 of the selected output. Targets are Core Audio device UIDs. `auto`
follows the current default input or output. An explicit UID does not fall back
to another device. Apple documents taps in
[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

Audio callbacks write mono float samples into a bounded single-producer,
single-consumer ring without allocation, mutexes, or logging. A service worker
resamples continuously, converts to little-endian signed 16-bit mono, computes
levels, and emits 40 ms frames. Overflow emits a gap. Device removal and default
changes cause a gap and bounded reconnect attempts. A stable stream resets the
retry budget. Stop waits for callbacks, drains the ring, and emits a partial
final frame. `fs_capture_finish` stops capture and retains queued events.
Clients drain those events before `fs_capture_stop`.

During a route interruption the recording owner clears the affected channel's
level, interim hypothesis, and active echo-processing state. A late interim
result from before the interruption or pause cannot repopulate cleared speech.
Final segments stay queued. If processed microphone startup produces no valid
PCM for 1,500 ms, capture falls back to a fresh standard engine, then reports
failure if that engine also produces no valid PCM. Valid silence satisfies
startup.

Discovery never requests access. Microphone states are `not_determined`,
`authorized`, `denied`, and `restricted`. `fs_audio_request_microphone` is an
explicit setup operation. It can block on a system dialog, so it runs away from
the service event loop. A completed system-audio request does not prove capture
permission. Zero PCM is not proof of permission or of a working recording.

The responsible capture executable needs `NSMicrophoneUsageDescription`,
`NSAudioCaptureUsageDescription`, a stable bundle identity, and a signature.
Permission granted to the standalone `foresight-audio` probe does not authorize
the Dart service. The installed service calls the permission operation itself.
An unresolved tap initialization reports `capture_permission_pending` after 30
seconds.

`FORESIGHT_CAPTURE_RUNTIME` may name an absolute executable for controlled
tests. Without that setting, Mac capture uses Core Audio. An invalid override
is rejected. Probe output is a diagnostic. It is not an acceptance result.

## Release gates

These gates are still open. A local development bundle does not close them.

- The release CI artifact runs real embeddings, grounded generation, Whisper, cancellation, model setup, and worker cleanup. The current CI DMG omits the Python/LiteRT and Whisper runtimes.
- Microphone and system audio work desktop-first and MCP-first, including denied or revoked permission, device changes, and closing the desktop.
- Explicit stop flushes transcripts. Service crash recovery preserves committed data and marks an unfinished recording interrupted.
- Shortcuts, app reopen, login, source links, imports, notifications, and Google authorization and sync work in a release build.
- A relocated, quarantined, signed artifact works for a fresh account without Homebrew, SDKs, repository files, or a developer environment.
- An upgrade coordinates with a running service or recording, and macOS 15 is exercised on actual hardware.

## Published DMG acceptance

[Release acceptance](../validation/release-acceptance.md) mounts the downloaded DMG and validates a new owned installed copy, real model
workflows and saved-data persistence across reinstall. Existing apps are refused.
Hardware and normal desktop/Finder checks remain separate manual gates.
