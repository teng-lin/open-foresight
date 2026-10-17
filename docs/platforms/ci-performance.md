# CI dependencies, checks, and release promotion

Dependency compilation belongs to `ci-dependencies.yml`, separate from
`macos.yml` application checks. A changed application must still pass all native,
core, service, Flutter, bundle, and ABI gates. This changes reuse and scheduling,
not the application test requirements.

## What is reused

| Output | Identity | Storage |
| --- | --- | --- |
| macOS static SDK | SDK builder and its pinned sources/flags | Actions artifact, 90 days |
| macOS Python/LiteRT/Whisper prefix | runtime builders, lock and patches | Actions artifact, 90 days |
| Linux core | core Dockerfile, CMake hook, Python locks | GHCR image by digest |
| Linux LiteRT | its Dockerfile, builder, patch, core identity | GHCR image by digest |
| Linux Whisper | its Dockerfile, builder, core identity | GHCR image by digest |
| Linux assembled SDK | assembly Dockerfile and all component identities | GHCR image by digest |
| Tested macOS/Linux applications | exact successful main commit | Actions artifact, 30 days |

The producer runs when dependency inputs change on main or a same-repository
PR, on manual dispatch, and monthly to refresh expiring artifacts. Fork PRs do
not get a publishing producer. Dependency jobs have their own concurrency groups
with cancellation disabled. Application/docs pushes cannot cancel compilation.
Linux LiteRT and Whisper run in separate jobs after core, then assembly copies
their outputs. Registry layer caches are separate per component. A LiteRT recipe
change leaves the core and Whisper identities intact. The initial migration to
these new component identities may require one Linux bootstrap; subsequent
unchanged recipes reuse the image. macOS producers can bootstrap from existing
exact main/PR caches.

Consumers verify the artifact's repository, workflow path, event, completed
producer job, identity and archive checksum. Shared dependencies come from main
or source commits reachable from main. A dependency PR may also consume its own
completed producer; another unmerged PR cannot. An explicit manual build can be
consumed by that same source head. Merged dependency PR outputs can be reused
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
or Linux build runners. Code changes run both platform gates; main also builds
the complete Linux portable candidate. The aggregate rejects failures,
cancellations, and unexpectedly skipped selected jobs. If branch protection is
introduced, require `platform-checks`; individual platform jobs intentionally
skip on documentation changes. Classification errors fail that check.

Flutter is cached by pinned version/platform and its git revision is verified.
Pub dependencies are cached by lockfile. Native/test gates retain the existing
parallel core/desktop execution.

Before publishing a release, finish successful main CI for the exact tag commit.
It archives the tested macOS application and the Linux portable bundle. macOS
release CI verifies the promoted app, runs the existing real-model and cloud
acceptance, then makes the DMG. Linux release CI wraps the promoted tarball and
runs the distro installation/lifecycle matrix. No release job compiles an SDK
or application. Final downloaded-installer acceptance runs separately in `release-acceptance.yml`.
Main candidates require the bundled Google application registration; macOS
promotion also verifies the registration and browser invitation without an account.
Rotated distribution settings require a fresh main candidate; release promotion
does not silently change its bundled configuration.

Do not publish from a docs-only commit without creating candidates: manually run
`macos.yml` on main at that commit first. `workflow_dispatch` forces full checks.
If a candidate expired, rerun main checks for that commit before releasing.
Old tags whose committed workflows predate this change retain their old build
behavior; this does not rewrite or retag v0.1.0.

## Recovery

For missing dependencies, inspect or run **Reusable CI dependencies** on main
(or the dependency PR). Consumers wait a bounded time and fail clearly if the
qualified producer is unavailable; they do not fall back to compilation.
A registry digest deleted after qualification is also an error. Restore the
producer output deliberately. Authentication/network errors must be fixed
rather than treated as cache misses. Before a cold registry build, a tiny image
publication checks write permission, avoiding a long compile that cannot publish.

For a local SDK build, run `tools/build_linux_sdk.sh` on an x86-64 Docker host.
It builds the same four recipes, sequentially for a single local builder. The
hosted producer parallelizes the independent components. Using emulation on an
ARM host does not qualify x86-64 runtime support.

Local validation after merging current main: 198 offline Python tests passed (10 skipped),
workflow actionlint passed, all embedded Python/shell blocks parsed, and the real
macOS SDK/runtime prefixes survived archive extraction and verification at new
paths. The local ARM Mac does not qualify the x86-64 container builds.

No hosted speedup is claimed until comparable successful runs finish. Artifact
transfer, runner queues, apt/base-image changes and first-time compilation still
cost time. The existing timing evidence below predates this redesign.

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
tests, and the release build in order. Default developer and Linux builds retain
the sequential path; both paths call the same gate script.

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

Local validation on the development Mac: native CTest 13/13; parallel core
coverage run 642 passed / 8 skipped, desktop run 107 passed / 10 skipped; both
AOT executables and the Flutter macOS release app built. The overlapping groups
completed in 83.6 seconds. Subsequent service integration passed 14 tests with
one opt-in native desktop integration skip. Offline Python validation passed
159 tests with 10 skipped and 86 subtests, including process-level concurrency,
failure propagation and partial-launch cleanup checks. These local timings do
not predict GitHub runner timing or establish a hosted speedup.
