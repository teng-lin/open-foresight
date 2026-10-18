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
built. A trusted completed artifact is used when available. Otherwise macOS
builds its pinned SDK and runtime sources locally; Linux has the corresponding
local SDK fallback. Fork PRs validate locally rather than publishing artifacts
with repository credentials. Same-repository PRs normally reuse their qualified
producer artifacts. Source fallback preserves the artifact trust policy.

Component identities include the recipes, producing workflow and producing
tools, plus parent identities. Promotion accepts a PR artifact only from its
merged final head; intermediate commits are rebuilt on main. Consumers verify
repository, workflow, event, successful producer job, ZIP digest, component
identity and archive contents before installing a prefix.

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
its command-registry guard reads that source tree. Documentation edits do not
invalidate application stages. Main, release and scheduled validation run fresh.

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
and installed document parsing. Those installation checks remain necessary for
application or packaging changes, but no longer compile a duplicate application.
The disposable installer-test container permits the nested parser sandbox to create namespaces and grants `NET_ADMIN` so bubblewrap can initialize its private loopback interface; the actual
parser sandbox is still required and checked. Release package publication retains
its separate main-only workflow and credentials.

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
