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

Other original SDK artifacts may qualify after their PR merges when immutable
Git evidence relates the producer to the approved final PR head, the consumer
computes identical component build identities, and all producer-control files
(including the dependency workflow) have identical bytes and modes. The final
head must pass the authoritative merge-tree and main-reachability proof. This
retains the original receipt, source, successful attempt and payload checksums;
it does not relabel the output as a new build. Changed build inputs or controls
require a compatibility review and preserve the artifact rather than silently
authorizing a cold compile.

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
commit. Main pushes always run current validation. Their native compilation-only
lookup can retain compatible objects from verified main or approved merged-PR
producers. For another PR, the original producer must belong to the reviewed
final PR history and its complete conservative native input inventory must equal
that final head. The existing final-source approval check also proves the final
head is on main, or that its full tree equals the authoritative rebase merge on
main. Thus a Dart-only final fix can preserve an earlier native compilation
archive without relabeling it as a final-head build. Repository, workflow,
original source/recipe, successful job attempt, environment, upload bounds and
payload digests remain independently verified. This eligibility applies only to
compiler work on main pushes, manual dispatches and schedules; successful test-result reuse remains PR-scoped, and main/release
validation always configures, incrementally builds and tests current inputs.
API or missing-source proof failures stop lookup rather than authorize a cold
build. SDK, LiteRT and Whisper artifacts retain their separate approval policy.
macOS distribution stamping
changes the native version input; its derived receipts remain ineligible until a
separately verified stamping recipe can describe those exact inputs.
Native process identity checks run again. Binary archives have their own
SHA256 and exact-source receipt; downstream consumers validate both before
unpacking. Unchanged source timestamps are restored only after their file hashes
match, allowing Ninja to retain valid object files. Distribution stamping makes
the input tree derived, so those results are not reusable as clean PR results.

Ubuntu package lifecycle and model/audio acceptance share the exact application
bundle. PR acceptance builds it once, exports it, and mounts it read-only into
an acceptance-tools image. On main, acceptance starts after a successful
`linux-bundle` producer job and downloads its verified exact-source candidate;
manual and scheduled acceptance select the newest retained verified candidate
on reviewed main without compiling an application. Historical dispatches resolve
the product source from the producer artifact, independently of its controller
commit. Acceptance checks out that original product for its Dart/Flutter test
packages while retaining the current acceptance-image recipe. The tools image installs test prerequisites but has no application
or SDK build step. The package job creates the DEB and installs it in Ubuntu
24.04 to test dependencies, layout, service lifecycle and document parsing.
Documentation-only main pushes skip this work. Those installation checks remain necessary for
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

## Instrumented SDK reuse

ASan/UBSan and TSan need separate instrumented gRPC/protobuf installations.
The sanitizer workflow first restores its existing exact scoped cache, then
looks for shared verified SDK artifacts. GitHub caches under another PR's merge
ref are not a shared artifact store. The existing cache keys and builder files
remain unchanged, preserving already running producers and their saved work.

Compiler installation uses the Arch archive for `2026/10/18` and the Ubuntu
snapshot `20261018T210000Z`. The original install commands and SDK recipes stay
unchanged. Official repository indices were checked against all 12 Arch and 65
Ubuntu compiler/ABI package versions recorded in successful run `39170861992`.
Ubuntu uses an isolated, signed snapshot source list so rolling mirrors and
third-party feeds cannot select newer toolchain packages. The separately
recorded [toolchain profiles](../../tools/sanitizer_toolchain_profiles.json) bind
the original artifacts, complete environment, compiler and runtime hashes.
Post-install checks require exact equality before restoring SDKs; their existing
semantic identities remain unchanged. GitHub's preinstalled Ubuntu runner image
can still change independently of these repositories. Such drift stops with a
specific environment mismatch and requires compatibility review; it never
authorizes an automatic SDK rebuild.

Shared identities bind the consumed recipes, compiler/runtime bytes, relevant
system ABI packages, flags and install paths. Only definitions actually imported
from the macOS SDK builder enter the sanitizer recipe: an unrelated JSON pin or
macOS build setting does not invalidate these Linux SDKs. Executable controls
are qualified separately against a reviewed source. Approved merged producers
remain eligible when the consumer changes unrelated application tools. An
intermediate PR producer needs equal recipes and controls at the approved final
head, including authoritative rebase-merge proof.

