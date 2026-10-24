# CI integrity

These rules govern how CI produces, consumes and publishes build outputs. They
are enforced in code, chiefly `tools/ci_producer_trust.py`,
`tools/sdk_producer_trust.py`, `tools/ci_artifacts.py` and
`tools/ci_release_candidates.py`, and by their tests. Changing them needs owner
review. The pipeline and cache design is described in the
[CI performance guide](ci-performance.md); the history and remaining workstreams
are in the [CI restructure plan](../plans/2026-10-19-ci-restructure-plan.md).

## Artifact sources

- SDKs and dependency outputs may come from:
  - `main`;
  - the consumer's own PR;
  - the final head of a merged same-repository PR, if its producer-control files
    are byte-identical (including file modes) to reviewed `main` source and its
    component identity matches. Verify the merged-tree and main-reachability
    proof. This exception exists only while the owner keeps PR-produced SDK
    promotion ([decision 7](../plans/2026-10-19-ci-restructure-plan.md#8-owner-decisions)).
- Release candidates come only from stamped `release`-tier runs of reviewed
  `main` source at or above `RELEASE_SOURCE_FLOOR`. Per-merge candidates are
  retired.
- Preview bytes never become release bytes.
- PR bundles serve only that PR's checks.

## Verifying a consumed artifact

Check every consumed artifact for:

- the repository;
- the workflow path and event;
- the producer source commit, component or build-input identity, and the
  artifact upload window;
- that the producer job succeeded in the attempt that uploaded the artifact, as
  recorded by its receipt;
- the receipt, including tier and label where its producer contract defines
  them. A receipt without a tier field is a legacy receipt, accepted only for the
  producers listed in `tools/ci_producer_trust.py`;
- the content checksum.

Never present stamped or older bytes, including SDKs, as a new compilation.

## Who may write

- Only `main`-ref runs write to shared registries, registry caches, or caches
  that `main` reads. These are dependency-SDK producers on `main` push, dispatch
  or monthly refresh; `main` sweeps; cache-publish dispatches; the scheduled
  nightly preview; release; and preview.
- They write only from dedicated publish jobs.
- Every PR run, same-repository included, is read-only toward those stores. No
  job that can execute on `pull_request` declares any `write` permission.
- Main-only jobs in PR-triggered workflows have explicit `main`-ref and event
  guards. Other scheduled drift runs are consume-only.

## Release bytes

- Release publishes exactly the bytes that passed pre-release acceptance.
- Identity stamping is recorded as its own step and carries the original
  producer's provenance.

## Compatibility and cache keys

- Fail on incompatible bytes: ABI, toolchain or version.
- Keep each component's cache key limited to its real inputs.

## Design defaults

- **Reuse.** Prefer reuse. A miss on a content-addressed key is reason enough to
  rebuild; investigate only if the miss rate rises.
- **Cancellation.** Superseded PR runs may be cancelled, including in-flight
  application builds. Dedicated SDK and instrumented-SDK producer jobs do not
  cancel.
- **Waiting.** Wait at most 30 minutes for another run's producer, then build or
  fail with an actionable message. Release coordination is exempt.
- **Test results.** Per-stage test results are not cached across runs; compiler
  outputs and SDKs are. `main` skips re-testing only through a verified,
  per-job chained identical-tree receipt.
- **Expiry.** Artifact expiry or a cache-key change may cause one rebuild. Do
  not build migration paths to avoid it.

## Transitional mechanisms

These remain in code until they are deliberately retired. Do not remove them as
a side effect of other work.

- Existing guarded publish jobs and stage-result caches, until the CI plan's
  replacements (WS2b, WS2c) land. PR checks stay until the plan's hosted safety
  gates pass.
- Legacy tierless producer receipts (`tools/ci_producer_trust.py`).
- The dependency-seed attempt-1 qualification
  (`tools/ci_app_dependency_seed.py`), until its verifier is migrated.

## Testing CI tooling changes

- Tests that consume archived source or run in containers must also pass from a
  complete source export without `.git`. Use checksum-verified frozen historical
  fixtures or narrowly scoped fixture revisions, so that unit tests do not
  depend on local HEAD or deep Git history.
- Artifact and cache fixtures must pass with an inherited PR ref different from
  their fixture PR, with a `main` ref, and with no ref. Inject fixture CI
  metadata explicitly; a local environment without GitHub variables does not
  verify hosted behavior.
- Preserve real archive, receipt, checksum and provenance assertions. Cover
  caches saved from verified artifact copies as well as original builds,
  keeping byte-level verification and the original producer's provenance.
- For application dependency reuse (`tools/verify_app_dependency_reuse.py`),
  verify both the dependency-only tree and the configured full application
  after its sources are copied. Cover fresh generated application files,
  existing dependency outputs, and the actual Make or Ninja backend. The guard
  must still reject dependency compilation and relinking. An unrelated
  application dry-run failure must keep its output and fail with an actionable
  diagnostic; it never authorizes a rebuild. Use small reproductions rather than
  recompiling real SDKs or vendor libraries.


## Tool package initialization

SDK producer controls include `tools/__init__.py` because importing a tooling
module executes its package initializer. The registry leaf used by the producer
workflow is also an explicit control. Historical namespace producers have no
initializer; the immutable reader preserves that absence. Absence cannot qualify
any present consumer initializer, even an empty file. A present initializer must
match verified regular Git bytes and executable mode, just like other controls.
Existing reviewed-source and exact-artifact approval rules still apply; a changed
control set never supplies permission for a cold compilation of compatible SDK
bytes. Review this control-set change with the package import migration.
