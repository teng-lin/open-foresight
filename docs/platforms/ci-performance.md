# CI dependencies and release promotion

CI uses content-addressed, verified dependency artifacts and exact-commit
application candidates. Historical benchmarks and earlier procedures are in
[the dated history](ci-performance-history-2026-10-18.md).

## Current pull request procedure

The shared `tools/ci_changes.py` classifier selects platform gates. Documentation
and explicitly listed maintenance changes avoid native builds; unknown paths
select every platform. `platform-checks` and `acceptance-checks` always report the
aggregate result, including when selected expensive jobs are skipped.

Dependency producers and macOS consumers check out the PR head. Advancing main
therefore cannot make consumers request a merge-tree identity that no producer
built. A trusted completed artifact is used when available. Consumers wait for a
compatible running producer across application-only commits instead of starting
a duplicate build. A source build is a last resort when no compatible verified
output can be obtained. Fork PRs retain local validation without publishing
artifacts with repository credentials. Follow [AGENTS.md](../../AGENTS.md):
identify the affected input or artifact problem and justify a rebuild before
triggering it. A network error or cache-key migration alone does not justify
recompilation.

Component identities include consumed recipes, source trees, relevant pins,
build settings and parent identities. Receipt handling, cache transport and
unrelated shared pins do not invalidate compiler outputs. Producer-control
qualification is checked separately from build compatibility. Consumers verify
repository, workflow, event, actual producer source, successful job and attempt,
upload times, ZIP digest, component identity and archive contents.

The reviewed SDK approval manifest preserves compatible existing artifacts
across the identity migration and stacked/rebased PRs. Each entry pins the
original run, source, artifact, receipt and checksums, and proves that its full
legacy build/control input closure equals an approved merged source. It retains
the original provenance. Only this exact verified path may create local approval
metadata for an old descriptor. Cleanup retains referenced original identities.
These entries do not authorize arbitrary intermediate PR artifacts.

## Application stages

Linux native regression and macOS validation run four separate jobs: native,
core, desktop and service. Core and desktop run in parallel after native;
service consumes the native/core binaries and all three qualification identities. `tools/build.sh --stage` uses these same
boundaries locally; its default still builds and tests the complete application.

A PR stage may reuse a completed successful result from the same PR or main.
The verifier independently checks the producing workflow, job, attempt, commit,
artifact digest and content manifest. Its key includes the complete relevant
source inventory, actual compiler/runtime/system packages, extracted SDK bytes,
validation flags, locale, timezone and UTC date, plus prerequisite identities.
Unknown paths invalidate every stage. Native code changes invalidate all four;
core changes invalidate core, desktop and service; desktop tests/assets affect
only desktop and service. Desktop library changes also invalidate core because
its command-registry guard reads that source tree. Dart test-support changes
invalidate their consuming Dart stages, without invalidating native compilation.
Documentation edits do not invalidate application stages. Main, release and
scheduled validation run fresh.

A native validation miss can restore compatible compilation work from a
successful producer while rerunning configure, build and CTest. This is separate
from reusing a passed test result: the compiler, SDK, system packages and build
settings must match, while a new validation date or changed test still requires
fresh tests. Changed source bytes rebuild even when checkout timestamps are old;
unchanged native/dependency objects retain their exact output timestamps.
The host kernel string and whole pins record do not discard compiler work;
tracked pin changes refresh CMake configuration values and rebuild affected
targets. Validation reuse still checks the full environment.

Native jobs publish a small receipt beside the full object archive. Warm lookup
verifies its producer and environment before downloading objects, then requires
the downloaded payload's receipt and checksums to match. Legacy archives without
sidecars permit three full candidate transfers; an incomplete search then fails
with the next artifact identified, instead of authorizing a cold build while
older compatible work may remain. API/protocol failures also abort the lookup.
Failed producer jobs are not accepted as validated cache results.

The native key describes the implementation and validation inputs, rather than
including the source commit in every compiled object. On a native hit, CMake
always regenerates and relinks the small helper build-identity unit, then the
runner checks the actual helper's `--build-id` against the current version and
commit. Native process identity checks run again. Binary archives have their own
SHA256 and exact-source receipt; downstream consumers validate both before
unpacking. Unchanged source timestamps are restored only after their file hashes
match, allowing Ninja to retain valid object files. Distribution stamping makes
the input tree derived, so those results are not reusable as clean PR results.