Consumers require the same repository/workflow, a successful qualifying job and
exact attempt, upload bounds, original checkout, ZIP/payload digests and file
manifest. A restored scoped cache must also identify its successful SDK build
and cache-save steps. A later application failure preserves that work; a new
successful qualifying job is still required before another PR can consume the
shared artifact. Provenance distinguishes original compilation from subsequent
qualification and publication. The initial migration pins PR #119's original
run, reviewed source and workflow bytes, and verifies the actual merge checkout
from its job log rather than relabeling it as the PR head.

A cache miss, transport error or failed qualification stops before invoking the
SDK builder. When a replacement is necessary after preserved outputs have been
assessed, dispatch the sanitizer workflow with `allow_sdk_build` and a concrete
`sdk_rebuild_reason`. This records the justification; it does not require a
separate user approval for already authorized work. The workflow never cancels
an active compatible SDK producer when another commit arrives.

## Distribution candidates and previews

Ubuntu application builds keep FlatBuffers and SentencePiece in a separate layer
before copying the application checkout. The normal native build and this layer
share `cmake/ForesightInferenceDependencies.cmake`, including its exact source pins
and options. Both use `/src/build/_deps`, so subsequent application configuration
retains dependency objects, headers and licenses. A Dart edit or new source
revision still runs the current application's build and tests. CI dry-runs the
backend after configuring both projects and refuses any planned dependency
compilation, archive creation or relinking before executing the build. A lost
object or timestamp mismatch requires investigation rather than a silent library
rebuild. Local developer builds can populate dependencies normally; CI always
sets `REQUIRE_DEPENDENCY_REUSE=1`.

The retained Ubuntu seed permits one exact CMake runtime migration for
`libarchive.so.13`, `libcurl.so.4` and `libxml2.so.2`. The immutable
[compatibility proof](../../tools/ubuntu_app_dependency_runtime_compatibility.json)
binds their original/replacement bytes, package versions and ELF symbol contracts.
These three libraries are consumed only by the unchanged CMake executable;
compiler and generated-output consumers remain excluded from this exception.
The remaining 486 consumed files must match byte for byte, and the configured
build dry-run must still prove that dependency compilation and relinking are
unnecessary.

Application cache transport uses the current Docker context's Docker driver with
the containerd image store. Provisioning happens before loading a qualified SDK
archive; a separate container driver cannot see that archive's local tag. The
fixed same-repository application caches are imported even when the SDK comes from
an approved legacy archive. Registry errors stop the job instead of silently
starting an uncached dependency build. PR acceptance reads the cache; the existing
main-only Linux bundle job exports only its secret-free `application-dependencies` stage to
`app-deps-buildcache-v1`. It never overwrites the original
`app-buildcache-x86-64` tag: that tag keeps the reviewed migration manifest and
layers referenced while both caches remain importable. Packaging
stages containing distribution secrets never export caches.

Older SDK archive receipts can name a Docker config ID while the containerd
image store addresses the imported image by its manifest or index digest. Only
the exact missing-image lookup permits a fallback. It derives eligible IDs from
the checksum-verified archive's OCI graph, verifies metadata hashes and layer
inventory, and requires a unique Linux/amd64 image bound to the original receipt.
Load output and mutable tags do not establish identity. The retained original
Linux SDK archive was checked against Docker 29's reported manifest ID before
shipping this compatibility path; no SDK recompilation is involved.

CI supplies the `appdeps_seed` named context with qualified existing dependency
outputs. Their original provenance remains separate from the current build and
its test result. Local developer Docker builds retain an empty default context
and populate dependencies normally; they can provide a verified seed with
`--build-context appdeps_seed=PATH`. A genuine dependency pin, option, compiler or
consumed-header change requires an explicit compatibility review. Update the
qualified seed and its original producer evidence when reuse is valid; otherwise
document the exact incompatible input and the affected component before running
its necessary replacement build. A missing tag or transport failure does not
authorize that build.

Main builds allocate a monotonic distribution number and stamp it before
building Linux and macOS candidates. A missing platform uses the surviving
platform's verified version and build number. An existing requested candidate
stops compilation unless an operator supplies a concrete output-affecting
`rebuild_reason`; select `platforms=linux` or `platforms=macos` for a missing
platform. Compiler recipes remain bound to the selected product source.

Release preparation only discovers and verifies candidates; it never dispatches
a build. Linux and macOS can have separate producer runs. A successful platform
job remains eligible when a sibling job fails, with its original successful
attempt, receipt, upload bounds and checksums intact. Candidates and small
identity receipts are retained for 90 days. Missing or incompatible candidates
stop with an actionable error, preserving completed outputs and active producers.

