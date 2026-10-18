# Agent instructions

## Reuse SDKs before rebuilding

Treat SDK reuse as the default. LiteRT and the other native SDK builds are
expensive. Before changing CI, pushing a change that affects dependency jobs,
dispatching a workflow, or rerunning a failed job, think carefully about whether
an existing verified SDK can be reused.

- Inspect the existing artifacts, receipts, producer jobs, and relevant build
  inputs first. Prefer a completed, compatible artifact. Preserve a running
  compatible producer instead of canceling it and starting again.
- Rebuild only when a concrete dependency, source, recipe, toolchain,
  architecture, ABI, or output-affecting build setting changed, or when a
  compatible verified artifact is genuinely unavailable or invalid.
- Justify a necessary rebuild before triggering it. State the affected component,
  the exact input change or artifact problem, why existing artifacts cannot be
  reused, and which dependent components actually need rebuilding. Record this
  in the work update and PR description where applicable. A cache miss alone
  does not establish that recompilation is necessary; investigate its cause.
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
