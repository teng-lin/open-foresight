# macOS development and release

The implementation targets Apple Silicon and macOS 15 or later. Flutter is the
desktop shell; the AOT Dart application service owns the profile, model workers,
recording, and writes. MCP and the desktop attach to that service. Closing a
window or an MCP client does not shut down the service.

This document describes the implementation and its build commands. A development
bundle is not a validated public release. The release gates in
[the support plan](macos-support-plan.md) include Developer ID signing,
notarization, physical permission/device tests, a fresh account, and the actual
minimum OS. Keep the results of those gates separate from automated tests.

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

`.github/workflows/macos-release.yml` runs only when a GitHub release is published
(including prereleases). Its tag must match `v` plus the version in
`apps/desktop/pubspec.yaml`, for example `v0.1.0`; see
[Versioning and releases](../README.md#versioning-and-releases). A tag push alone, pull request,
or branch push does not generate a DMG.

The release workflow reuses the macOS build and regression gates in `macos.yml`,
archives the tested application with `ditto` to preserve executable permissions
and symlinks, then creates and verifies a compressed Apple Silicon disk image
containing `Open Foresight.app` and an `/Applications` shortcut. It attaches the
versioned `.dmg`, SHA-256 sidecar, and bundle manifest to the GitHub release after
the checks succeed. Reruns replace assets with matching names. Actions copies
are retained for 14 days. The regular PR workflow continues to run its existing
build and regression checks.

CI assembles the complete ad-hoc bundle with standalone Python 3.13.16, the
source-pinned LiteRT extension (including native stop sequences, macOS ABI fix
and accelerator dependencies), and static Whisper with embedded Metal shaders.
`tools/build_macos_runtimes.py` prepares and verifies the cached payload; its
cache key includes the dependency lock, builders and source patches. Python and
Bazel downloads are checksum pinned and Whisper uses a full source commit.

Every PR runs packaged generation/embedding capability checks, both native and
SentencePiece initialization orders, and Whisper help with a minimal environment.
Release builds additionally download checksum-pinned public E2B, EmbeddingGemma
and Whisper Tiny weights outside the application, then run real CPU inference
and the JFK transcription fixture. Models are not embedded in the DMG. The DMG
job repeats the runtime completeness checks on the restored application before
publication. Evidence is retained alongside the packaging manifest.

The CI artifact remains ad-hoc signed, without Developer ID or notarization.
Physical capture, GPU execution on supported hardware, credentials and the
remaining release validation below are separate gates.

### Local assembly and signed distribution

Prepare a relocatable standalone arm64 Python 3.13 prefix, not a virtual
environment or Homebrew Python. Install `requirements-litert-macos.lock` into
that prefix. The lock includes NumPy2.5.1 and SentencePiece0.2.1 for the
reconstructed dedicated CPU query detector. Its three worker/executor/weights
modules are copied beside the existing adapters, and runtime configuration
points to those installed modules and the bundled interpreter. The dedicated
model remains separately registered; original oracle binaries and model weights
are never copied. Build the pinned Whisper runtime described in
[speech-models.md](speech-models.md) for arm64 with deployment target 15.0; retain
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
See [production runtime acceptance](reference-production-runtime-acceptance.md)
for real model probes and the limits of local ad-hoc validation.

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
See [the audio feasibility record](macos-audio-feasibility.md) for measured probes
and the physical device/permission checklist.

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
