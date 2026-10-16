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

Prepare a relocatable standalone arm64 Python 3.13 prefix, not a virtual
environment or Homebrew Python. Install `requirements-litert-macos.lock` into
that prefix. Build the pinned Whisper runtime described in
[speech-models.md](speech-models.md) for arm64 with deployment target 15.0; retain
its source license. Models themselves belong in the user profile and are not
sealed into the application.

```sh
.venv/bin/python tools/package_macos.py \
  --python-runtime /path/to/standalone/python \
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
service shutdown, and closed desktop clients. A shared installation lock held
through every service lifetime excludes replacement; the installer holds the
exclusive counterpart through staging, atomic exchange, verification, and
rollback. Copying uses `ditto` to preserve quarantine and extended metadata.
Ad-hoc installation requires the explicit development option. Do not replace an
active bundle with an ordinary recursive copy.

## Recording and desktop setup

The service owns Core Audio capture, including when started by MCP. Microphone
authorization is an explicit setup operation; attach/status calls do not prompt.
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
