# CI dependencies and release promotion

CI uses content-addressed, verified dependency artifacts and exact-commit
application candidates. Historical benchmarks and earlier procedures are in git
history.

## Current pull request procedure

The shared `tools/ci_changes.py` classifier selects platform gates. Documentation
and explicitly listed maintenance changes avoid native builds; unknown paths
select every platform. `platform-checks` and `acceptance-checks` always report the
aggregate result, including when selected expensive jobs are skipped.

Root `tests/test_*.py` changes and Python coverage/quality configuration run in
the unconditional Python quality job without rebuilding Ubuntu applications.
Explicit package-contract tests retain the packaging gate, and real Apple
runtime tests retain the macOS gate. Nested native, inference and service tests,
test support such as `conftest.py`, application tests, and unknown paths keep
platform validation. Mixed changes take the union; forced validation still
selects every platform.

Dependency producers and macOS consumers check out the PR head, so advancing
main cannot request an identity that no producer built. Consumers try verified
artifacts first, then wait for a same-head live producer or a trusted main
producer with the same verified component identity for at most 1,800
seconds. If none remains, they fail with the missing identity and producer;
they do not silently compile replacement SDKs. Explicit fork validation may
build pinned sources locally, without publishing shared outputs. Dependabot
never takes that fallback. Timeouts preserve the dedicated producer.

Follow [AGENTS.md](../../AGENTS.md) for artifact integrity and reuse defaults.
A content-addressed miss or expiry may cause a dedicated producer to rebuild;
justify SDK or toolchain input changes in the PR and preserve successful
dependency outputs when unrelated application checks fail.

Component identities include consumed recipes, source trees, relevant pins,
build settings and parent identities. Receipt handling, cache transport and
unrelated shared pins do not invalidate compiler outputs. Producer-control
qualification is checked separately from build compatibility. Consumers verify
repository, workflow, event, actual producer source, successful job and attempt,
upload times, ZIP digest, component identity and archive contents.

PR acceptance restores its successful application's original artifact and attempt.
If GitHub's job list still shows that exact producer as pending, the consumer
refreshes the same job ID within a bounded visibility window before deciding
whether it qualifies. Repository, source, attempt, completion, upload interval and
checksum checks remain mandatory. An acceptance failure should retry the consumer
against those saved bytes rather than rerunning the successful application or SDK
producer.

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
head must pass the authoritative merge-tree and main-reachability proof. When a
squash merge includes unrelated changes from an advanced base, SDK qualification
instead requires the authoritative merge commit to be reachable from main and
its complete component build identity and producer-control bytes/modes to equal
the approved final head's. Original-to-final equivalence remains mandatory. This
retains the original receipt, source, successful attempt and payload checksums;
it does not relabel the output as a new build. Changed build inputs or controls
require a compatibility review and preserve the artifact rather than silently
authorizing a cold compile.

SDK final approval, native compiler-work reuse and sanitizer final approval share
`tools/sdk_final_approval.py::approved_final_heads`. It checks the expected
workflow/repository and merged producer relationship before the authoritative
merged-source proof, and limits PR commit history to three 100-entry pages
(GitHub exposes at most 250 commits). Each consumer still checks its own build
and control equivalence. The exact-manifest historical SDK approval bridge
retains its separate policy and history bound. Qualification refactors do not
change SDK build identities. Only SDK callers may supply the scoped merged-input
equivalence proof; compiler-work and sanitizer callers retain the whole-tree
proof. Existing approved merged producers and exact
manifest originals keep their verified reuse paths, original receipts and bytes.

## Consumer-scoped producer trust (WS2-0)

`tools/ci_producer_trust.py` is the shared workflow/event/job allowlist for PR
application handoff, fork SDK handoff, release candidates, dependency SDKs,
sanitizer SDKs, the frozen dependency seed and installer-acceptance reuse. Caller
prefixes such as `acceptance / acceptance` are explicit. Each row records its
receipt tier; `None` means today's legacy receipts have no tier requirement.
The rows retain today's names and events. In particular, neither PR artifacts
nor preview producers qualify as release candidates, and scheduled sanitizer
runs do not qualify as SDK producers. Future producer names and tier requirements
must be introduced with their consumer's proof and negative fixtures.

Application rows are separate for artifact pulls, release preparation and PR
package fixtures; SDK registry aliases have their own dependency-producer row.
Release-only requirements can therefore tighten without affecting unrelated
consumers. Every receipt consumer enforces its row's `receipt_tier` when set;
`None` preserves the legacy schema-1 behavior. SDK approval helpers derive their
workflow identity from the same table, retaining their separate merged-source
and exact-manifest proof. These rows introduce no new producer names or events.

The table only identifies producers. Consumers retain their repository and source
policy, successful original-attempt proof, upload-window binding, receipt checks
and byte checksums. Producer controls include the table, independently of SDK
build-input fingerprints, so extracting this policy does not invalidate compiled
SDKs or authorize a rebuild. The seed row remains restricted to its original
main-push `linux-bundle` producer until a later workstream requalifies it.

This refactor changes no workflow execution or runner-minute baseline. Its direct
deletion is the duplicated SDK job allowlists; hosted savings come from subsequent
producer/consumer restructuring.

Historical final-head approval reads the producer's actual control closure.
Before this extraction, `ci_producer_trust.py` did not exist; it is conditional
only when the immutable producer controls do not reference it. A present table
is still verified and compared by bytes and Git mode. A referenced missing
table, another missing control, changed producer/final control, corrupt blob or
incomplete Git tree fails closed. SDK recipe reads remain strict. This preserves
the merged-final proof for older outputs without omitting a newer producer's
consumed table or changing any build fingerprint.

The real 2026-10-19 receipt probes qualify macOS runtime artifact `12154159175`
from run `39177548843`, successful job `117823344728`, original attempt 1. Its
producer `d5a33af49f1692665591dbf1d60e629fbc3e56ce` belongs to merged PR #110;
its build/control closure matches reviewed final head
`c8e031f02d154a676961f2d3a3712f5316940c29`. The payload's recorded digest is
`sha256:485980a96a60de46c7c496a1c9f8ef601b67f13590278d8b099fa4fd5a9b552f`.
The macOS SDK probe retains approved original `12144094861` from run
`39148967092`. These metadata/receipt probes transfer no large SDK payload and
compile nothing; subsequent downloads retain full checksum/receipt validation.

## Python validation ownership and parallel workflow lint

The unconditional Ubuntu quality job runs the complete ordinary Python suite
and remains the authoritative 95% branch-coverage gate. Native Linux and macOS
jobs run `tools/platform_python_tests.py --platform <platform>` instead of
repeating the complete suite. Its explicit inventory retains shared real
compiler/Make/Ninja, filesystem, shell, protobuf and incremental-reuse fixtures;
Linux export/packaging/extractor contracts; and macOS Mach-O, deployment target,
DMG, metadata and SDK-source guards. The macOS packaging job still runs installed
component probes with current native/service/MCP binaries available.

The inventory fails on missing assigned files and unassigned ordinary test files
with platform/tool probes or skip conditions. Files whose host probes are fully
mocked have explicit quality-only ownership and reasons. This guard is an audit
backstop for common conditions, not a proof that arbitrary Python cannot inspect
the host; review new process/tool contracts for platform ownership. Existing
CTest, Dart, desktop, service and real installed-application gates remain enabled.

