# CI candidate qualification and activation

The reliability work lands preparation with direct main validation, the current
production selector and the transitional Arch checks retained until hosted proof
qualifies. The dedicated main-only `CI qualification index` workflow publishes
the runtime `ci-qualification-index` artifact. Its repository, workflow/event,
reviewed-main source, original successful uploader/attempt, upload window, receipt
and ZIP checksum are verified before its capability evidence is independently
rechecked. Scheduled reconciliation discovers observer proofs within 30 minutes;
observer completion does not queue another full index verification. The committed `ci-rollout-index.json` is only an inactive schema
example; an empty index cannot authorize receipt reuse, path narrowing, acceptance
phase narrowing or Arch retirement. A PR run cannot qualify its own new main-only
producer controls.

`tools/ci_selection.py` observes the WS3 path union and prerequisite/consumer
closure alongside the current classifier. Its required-owner report includes
acceptance and the transitional Arch owner. The live `ci:full` label can broaden
production selection; proposed narrowing remains observation only. The frozen
50-PR changed-file inventory is in `tests/fixtures/ci-selector-50-prs.json`, with
its SHA256 alongside it. It includes all six known historical escapes and both
sides of renamed files; replay requires no Git metadata or network access.

`tools/ci_rollout.py` defines the retained-source closure, excluding only the
listed legacy implementation files whose removal is planned. It hashes source
bytes and modes, includes unknown files under the retained source roots, and
rejects symlinks, incomplete exports and any retained-path mismatch. The closure
comparison is intentionally strict for initial Arch retirement: a retained-path
change requires fresh reviewed-main qualification. Ongoing coordinator and path
selection eligibility use the separate schema-2 `control_closure`, which hashes
CI tools/actions/recipes, dependency/toolchain declarations and CI contract tests.
Application and ordinary product-test changes remain bound by fresh per-job
PR/sweep evidence and do not revoke the qualified coordinator implementation.
Unknown CI/control changes still fail closed. No caller may omit a changed
control to make comparison pass. SDK and the historical dependency-seed receipt
formats are unchanged.

Candidate producers can prepare the following descriptor before identity
stamping mutates source files. This command creates local metadata; it does not
claim that gates passed or upload anything:

```sh
python -m tools.ci_rollout --source "$GITHUB_SHA" \
  --run-id "$GITHUB_RUN_ID" --attempt "$GITHUB_RUN_ATTEMPT" \
  --producer-job 'build / changes' --output qualification/qualification.json
```

The producer job name must be the actual Actions jobs-API name, including any
reusable-workflow prefix. An authorized reviewed-main job must upload only that
file as artifact `ci-rollout-qualification`. The qualification index identifies
its artifact ID, run ID, original attempt, original uploading job ID and complete
ZIP checksum. No current artifact without the candidate marker qualifies.
The main-only `ci-qualification.yml` dispatch executes selector-replay,
archive-SDK, source-scoped fork-format, and tooling-recipe-change exercises.
Transport exercises load and export an existing verified SDK with the real Docker
driver/containerd store, then execute the current application build and complete
test driver. They never impersonate a PR event, compile an SDK, or publish SDKs.
The source-scoped archive preserves its original provenance and is consumed only
within that exercise. Recipe changes are restored after the run, including on
failure. Logs retain failed subprocess output.

Scheduled `nightly-checks` records proof only after its real platform, acceptance
and installer closure succeeds and the full prepared selector actually ran.
Scheduled Arch drift similarly records proof after its real validation. Synthetic
exercises and unchanged/no-build nights emit no qualifying descriptor. All these
hosted exercises remain pending until reviewed main executes them; local fixture
passes are not retirement evidence.

While either Arch retirement or acceptance narrowing lacks proof, the scheduled
preview runs fresh application validation even when main has not changed. Its
new dated preview label changes embedded application metadata; verified SDKs and
native compiler outputs remain reusable. An active original producer is preserved,
and a failed original producer retries only its failed jobs. Once both capabilities
qualify, unchanged-source preview skipping resumes. A skipped controller is never
counted as an actual nightly observation.

`ci_rollout.authorize` independently rereads repository, workflow/event/main ref,
main reachability, exact original-attempt jobs, uploading-job success/window,
artifact origin, downloaded checksum, descriptor marker and retained closure.
It verifies actual platform/acceptance/installer execution for scheduled nightly
proofs and enumerates the full schedule history so a selected pair of green runs
cannot hide an intervening failure. Missing, expired or conflicting evidence
fails closed. An artifact left by a failed uploader never qualifies.

The `main_receipts` capability needs publisher-consumer evidence and actual
identical, divergent, partially selected and failed/rerun observer parity cases;
`path_selection` needs the real selector replay. `arch_retirement` additionally
needs two consecutive actual green nightlies, actual Arch drift, and archive-SDK,
fork-SDK and recipe-change exercises on the qualified replacement closure.
`acceptance_narrowing` separately needs historical acceptance-failure replay and
four green weeks of actual observation. The four-week gate does not block the
independent path selector. Runtime output/report names for the dedicated
qualification jobs are fixed in `ci_rollout.KINDS` and must match their actual
workflow contracts before activation.

Retained native compiler lookup, verified payload restoration and environment
collection now live in `ci_native_cache.py`, `ci_build_artifacts.py` and
`ci_build_environment.py`; shared Git/ZIP/timestamp primitives live in `ci_git.py`.
The legacy stage modules delegate to these same implementations until retirement
qualifies. Restoring compiler objects still requires fresh configure, build and
tests. No successful test result is promoted through those retained helpers.

## Evidence expiry and renewal

Qualification artifacts expire normally. The JSON file
`docs/platforms/ci-rollout-index.json` is an inactive schema example, not runtime
activation input. Runtime consumers discover only the authenticated main-only
`ci-qualification-index` artifact and reverify its original producer and the
capability evidence. No committed file, environment flag or local report can
waive that proof.

When a pinned proof expires, the affected capability becomes inactive and checks
expand. Do not copy or restamp old receipts to preserve retirement, delete caches,
or restart successful SDK jobs. A content-key miss or expired SDK artifact may
cause one normal rebuild by its authorized producer; it is not a reason to build
an expiry migration.

Renew qualification on the current reviewed main source using the existing
`CI candidate qualification` dispatch: run `archive-sdk`, `fork-sdk` and
`recipe-change`; run `selector-replay` or `acceptance-replay` when renewing those
capabilities. Use `Publish Linux application caches` with `qualify_consumers`
for publisher-consumer proof. Allow two consecutive actual scheduled full
nightlies and the scheduled Arch drift to qualify the same retained closure for
initial Arch retirement again. Coordinate that source window rather than forcing
proof acceptance. The index publisher will discover the fresh artifacts and
verify the gates without another code change. Main receipts additionally need
fresh actual observer parity cases. Acceptance narrowing additionally retains
its zero-miss historical-failure replay and four green weeks of real nightly
observation. Until renewal succeeds, broader checks remain the supported path.
