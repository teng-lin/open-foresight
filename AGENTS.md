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
- Batch related fixes and validate locally before pushing. Rerun only the
  affected jobs when possible; preserve successful expensive build results.

This policy requires evidence and a concrete justification for rebuilding. It
does not add a separate user-approval step for work already authorized.

See [the CI performance guide](docs/platforms/ci-performance.md) for the current
pipeline and cache design.
