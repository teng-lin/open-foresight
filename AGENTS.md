# Agent instructions

## Reuse SDKs, libraries, and build caches before rebuilding

Treat reuse as the default for SDKs, LiteRT, Whisper, gRPC/protobuf, and all other
libraries, toolchains, dependency downloads, and build caches. These builds are
expensive. Before changing CI, pushing a change that affects dependency jobs,
dispatching a workflow, or rerunning a failed job, think carefully about whether
existing verified artifacts or compatible cached work can be reused.

- Inspect the existing artifacts, receipts, producer jobs, and relevant build
  inputs first. Prefer a completed, compatible artifact. Preserve a running
  compatible producer instead of canceling it and starting again.
- Rebuilding is a last resort. First assess compatible artifacts, cache
  restoration, incremental builds, and retrying only the failed step. Rebuild
  only when those options cannot produce the required compatible, verified
  output, and explain why. Recompile only the affected components; retain
  unchanged libraries, downloaded dependencies, and valid compiler outputs.
- A rebuild can be necessary when a concrete dependency, source, recipe, toolchain,
  architecture, ABI, or output-affecting build setting changed, or when a
  compatible verified artifact is genuinely unavailable or invalid.
- Justify a necessary rebuild before triggering it. State the affected component,
  the exact input change or artifact problem, why existing artifacts cannot be
  reused, and which dependent components actually need rebuilding. Record this
  in the work update and PR description where applicable. A cache miss alone
  does not establish that recompilation is necessary; investigate its cause.
- Do not delete caches, clean dependency builds, disable cache restoration, or
  restart successful library builds merely to troubleshoot an unrelated
  failure. Identify the incompatible or corrupt entries and justify any cleanup;
  preserve the rest. A test failure, upload failure, or transient network error
  does not by itself justify recompiling already successful dependencies.
- Application changes, Dart tests, documentation, logging, timeouts, upload
  settings, job organization, and receipt or promotion plumbing should reuse
  SDKs when their actual build inputs match. Commit IDs and rebase merges alone
  do not justify rebuilding an SDK.
- Keep invalidation specific to each component and its real dependencies. A
  change to an unrelated version in a shared pins file must not invalidate every
  SDK. Changing cache-key code must not force a cold build of compatible SDKs;
  provide a verified reuse or migration path for existing artifacts.
- Keep provenance and integrity checks intact when broadening reuse: verify the
  producer repository, workflow, successful job and attempt, relevant build
  inputs, receipts, and artifact checksums. Do not relabel an old artifact as a
  newly compiled SDK or silently accept incompatible or untrusted bytes.
- Before pushing follow-up commits to an open PR, fetch its current review
  threads and CI results. Verify each finding against the code, address valid
  findings together with related CI fixes, and validate the combined changes
  locally before pushing. Check for new reviews while CI runs. Rerun only the
  affected jobs when possible; preserve successful expensive build results.

This policy requires evidence and a concrete justification for rebuilding. It
does not add a separate user-approval step for work already authorized.

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
