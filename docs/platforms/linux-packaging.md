# Linux packages and CI

Open Foresight builds one portable x86-64 application bundle, then wraps it with
the native tools for Debian/Ubuntu, Fedora and Arch/Omarchy. The workflow is
`.github/workflows/linux-packages.yml`. It runs only when a GitHub release is
published (including prereleases), not on pull requests, branch pushes, or tag
pushes alone. The release tag must be `v` followed by the version in
`apps/desktop/pubspec.yaml`, for example `v0.1.0`; see
[Versioning and releases](../../README.md#versioning-and-releases).

## Compatibility baseline

Application executables are rebuilt inside Ubuntu 24.04: the helper, Flutter app,
application service/MCP server, inference worker and Whisper Vulkan executable.
LiteRT-LM is source-built at the pinned upstream commit with the native ordered
stop-sequence extension required by note enhancement. The SDK retains its wheel,
native library, passing native regression log and checksum manifest; the application
packager verifies those artifacts and copies the wheel's Linux vendor dependencies.
The stock 0.18.0 library lacks that setter and is not selected by release CI.
ONNX uses a pinned, SHA-verified upstream archive. The build pins
Flutter, gRPC (including its protobuf submodule) and Whisper to full source
commits. The modern protobuf toolchain is intentional: our authoritative
descriptor uses Edition 2024, which older distro protoc packages cannot generate.
The original descriptor and its presence/UTF-8 semantics are retained.
The default native inference bundle uses Python only for build/test tooling.
An explicitly supplied `tools/package.py --query-python-runtime PREFIX` can
add a standalone Python >=3.12 runtime with pinned NumPy2.5.1 and
SentencePiece0.2.1 for the reconstructed dedicated CPU query detector. This
optional runtime is private and relocatable; its worker path and interpreter
come from the bundle, with no automatic host-Python fallback. The three
reconstructed worker modules and distribution notices are copied explicitly;
original oracle code and model weights are excluded. A native-only bundle
keeps dedicated-runtime setup unavailable until an explicit runtime is supplied. The reusable SDK retains its build-time Python environments
and dependency locks, independently of the native inference runtime.
The SDK (gRPC, Flutter, Python, LiteRT-LM and Whisper) is a separate private GHCR image.
Its tag hashes the SDK Dockerfile, CMake hook, dependency locks, runtime builders
and native stop-sequence patch;
application CI consumes the resolved immutable image digest. Ordinary app changes
skip the SDK build entirely. The first bootstrap is slower on two-core runners;
unused duplicate gRPC libraries are excluded and compilation uses `-O2`.
CI saves the SDK core image/cache before building LiteRT-LM and Whisper, preserving the
successful C++/Flutter/Python build if a shader build fails. Whisper uses pinned
SPIRV-Headers; upstream RE2 tests are disabled alongside gRPC/protobuf tests.
Release CI publishes a missing SDK with its repository token and reuses an
already published matching SDK on subsequent releases.
BuildKit caches intermediate SDK layers too. The first source-extension build
is included in the SDK job's existing timeout.

See [production runtime acceptance](../validation/reference-production-runtime-acceptance.md)
for the actual model/package checks and the boundaries of local validation.

`packaging/check_abi.py` audits version requirements of every ELF file, including
inference libraries, and rejects requirements above glibc 2.39 or GLIBCXX 3.4.33.
Both CI and manual package creation enforce this check. An Arch-built executable
requiring glibc 2.43 cannot accidentally become an Ubuntu package.

Initial installation targets are Ubuntu 24.04, Debian 13, Fedora 44 and current
Arch/Omarchy, on x86-64. CPU transcription requires AVX2, FMA, F16C and BMI2, selected
by [the pinned Whisper build's portable x86 defaults](https://github.com/ggml-org/whisper.cpp/blob/0c7be696371069e0baa2515ed7aa08d5a5473aa6/ggml/CMakeLists.txt#L141).
Older releases and ARM64 are outside this initial matrix.
The container base and apt repositories receive updates; pinned source versions
and normalized archives do not make the complete compiler build bit-for-bit
reproducible. Build manifests and ABI reports record what was produced.

## Build locally

Run from a clean checkout with Docker/BuildKit available:

```sh
docker build --file packaging/sdk.Dockerfile --tag open-foresight-sdk:local .
docker build --file packaging/build.Dockerfile --target artifact \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --output type=local,dest=build/portable .
export SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
python3 packaging/package_linux.py --bundle build/portable/dist/open-foresight \
  --format tar --version 0.1.0 --release 1
```

The Docker build runs descriptor verification, native CTest, Flutter analysis and
regular Flutter tests before packaging. Large model downloads and GPU inference
are not part of this build. The exported bundle includes the GPU-capable Whisper
runner and LiteRT runtime, with model setup available on first launch.

Build each installer inside its native distro container, using the same commands
as CI. These commands install/remove packages only inside disposable containers:

```sh
mkdir -p artifacts
cp dist/packages/*.tar.gz dist/packages/*.tar.gz.sha256 artifacts/
docker run --rm -v "$PWD:/work" -w /work -e SOURCE_DATE_EPOCH \
  ubuntu:24.04 bash packaging/ci/package-and-test.sh deb 0.1.0 1
docker run --rm -v "$PWD:/work" -w /work -e SOURCE_DATE_EPOCH \
  fedora:44 bash packaging/ci/package-and-test.sh rpm 0.1.0 1
docker run --rm -v "$PWD:/work" -w /work -e SOURCE_DATE_EPOCH \
  archlinux:base-devel bash packaging/ci/package-and-test.sh arch 0.1.0 1
```

Use an empty `dist/packages` directory for each format invocation; the packager
refuses to overwrite an existing package. On a matching build environment, the
lower-level command is:

```sh
python3 packaging/package_linux.py --bundle /path/to/open-foresight \
  --format deb --version 0.1.0 --release 1
```

Use `rpm` with rpmbuild or `arch` with makepkg. Arch packaging runs as an ordinary
user and emits an `open-foresight-bin` package plus its exact local binary
PKGBUILD/payload. That recipe is rebuildable with makepkg, requires no AUR helper,
and is not a source-build recipe or an AUR publication. Omarchy uses this same
Arch package; its Hyprland integration remains user-configurable in the app.

## Installed layout and ownership

* `/opt/open-foresight`: private application libraries, Flutter assets, helper,
  Whisper, native inference and the application service/MCP server.
* `/usr/bin/open-foresight`: stable launcher, independent of the source checkout.
* `/usr/share/applications/io.openforesight.App.desktop`: application menu entry.
* `/usr/share/pixmaps/open-foresight.png`: icon.
* `$XDG_DATA_HOME/open-foresight`: per-user profile and downloaded models.

The package owns program files only. It has no script that starts the app,
changes desktop shortcuts, moves an active profile, downloads models, installs
GPU drivers, or deletes user data. Existing legacy profiles use the explicit
offline migration documented in the main README.

The bundle includes private protobuf/gRPC libraries and SQLite (including the
unversioned name Dart opens), ICU and native inference libraries. It does not
replace the system glibc, C++ runtime or GPU driver.
OpenSSL's `libssl` and `libcrypto` both come from the host: mixing a bundled older
crypto library with a newer distro TLS library breaks its versioned symbols.
Distro dependency names are centralized in `packaging/metadata.json`. RPM host
requirements are explicit: automatic scanning of private protobuf/inference
libraries would otherwise require libraries already inside the payload.
All payload ELF linkage is checked after native installation.

## CI validation and artifacts

CI builds on ordinary hosted Linux runners without a GPU. After the baseline
build, parallel native-container jobs create `.deb`, `.rpm`, and `.pkg.tar.zst`
files. Each installs its dependencies and package, validates the desktop entry,
verifies installed payload hashes, checks every ELF for missing libraries, imports
the native LiteRT runtime, rejects bundled Python files, runs Whisper help and
decodes the public JFK fixture on CPU with a SHA-verified Tiny model, then
launches the installed app under Xvfb as an ordinary user. It checks activation
IPC and a private SQLite profile, reinstalls the same version, removes the
package, and verifies a per-user sentinel survives. The DEB also gets a separate
Debian 13 installation/startup test.

The Tiny download exists only in the temporary test directory and never enters
the installer or a user profile. These tests do not certify GPU inference,
physical audio, mixed-language accuracy,
Wayland/global shortcut portals, or a real browser consent flow. Those require
separate desktop/hardware acceptance. There is no automatic CPU fallback policy
added by packaging. The bundled Whisper defaults to Vulkan device 0; override
`FORESIGHT_WHISPER_DEVICE` as appropriate for a machine with multiple GPUs.

Artifacts are retained for 14 days with SHA-256 sidecars, the source revision,
version/release, source-date epoch and ABI report. Tar preserves executable modes
across Actions artifact upload/download. Release tags must match pubspec, and the
native package release is `1`. After all package installation tests pass, CI
attaches the portable archive, `.deb`, `.rpm`, `.pkg.tar.zst`, checksums, build
manifests, and ABI report to the triggering GitHub release. Reruns replace assets
with matching names. CI does not create the release, sign Linux packages, or
configure apt/dnf/pacman repositories.

GitHub Actions must be enabled and its account spending/payment limits must allow
hosted jobs. A failure before any steps execute does not validate the build.

## Application configuration

Model weights, account tokens, databases and local environments are excluded from
the build context. No real Google account is required for CI. For a distribution
that includes its OAuth application registration, supply the application-only
configuration explicitly through a BuildKit secret:

```sh
docker build --file packaging/sdk.Dockerfile --tag open-foresight-sdk:local .
docker build --file packaging/build.Dockerfile --target artifact \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --secret id=google_client,src=/path/to/google-client.json \
  --output type=local,dest=build/portable .
```

This configuration is intentionally copied into the distributed app so every
desktop user can read it. It is not an account token. The packager rejects a
tokens/profile file, verifies the bundle manifest, and refuses escaping symlinks.
CI does not currently inject application configuration; browser sign-in requires
configuration through the app or a separately configured release build.

Package metadata currently uses `LicenseRef-Unspecified`, reflecting the absence
of a declared project license. Set the intended license in metadata when one is
adopted; packaging does not choose a license for the project. Bundled dependency
notices remain part of their payloads.

References: [GitHub Actions artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts),
[Debian shared-library policy](https://www.debian.org/doc/debian-policy/ch-sharedlibs.html),
[RPM spec format](https://rpm.org/docs/6.0.x/manual/spec.html),
[Arch PKGBUILD](https://man.archlinux.org/man/PKGBUILD.5.en).