Ubuntu package lifecycle and model/audio acceptance share one application image
and build. The package job extracts that exact bundle, creates the DEB and
installs it in Ubuntu 24.04 to test dependencies, file layout, service lifecycle
and installed document parsing. Documentation-only main pushes skip this work;
manual and scheduled acceptance still run. Those installation checks remain necessary for
application or packaging changes, but no longer compile a duplicate application.
The disposable installer-test container explicitly selects the CI AppArmor
profile that permits user namespaces; generic `apparmor=unconfined` still receives
Ubuntu user-namespace capability restrictions. The same disposable containers
use Docker's `--security-opt systempaths=unconfined`: Docker's default masked and
read-only `/proc` child mounts prevent an ordinary user's nested `proc` mount.
Linux rejects such mounts when they could reveal paths hidden by locked inherited
mounts. This setting removes those outer system-path masks; it grants no extra
capabilities. It applies only to these package-test containers, never to installed
applications or host sysctls. The existing named AppArmor profile, seccomp setting
and `NET_ADMIN` for isolated loopback remain necessary independently.
See the [Docker option documentation](https://docs.docker.com/reference/cli/docker/container/run/#security-configuration),
[Docker CLI implementation](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/opts.go#L954-L973),
[default system-path masks](https://github.com/moby/moby/blob/v27.5.1/oci/defaults.go#L104-L124),
and [Linux mount visibility check](https://github.com/torvalds/linux/blob/v6.8/fs/namespace.c#L5272-L5357).
An ordinary-user bubblewrap probe exercises `--proc /proc` before expensive
installer prerequisites and stops immediately on failure. The actual parser
retains its restricted mount layout, isolated namespaces and dropped capabilities;
installed PDF/RTF parsing remains required. Release package publication retains its
separate main-only workflow and credentials.

Only the native job fetches and hashes the macOS compiler SDK. Native cache
archives retain object files and dependency sources for incremental rebuilds;
Dart/Flutter/service/package jobs download a separate slim native runtime archive
containing executable products and SDK license/provenance files. They do not
transfer compiler objects or a compiler SDK. Each archive has its own SHA256 and
content manifest, bound to the same native qualification identity. The service
job waits for desktop success and includes its identity, but omits the unused
Release application: its Flutter integration test builds a separate Debug target.
Linux's fast Flutter integration checks run in the desktop job, allowing native
setup to omit Dart and Flutter. Role-specific setup avoids unnecessary package
resolution and CocoaPods installation.

Stage payloads retain native test outputs, language logs and available coverage.
Core and desktop diagnostics also upload coverage separately. These jobs preserve
the existing required aggregate checks: missing or failed selected stages cannot
produce a successful platform or acceptance result.

## Distribution candidates and previews

Ubuntu application builds keep FlatBuffers and SentencePiece in a separate layer
before copying the application checkout. The normal native build and this layer
share `cmake/ForesightInferenceDependencies.cmake`, including its exact source pins
and options. Both use `/src/build/_deps`, so subsequent application configuration
retains dependency objects, headers and licenses. A Dart edit or new source
revision still runs the current application's build and tests.

Application cache transport uses the current Docker context's Docker driver with
the containerd image store. Provisioning happens before loading a qualified SDK
archive; a separate container driver cannot see that archive's local tag. The
fixed same-repository application cache is imported even when the SDK comes from
an approved legacy archive. Registry errors stop the job instead of silently
starting an uncached dependency build. PR acceptance reads the cache; the existing
main-only Linux bundle job exports only its secret-free `tested` stage. Packaging
stages containing distribution secrets never export caches.

CI supplies the `appdeps_seed` named context with qualified existing dependency
outputs. Their original provenance remains separate from the current build and
its test result. Local developer Docker builds retain an empty default context
and populate dependencies normally; they can provide a verified seed with
`--build-context appdeps_seed=PATH`.

Main builds allocate a monotonic distribution number and stamp that version
before building the Linux and macOS candidates. Nightly/manual previews use the
same bundle and installer paths and run installed-package validation. A release
coordinator identifies its own freshly dispatched build using a unique request
ID and pins downstream downloads to that producer run.

Release publication requires administrator-created protected tags, complete
installer provenance and installed acceptance. See
[preview packages](preview-packages.md) and
[release acceptance](../validation/release-acceptance.md).

## Monthly dependency maintenance

The monthly schedule opens a draft PR advancing the reviewed Ubuntu archive
snapshot in `tools/pins.json` and Docker build arguments. It does not silently
upgrade live apt packages or republish existing SDK identities. Review the
snapshot and resulting dependency, package and integration checks before merge.
Weekly grouped Dependabot proposals update requirement inputs; regenerate hashed
Python locks using the commands in CONTRIBUTING. Weekly OSV scans report
vulnerabilities without blocking normal publication.

Ubuntu SDK and build images record their snapshot in image labels and package
provenance. Debian, Fedora and Arch acceptance use current distribution packages
on purpose. See [Linux packaging](linux-packaging.md).

The minimal Ubuntu base bootstraps HTTPS with a dated Mozilla CA bundle fetched by BuildKit under an explicit SHA256 checksum, then installs the archive snapshot's own `ca-certificates` package. The bootstrap URL and digest are reviewed in `tools/pins.json` and guarded against the Dockerfile. TLS and apt Release-signature verification remain enabled.
