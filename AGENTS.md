# Agent instructions

## Reuse SDKs, libraries, and build caches before rebuilding

**Integrity (mandatory).**

**Sources.**
- SDKs and dependency outputs may come from:
  - `main`;
  - the consumer's own PR;
  - the final head of a merged same-repository PR, if its producer-control files are byte-identical (including file modes) to reviewed main source and its component identity matches. Verify the authoritative merged-tree and main-reachability proof. This exception lapses if [decision 7](docs/plans/2026-10-19-ci-restructure-plan.md#8-owner-decisions) drops PR-produced SDK promotion.
- Application candidates come only from stamped `release`-tier runs of reviewed main source. Transition ([WS5b](docs/plans/2026-10-19-ci-restructure-plan.md#ws5b-candidates-on-demand-and-release-gates-three-prs-before-ws5a)): until WS5b-1 lands, today's per-merge main-push candidates remain the release source. Between WS5b-1 and WS5b-3, they remain the source only for sources below `RELEASE_SOURCE_FLOOR`, through a legacy trust row that expires at WS5b-3.
- Preview bytes never become release bytes.
- PR bundles serve only that PR's checks.

**Verification.** For every consumed artifact, check:
- the repository;
- the workflow path and event;
- the producer source commit, component/build-input identity, and artifact upload window;
- that the producer job **succeeded in the attempt that uploaded the artifact**, as recorded by the receipt;
- the receipt, including tier and label where its producer contract defines them; legacy schema-1 producer rows remain valid only within their documented transition and expiry;
- the content checksum.

Never present stamped or older bytes, including SDKs, as a new compilation.

**Who may write.**
- Only main-ref runs (dependency-SDK producers on main push, dispatch or monthly refresh; main sweeps; cache-publish dispatches; the scheduled nightly preview; release; preview) write to shared registries, registry caches, or caches that main reads.
- They do so only from dedicated publish jobs.
- Every PR run, same-repository included, is read-only toward those.
- The target enforcement is job permissions: no job that can actually execute on `pull_request` declares any `write` scope. Main-only jobs in PR-triggered workflows must have explicit main-ref and event guards. Other scheduled drift runs are consume-only.

**Release bytes.**
- Release publishes exactly the bytes that passed pre-release acceptance.
- Identity stamping is recorded as its own step, carrying the original producer's provenance.

**Compatibility.**
- Fail on incompatible bytes (ABI, toolchain or version).
- Keep each component's cache key limited to its real inputs.

**Rollout.** Existing guarded publish jobs and stage-result caches remain until their replacements land in WS2b and WS2c. Do not remove PR checks before the plan's hosted safety gates pass. The dependency-seed legacy attempt-1 qualification remains until its verifier is deliberately migrated.

**Cost (defaults).**
- **Reuse.** Prefer reuse. A miss on a content-addressed key is sufficient reason for CI to rebuild; investigate only if the miss rate rises.
- **Cancellation.** Superseded PR runs may be cancelled, including in-flight application builds. Dedicated SDK and instrumented-SDK producer jobs stay non-cancelling.
- **Waiting.** Do not wait more than 30 minutes for another run's producer; build, or fail with an actionable message. Release coordination is exempt.
- **Test results.** Per-stage test results are not cached across runs; compiler outputs and SDKs are. Main skips re-testing only through a verified, per-job chained identical-tree receipt.
- **Expiry.** Artifact expiry or a cache-key change may cause one rebuild. Do not build migration paths to avoid it.

**Agent hygiene.**
- Do not delete caches, clean builds or restart successful dependency jobs to troubleshoot an unrelated failure. Rerun only failed jobs first.
- Justify SDK or toolchain input changes in one line of the PR description.

## Verify changes before pushing

- Fetch the current PR head, review threads, and CI results. Read the actual
  failed-step output, verify each finding against current code, and batch valid
  review fixes with related CI fixes before pushing. Check again for new reviews
  while CI runs. Do not report a fix as verified from a passing unrelated check.
- For workflow edits, require both actionlint and ShellCheck. Confirm ShellCheck
  is on PATH before running actionlint: actionlint silently skips embedded shell
  checks when it is unavailable. Match the hosted lint command and tool versions
  where possible; a partial local lint run is not the hosted lint gate.
- Run the applicable CI commands locally. Tests that consume archived source or
  run in containers must also pass from a complete source export without `.git`.
  Use checksum-verified frozen historical fixtures or narrowly scoped fixture
  revisions; unit tests must not accidentally depend on local HEAD or deep Git
  history. Preserve real archive, receipt, checksum, and provenance assertions.
  Artifact/cache fixtures must also pass with an inherited PR ref different from
  their fixture PR, a main ref, and no ref. Inject fixture CI metadata explicitly;
  a local environment without GitHub variables does not verify hosted behavior.
  Cover caches saved from verified artifact copies as well as original builds,
  preserving byte-level verification and original producer provenance.
- For native/protocol/application changes, run the complete native, Dart core,
  and desktop suites before pushing. Point Dart tests at the current native
  library and helper so native integration tests actually run. When moving data
  between argv and stdin, update and exercise every runner fixture and consumer;
  checking only the C++ side is insufficient. Check test counts and skip reasons.
  Compare the local CTest inventory against the repository-root CMake inventory;
  standalone native/helper projects omit inference tests such as probe failures.
  Run those omitted targets too, reusing verified dependency libraries and tools.
  Run the CI coverage command and enforce its existing threshold; a plain test
  pass does not establish coverage. Check both libc++ and libstdc++ behavior when
  worker shutdown depends on stream errors or exception state.
- For service, capture, native-launch, or desktop-boundary changes, also run the
  compiled service/MCP subprocess suite and the real desktop/service integration
  on an isolated display. Use the current service, MCP, helper, and native binaries.
  Capture fixtures must honor the production output protocol, including pw-record
  writing raw PCM to its owned FIFO while stdout carries diagnostics. Passing
  unit tests alone does not verify these process and UI boundaries.
- Test development hooks both disabled by default and explicitly enabled. Dart
  compile-time defines need a source-compiler test invocation where required;
  an ordinary kernel test run may not inherit the define. Verify release builds
  remain hook-free even when a cached development option was previously enabled.
- For application dependency reuse, verify both the dependency-only tree and the
  configured full application after its sources are copied. Cover fresh generated
  application files, existing dependency outputs, and the actual Make/Ninja
  backend behavior. The guard must still reject dependency compilation/relinking;
  an unrelated application dry-run failure must retain its output and fail with
  an actionable diagnostic, never authorize a rebuild. Use small reproductions
  without recompiling real SDKs or vendor libraries.
- Before large parallel Dart/Flutter runs, check temporary-storage capacity and
  quotas. Use a private task-specific disk-backed TMPDIR when needed. A storage
  failure is an infrastructure failure, not a passing test or a reason to delete
  dependency caches. Rerun the affected tests after correcting the environment.
- Preserve failed command output in logs, including captured subprocess output.
  If this host cannot execute Docker or Apple checks, state that limit explicitly
  and require the corresponding hosted checks before merge. Do not claim those
  runtime paths passed based only on mocks, static inspection, or a narrow fixture.

See [the CI performance guide](docs/platforms/ci-performance.md) for the current
pipeline and cache design.
