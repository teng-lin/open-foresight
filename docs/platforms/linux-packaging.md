# Linux packages and CI

Main CI builds and tests one portable x86-64 application bundle.
`.github/workflows/linux-packages.yml` retrieves that exact-commit candidate and
wraps it with the native tools for Debian/Ubuntu, Fedora and Arch/Omarchy.
The release coordinator, `.github/workflows/release.yml`, calls both platform
packagers after successful candidates exist for one reviewed main commit. It
creates the tag and a draft, then every packaging job checks out that exact tag.
The tag must be `v` followed by the version in `apps/desktop/pubspec.yaml`, for
example `v0.1.1`; see [Versioning and releases](../../README.md#versioning-and-releases).
Tag pushes and manually publishing a release do not invoke these reusable packagers.
Publication follows installed-package acceptance.
A pull request that changes `apps/desktop/**`, `packages/foresight_core/**`,
`packaging/**`, or this workflow builds the portable bundle on an `ubuntu-24.04`
runner with `packaging/build.Dockerfile` and builds and installs the Debian
package inside `ubuntu:24.04` using `packaging/ci/package-and-test.sh`. That job
fails the pull request when the build or install fails. It does not publish
release assets.

## Compatibility baseline

Application executables are rebuilt inside Ubuntu 24.04: the helper, Flutter app,
application service/MCP server, inference worker and Whisper Vulkan executable.
LiteRT-LM is source-built at the pinned upstream commit with the native ordered
stop-sequence extension required by note enhancement. The SDK retains its wheel,
native library, passing native regression log and checksum manifest; the application
packager verifies those artifacts and copies the wheel's Linux vendor dependencies.
The stock 0.18.0 library lacks that setter and is not selected by release CI.
The build pins
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
The SDK is assembled from separate content-addressed GHCR images: core
(gRPC, Flutter, Python), LiteRT, and Whisper. `.github/workflows/ci-dependencies.yml`
builds changed recipes, running LiteRT and Whisper concurrently after core.
Read-only PR jobs retain each verified component as an Actions artifact for
14 days. Same-repository application checks wait for those images rather than rebuilding an SDK;
after review, main can publish the saved images without recompiling them.
Application checks consume qualified image digests; release packaging consumes
the exact-commit portable candidate from successful main CI. Fork PR checks retain
their local SDK build; same-repository consumers wait for verified artifacts.
Registry authentication and transport errors
fail before compilation. Component registry caches preserve completed layers.
See [CI dependencies and promotion](ci-performance.md) for bootstrap, trust,
artifact expiry, and release readiness. A local model probe does not stand in
for the published-installer checks below.

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

## Document import sandbox

PDF and RTF imports require `/usr/bin/bwrap` (bubblewrap), `/usr/bin/pdftotext`
(poppler), and `/usr/bin/unrtf`, plus host permission for bubblewrap to create its
user, mount, PID, and network namespaces. Package dependencies provide these
executables; namespace permissions also depend on kernel, container, and host
security policy.

Ubuntu 24.04 mediates unprivileged user namespaces through AppArmor. If a sandbox
startup error reports a namespace permission denial, an administrator must review
the host policy and allow the necessary user-namespace access in the applicable
AppArmor profile for bubblewrap. See [Ubuntu's AppArmor user-namespace
guidance](https://documentation.ubuntu.com/security/security-features/privilege-restriction/apparmor/#apparmor-unprivileged-user-namespace-restrictions).
Open Foresight reports the startup diagnostic and stops the import when its
sandbox cannot start. Ordinary PDF/RTF parsing errors retain their document
diagnostics.

The `linux-document-imports` CI job runs the shipped parser against actual PDF
and RTF fixtures directly on a disposable Ubuntu host. It requires all tools and
fails on missing prerequisites or namespace errors. If the host initially denies
the namespace probe, CI loads `packaging/ci/document-sandbox.apparmor` for that
runner's bubblewrap executable and retries; this profile is never installed by
the product packages. The initial denial and actual import output are retained
as CI evidence. Local runs missing required executables report a skipped test.

## Build locally

Run from a clean checkout with Docker/BuildKit available:

```sh
tools/build_linux_sdk.sh
tools/build_linux_container.sh
export SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
python3 packaging/package_linux.py --bundle build/portable/dist/open-foresight \
  --format tar --version 0.1.0 --release 1
```

The shared wrapper uses the `ci` Docker target, retaining verified SDK and
application dependency outputs. Python 3.13 and the GitHub CLI are needed on the
host for qualification; the SDK supplies Dart and Flutter. `--seed` accepts an
existing qualified dependency directory, and `--sdk-image` selects an already
available compatible SDK. The build container runs `tools/linux_container_build.sh`
without tests, packages the bytes, and exports its exact source/build tree with
checksums and nanosecond timestamps. A second container verifies those inputs and
runs CTest, core and desktop coverage, service/MCP with a native UI, fast integration
and Linux host contracts without rebuilding application outputs. The wrapper
then extracts the verified package to `build/portable/dist/open-foresight/`.
Large model downloads and GPU inference are separate acceptance gates. The bundle
includes GPU-capable Whisper and LiteRT, with model setup available on first launch.

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
the native LiteRT runtime, rejects bundled Python runtimes and unexpected Python
source files, runs Whisper help and decodes the public JFK fixture on CPU with a SHA-verified Tiny model, then
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
native package release is a durable per-draft counter that increases on every
full rebuild, including when an older workflow is rerun. After native installation
tests pass, CI attaches the portable archive, `.deb`, `.rpm`, `.pkg.tar.zst`,
checksums, provenance and ABI report to the draft. The coordinator publishes only
after every downloaded installer passes acceptance. Public assets are immutable;
cut a new application version for a correction. Linux packages are not signed and
no apt/dnf/pacman repository is configured.

Prepare a release from reviewed main with:

```sh
gh workflow run release.yml --repo teng-lin/open-foresight --ref main -f tag=v0.1.1
```

Missing, expired, and documentation-only candidates cause the coordinator to force
main CI before creating the tag. A failed build leaves no new tag. To rebuild a
failed draft, rerun all coordinator jobs: preparation reserves the next package
release and removes only the draft's old assets before both platforms rebuild.
After fixing orchestration, a fresh dispatch on reviewed main can resume the same
unpublished tag. It retains the tag's product commit and requires its verified
candidates to remain available; acceptance tools follow the new control commit.
Uploading to an existing public release from a different branch is unsupported.
See [installer acceptance](../validation/release-acceptance.md) for exact-source
verification and the explicit historical recovery audit option.


GitHub Actions must be enabled and its account spending/payment limits must allow
hosted jobs. A failure before any steps execute does not validate the build.

## Application configuration

Model weights, account tokens, databases and local environments are excluded from
the build context. No real Google account is required for CI. For a distribution
that includes its OAuth application registration, supply the application-only
configuration explicitly with `--google-client`; the wrapper mounts the file
read-only into the build container at `/run/secrets/google_client`:

```sh
tools/build_linux_sdk.sh
tools/build_linux_container.sh --google-client /path/to/google-client.json
```

This configuration is intentionally copied into the distributed app so every
desktop user can read it. It is not an account token. The packager rejects a
tokens/profile file, verifies the bundle manifest, and refuses escaping symlinks.
CI supplies the Google application registration through
`FORESIGHT_GOOGLE_CLIENT_JSON` and requires it for main release candidates with
`REQUIRE_GOOGLE_CLIENT`. Browser sign-in uses that bundled configuration.

The project uses the [MIT license](../../LICENSE), and
`packaging/metadata.json` records the SPDX identifier `MIT`. Packages include the
project license and the notices for bundled third-party dependencies. Model terms
are separate from the application license.

References: [GitHub Actions artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts),
[Debian shared-library policy](https://www.debian.org/doc/debian-policy/ch-sharedlibs.html),
[RPM spec format](https://rpm.org/docs/6.0.x/manual/spec.html),
[Arch PKGBUILD](https://man.archlinux.org/man/PKGBUILD.5.en).

## Published installer acceptance

[Release acceptance](../validation/release-acceptance.md) downloads the published packages and validates native installation, ordinary-user
startup, real model workflows and saved-data persistence across reinstall.
Hardware and normal desktop/Finder checks remain separate manual gates.

## Reviewed Ubuntu archive snapshot

Ubuntu SDK and application build images pass the reviewed `UBUNTU_SNAPSHOT`
build argument to every apt transaction. The value is recorded in
`tools/pins.json`, the image label `org.openforesight.ubuntu-snapshot`, bundle
manifest and installer `.build.json` provenance. Ubuntu 24.04 apt supports dated
archive selection through `--snapshot`; changing base-image digests alone does
not choose newer archive packages.

The monthly dependency schedule proposes a draft snapshot update PR. Review and
merge it after dependency, package and integration checks pass; it does not write
to main or silently republish an existing identity from the live archive.
Debian, Fedora and Arch acceptance images deliberately install current distribution
packages so compatibility checks can find changes on those supported systems.

Dependabot updates Python requirement inputs weekly. Regenerate hash-pinned
locks with the Python 3.13 commands in CONTRIBUTING before merging those updates.
