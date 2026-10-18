# CI dependencies, checks, and release promotion

Dependency compilation belongs to `ci-dependencies.yml`, separate from
`macos.yml` application checks. A changed application must still pass all native,
core, service, Flutter, bundle, and ABI gates. This changes reuse and scheduling,
not the application test requirements.

## What is reused

| Output | Identity | Storage |
| --- | --- | --- |
| macOS static SDK | SDK builder and its pinned sources/flags | Actions artifact, 90 days |
| macOS native LiteRT/Whisper prefix | runtime builders, pinned wheel hashes, sources and patches | Actions artifact, 90 days |
| Linux core | core Dockerfile, CMake hook, Python locks | GHCR image by digest |
| Linux LiteRT | its Dockerfile, builder, patch, core identity | GHCR image by digest |
| Linux Whisper | its Dockerfile, builder, core identity | GHCR image by digest |
| Linux assembled SDK | assembly Dockerfile and all component identities | GHCR image by digest |
| Tested macOS/Linux applications | exact successful main commit | Actions artifact, 30 days |

The producer runs when dependency inputs change on main or a same-repository
PR, on manual dispatch, and monthly to refresh expiring artifacts. Same-repository
PRs can produce scoped macOS archives. Linux registry publication runs only on
main; PR dependency checks build the complete Linux SDK locally with read-only
credentials. Fork PRs do not get dependency producer jobs. Dependency jobs have
their own concurrency groups with cancellation disabled. Application/docs pushes cannot cancel compilation.
Linux LiteRT and Whisper run in separate jobs after core, then assembly copies
their outputs. Registry layer caches are separate per component. A LiteRT recipe
change leaves the core and Whisper identities intact. The initial migration to
these new component identities may require one Linux bootstrap; subsequent
unchanged recipes reuse the image. macOS producers can bootstrap from existing
exact main/PR caches.

The monthly Linux dependency schedule bypasses qualified descriptors and Docker
layer caches, rebuilds from digest-pinned base images, applies Ubuntu package
upgrades, and publishes a fresh immutable SDK digest. Release candidates keep the
exact digest recorded by their successful build. Update the checked-in base-image
digests deliberately when advancing the OS baseline.

Consumers verify the artifact's repository, workflow path, event, completed
producer job, identity and archive checksum. Shared dependencies come from main
or source commits reachable from main. A macOS dependency PR may also consume its
own completed producer; another unmerged PR cannot. Linux PR model acceptance
reuses a qualified shared descriptor when available and otherwise builds its SDK
locally without publishing. An explicit manual build can be consumed by that
same source head. Merged dependency PR outputs can be reused
without compiling again; squash/rebase merges may require a fresh producer if
the original source commit is no longer reachable. Application candidates require
a successful main workflow and the exact release commit. Archive extraction
rejects traversal and external links and preserves executable bits. macOS prefix
verification checks source manifests and executable/runtime capabilities without
starting a compiler. Linux consumers use an immutable digest, never a moving tag.
No distribution credentials or user configuration are added to dependency archives.

## Normal checks and release readiness

Documentation-only changes run the change/whitespace classifier, workflow lint,
version checks and stable `platform-checks` aggregate without allocating macOS
or Linux build runners. Code changes run both platform gates and a separate
Ubuntu document-import check. The Linux gate runs the offline pytest suite;
the document check requires actual PDF and RTF imports through the shipped
sandbox and retains its evidence. Main also builds the complete Linux portable
candidate. Pull requests that change the desktop, application service, or
packaging additionally build and install the Ubuntu 24.04 package. The aggregate
rejects failures,
cancellations, and unexpectedly skipped selected jobs. If branch protection is
introduced, require `platform-checks`; individual platform jobs intentionally
skip on documentation changes. Classification errors fail that check.

Flutter is cached by pinned version/platform and its git revision is verified.
Pub dependencies are cached by lockfile. Native/test gates retain the existing
parallel core/desktop execution.

