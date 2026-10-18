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