Actionlint runs in an independent `workflow-lint` job, with ShellCheck required
on PATH, alongside platform setup. The existing `platform-checks` aggregate
requires that job to succeed even on editorial-only changes. Classification no
longer waits for Go/actionlint startup before releasing the platform jobs.

Previously observed duplicate Python steps consumed 90 seconds on Arch and 181
seconds on macOS. Those 271 seconds are an upper bound on removable runner time:
focused host contracts still run. Measure the new hosted jobs before claiming
an elapsed-time improvement; the workflow's parallel critical path can differ.

Linux portal protocol tests run only on Linux; portable shortcut parsing and the
macOS channel test remain outside that group.

## Measured main baseline

The earlier failed main samples are no longer the only baseline. Main
[run 39264664955](https://github.com/teng-lin/open-foresight/actions/runs/39264664955),
revision `fdac2293`, completed all 18 jobs successfully, including both current
application bundles and receipts. Its Linux job reused verified SDK producer
`39250487487` and dependency seed producer `39146018643`, reporting no dependency
compilation. The missing local SDK image was already fixed with verified
`resolve --load --discard-archive`; it does not require recompilation.

| Baseline measurement | Duration |
| --- | ---: |
| Run creation to completion | 26m 30s |
| Sum of job durations | 70.1 runner-minutes |
| Active jobs on the critical path | 24m 12s |
| macOS native, including Python | 6m 21s |
| Python tests/coverage within macOS native | 3m 42s |
| macOS core | 10m 59s |
| Core tests/coverage within that job | 9m 07s |
| macOS desktop, overlapping core | 9m 19s |
| macOS service | 4m 09s |
| macOS packaging | 2m 14s |
| Linux bundle | 12m 23s |

Initial scheduling accounted for 21 seconds; the remaining critical-path gaps
totaled 1m 57s. Job timestamps cannot separate queue time from orchestration.
Core ran 982 tests with eight skips and 91.00% coverage, above its 90% minimum.
The historical four 30-second portal failures also are not a current savings
estimate; the fixture now supplies an explicit authentication identity.

## Measure before changing validation coverage

Python jobs print their 20 slowest tests and retain JUnit timings; the full quality
job also retains coverage. Core and desktop jobs retain Dart JSON events under
`test-results/<platform>/<stage>/`, including test names, durations and skips.
Inspect these artifacts before treating overlapping platform suites as duplicates.
New core and desktop stage payloads retain these event streams byte-for-byte,
including when a verified artifact copy is saved again. On a cache hit the
reports are retained verified evidence, not fresh timing measurements. The reuse
log identifies the supplying artifact's producer; for saved copies, follow that
producer's reuse history to find the original execution. Historical verified payloads
without event streams remain usable. Missing timing data does not justify
rebuilding a compatible stage or SDK.

Fresh core and desktop executions clear their own previous event streams before
analysis. Verified restores discard only unlisted event streams from that same
platform and stage, after validating the archive, so saved copies cannot inherit
stale local timing evidence. Other diagnostics and stages remain intact.

Stage logs include `CI phase:` JSON records on stderr with `phase`, monotonic elapsed
`seconds`, and `status`. These distinguish API requests, producer qualification,
metadata lookup, artifact transfer with ZIP checksum verification, receipt
validation, archive verification/extraction and stage execution. Timings are
inclusive: parent phases contain their children, so do not add every record to
estimate job duration. Failed phases report `error` and propagate the original
failure; timing does not change reuse eligibility, retry budgets or integrity
checks. A slow or failed lookup does not authorize rebuilding dependencies.

To compare core coverage overhead on the same host, reuse the current verified
native library/helper and configured language tools, then run:

```sh
FORESIGHT_CORE_COVERAGE_BENCHMARK=1 \
  FORESIGHT_PYTHON="$PWD/.venv/bin/python" \
  ./tools/build.sh --platform linux --stage core
```

Use `--platform macos` on a Mac with its current native prerequisites. This opt-in
mode runs the complete plain suite and the complete suite with coverage. It
enforces the existing core coverage minimum (90% unless explicitly configured),
requires matching test identities and skip outcomes, and still runs the source
compiler hook regression and service/MCP compilation. Reports are retained as
`plain.events.jsonl` and `coverage.events.jsonl`. Any test, coverage or comparison
failure stops the gate. Ordinary CI does not enable the extra benchmark run.

The benchmark logs its execution order and alternates which suite runs first
using the parity of `GITHUB_RUN_NUMBER` and `GITHUB_RUN_ATTEMPT`. Consecutive runs
at the same attempt number reverse the order, as do retries of one run. Intervening
non-benchmark runs and reset attempt numbers can change which samples alternate.
These counters must contain decimal
digits, and the attempt must be positive. Local runs default to plain then
covered; set `GITHUB_RUN_NUMBER=1` to exercise covered then plain. Report names
always identify the suite, regardless of execution order. Repeat both orders on
the same revision and record runner/toolchain versions and cache warmth: order
alternation reduces systematic warm-up bias but does not remove it.
Cross-platform timings alone cannot isolate instrumentation overhead. Keep the
existing macOS coverage gate until a replacement has passed its unchanged
threshold and platform-dependent execution has been accounted for. Report PR
elapsed time separately from summed runner time; parallel jobs can dominate the
critical path even after another job becomes faster.

For a hosted comparison, the existing Platform candidates and checks manual
dispatch accepts `core_coverage_benchmark=true`, with `platforms=all`. It runs full
macOS core tests plain and covered on the same host, plus full Linux core tests
with coverage on the same source revision. The macOS coverage gate stays at 90%;
the Linux trial also checks 90%. This input defaults to false and only affects
core jobs. Normal Linux core execution stays plain, and normal macOS core stays
fully covered. Compare the retained core events and phase logs with their stage
environment records; the observed 447-second macOS versus 97-second Linux sample
mixes platform and instrumentation and cannot estimate coverage-placement savings.
The manual experiment has not been executed by this change.

## Observe model and audio selection before skipping

`tools/ci_acceptance_plan.py` records proposals in the changes job's
`acceptance-selection-observation` artifact. The report contains changed paths,
per-phase reasons, and `permits_skipping: false`. It has no job-selection outputs;
CPU model, software Vulkan and private virtual-audio steps keep their existing
conditions and all assertions. Package production and installed Ubuntu/Debian
smoke/lifecycle checks are unchanged.

The initial audited map is deliberately narrow:

| Changed input | Proposed acceptance |
| --- | --- |
| Exact CPU-model suite entry points listed in `SUITE_INPUTS` | CPU model group |
| `tools/accept_software_gpu.py` | Software Vulkan |
| Exact recording, PipeWire and meeting suite entry points in `SUITE_INPUTS` | Virtual audio group |
| Explicit editorial/standalone quality inputs | No expensive phase proposed |
| Inference, retrieval, audio, meeting, service, native, shared test support, packaging, dependencies, unknown/new inputs | All three phases |
| Missing/unreadable PR history, main completion, manual dispatch or schedule | All three phases |

Suite membership is not a claim that production dependencies are disjoint. In
particular, meeting summary depends on generation/retrieval and the shared service,
so their changes select every phase. Retain observations across representative
PRs and compare actual outcomes before broadening this map or allowing skips.
The scheduled nightly preview provides the weekly consume-only external audit.
Each night retries selection until a qualified completion receipt proves that
this UTC week's three external gates actually ran successfully. A superseded
Monday or active same-source producer therefore does not lose the whole week.
Main completion and explicit full manual validation retain all selected gates.

The older CPU-model and audio phases totaled about nine runner-minutes, with
software Vulkan roughly another minute. Those are possible future phase savings,
not end-to-end PR savings: application production, setup and package smoke still
run. The 149-second meeting and 126-second Gemma tests retain their assertions.

## Application stages

The retained legacy Arch Linux regression runs four separate jobs: native,
core, desktop and service. Core and desktop run in parallel after native;
service consumes the native/core binaries and all three qualification identities.
The required Linux build/test pair and consolidated macOS job run fresh tests
against their verified SDK and application inputs; they do not reuse test results. `tools/build.sh --stage` uses these same
boundaries locally; its default still builds and tests the complete application.

A retained legacy PR stage may reuse a completed successful result from the same PR or main.
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
older compatible work may remain. After exhausted HTTP 5xx retries while
qualifying a producer, lookup may try another retained producer, which must pass
every original provenance, successful-attempt, environment and payload check.
Other artifacts from the unavailable run do not repeat the failed lookup. Three
unavailable producers exhaust the bounded recovery search and propagate the error.
If no fully verified compatible producer is found, the original server error is
re-raised; an incomplete search never permits a cold build. Authentication and
protocol errors still abort immediately.
Failed producer jobs are not accepted as validated cache results. GitHub metadata
reads and artifact downloads retry transient server, timeout and truncated-response
failures up to three times, with two- and four-second delays. Each download retry
discards only its partial transfer, then verifies the original artifact digest.
Permission/not-found errors, integrity failures and exhausted transport retries
still propagate; they never authorize a cold dependency build.

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
Unresolved API or missing-source proof failures stop lookup rather than authorize a cold
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
bundle from the successful in-run `linux-build` producer. Independent
`acceptance-cpu`, `acceptance-audio` and `acceptance-deb` jobs verify the repository,
workflow, source, successful original job attempt, upload bounds, ZIP and payload
checksums, and distribution metadata before mounting the application read-only.
Rerunning failed acceptance jobs retains that original producer and never compiles
or relabels it. Fork-local verified SDK artifacts remain scoped to their PR; they
never enter the main SDK or release-candidate pools. DEB acceptance skips the SDK
download because its package lifecycle checks use only the portable application.
Pinned snapshot package setup retries transient failures, requires a complete
index update, and preserves downloaded work between attempts. On main,
acceptance starts after a successful
`linux-bundle` producer job and downloads its verified exact-source candidate;
nightly acceptance uses its same-run, separately labelled preview bundle.
The tools image installs test prerequisites without building an application or
SDK. DEB acceptance creates and installs the package in Ubuntu 24.04 to check
dependencies, layout, service lifecycle and document parsing.

The main `linux-bundle` job loads the verified SDK into its shared Docker daemon
before inspecting it to qualify existing dependency objects. Resolving a registry
descriptor alone does not load an image; failed inspection must never authorize
recompiling the SDK or dependencies.

Acceptance tooling has its own `acceptance-tools-buildcache-v1` registry cache.
The dedicated reviewed-main `publish-caches` job and the main-only
`linux-cache-publish.yml` workflow can publish it. PR and acceptance consumers
have read-only registry access. Its dependency stage binds
the immutable SDK, snapshot package recipe, Flutter verification and all local
package manifests/lockfiles. Sources are copied afterward, so ordinary source or
test edits reuse package setup and dependency downloads. Registry authentication,
transport and malformed-manifest failures stop lookup rather than silently
discarding reusable layers. The legacy application cache remains imported and
unchanged. Before the first main publication, a confirmed missing tools cache
requires only acceptance package/tool setup using the existing verified SDK.
There is no SDK or application build in that stage. Exercise the layer boundary
locally with `FORESIGHT_DOCKER_CACHE_TEST=1 python -m pytest
tests/test_acceptance_image_cache.py`; it uses a cached Ubuntu base, fake external
tools, and a disabled build network, and never compiles real dependencies.
Cleanup retains the tools cache and its child manifests. Historical product
overrides keep their original recipes and cannot replace current shared caches.
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
starting an uncached dependency build. PR acceptance reads the cache. The
dedicated main-only `linux-cache-publish.yml` workflow and `publish-caches` job
export the secret-free `application-dependencies` stage to `app-deps-buildcache-v1`. They never overwrite the original
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

Recover transient external failures by retrying failed jobs in the original
`release.yml` coordinator, retaining successful sibling formats and original
candidate, receipt, upload-attempt and attestation bindings. The retry executes
its original workflow/tooling revision; a merged tooling fix cannot repair that
historical code. Standalone packaging dispatches and fresh partial coordinators
do not replace missing publication proof. Publication-only re-verifies an
existing qualified evidence index without building or packaging. If the original
code cannot produce that index, hold publication for reviewed recovery and
preserve installers, logs and provenance; do not delete successful formats or
rebuild accepted bytes. See [release recovery](../../RELEASING.md#recover-from-a-failed-run).

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
[preview installers](#preview-installers) and
[release acceptance](../validation/release-acceptance.md).

## Preview installers

The **Preview packages** workflow builds installers for testing before an official
release. It never creates a release or a release tag. Its final artifact contains:

- macOS 15+ Apple Silicon `.dmg` (currently ad-hoc signed, like the existing release pipeline).
- Linux x86-64 `.deb`, `.rpm`, Arch `.pkg.tar.zst`, and portable `.tar.gz`.
- SHA-256 sidecars, installer provenance and a root `preview.json` manifest.

### Running it

After the workflow is merged onto main, use **Actions → Preview packages → Run
workflow**, select **main**, then choose:

| Input | Behavior |
| --- | --- |
| `validation: standard` | Full source/build gates, package integrity, install/startup, service/MCP, reinstall/removal and user-data preservation checks |
| `validation: full` | Standard checks plus installed inference/speech model acceptance and live cloud checks against bundled distribution configuration |
| `force: false` | Skip after green `nightly-checks`, or retry failed jobs once in the original producer run |
| `force: true` with `rebuild_reason` | Explicitly replace the preview identity for a concrete output-affecting change |
| `exercise_failure_path` / `exercise_recovery` | Open/close the isolated exercise issue without building or publishing |

Validation is selected when a new preview is created; original-run retries keep
that validation mode and distribution identity. Cross-run recovery/revalidation
is removed. An unchanged green nightly is skipped even if a later dispatch
requests a different mode; the summary names the earlier run. Missing
cloud configuration fails full validation; it is not treated as a pass. Standard
Linux smoke checks retain the existing small Whisper fixture, but do not run the
full inference/embedding/cloud acceptance suite. Physical-device audio, GPU,
Gatekeeper/quarantine, notarization and fresh-account checks are not established
by either automated mode.

From the CLI:

```sh
gh workflow run preview-packages.yml --ref main -f validation=standard
gh workflow run preview-packages.yml --ref main -f validation=full
# Retry only failed jobs in their original run; keep successful builds:
gh run rerun REPLACE_WITH_PREVIEW_RUN_ID --failed
# Exercise tracking without building or publishing:
gh workflow run preview-packages.yml --ref main -f exercise_failure_path=true
```

The nightly schedule checks main at **07:23 UTC**. It builds only if that exact
commit has no green `nightly-checks`. A failed aggregate triggers one retry of the
original producer's failed jobs and exits without waiting; that original run's
aggregate and issue job report the result. Pre-rollout runs without the aggregate
cannot authorize a skip or automatic retry. Exhausted retries fail with an
actionable diagnostic, preserving compatible SDKs and successful jobs.
Application intermediates expire after 14 days; final installer downloads are
retained for 90 days. An intentional new identity requires `force` and a concrete
output-affecting `rebuild_reason`. The schedule is best effort and can be delayed
by GitHub; manual dispatch remains available.

Only reviewed main is supported by the preview coordinator. It freezes one SHA
before starting either platform and fails if main advanced before planning. Main
may continue advancing after that point: all build and packaging jobs keep using
the frozen source. Branch/fork builds do not receive a preview publication path.

### Downloads and acceptance

Open the workflow summary and follow the **tested preview installers** download
link. The final artifact is named
`Open-Foresight-VERSION-nightly.DATE.BUILD-SOURCE_SHA`. It is created only after all
platform builds, package formats and selected acceptance jobs succeed. Individual
`preview-*` and `tested-preview-*` artifacts are intermediate job inputs/outputs;
the combined final artifact and `preview.json` are the certified download set.
Acceptance evidence is retained for 30 days.

`preview.json` records the source, target version, numeric build number, nightly
label, validation level, workflow URL and every output file's checksum. Standard
builds explicitly record full model/cloud acceptance as **not_run**. All five
installer formats must have the same source/build number and expected preview
version before the combined artifact can be produced.

### Versions and build numbers

The preview targets the checked-in version when it is newer than the latest
stable release. Otherwise it targets the next patch after the latest stable.
For example, source `0.1.1` after stable `v0.1.1` produces `0.1.2` previews; source
`0.2.0` after that release produces `0.2.0` previews. This does not commit a source
version bump or create a tag.

For target `0.1.2`, date `20261018`, build `12`:

| Format | Version |
| --- | --- |
| App/DMG | Marketing version `0.1.2`, numeric bundle build `12`; Settings displays `nightly.20261018.12` |
| Debian | `0.1.2~nightly.20261018.12-1` |
| RPM | Version `0.1.2~nightly.20261018.12`, release `1` |
| Arch | Version `0.1.2`, package release `0.12` |
| Portable archive | `0.1.2~nightly.20261018.12-1` in the filename/provenance |

Native package-manager comparators check preview ordering before packaging. All
previews sort below the intended stable package (`0.1.2-1` in this example).
Arch uses a numeric package release because its `pkgver` rules differ from
Debian/RPM tilde versions.

Normal main application candidates and previews share a compare-and-swap build
counter on the managed **`ci/build-sequence`** branch. Do not delete/reset that
branch. Allocation respects the checked-in build number as a lower bound and
never force-pushes the counter; concurrent allocators retry conflicting updates.
A failed build can leave a gap, which is expected. Both platforms receive the
same number. Local developer builds still use the checked-in pubspec number.

Identity is stamped into the build checkout before analysis, compilation and
testing. A generated `.distribution-build.json` and derived Dart constant carry
the label; they are not committed. A preview therefore reuses dependency SDKs,
but does **not** relabel an already tested stable application candidate.

### Relationship to official releases

Preview uses its own `preview-packages` concurrency group. Official release
workflows serialize through `distribution-packages`, while the
compare-and-swap allocator protects build numbers. A release can start while a
nightly runs.
Official release preparation discovers existing exact-product candidates and
does not dispatch a build. Each platform retains its original successful producer
run; source, version and distribution identity must match across the pair. A
missing platform uses the surviving build number. Both packagers use current
controls with those original application bytes. Unsupported or incompatible
historical inputs fail without substituting newer source or publishing a release.

Packaging code is shared: both channels use the Linux native package/lifecycle
scripts and `tools/create_dmg.py`. Standard and full previews contain the same
features/configuration; the validation level only changes acceptance depth.
Preview artifacts have separate names from `ci-macos-app-*` and `ci-linux-app-*`,
and cannot satisfy stable candidate discovery. Official releases retain their
existing mandatory model/cloud and downloaded-installer acceptance gates.

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
| Transport or receipt code changes | Existing bytes may be reused only through verified qualification; expiry or a key change may cause one rebuild without a migration bridge. |
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

### WS-P policy adoption (2026-10-19)

The [restructuring plan](../plans/2026-10-19-ci-restructure-plan.md) keeps repository, source, input identity, original producer attempt, upload-window and checksum checks mandatory. Cost rules are defaults; dedicated producers stay non-cancelling and normal producer waits are bounded at 30 minutes. Main-only publication and removal of stage-result reuse roll out with WS2b/WS2c; the current guarded workflows remain during that transition. This documentation change modifies no SDK input and compiles nothing. Runtime measurements remain at the plan baseline until implementation lands.

## WS0: measured baseline and inventory follow-ups

The restructuring baseline is the configuration after #148, main `b62e5e02`,
measured from runs since 2026-10-19 13:57 UTC. These are historical observations,
not forecasts or results of the follow-ups:

| Measure | Baseline |
| --- | ---: |
| App PR final push to green, p50 (6 pushes) | 36.9 min |
| All green PR commits, p50 / p90 (11 pushes) | 37.2 / 56.6 min |
| Runner-minutes per app PR push, p50 (20 pushes) | 85 |
| macOS minutes per app PR push, p50 (range) | 31.6 (27–44) |
| macOS jobs per app PR push | 6 |
| Time at the five-macOS-job cap | 59 / 264 min (22%) |
| Main minutes per identical-tree merge | 84–91 |
| Acceptance chain floor | 29.5 min |
| Main acceptance history | 6/6 accepted; `88cf883e` red and untracked |

`tools/ci_stats.py SNAPSHOT_DIRECTORY` reports JSON for each PR push and merged
PR, plus percentile and mean summaries. Capture REST runs into `runs.jsonl`,
all-attempt job records into `jobs/<run-id>.jsonl`, PR metadata into `prs.json`,
and resolved Git trees into `trees.txt` (`SHA TREE [PARENTS]`). PR metadata needs
`number`, `state`, `headRefName`, `headRefOid`, `mergedAt`, and `mergeCommit.oid`.
For merged PRs whose REST run association is empty, only an unambiguous branch
name in that snapshot may restore attribution. Reused ambiguous branch names are
left unassigned. Closed unmerged PRs are excluded from push-to-green samples, while their
runner-minute costs remain in the per-push accounting.
Every required check must succeed; missing or skipped required checks never count
as green. First workflow creation approximates push time, including queue delay.

For `workflow_run` acceptance, save its actual candidate-selection log as
`logs/<run-id>.txt`. The parser reads the logged source JSON or `source=SHA`;
it does not equate the workflow's own `head_sha` with the candidate it tested.
Missing or conflicting candidate evidence is reported as unattributed. Missing
merge runs and missing tree identities remain explicit unknowns, never zero-cost
merges. Historical repeated successful jobs are counted once across attempts.
Per-merge cost includes direct main pushes and the known
`integration-acceptance.yml` `workflow_run` chain with a logged candidate source.
Scheduled drift, nightly, release and cache-publish dispatch work is reported
separately in `non_merge_runs` and `non_merge_runner_minutes`, even when it shares
a merge SHA. Each excluded run records its workflow, event, minutes and reason.
Unsupported downstream workflows and missing source evidence also stay explicit.
Dispatches are not identified as main sweeps from their display title: these
snapshots do not contain the selection receipts required to prove sweep identity.
WS5a must add verified sweep evidence before those dispatch costs enter the
per-merge KPI. A shared commit SHA alone never proves that a merge caused a run.
Use a snapshot bounded to the measurement window and `--current-since TIMESTAMP`
to distinguish shapes observed in the current configuration from older shapes
not observed since that cutoff. A shape's absence is an observation, not proof
that its workflow was deleted. The mixed Oct 16–19 snapshot cannot reproduce the
current-configuration baseline without filtering and candidate log evidence.

`tools/ci_stats.py --lines` counts physical code lines, excluding blanks,
comments, and Python docstrings, without Git metadata. It inventories workflows,
`tools/ci_*`, `tests/test_ci_*`, and its explicit set of historically named CI
helpers and their tests. The same inventory must be used for the final deletion
comparison; the frozen pre-WS0 file counts are in
[ci-restructure-baseline.json](ci-restructure-baseline.json).

The host runner now reads its fresh JUnit report and fails if any assigned file
is absent or wholly skipped. `test_rpm_scriptlets.py` runs with `rpmspec` in the
Fedora contract. The opt-in BuildKit fixture runs enabled in Ubuntu acceptance,
after the pinned Ubuntu base is already present; it compiles no SDK or vendor
code. `test_litert_identity.py` belongs to the existing `native_litert_identity`
CTest target rather than an ordinary pytest invocation that always skips it.
The pinned sentencepiece wheel activates the legacy executor's ordinary math
contracts on both hosts; authenticated original-model cases retain their
existing opt-in requirement. These changes preserve the PR suites.

The sentencepiece lock addition changes the assembled Linux SDK image because
that image installs the development lock. Its core, LiteRT and Whisper build
inputs are unchanged: reuse those verified component images, and only assemble
the new SDK layer that installs the additional wheel. No vendor library needs
recompilation for this Python contract dependency.

The scheduled preview selects a consume-only external audit until the current
UTC week has a verified completion. PR selection resolves the merge
base before calling the common classifier, which is equivalent to diffing
`base...HEAD` and avoids selecting changes introduced only by advancing main.
At least five hosted follow-up runs are still needed before claiming measured
latency or runner-minute savings; no after-value is claimed from local tests.

### WS-Na nightly safety net (2026-10-19)

`nightly-checks` requires the current run's selected platform suites, installer lifecycle jobs and final download artifact to succeed. It explicitly excludes the separate main model/audio acceptance until WS2b moves those gates in-run. Unchanged main skips only after a successful `nightly-checks`; a failed producer retries only its failed jobs once, preserving the original run and successful outputs, then returns without waiting. Planning-only triggers cannot recursively retry an exhausted producer.

`ci-nightly` issues track failing jobs, the range since the last green aggregate and PRs in that range. Older reruns cannot overwrite or close newer results. Dispatch `exercise_failure_path: true` to fail without reserving a build number, building or publishing; `exercise_recovery: true` closes the separate `ci-nightly-exercise` issue. Exercise runs are excluded from real-night selection and retry. The preview group is `preview-packages`; official releases retain workflow-level serialization in a separate group, allowing release preparation to start while a nightly is active without letting a queued draft displace an older publication.

Deleted: cross-run preview recovery/revalidation jobs, `preview_reuse.py` and obsolete recovery-only tests. Retry uploads replace only their original run's own artifacts. No SDK recipe or compiled dependency input changes. Offline contract tests cover green/skip/failure evidence, original-run retry, pagination, stale results and isolated issue open/update/close. Hosted exercises, a real failed-job retry, two consecutive green nights and release/nightly concurrency still need proof; no latency savings are claimed before the five-run measurement gate.

### WS-Nb daily drift safety net (2026-10-19)

Sanitizers run daily even when main is unchanged. Scheduled jobs restore and
verify existing instrumented SDKs; they skip the SDK build, cache save, SDK pack
and SDK upload steps. A missing verified SDK fails with the existing restoration
diagnostic and cannot authorize compilation. The verifier continues rejecting
scheduled runs as producers. Push and explicit dispatch producer paths remain
non-cancelling, in concurrency groups separate from scheduled consumers. TSan
probation remains available for PRs and explicit runs, while scheduled races fail
the job. The issue tracker reads actual job conclusions in every case.

`arch-drift.yml` runs the full `tools/build.sh` gate and Linux host Python
contracts daily in the pinned Arch container, with its rolling pacman toolchain
list inlined. It records the compiler and complete package inventory before the
build, restores existing compatible Flutter/pub caches and verifies Flutter's
exact commit. It uses Arch's installed gRPC/protobuf and never builds an SDK.
Before the Arch application build, `ci_native_work.py` searches retained verified
native-stage compiler payloads, including FlatBuffers/SentencePiece outputs.
It qualifies the exact compiler, complete package inventory, absolute workspace,
CMake arguments and native flags; Mac callers additionally bind SDK bytes/prefix,
Xcode and Apple SDK. Ubuntu objects cannot substitute for different Arch inputs.
The original successful producer receipt and checksums stay authoritative.
Only proven Dart coverage/scheduling controls and report/SDK locators are excluded
from compiler compatibility; successful stage identities still bind those
validation settings. Unknown flags and native hooks remain strict. Search/API
failures stop the job, while a completed miss records actual incompatible fields.
Changed CMake inputs remove only the old CMake cache, retaining objects and
fetched dependencies. Every hit still runs current configure/build/CTest and all
application gates; neither old test success nor a new cache publication is used. Before a manual hosted probe, inspect existing
verified artifacts and identify any actual toolchain/input drift or missing
compatible work. This workflow neither deletes dependency caches nor publishes
compiler outputs. Its temporary PR trigger selects only its own workflow path;
remove that trigger after the rollout probe passes.

Main-ref-only final jobs open/update `ci-sanitizers` and `ci-arch-drift` issues on
failure and close them on a passing run. Missing or skipped suites fail closed;
older reruns cannot overwrite newer results. No PR job receives an issue-write
token. Contract fixtures cover these paths, the schedule's read-only SDK policy,
the unchanged recipe/cache keys and the Arch toolchain/gate inventory. Hosted
scheduled SDK restoration and the Arch runtime gate still require proof before
removing any existing PR checks. These jobs add independent drift coverage;
runner-minute savings remain unclaimed until measured over five hosted runs.

### WS1 explicit fork-local validation

Ordinary macOS consumers now fail with the missing identity and producer when
neither a same-head producer nor a compatible trusted main producer remains,
instead of silently compiling dependencies. An application-only head can thus
retain main's earlier dependency producer without waiting for another PR.
Fork PR validation may explicitly pass `--allow-local-build`; both compiler-SDK
and runtime steps derive that flag from nonempty head/base repository metadata
on an actual fork `pull_request` event. The explicit permission propagates to
the vendor dependency needed by a fork runtime. Dependabot never uses that local
fallback, and an exhausted wait for a still-running producer always fails.
Existing verified artifacts are attempted first in every mode. This changes no
SDK recipe, component identity or vendor input.

### WS1 quick wins (2026-10-19)

Platform `changes` publishes `ci-selection.json` and a step summary listing the
revision range, force/platform overrides, selected gates and each changed path's
contribution. Locally, run `python tools/ci_changes.py --explain origin/main...HEAD`;
it needs no GitHub environment. Unknown paths select full validation; explicit packaging files and `packaging/ci/`
retain their narrower selection. The unreachable duplicate `packaging/ci/` branch
in the Linux-only rule is removed.

Quality owns the required `contracts` job: generated Dart binding drift and
protobuf descriptors. The separate RPC workflow, repeated RPC Dart analysis and
subset tests are deleted; full core suites retain those Dart tests. Native
process integration remains covered by CTest, without separate repeat steps.
The macOS assembly job runs only `CompiledMacComponentTests` from the tooling
file; the host inventory owns the remaining tooling tests. The duplicate explicit
integration inventory command is removed; its quality test remains.

Superseded PR platform and acceptance runs cancel, with platform groups scoped
to the caller workflow. Main, release and preview work stays non-cancelling;
dedicated dependency producers remain non-cancelling. `ubuntu-application`
no longer deletes preinstalled toolchains. The four Linux registry producers
clean only after both the verified reuse probe and immutable-image lookup miss.
Linux compile jobs and `ubuntu-package` record `df -h / /mnt` and `docker system df`
at start and end, including failed jobs. Compile cleanup remains on cold builds;
Docker relocation to `/mnt` is reserved for measured low-space runs.

The baseline records 96 seconds median (354 seconds maximum, 36 runs) for
`ubuntu-application` cleanup, and 47–344 seconds of promotion cleanup. Removing
these steps is structurally verified, while the before/after runner-minute and
latency comparison still requires at least five completed hosted runs. No SDK
input or component identity changed in this workstream. Transport allowlisting
explicitly accounts for storage probes and conditional cleanup without making
them compilation inputs. The net change and test evidence are recorded in the PR.

Retry diagnostics now allow replacement throughout the nightly's called-workflow
closure, including development packages, document sandbox evidence and distro
installer evidence. A fixture-only BuildKit PR selects the Linux consumer that
runs its opt-in Docker proof rather than leaving that file wholly skipped.
Drift issue writers require an explicit main-ref and allowed-event guard. Their
serialized surviving invocation reconciles the newest completed actual suites;
empty, pending and cancelled suite jobs provide no result. A cancelled/replaced
issue job does not discard its run's otherwise completed test evidence, and a
stale queued writer reports the newer tests instead of assuming a replacement
writer will run.

## Ubuntu build and test handoff (WS2a origin)

`linux-build` and `linux-test` in `macos.yml` are required by the platform
aggregate in this held successor, including main and nightly calls when selected.
The former nonblocking WS2a comparison job is removed. Application registry
consumers are
read-only; the dedicated main-ref `publish-caches` job owns the three Linux
registry build caches and `integration-models-v1`. Other guarded legacy writers
remain until their planned replacements land. The build
restores the verified SDK and qualified Make dependency seed before building the
secret-free Docker `ci` target. A miss may rebuild the application test image;
unchanged SDKs and dependency objects remain verified and reused. The switch stays
local until the hosted shadow safety and measurement gates pass.

`tools/build.sh --build-only` compiles native products, service/MCP AOT and Flutter
release without running suites. `--test-only` first rejects any nonempty full
application build plan, then runs CTest and the existing Dart/service gates against
the restored outputs. Compiler, generated-file and link commands fail that guard;
Make's recursive no-work bookkeeping is retained in a diagnostic log. Dart tests
and analysis run only in the test phase; AOT/release compilation runs only in the
build phase. Linux retains both 90% coverage gates. macOS collects desktop coverage
when its gate/report configuration requests it, and the ordinary all-mode path
continues to build and test.

`tools/linux_container_build.sh` is the single in-container build/package script.
A previously materialized dependency seed is revalidated against the complete
verified producer layers, including headers, object bytes and timestamps; its
retained files are never replaced while checking reuse. The host driver
`tools/build_linux_container.sh` calls it locally and in CI through
`/workspace/tools/linux_container_build.sh`, mounting source read-only and
configuration secrets read-only outside the image. Distribution stamping happens
on the verified host checkout. Packaging retains the exact GPU runtime flags,
Google-client requirement, ABI report and tar package used by the existing builder.
Only the host's Git checkout writes the application receipt, including tier/label.
The PR handoff uses `linux-bundle-<run>-<attempt>`, never candidate lookup names.

The input identity covers the SDK image ID, dependency-seed qualification digest,
CI/dependency Docker recipe and pinned Ubuntu snapshot. A rebuilt CI image may
have another image ID; its recorded inputs must still match exactly. The handoff
archive preserves source and build bytes, modes, symlinks and nanosecond timestamps,
excluding `.git`, virtual environments, `build/_deps` and the separately uploaded
`dist` bundle/installers. The second runner keeps
its independently verified seed at that same `/src/build/_deps` path. Before any
restore or execution, API provenance checks bind the artifact to its repository,
workflow, original successful job/attempt and upload window, and verify the actual
downloaded ZIP digest. The archive checksum and complete restored manifest are
then checked. The Dart package cache lives at `/src/.pub-cache` and travels in
this manifest with the lockfiles and package configuration. Consumers pin the exact
original SDK run, artifact ID and ZIP digest selected by the build runner,
including approved original artifacts. Fork consumers first reuse that verified SDK.
Only a missing assembled SDK permits the existing component producer to use
qualified parents and read-only cache layers; missing parents or transport errors
fail without compiling those libraries. A new SDK is saved once and its verified
archive is retained for the in-run envelope; a producer reuse race preserves the
original qualification instead of relabeling bytes. That source-scoped SDK is uploaded once
for the in-run consumer, retaining any original reused receipt; its scoped trust
row cannot serve release lookup.

The comparison retains per-test pass/skip sets for CTest, core, desktop, compiled
service/MCP and host Python. Byte-identical reports forwarded with legacy stage
prerequisites are counted once; conflicting copies fail. Service/MCP requires zero skips. The `makepkg` notice probe is deselected from
host inventories and runs explicitly in the Arch installer contract. The Ubuntu
`dpkg-deb` notice probe is the one directional distro difference; other missing,
failing or changed test identities fail comparison. Native JUnit
reports travel with the legacy stage artifact so comparisons remain possible when
that existing tier restores a compatible result. Source/build archive byte counts
are printed in producer logs and retained with the manifest.

Local verification uses real Unix Makefiles and a tiny static dependency archive
across replaced runner filesystems: source timestamps keep the restored graph idle,
changed source is rejected, and dependency bytes remain unchanged. Hosted acceptance
still needs archive-SDK, fork-style and recipe-changing shadow runs, per-test outcome
comparison, and at least five runs for build/test latency and tar-size measurements.
The target is build p50 at most 7 minutes and test at most 11 minutes. No hosted
measurements or Docker runtime pass are inferred from local fixtures. The SDK recipe
projection is unchanged by this workstream; the foundation's SentencePiece Python
wheel change affects only the assembled Linux SDK Python layer, retaining all
core, LiteRT, Whisper and macOS component identities.

SDK consumer waits ignore skipped alternatives with duplicate display names.
GitHub may expose the skipped main-registry job before its PR-archive counterpart
is created after parent jobs finish. That placeholder is not proof that the
component finished. Linux application consumers use `ci_dependency_wait.py` to
share the qualified source/identity wait with macOS, capped at 1,800 seconds.
Network and provenance failures remain fatal. The foundation's consumer-only
correction preserved every SDK producer-control byte, allowing its running
producer and eventual original artifact to remain qualified without recompilation.
This shadow follow-up also corrects the internal `ci_artifacts.pull(wait>0)`
completion race: when the producer finishes or the deadline expires, it performs
one final qualified artifact read without another sleep or a fresh deadline.
Every candidate still passes the original source, successful-attempt, receipt and
checksum checks, and rejected candidates retain their qualification error. The
follow-up lands after the foundation's merged-final approval so its unchanged SDK
recipes can reuse those original verified bytes despite consumer-control edits.

### Hosted shadow diagnostics

The [D313 transport/benchmark run](https://github.com/teng-lin/open-foresight/actions/runs/39368931590)
verified the canonical SDK tag, original qualification and restored build inputs.
Its source/build archive was 106,639,256 bytes (110,482,468-byte artifact ZIP),
with all 14,675 payload entries and 1,008 tracked source entries verified.
No SDK or dependency compilation was needed. An offline diagnostic comparison of
the downloaded native, core, desktop, service and host-Python artifacts matched
the same-head Arch outcomes. The hosted comparison job was skipped; this offline
match does not replace that gate. Compiled service/MCP had 22 passes and zero
skips. The separate
[acceptance run](https://github.com/teng-lin/open-foresight/actions/runs/39368931645)
passed private virtual-audio desktop/core/meeting checks (2/1/1, zero skips).

The same-host core benchmark ran plain then covered: 220s and 191s, respectively,
with identical 1,105-pass/10-skip outcomes and 92.61% core coverage. This single
ordered observation does not establish a coverage speedup or ordinary latency.
The build job took 310s; the test job took 804s and failed its final host Docker
cache fixture because loading an SDK does not restore the base image's own
reference. It is diagnostic evidence, not a passing timing sample. The host step
now inspects the same pinned Ubuntu base and pulls it when missing, before
running the offline fixture.

Normal measurements require a new PR event with `ci:validate-sdk-transport` and
`ci:benchmark-core` removed beforehand. Rerunning an old labeled event is not an ordinary sample.
Record each fresh build/test/comparison execution by run ID, attempt and job IDs;
report a shared event explicitly when using targeted build-job retries. Exclude
failed, skipped and special executions from ordinary p50 values. Preserve the
original successful producer attempt, upload window and checksums on every retry.

The [first ordinary event](https://github.com/teng-lin/open-foresight/actions/runs/39375443052)
passed attempt 1 (build 360s, test 654s, comparison 13s). Attempt 2 built in
322s but failed a host-Python fixture: its historical SDK receipt inherited the
consumer's attempt 2 while its successful original producer job was attempt 1.
The verifier correctly rejected that mismatch. Fixture packing now supplies the
historical attempt explicitly, including the forged-receipt negative case;
regressions exercise consumer attempts 2 and 7 and still reject a wrong producer
attempt. Full-suite rerun validation also exposed the same inherited-attempt
assumption in historical sanitizer and candidate-selection fixtures; their real
packing now supplies the original attempt too. No production provenance rule
changed. The failed attempt is excluded
and the five-execution measurement must restart on the corrected source.

The subsequent `575ef4e3` measurements use run `39381008467`. These are fresh
application job executions on one PR event, with targeted build-job reruns;
they are not independent pushes or representative PR workloads. Two attempts
qualified before the pagination correction:

| Attempt | Build job (seconds) | Test job (seconds) | Comparison job (seconds) |
| --- | --- | --- | --- |
| 1 | `118489943107` (349) | `118491795737` (618) | `118495044588` (9) |
| 4 | `118508574379` (550) | `118511943647` (974) | `118517946884` (8) |

Attempt 2 failed on Ubuntu snapshot HTTP 500/502 before application tests;
attempt 3 recovered only that test job and retains the original build, so it is
excluded from fresh build timings. Attempt 5 built successfully but exhausted
three GitHub HTTP 502 responses while qualifying its producer, again before
application tests. Attempt 6 retried only the failed test with attempt 5's
successful build and failed on the same API response; it is also excluded.

The same 100-job API page still failed on inspection; 10-, 30- and 50-job pages
and the attempt-specific endpoint succeeded. Producer enumeration now uses
30-job pages with `filter=all`, retaining every original attempt and propagating
later-page errors. Receipts, successful upload attempts, upload windows and
checksums remain mandatory. The two qualified measurements above remain part of
the diagnostic record; the five-execution gate restarts on the pagination
correction's new source. No five-sample median is established by these results.


### Publish the Linux CI tooling cache before switching runners

The dedicated `linux-cache-publish.yml` workflow can populate the CI tooling
layer from reviewed main without waiting for the platform switch. It consumes
a qualified SDK and the verified historical dependency seed, then exports only
`application-dependencies`, `ci`, and `acceptance-dependencies`. It retains the
original producer provenance and never builds an SDK or publishes application
candidates. The prerequisite retained existing checks and guarded cache writers.
PR runs cannot enter this workflow or write its registry tags.

After this workflow lands on main, dispatch it with
`gh workflow run linux-cache-publish.yml --ref main`. The job checks current main
before setup and before entering publication. If main advanced, dispatch a new
run so it checks out the current SHA; rerunning the old job retains its stale SHA.
For a transient failure while that SHA is still current, read the logs and retry
only the failed job. Cache publication is a prerequisite to measure the later
runner switch, and does not establish a performance improvement by itself.

At the prerequisite stage, the retained legacy writer could replace the
acceptance cache with layers keyed on stamped manifests. This combined graph
moves those exports to `publish-caches`. Measurements must verify actual cache
reuse; publication alone does not prove a hit for every consumer.

### Combined platform and on-demand candidate rollout

This batch combines WS2b, WS2b-2, WS4 and WS5b-1 on reviewed main
`ddab4116`, the merge of PR #154, retaining its main-only cache publisher and
cleanup protection. That merge has the same tree as final head `39c7e0ad`.
Earlier reviewed main `20063921` has the same tree as PR #153's final head
`4ac0f997`. PR #153 merged the corrective shadow path; the platform switch
remains subject to the hosted gates below.

The current normal shadow series, run `39394748912` on `4ac0f997`, has three
qualified executions: attempt 1 took 348 seconds for `linux-build` and 737 seconds
for `linux-test`; attempt 2 took 456 and 834 seconds; attempt 4 took 432 and 851
seconds. Each includes successful per-test comparison, original producer and artifact qualification,
and the real host Docker fixture. These are repeated executions of one event,
not independent PR pushes. They do not establish the required five-execution
median, and all three test times exceed the 660-second target. Attempt 3 failed
on snapshot HTTP 500/502 before compilation and is excluded. Further cold
repetitions stopped before cache publication. Snapshot installation
accounts for most variation; subtracting its duration is not a measured cache hit
or a passing performance result.

The Linux test-only runner first verifies the restored no-build plan and runs
native CTest. It then runs core, desktop followed by fast tests, and host Python
contracts concurrently in separate display and temporary sessions. Compiled
service/MCP and UI checks follow after every branch succeeds. Desktop, fast and
service Flutter commands remain sequential; no branch invokes a nested parallel
runner. `FORESIGHT_LINUX_TEST_SCHEDULE=0` retains the legacy sequence. This is a
scheduling change, not measured savings. The next stable-source measurement
series records actual cache state and requires five qualified executions;
cold-source results above remain in the record.

Hosted parity, archive-SDK, fork-style and Docker-recipe exercises and the
latency/size evidence remain rollout gates. Final combined-source Mac validation
is required before every push. Local fixtures and lint do not establish those
hosted or Mac runtime results.

In this graph, `platform-checks` requires `linux-build` and `linux-test` rather
than the old native stage chain. Completion markers retain the current explicit
skipped-ancestor override and bind consumers to a normally completed producer.
CPU, audio/software-Vulkan and DEB acceptance run independently using the exact
successful in-run Linux artifact, original attempt, receipt and checksum. Main
acceptance continues to use the stamped per-merge `linux-bundle` candidate until
WS5b changes that release path. The dedicated main-only `publish-caches` job
publishes only dependency and tooling stages; PR consumers remain read-only.
In a nightly call, this job is blocking: a publication failure fails the build
call, prevents preview publication, and keeps that run ineligible for green-nightly
rollout evidence.
The consume-only weekly audit qualifies a green same-source preview without
compiling another application. Nightly Linux matrix jobs have explicit format-only
names so the actual API job names match the required green closure. Weekly
completion requires a checksum-verified receipt from the original successful
main preview audit attempt, its upload window, and all three performed audit
steps plus the completion marker. A successful job whose gates were skipped
does not satisfy the week. A queued or running canonical same-source preview
defers selection to the next nightly without dispatching or waiting; missing or
failed producers still fail with an actionable message. Deferral uses the
canonical API queue-update or running-attempt start time and ends after 30
minutes; missing, future or stale timestamps fail with retry guidance when no
qualified retained bundle or fresh canonical producer exists. Retained qualified
bundles are examined before scheduling-only deferrals, so a newer stale queue
cannot hide an older green bundle. Artifact identity and checksum errors still
fail immediately; only the specific deferral-age error is postponed while
alternatives are evaluated.
A receipt left by a failed or cancelled original audit, or by missing/skipped
audit steps, cannot suppress the week and is ignored before downloading bytes.
Ambiguous identities and known upload-window, ZIP, digest or receipt
contradictions still fail closed.

The Linux document-import consumer restores its existing pinned Flutter cache
without saving. The dedicated main-ref `publish-caches` job warms that same
path and key using the pinned toolchain, verifies current main before warming
and immediately before saving, and saves only a cache miss. If main advances,
it skips only this toolchain cache work and preserves the existing registry and
model publishers. Invalid ref, event, checkout or metadata transport still fails.
It compiles no application or vendor library for this cache.

Package contracts consume the same run's verified Linux bundle and keep native
DEB/RPM/Arch lifecycle checks plus the separate signed DMG fixture. The single
`macos` job reuses the qualified SDK, runs fresh native,
core, desktop and compiled service/MCP gates in one workspace, then assembles and
smokes the application. Nightly callers explicitly request the Mac coverage
report, and the job retains the core/desktop coverage files as evidence. The
retired compiler-work producer is no longer queried by this job. The first
hosted run on PR #155 (`221d7796`, run `39418919789`) spent approximately
476 seconds examining 45 legacy payloads that failed the environment-package
identity check, followed by 106 seconds of actual native compilation. The
complete Mac job passed in 24 minutes 41 seconds. This original cold sample is
retained; removing the lookup does not establish a new elapsed time. Record
genuine cold native compilation and complete job timing on subsequent hosted
runs for the WS4 latency gate. A warm restore cannot establish that gate. Add a
compiler cache only if the plan's measured threshold calls for it, with
separately reviewed inputs.
Mac Flutter/pub consumers are restore-only. The scheduled nightly preview calls
the dedicated `macos-cache-publish.yml` publisher only after a successful plan
selects a build. Unlike the Linux publisher, its result does not block preview
publication or the product's `nightly-checks`. No-build nights skip it, preserving
the original failed producer's retry selection. The workflow also permits an
explicit main dispatch. It has no independent schedule. The publisher warms the
same pinned SDK and enforced lockfiles,
checks that its checkout is still current main immediately before publication,
and saves only missing keys. It compiles no SDK or application. Retained legacy
Arch stage failures remain blocking in the nightly; the audit does not ignore
them. Current application/calendar/service source, SDK approval and wait
proofs, BSD-safe source copying, and rerun output isolation remain intact.

Installers stay outside the source/build archive. Its authenticated manifest
records only the original portable tar name, size and digest plus checksum and
build-sidecar digests. The API-qualified original handoff step exports the exact
manifest digest and producer job; the successful Linux consumer requires those
outputs before recording consumption evidence. It checks the separately verified
portable bytes and sidecars against that compact record, as well as the source,
tier, label, original producer and source/build archive checksum. Substituting an
unqualified or locally changed manifest cannot produce a consumption receipt.

Per-main application builds, the dependency-seed historical attempt-1
qualification, and the retained Arch stage helpers remain. The WS5b-1 transition
below changes candidate naming and authorization; WS2c, WS5b-2, WS5b-3 and
post-merge receipt reuse remain separate later steps.


### On-demand tested release candidates (WS5b-1)

`release.yml` resolves the reviewed source and verifies reusable tested candidates
before allocating a distribution number or compiling an application. Its
`candidates_only` dispatch runs the same required platform, package, acceptance
and consume-only sanitizer gates, then stops after the candidate receipt without
creating a draft release. Only this release tier uploads canonical `ci-*-app`
candidates. Per-merge main bundles remain available under `main-*` names for
main acceptance during the transition; they do not count as tested candidates.
Preview bytes remain ineligible for release.

The release Linux test consumes the API-qualified source/build manifest and its
original successful producer job together with the separately qualified portable
archive. The compact manifest binds the portable filename, size, content digest
and checksum/build-sidecar digests; `dist` remains excluded from the source/build
archive. Changing a local manifest or substituting another producer cannot
satisfy the external qualifier outputs.

Before the first hosted candidate dispatch, configure `RELEASE_SOURCE_FLOOR` to
the authoritative merged WS5b-1 commit. The committed policy deliberately leaves
that value empty until the merge exists; preflight fails closed without the
reviewed floor. Sources below it retain the bounded legacy path until WS5b-3 or
the policy expiry. Missing or expired original artifacts can require a fully
gated rebuild, while surviving invalid evidence fails closed. Original job
attempts and checksums remain authoritative when forwarding existing bytes.

This stage keeps per-merge builds enabled. The on-demand switch requires two
successful hosted `candidates_only` runs, or one such run and a release. Local
fixtures do not establish those hosted gates or release readiness.