Use `release.yml` on reviewed main to prepare a release. Before creating a tag,
the coordinator requires successful candidates for that exact commit: the macOS
application and Linux portable bundle. If candidates are absent, expired, or
missing after a documentation-only commit, it forces `macos.yml` on main and waits.
A failed candidate build leaves no new release tag.

Both reusable packagers check out the tag, promote those candidates into a draft,
and perform platform checks. macOS runs runtime/model/cloud checks before making
the DMG; Linux runs its native installation/lifecycle matrix. Final downloaded
installer acceptance in `release-acceptance.yml` must pass for every format before
the coordinator publishes the draft. No release job compiles an SDK or application.
The Linux package release increases for each full draft rebuild. Public release
assets cannot be overwritten; corrections require a new app version.

After an orchestration fix, dispatch the coordinator from reviewed main with the
same unpublished tag. It resumes the immutable product commit using that commit's
successful candidates; missing or expired historical candidates fail rather than
substituting a newer main build. Packagers still check out the product tag, while
orchestration and acceptance tools use the reviewed control commit. Preparation
records both commits in its job summary. Draft discovery uses authenticated release
listing, with push access to read unpublished metadata and assets.

Main candidates require the bundled Google application registration. Rotated
distribution settings require a fresh candidate; promotion does not change its
bundled configuration. Product tags are never rewritten or retagged. The v0.1.1 release supersedes the mismatched
v0.1.0 release.

## Recovery

For missing dependencies, inspect or run **Reusable CI dependencies** on main
(or the dependency PR). Consumers wait a bounded time and fail clearly if the
qualified producer is unavailable. The Linux PR model-acceptance path instead
performs a local SDK build when no qualified descriptor exists; this fallback
applies only to an ordinary cache miss, not authentication or network errors.
A registry digest deleted after qualification is also an error. Restore the
producer output deliberately. Authentication/network errors must be fixed
rather than treated as cache misses. Before a cold registry build, a tiny image
publication checks write permission, avoiding a long compile that cannot publish.

For a local SDK build, run `tools/build_linux_sdk.sh` on an x86-64 Docker host.
It builds the same four recipes, sequentially for a single local builder. The
hosted producer parallelizes the independent components. Using emulation on an
ARM host does not qualify x86-64 runtime support.

Current gate selection comes from [macos.yml](../../.github/workflows/macos.yml)
and [integration-acceptance.yml](../../.github/workflows/integration-acceptance.yml).
Native CTest, core Dart, Flutter, service/MCP and installed/model acceptance are
separate checks. Test totals change with the source revision; use each run's
retained reporter output instead of interpreting historical counts below as the
current suite size.

No hosted speedup is claimed until comparable successful runs finish. Artifact
transfer, runner queues, apt/base-image changes and first-time compilation still
cost time. The existing timing evidence below predates this redesign.

---

## Linux candidate cache and gate scheduling