The main-only `linux-packages.yml` workflow can be dispatched with `tag=v0.1.2`,
`candidate_run=39189741345` and `format=rpm` to recover only the missing RPM.
`format=all` considers DEB, RPM and Arch independently; `macos-release.yml`
handles the DMG. These workflows use current packaging controls and original
verified application bytes from the immutable product tag. They preserve the
draft generation, retain identical verified assets, and reject conflicting
bytes instead of deleting or overwriting them. Neither workflow builds an
application, SDK, LiteRT or Whisper library.

Installer creation and validation are separate steps. Installer bytes upload
before installation tests; validation evidence uploads separately. A lifecycle
failure therefore preserves the installer and the original application candidate.
RPM contracts exercise real macro expansion and upgrade locks. Package-only PRs
run the DEB/RPM/Arch lifecycle against a verified reviewed-main application fixture,
and a tiny signed macOS fixture exercises DMG creation, mounting and execution.
These recipe contracts do not require an application or SDK build.

Nightly/manual previews use the same installer paths and validate installed
packages. A new preview label is a new embedded distribution identity, which
requires application assembly while retaining compatible dependencies. A retry
retains the original identity and restores surviving application/installer
artifacts. Standard-to-full validation consumes the original installers and
records their original producer; it does not allocate a new build number or
compile the application again. Expired or incompatible outputs stop recovery
rather than silently start a new full build. An intentional replacement requires
`force` and a concrete `rebuild_reason`.

Release acceptance can restore a prior successful aggregate with `acceptance_run`
only when its source, successful job/attempt, artifact digest and all four current
installer hashes match. New GPU evidence can be attached to those exact bytes;
missing evidence remains `manual_pending`. Changing installer bytes requires
fresh acceptance, without rebuilding the SDK or application.

Release publication requires administrator-created protected tags, complete
installer provenance and installed acceptance. See
[preview packages](preview-packages.md) and
[release acceptance](../validation/release-acceptance.md).

## Checking reuse before a push or rerun

A matching cache key proves neither that a runner can read the cache nor that
the producer is eligible. Check the actual storage scope and producer evidence
across these transitions before changing dependency jobs:

| Transition | Required evidence |
| --- | --- |
| Another commit on the same PR | The completed output is accessible; an active compatible producer is preserved. |
| A new PR after an earlier PR merged | A shared artifact or registry layer is accessible and its original source is approved. A cache under another PR's merge ref alone is insufficient. |
| Rebase or merge to main | Relevant build inputs remain compatible, original receipts stay intact, and main runs current validation. |
| An application test or upload fails | Successful dependency outputs remain saved and reusable independently of the failed operation. |
| Transport or receipt code changes | Existing bytes have a verified qualification or migration path without changing their build identity. |
| A dependency, compiler or ABI changes | Identify the exact incompatibility and rebuild only affected components after checking preserved compatible outputs. |

Exercise the external interfaces too: consult the installed CLI's supported
options, retain representative real output for parser tests, and model actual
filesystem behavior such as Ubuntu's symlinked `/etc/os-release`. Mock commands
alone cannot establish that a hosted job will reach dependency restoration.
Report separately what was proved offline and what still needs hosted execution.

Remaining efficiency limits need separate evidence before narrowing them:

- Unknown shared tools and workflow paths conservatively select all platform
  gates. Distinguishing Linux-only transport changes requires an audited input
  inventory, including the Python tests currently run by native jobs.
- Model download keys still include the complete release-model test script;
  diagnostic edits can therefore miss a compatible weight cache. Flutter/pub
  keys remain version/role/lock based. Repeated Python setup can also download
  the same locked wheels in different jobs.
- Fresh Ubuntu jobs materialize the immutable dependency seed even when a
  registry layer is reusable; its downloaded blobs are currently job-local.
- Sanitizer application jobs do not yet retain their own FlatBuffers and
  SentencePiece object trees. Their previous uploads contain test evidence and
  installed gRPC/protobuf SDKs, not those objects. Ordinary Release native
  archives use different instrumentation/build flags and cannot supply them.
  Until compatible instrumented objects are retained, these two application
  dependencies need compilation; this does not justify rebuilding the installed
  sanitizer SDK. Preserving that compiler work needs a separate verified cache.
- GitHub SDK payloads and receipts expire. New publishers request 90 days, but
  the four original Linux artifacts expire on November 1, 2026; the verifier's
  24-hour reserve makes October 31 their reuse cutoff. The three macOS originals
  expire on January 16, 2027. Verify main's Linux image promotion and descriptor
  publication before that cutoff. Promoted descriptors preserve original
  qualification history separately from their current receipt. Retain original
  bytes and evidence in verified immutable storage before expiry; finite
  retention is not durable preservation. Expiry alone does not justify
  recompiling a compatible SDK or accepting an unqualified image.

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