The successful bundle job in [run 39044666354](https://github.com/teng-lin/open-foresight/actions/runs/39044666354/job/117430975486)
took about eleven minutes: application build/test took 373.9 seconds, while
actual bundle assembly and ABI validation took only 2.3 seconds. Exporting the
complete builder cache to Actions took another 175.1 seconds. SDK setup/pull,
archive/upload and cleanup account for most of the rest. These measurements
predate the changes below and do not establish their speedup.

Linux candidates now use the SDK image's GHCR repository for a rolling
`app-buildcache-x86-64` tag. SDK layers already exist in that repository, so
exporting the application cache no longer sends them to the separate Actions
cache service. Only the main-only `linux-bundle` job receives `packages: write`;
it must have write access to the existing SDK package. Registry permissions,
network transfers and cold application layers still cost time. Unlike Actions
caches, GHCR versions have no automatic seven-day eviction: the tag is rolling,
but untagged cache versions/blobs may need registry retention/cleanup. Keep
qualified SDK digests when cleaning up this shared repository.

The `tested` Docker target ends after native build/CTest, core and desktop
analysis/tests/builds, and service integration. It enables the existing parallel
core/desktop orchestrator, preserving failure propagation and the service
integration prerequisite.

CI exports only `tested` to the registry cache, then assembles the distribution
bundle using the same local BuildKit result. Distribution secrets are supplied
only to that second build, which refreshes packaging for every run/attempt and
still requires Google configuration and ABI validation. The completed bundle
continues through exact-commit qualification and distro installation gates.

`SOURCE_REVISION` remains the actual source commit in both the helper binary and
bundle manifest. A new commit therefore still invalidates the revision-stamped
build/test layer; this change does not promise reusing a whole application build
across documentation, packaging or source commits. `COPY . .` still includes the
full repository context. Further separation would require explicit compile/test
boundaries and provenance checks, rather than replacing the commit with a stable
content hash. The first registry cache export is also cold. Compare successful
hosted runs before claiming an overall time reduction.

Earlier local verification before the audit fixes: all workflows passed actionlint; Docker's build check passed
without warnings; 11 CI dependency/provenance tests and three process-level
parallel-gate tests passed. Packaging contracts passed on the host (five passed,
two Linux-only skips) and in a Linux GCC container (six passed, one CMake-only
skip), exercising all seven distinct contracts across those environments. A full
x86-64 SDK/application build remains a hosted-CI validation requirement.

---

## Earlier macOS timing and parallel gates

Run [39009404171](https://github.com/teng-lin/open-foresight/actions/runs/39009404171)
provides the initial measurement (before the runtime source-snapshot fix):

| Work | Observed time |
| --- | --- |
| Python tests and coverage | 14 seconds |
| Flutter installation | 39 seconds |
| Cached dependency SDK verification | under 1 second |
| Native build and CTest | about 64 seconds |
| Core analysis, coverage and service/MCP compilation | about 4 minutes |
| Desktop dependency resolution, analysis, tests and release build | about 4 minutes |
| Service integration | about 55 seconds |

That run failed early in inference runtime compilation. It does not measure a
successful cold LiteRT/Whisper build or total release packaging. Runner queue
time is separate from execution and varies with available GitHub capacity.

`FORESIGHT_PARALLEL_GATES=1` overlaps the core and desktop groups after the native
build/CTest prerequisite. macOS CI enables this within its existing runner,
without allocating additional jobs. Both gates must pass before service
integration or packaging. The core group still runs analysis, coverage, and both
AOT compilations in order. The desktop group still runs analysis, all widget
tests, and the release build in order. Default developer builds retain the sequential path; Linux candidate builds
now enable the same parallel gates; both paths call the same gate script.

Each parallel gate writes its own log under `test-results/build-gates/`. Full
logs and exit statuses are printed in separate Actions groups after each awaited
gate finishes. Failed gates cannot be masked by a passing sibling. Interrupted
or partially launched orchestration terminates only the owned process groups
and reaps the direct children. Existing CI evidence upload retains the logs.

Potential savings are the overlap of the two groups, reduced by CPU/memory
contention. No hosted speedup is claimed until a successful comparable run.
The verified SDK and inference-runtime caches remain important: parallel tests
do not remove cold compiler work or runner queues. Splitting additional macOS
jobs can increase queue pressure and artifact-transfer overhead.

Historical local validation before the later audit fixes: native CTest 13/13; parallel core
coverage run 642 passed / 8 skipped, desktop run 107 passed / 10 skipped; both
AOT executables and the Flutter macOS release app built. The overlapping groups
completed in 83.6 seconds. Subsequent service integration passed 14 tests with
one opt-in native desktop integration skip. Offline Python validation passed
159 tests with 10 skipped and 86 subtests, including process-level concurrency,
failure propagation and partial-launch cleanup checks. These local timings do
not predict GitHub runner timing or establish a hosted speedup.

Dependency publication runs only on main. Pull requests build the full Linux SDK
locally with read-only credentials and never export registry caches or images.
The monthly dependency schedule bypasses qualified descriptors and Docker layer
caches, rebuilds from digest-pinned base images, applies Ubuntu package upgrades,
and publishes a fresh immutable SDK digest. Release candidates keep the exact
digest recorded by their successful build. Update the checked-in base-image
digests deliberately when advancing the OS baseline.
