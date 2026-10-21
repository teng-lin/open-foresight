# CI reliability and runtime improvement plan

This plan completes the current CI restructuring while addressing failures and runtime costs observed after its first implementation batches. Fix incomplete gates and unstable tooling reuse first, then reduce repeated main validation and test overhead. Every change preserves the artifact integrity rules in [AGENTS.md](../../AGENTS.md).

- Implementation source baseline: merged main `02d572fbd66022bb125d188dfa296ba7f2bf85bc`, PR #162, October 20, 2026. Workflow/tooling source is unchanged from #160. The original 20-PR measurement window remains frozen through #160.
- Relationship: this is the implementation continuation of the [October 19 restructuring plan](2026-10-19-ci-restructure-plan.md), not a replacement for its policy, owner decisions or hosted retirement gates.
- Delivery: three PRs, with staged commits, hosted qualification between merges and explicit stop conditions. This plan authorizes no release, merge, registry mutation or premature check retirement.
- Revision: 5. Frozen hashes, reviewer verdicts and finding dispositions are recorded in the [review record](2026-10-20-ci-reliability-and-runtime-reviews.md).

## Evidence and scope

The latest 20 merges are #137, #140, #143, #144, #147, #145, #141, #146, #148, #149, #151, #150, #152, #153, #154, #155, #157, #158, #159 and #160, in merge-time order. The comparison is observational: application size, selection, cache state and workflow shape changed across this window.

The [frozen per-PR baseline](../platforms/2026-10-20-ci-review-baseline.csv) records source/head trees, run links, durations and denominators. Its main snapshot predates completion of #160's main run; the unfinished result remains excluded rather than being retroactively counted as success.

| Measurement | Older 10 | Newer 10 | Interpretation |
| --- | ---: | ---: | --- |
| Median successful first-attempt full platform run on the final PR revision | 29.7 min, n=8 | 21.8 min, n=9 | About 26% faster; excludes docs-only and failed first attempts |
| PR workflow first-attempt failures | 25/148, 16.9% | 11/91, 12.1% | All revisions; cancellations excluded; counts workflows, not jobs or distinct commits |
| Main platform first-attempt failures | 2/10 | 4/9 | One main run was unfinished in the snapshot; does not establish a regression caused by a particular PR |
| Merge tree identical to final PR head tree | 8/10 | 8/10 | Potential receipt eligibility only; never sufficient validation evidence |

The newer five PRs within the newest ten had 8/34 first-attempt workflow failures, versus 3/57 in the preceding five. This is a reason to stabilize failures before claiming sustained reliability improvement. Repeated green qualification attempts do not dilute the first-attempt denominator.

[PR #160 platform run 39490406389](https://github.com/teng-lin/open-foresight/actions/runs/39490406389) provides a recent complete example:

| Job or phase | Duration |
| --- | ---: |
| macOS job | 23m 07s |
| Linux build job | 6m 16s |
| Linux test job | 14m 06s |
| macOS host contracts | 201 s |
| macOS native compilation | 143 s |
| macOS core tests | 555 s |
| macOS desktop tests | 413 s, overlapping core |
| macOS desktop release compilation | 166 s, following desktop tests |
| macOS compiled service and MCP integration | 181 s |
| Linux core tests with coverage | 566 s |

Job durations are not additive: the workflow and the core/desktop branches already overlap. The Linux source/build handoff is about 111 MB compressed in this run, and its qualification/download step took 10 seconds. Do not prioritize a new compression protocol over the substantially longer test phases.

Confirmed failure classes include snapshot HTTP 500/502/503 during CI tool installation in main runs [39432741777](https://github.com/teng-lin/open-foresight/actions/runs/39432741777), [39484475229](https://github.com/teng-lin/open-foresight/actions/runs/39484475229) and [39488996991](https://github.com/teng-lin/open-foresight/actions/runs/39488996991); DMG EAGAIN after all existing retries; and a separate signed fixture SIGKILL in [39433496289](https://github.com/teng-lin/open-foresight/actions/runs/39433496289). A step name alone does not identify a root cause.

### Post-baseline update: PR #162

[PR #162](https://github.com/teng-lin/open-foresight/pull/162) merged October 20 at 22:13:29 UTC as `02d572fbd66022bb125d188dfa296ba7f2bf85bc`, directly after #160. The seven changed files are service/socket handling, desktop forwarding, regression tests and their lifecycle documentation; no workflow, tooling or cache implementation changed. Preserve its bounded reset handling, fail-closed live-socket protection and Linux backlog/reset regression tests. The S2 listener handoff fix is completed work, not a future CI optimization.

Its [final-head PR platform run](https://github.com/teng-lin/open-foresight/actions/runs/39502759268) succeeded on attempt 1: macOS 18m25s, Linux build 5m26s and Linux test 14m21s; total workflow elapsed time was about 20m11s. This is one additional observation, not proof of a lower error rate. Main push runs [39506520328](https://github.com/teng-lin/open-foresight/actions/runs/39506520328) and [39506520356](https://github.com/teng-lin/open-foresight/actions/runs/39506520356) were still in progress when checked. Do not insert their unknown outcomes or this twenty-first merge into the frozen 20-PR denominators. Collect fresh matched samples after #162 before accepting a P7 scheduling improvement.

## Existing work and prerequisites

The historical progress document contains implementation-era statements. Before changing behavior, reconcile it against current source and authoritative hosted evidence:

| Workstream | Current source | Remaining prerequisite |
| --- | --- | --- |
| WS2b and WS2b-2 | In-run Linux build/test, acceptance and package bundle consumption landed in #155 | Preserve original producer attempts and complete parity/recipe-change qualification |
| WS4 | One main macOS workspace landed in #155 | Five ordinary stable-source observations, latency target and resource evidence remain |
| WS5b | Release evidence in #157; per-merge candidates removed in #158 | Retain exact two-controller qualification and prove the changed direct-preview route on reviewed main |
| WS5a | Main push still executes platform checks | Implement per-job evidence and sweep coordination before removing the push trigger |
| WS2c | Four Arch stages and stage-result machinery remain | Two qualified green nightly-checks and one qualified green Arch drift; evidence must cover the active replacement route |
| WS3 | Existing catch-all selector with partial exceptions remains | Host inventory rules, dependency closure and replay of at least 50 merged PRs |

The prior green preview controllers and Arch drift are useful evidence, not automatic proof of the later #158 preview route. Verify actual job execution, final aggregates, source, attempt, selected suites and installer outputs; exercise-only, unchanged-preview skips and synthetic issue exercises do not satisfy retirement.

Existing owner decisions remain in force. This work keeps daily Arch drift, consume-only scheduled drift, and the current PR-produced SDK approval exception. It does not change sanitizer requiredness, strict status checks, repository ownership or release policy. Any proposal to change one of those is a separate decision, not a prerequisite invented for this plan.

## Integrity requirements

1. PRs read shared registries and caches; dedicated main-ref publish jobs alone write them. Every PR-runnable job declares no write permission. Audit implicit actions/cache saves as well as explicit registry writes; job token permissions alone do not prevent cache saves.
2. Every reused artifact binds repository, workflow/event/ref, exact source and component inputs, original successful uploading job attempt, upload window, receipt contract including tier/label where defined, and checksum. Fail closed on provenance or compatibility errors.
3. Compiler outputs, SDKs and verified tooling may be reused. PR test results are not reused across runs. Main may skip a job only through verified, chained identical-tree evidence. Never describe reuse or stamping as fresh compilation.
4. Release-tier candidates come from reviewed main, and publication consumes exactly the installer bytes accepted before release. PR and preview artifacts never become release artifacts through a main evidence receipt.
5. Retain guarded legacy publishers and stage caches until their replacements qualify. Preserve the frozen dependency-seed attempt-1 contract until a dedicated migration replaces it.
6. Producer waits remain bounded at 30 minutes outside release coordination. PR application work may cancel when superseded; dedicated ordinary and instrumented SDK producers remain non-cancelling.

## Delivery sequence

**Execution update (2026-10-20).** The user's later instruction supersedes the
GitHub PR sequence below: implement three batches in separate worktrees, review
and test each, merge them locally, then open one final GitHub PR and drive it to
merge. The table remains the dependency and qualification order. This changes
delivery, not the integrity or hosted evidence requirements. The combined code
must include the complete evidence-gated activation path: a dedicated main-only
publisher records authenticated qualification evidence, and read-only consumers
activate only capabilities whose source/control closure and required real runs
verify. Missing, expired or invalid evidence preserves the broader legacy path.
No additional activation code PR, unmerged-source publication, synthetic proof,
or elapsed-time bypass substitutes for qualification. The four-green-week gate
still applies to acceptance narrowing, independently of earlier capabilities.

Deliver this work in **three PRs**. The P1 through P9 identifiers below now name work packages, preserving the detailed contracts and review references; they do not require nine separate pull requests. Keep related changes in separate commits inside each PR so reviewers can inspect the boundaries and regressions can be reverted selectively.

| PR | Scope | Internal order | Gate before the next merge |
| --- | --- | --- | --- |
| PR 1 Reliability and tooling | P1 gate/selector fixes, P2 metrics, P3 tooling/publication, P4 DMG ownership/diagnostics | Establish gate and selection schema first, then metrics, then publisher/tooling and DMG changes | Full affected validation; real warm/miss/archive/fork/recipe Docker exercises and Apple contracts; replacement publisher consumers and matched measurements |
| PR 2 Main evidence and test performance | Qualified P3 publisher cutover, P5 observation, P7 measured improvements, inactive P6/P9 preparation and P8 retained-helper migrations | Measure/select P7 improvements first; prepare observer, coordinator, candidate selector/routes and retained helpers against that final configuration | Observer parity, adversarial receipts, real isolated dispatch/reconciliation exercises, 50-PR selector replay and full runtime/coverage checks; production still runs direct main validation |
| PR 3 Activate and simplify | Activate P6 receipts/sweeps and P9 selection; perform qualified P8 Arch retirement and delete disabled legacy publishers/obsolete machinery | Check retained qualification against the final source, then activate validation routing/aggregate ownership and remove only qualified obsolete paths | Two consecutive green actual nightlies and one green Arch drift on the active replacement closure before retirement; post-cutover main sweep, required aggregates, preview and release paths verified |

PR 1 lands replacement publisher/consumer plumbing with the existing guarded writers retained. Qualify the new main-only publication path and actual consumers after merge under isolated immutable identities; keep production shared-reference ownership on the old route until the coordinated switch in PR 2. This avoids requiring unmerged PR code to publish shared bytes. PR 1 preserves the transitional Arch executions and makes their failures required. Combining these fixes does not waive their individual validation matrices.

PR 2 first switches all qualified P3 shared-reference publishers, consumers and trust routes together, disabling old writes while retaining rollback code. Replacement publication and real consumers must have qualified after PR 1 before this merge. The following nightlies therefore exercise the switched production tooling route. PR 2 lands new coordination and selector code in **observation mode**, plus the retained Git/archive helper extraction into `tools/ci_git.py` and every sanitizer/native-work caller migration needed for P8. Preserve old stage behavior until retirement. It retains the direct main push trigger, the current production selector and all transitional checks. Production main receipts cannot skip work yet. Qualification exercises may dispatch isolated sweeps from reviewed main, but must not publish production validation receipts or change normal main routing. Their fixtures, receipt namespace and issue tracking stay separate from production evidence.

PR 2 also provides an explicit reviewed-main qualification mode that actually executes the prepared final selector, publisher/consumer routes, preview job graph and retained drift/helper paths under isolated immutable identities and channels, with the same implementation and trust checks intended for activation. Candidate publication remains main-only; qualification output cannot become release bytes or production validation receipts. Ordinary production routes and required legacy checks stay active. Exercise this candidate closure through two consecutive actual scheduled nightly-checks and one actual Arch drift; shadow decisions, synthetic exercises or isolated sweeps alone are insufficient retirement evidence. Include the #158 direct-preview route and actual installer lifecycle acceptance.

Implement only the P7 experiments that demonstrate improvement without changing test outcomes; unsuccessful experiments remain evidence, not shipped complexity.

After PR 2 merges, collect the hosted observation, dispatch, preview and retirement evidence on its final configuration. PR 2 includes shadow observation of per-phase acceptance narrowing, and the qualification interval must span its required four green weeks before PR 3 activates that narrowing; ordinary selector replay does not substitute for this time gate. This is a qualification interval, not another PR. PR 3 activates the already prepared coordinator and selector, retains the already qualified and switched publisher routes, removes the direct main push trigger, and retires Arch only when every documented prerequisite holds. Hold PR 3 if any prerequisite is missing; do not merge a partial cutover merely to keep the PR count. Selection/validator changes invalidate incompatible historical receipts, so the first cutover main source must receive a fresh qualified sweep whenever reuse cannot be proved. PR 3 must include an executable closure comparison proving that retained implementations, inputs and trust contracts match the qualified candidate closure; differences may be activation defaults, namespace/reference promotion and legacy deletion only, with their routing/security effects validated on the final head. A substantive retained-path change must move into PR 2 before qualification, or PR 3 must wait for renewed reviewed-main qualification. Do not weaken this proof to meet the PR count. Review and test routing activation, selection changes, Arch removal and cleanup together on PR 3's final head.

The stages have distinct rollback boundaries: revert an individual PR 1 subsystem while retaining failure propagation; leave PR 2 in observation mode if qualification fails; restore direct main validation and broader selection if PR 3 regresses. Arch restoration must not depend on retired caches. Each PR records SDK/toolchain input impact in one sentence; the default is no component SDK recipe change.

### Two PR alternative

Two PRs are possible by combining PR 1 and PR 2 into one preparation PR, followed by the activation/retirement PR. The same observation-only coordinator landing, hosted qualification interval and retirement gates apply. The combined preparation PR must include a reviewed-main-only staged publisher cutover that can be activated after its isolated publication/consumer qualification, without granting PR writes or needing another code merge; otherwise use the recommended three-PR split. This makes the first review and validation closure substantially larger, so three PRs are the recommended execution plan. No fourth PR is reserved for activation: the final PR contains that switch after qualification.

## P1 Gate coverage and selection corrections

Touch `.github/workflows/macos.yml`, `tools/ci_changes.py`, host contract inventories and their existing workflow/selection tests, including `tests/test_linux_switch_workflow.py` and `tests/test_platform_python_tests.py`.

- Add the selected `linux-native` reusable workflow result to the required platform aggregate while that Arch chain remains active. Do not make intentionally non-required sanitizers required as a side effect. Keep acceptance-checks independently required.
- Make expected success/skipped results depend on tier and selection. Pass the explicit tier from the workflow to the gate checker through `CI_TIER` or `--tier`; release expects the transitional Arch chain skipped even when its application gates are forced. A failed classifier, missing result, cancellation or skipped selected job must fail the aggregate. Preserve cheap editorial paths.
- Preserve the existing Ubuntu and Arch host-contract executions as distinct required environment owners during rollout. Update the switch test that currently excludes Arch and the ownership test that counts one Linux invocation across the aggregate. Assert exactly one invocation and fresh host-contract/JUnit evidence per selected environment. Do not remove an existing Arch check to satisfy the former assertion; P8 retires that owner only after qualification. Release retains its Arch exclusion.
- Extend the selection schema now: the classifier writes explicit boolean `superseded: false` into `ci-selection.json` on every ordinary PR/main/manual/release/preview platform run, so P5 can qualify ordinary evidence before sweep activation. P6 sets it true only on superseded sweep exits. Every P5/P6 validator of main validation evidence requires the field to be present and false; legacy selection artifacts without it cannot qualify main validation receipts and require fresh application validation after activation. SDK and dependency-seed receipt contracts remain unchanged.
- Select macOS for installed `packaging/notices/**` content. Select real host owners for changes to root Python tests in `platform_python_tests.SHARED`, `PLATFORM` or `EXTERNAL`; portable quality-owned tests remain quality-only. Use the existing inventories as the source of truth rather than a second hand-maintained list.
- Close prerequisite and consumer dependencies: package consumers need the current Linux bundle; selecting Linux build selects Linux test and acceptance. Tests must assert that explicit acceptance selection and its aggregate remain consistent.
- Retain the five required check names and their expected GitHub App binding. Validate the current ruleset rather than assuming the entire workflow conclusion is required.

Fixtures cover native/core/desktop/service failures, skipped reusable workflows, release mode, docs-only changes, notice-only changes, each host inventory and malformed selection. Replay #159 first-attempt metadata: a failed retained Arch core must no longer coexist with a green required platform aggregate. This fixes a missing guard; the initial measured failure rate may rise when previously hidden failures become visible.

Rollback restores prior selection breadth while retaining failure propagation. Do not roll back by ignoring failed selected jobs.

## P2 Metrics and stable measurement

Extend `tools/ci_stats.py` and its frozen fixtures. Preserve its existing rerun-job deduplication and all-attempt input format; the new work is collection/validation of complete snapshots, reliability/queue/cache metrics, comparable cohorts and operational reporting. Store normalized frozen inputs (`runs.jsonl`, `jobs/<run-id>.jsonl`, `prs.json` and `trees.txt`), `manifest.json`, `report.json` and `report.md` under `docs/platforms/ci-evidence/<snapshot-id>/`. Large full logs stay in retained run artifacts indexed by the manifest. Unit fixtures remain frozen, checksum-verified metadata with no dependency on local HEAD or live APIs. Record retrieval time and exclusions so interrupted runs cannot silently change denominators.

- Attribute PR runs through PR metadata or a unique branch plus creation window; ambiguous branch reuse stays unattributed. Enumerate all pages and all attempts. Distinguish workflow revision from checked-out product revision and in-run bundle source.
- Deduplicate unchanged jobs repeated by the failed-job rerun API. Record queue time, execution time, push-to-first-green and final revision readiness separately. First successful attempt latency must not be confused with time spent waiting for a rerun.
- Report first-attempt workflow, job and commit failure rates separately, with numerator and denominator. Keep cancellation, timeout, startup failure, incomplete and unknown results explicit. Report manual qualification reruns separately. Preserve all consumed runner-minutes and historical failures.
- Split confirmed package/network infrastructure failures, test assertions, provenance/ABI failures, maintenance publication failures and unknown causes. Preserve the actual failed command and diagnostic output; never classify from a generic post-job Docker warning.
- Group by configuration, selection, app/packaging/editorial scope, platform and cold/warm state. SDK producers, release, nightly, dispatch experiments and cache publishers are separate spend categories.
- Add per-stage cache hit/miss/restore failure and resolved input identities. A present cache tag is not a verified hit. Surface multiple publisher entry points and publication failures independently of application validation.

Use at least five ordinary observations per stable configuration for before/after job latency and size gates, matching scope and cache state. Preserve cold misses and failures; show successful latency alongside failure and cancellation rates. Deliberate repeats of one qualification event are labelled and do not substitute for five ordinary observations. Small samples do not establish causality or a statistically stable reliability rate.

Targets retain the original plan: app PR p50/p90 at most 22/30 minutes, Linux build p50 at most 7, Linux test at most 11, macOS at most 20, and identical-tree main validation p50 at most 6 runner-minutes. Runtime experiments must not worsen confirmed test failures, skip coverage or queue saturation. Reliability acceptance is no new deterministic failure plus a separately reported rolling sample; no tiny cohort is called proof of a percentage improvement.

Version new report fields and preserve existing consumers during adoption. Rollback restores the previous reporting path while retaining frozen inputs and new raw observations; it must not erase failures or recalculate a more favorable historical denominator.

## P3 Linux tooling reuse and cache publication

Touch `packaging/build.Dockerfile`, `packaging/acceptance.Dockerfile`, the container driver, handoff identity/transport helpers, `tools/ci_producer_trust.py`, dedicated publish workflows and their callers. Audit `.github/workflows/quality.yml`, `live-services.yml` and `preview-packages.yml` as part of the same writer closure.

### Tooling identity and transport

Separate the expensive OS tooling installation from application dependency seed changes. Publish a secret-free tooling base derived from the qualified SDK, pinned Ubuntu snapshot, architecture and real tooling recipe inputs. Layer the verified dependency seed/configuration over that base; preserve qualification of both the dependency-only tree and the configured full application.

The preferred consumer path resolves a qualified main-produced tooling image by immutable digest and verifies its producer receipt. An ordinary registry build-cache import can remain an acceleration, not the sole tooling artifact contract. Maintain fork and SDK-input PR support: their incompatible own-PR SDK requires a source-scoped local tooling build, and any handoff serves only that PR. It cannot write a shared image. A valid tooling content-key miss permits bounded tooling construction, never an SDK or vendor-library rebuild.

The exact contract includes the SDK/component identity, tooling package/snapshot recipe, platform and compiler ABI. Keep seed identity separate so unrelated seed changes do not rerun apt. Update `ci_linux_handoff.input_identity`, the container driver and fixtures together: both runners still compare the complete actual consumed input identities, including seed qualification, not an image ID assumed reproducible after rebuild. Tooling images introduce a new explicit producer row and receipt; do not broaden the SDK or application producer rows to cover them.

Keep checksum-pinned snapshots. On misses, use bounded retry of update plus install, retaining diagnostics and the same snapshot. Existing Acquire::Retries and the acceptance loop are not a complete outage solution. Do not switch to rolling mirrors or rebuild a successful SDK to recover a tooling outage.

### Publisher coordination and freshness

Inventory all three entry paths: the main platform `publish-caches` job, `linux-cache-publish.yml` dispatch, and preview/nightly's `build / publish-caches` call through `macos.yml`. Consolidate shared publication into an independent main-only maintenance workflow with one implementation and one non-cancelling publisher concurrency group. Application validation and preview acceptance must not depend on completion of that maintenance workflow. A small explicitly main-only trigger job may dispatch it with `actions: write`; PR-runnable validation keeps read permissions. Remove the preview caller's inherited `packages: write` when its writer is retired. Lock only publication, not the entire platform workflow or SDK producers.

Non-cancelling concurrency does not preserve every pending job: GitHub can evict an older pending publisher. Record cancelled/evicted/failed publication as maintenance status, never as successful publication and never as cancellation of an application run. An independent push/periodic/manual reconciler, outside that evictable group, recomputes still-needed eligible input identities and retries missing qualified publications. A cancelled job cannot report its own missing work. Recheck reviewed-main eligibility immediately before writes; stale requests reconcile current needs rather than advertise an older source blindly.

Use immutable content-addressed tooling references and separate discovery metadata from publication. Publish discovery only after the image and receipt are complete and the producer succeeds. Keep dependency, tooling and acceptance cache keys limited to their real inputs. Preserve the existing legacy dependency seed until a deliberate migration; if changing the current producer name/path, update `dependency-seed-current` and every consumer before retiring its old route.

Cache freshness runs independently of skipped main tests: changes to SDK identity, snapshots, recipes or lockfiles dispatch a main-only refresh even when P6 uses a receipt. Assign replacement owners for every current output: application dependency, CI-tool and acceptance-tool registry layers, document Flutter cache, and integration-model cache. Include quality Flutter and retained Arch Flutter/pub caches in the writer inventory; keeping daily drift requires their main-only refresh ownership to survive P8. A small publisher failure should appear as a maintenance failure, with retained logs and notification, rather than being labelled a product-test regression. Moving it to a separate workflow must not hide its status or make required tooling qualification optional.

Keep the existing guarded writers while qualifying the new path under isolated immutable identities. After replacement publication and real consumers pass, switch all shared-reference callers and trust routes together, without a period of uncoordinated writers to the same reference. Never introduce an evictable publisher dependency into the required application graph as an intermediate migration step.

Audit all workflows and composite actions for explicit and implicit cache saves. In particular, split quality Flutter and transitional Arch saves from restoration, and replace `live-services.yml`'s read/write `actions/cache` with restore-only access so scheduled live-service drift stays consume-only. Move shared saves to dedicated main publishers and retain PR-local read-only restore behavior. Test permissions and cache operations structurally; cache save authorization must not rely only on packages permissions.

Hosted acceptance covers ordinary warm consumers, confirmed miss, missing/corrupt receipt, inaccessible registry, incompatible ABI, own-PR SDK, archive-SDK loading in the Docker/containerd driver, a tooling-recipe change and an application-only edit. Require actual Docker execution and no-build assertions with both Make and Ninja fixtures. Restore the previous verified tooling digest or consumer path on regression; retain new artifacts for diagnosis and never delete caches as rollback.

## P4 DMG execution and diagnostics

Keep one required owner of both real DMG contracts. Initially retain the separate packaging DMG job, then remove only the duplicate macOS preflight invocation. Update `platform_python_tests` inventory and execution ownership checks to declare the external Apple owner and require its fresh test evidence, so the tests are neither lost nor claimed to have run twice.

Introduce a distinct `dmg` selection/output/result, selected whenever macOS validation or relevant package/DMG inputs are selected. Give the top-level DMG owner `needs: changes` and include it explicitly in `platform-checks.needs` and `ci_changes.check_gates`. An unselected DMG job must be skipped, while failed/missing/skipped selected DMG execution fails the existing required aggregate. macOS-only changes select macOS plus DMG without selecting Linux build/test or the Linux package matrix. Do not encode Apple ownership as a side effect of the broader `packaging` gate. Test the full macOS/package/editorial/release/preview selection matrix and relevant host-test changes.

Allow the DMG contract to start after classification without waiting for Linux build; Linux installer contracts retain their bundle dependency. This may require splitting the reusable workflow or its callers so a packaging-wide needs edge does not hold the Apple job. Keep the existing required aggregate names; no extra macOS slot should be introduced.

For transient DiskImages failures, capture stdout/stderr, exit code, OS/Xcode identity and bounded relevant system diagnostics. Retain the original DMG checksum and verify the same bytes across a bounded EAGAIN retry deadline. Test permanent corruption and non-EAGAIN errors failing immediately. Current verification already retries three times at two-second intervals; extend that policy only if repeated real execution justifies it. A fixture SIGKILL needs signing/runtime diagnostics and remains a separate failure class, not a generic retry exemption.

Always detach owned mounts and clean only task-owned directories. Preserve both mount/signature/execution and previous-version installation/database retention assertions. A repeated retry that masks a deterministic failure is a failed experiment.

The verification matrix includes both real Apple tests, transient and permanent injected failures, nonzero subprocess diagnostics, rerun behavior and selector/owner closure. Reverting restores the duplicate owner until the single owner is qualified; it never removes the only actual Apple execution.

## P5 Main evidence in observation mode

Implement the existing WS5a contracts without skipping current main work. Create `.github/workflows/main-evidence.yml` in read-only observation mode, triggered by main pushes and completion of the current platform workflow, with manual main-only reconciliation available. Its observer job requires explicit main-ref/event/repository guards, trusted reviewed-main verifier code and `contents: read`, `actions: read`, `checks: read`, `pull-requests: read`. It does not run on pull_request or hold writer permissions. A completion event from a PR run is ignored, and its metadata never authorizes checking out PR code. The observer compares its proposed per-job receipt/sweep decisions with the actual completed jobs. Keep the push-triggered workflow until this comparison passes on all exercised cases.

For each main source, bind a receipt to repository, source/tree, previous main source, schema/validator contract, required-check set, per-job selection/input identity, original PR source/run/job/attempt and timestamped successful check evidence. Read the authoritative merged source and final PR head directly. Ancestor reachability or `merged_source` is not tree equality. Exclude foreign-fork and Dependabot receipt promotion as the existing WS5a contract requires.

Require the latest named required checks from the expected GitHub App, workflow path and pull_request event. For each application gate, also require actual success in the latest applicable PR-head platform run: a skipped selected job is not success. If the new push does not select a job, chain only that job's valid evidence from the push's before source. A docs-only merge cannot launder an unswept divergent predecessor. A later failed/cancelled attempt invalidates prior success as current readiness; preserve the original successful uploading attempt when verifying artifact provenance.

Define compatibility for evidence when workflows, selection, required checks, toolchain, distribution configuration or validator contracts change. An incompatible or unresolved context requires a sweep rather than reuse. Receipts attest validation only and never authorize consuming PR application bytes as main/release bytes.

Fixtures cover all original WS5a cases plus wrong app, renamed workflows, mixed heads, partial checks, superseding attempts, missing originals, changed inputs, deleted evidence, force-push/rebase histories, pagination and API failures. Prove the distinction between the original artifact-upload attempt and latest readiness attempt.

Observation is qualified only when real identical, divergent, partially selected and failed/rerun cases agree with per-job execution. Record the 16/20 matching trees as an opportunity estimate; count eligible jobs and measured saved work only after their evidence qualifies.

## P6 Activate receipts and reconcile sweeps

Extend the P5 `main-evidence.yml` with the coordinator and the original WS5a source and permission guards. Separate its privileged coordinator from untrusted PR execution: it checks out reviewed main controls and treats PR metadata/artifacts strictly as data. Never execute a PR artifact or check out PR code in a writer job.

Touch `.github/workflows/main-evidence.yml`, `.github/workflows/macos.yml`, `tools/ci_changes.py`, a dedicated main-evidence verifier/coordinator, the statistics/receipt schema and their offline/hosted fixtures. The coordinator alone gains explicitly guarded `actions: write` and `issues: write`; observer-only jobs remain read-only.

Add the boolean `sweep` dispatch input to `macos.yml`, the `Main sweep <sha>` run-name marker, non-cancelling `main-sweep` concurrency, and its initial current-head/duplicate guard. Keep `source` checkout and main-ancestor proof. Ordinary manual dispatch, release and preview retain their existing forced selection; a sweep uses an explicit application-tier selector rather than the generic `workflow_dispatch --force` expression. It selects all application validation gates and their active required-owner closure even when the source diff is empty; it does not accidentally select the entire Linux installer matrix. Test this exact distinction against the real dispatch schema, classifier and job graph.

- Qualify current main and its evidence. When reuse is valid, write the per-job receipt. Otherwise ensure exactly one applicable main sweep exists. Sweep selection is the application tier, not release/preview stamping.
- Use source-scoped idempotency and per-repository dispatch reconciliation. GitHub concurrency is not ordered: do not rely on arrival order or an old pending run surviving. A stale coordinator must not leave current HEAD without evidence or a sweep.
- Run sweeps non-cancelling; their initial check exits superseded only if the source is no longer HEAD or a qualified duplicate already exists. Write explicit boolean `superseded: true` for those exits and `superseded: false` for an executing sweep in `ci-selection.json`. The evidence validator must qualify that artifact's original producer/attempt/checksum, require the flag to be present and false, and check actual selected-job success as well as both aggregates. Superseded, missing-marker and all-skipped runs never become evidence, even when GitHub reports green aggregate checks. Any successful sweep also binds dispatch event, workflow path, main ref and exact head_sha.
- Prove the actual workflow_run reconciliation behavior for dispatches made with GITHUB_TOKEN; do not infer it from token recursion rules. Regardless of that result, add independently scheduled reconciliation at `17,47 * * * *`, plus push, completion, manual and nightly reconciliation. This covers quiet periods and `[skip ci]` heads without relying on another merge or a once-daily fallback. Reconciliation is idempotent and avoids recursive dispatch loops.
- Track red main heads in a dedicated issue. Revert an isolated regression promptly, or fix forward on the existing plan's response schedule. Treat failed-job reruns as the first recovery action; do not restart successful dependencies.
- Remove the direct main push trigger only after observer parity and dispatch/reconciliation exercises pass. Keep release, preview and manual source guards intact. Connect P3 freshness triggers before activating skipped application work.

Exercise identical/divergent/docs-on-divergent sources, stale/duplicate dispatches, two close merges, current-head advancement while a sweep fails, `[skip ci]`, missing receipts, API failure, workflow changes and failed-job reruns. Rollback restores direct main validation, reconciles any uncovered HEAD and retains all receipts/logs. A bypass flag may only force fresh validation; it may never force receipt acceptance.

Record scheduled-versus-actual reconciliation delay and a last-success heartbeat. The operating objective is detection/tracking within two hours, with a nominal 30-minute polling interval and manual dispatch fallback; it is not a guarantee of GitHub scheduler delivery. Delayed/dropped schedules are an infrastructure failure, not green main evidence. Exercise a quiet-repository failed sweep and a missed heartbeat before activation. GitHub documents dispatch exceptions separately from [token recursion rules](https://docs.github.com/en/actions/concepts/security/github_token), and explicitly allows [scheduled events to be delayed or dropped](https://docs.github.com/en/actions/how-tos/troubleshoot-workflows).

## P7 Lifecycle tests and macOS runtime

Use retained Dart events and service JUnit to identify serial tails and repeated setup before modifying concurrency. In the observed Linux run, `service_shutdown_handoff_test.dart` accounted for about 120 aggregate case-seconds, `service_closing_protocol_test.dart` 83, and the startup-handoff case 44. Aggregate case-seconds overlap and are not projected wall-time savings.

Use #162 or later reviewed main as the P7 benchmark baseline. Keep its socket-reset/backlog regressions enabled under realistic subprocess load; reducing overlap or retries must not substitute for preserving the production fix.

Experiment with current-source, job-local immutable fixture compilation shared across test files. `HookedServiceBuild` currently compiles once per file. Key any shared fixture by exact entrypoint/transitive source, package configuration, Dart/compiler/native compatibility and compile-time hook defines. Keep hooks-enabled and hooks-disabled outputs distinct. Build before parallel consumers or use a single qualified owner; each test retains its private profiles, sockets, gates, processes and teardown.

Shared compilation must not become shared process ownership. `ServiceLauncher.stopAll()` currently recognizes a PID by its kernel path; give each launcher a private kernel alias or equally verifiable launch identity that remains observable after `exec`, and check that identity before every signal. A stale PID resolving to another launcher using the same compiled bytes must never authorize termination. A wrapper path that disappears from the executed command is insufficient. Add adversarial same-kernel/stale-PID and cross-file disposal tests. Only the job-level compilation owner disposes shared outputs after all consumers and their teardown complete; test files dispose only their private runtime resources.

Do not replace a test that specifically verifies source compilation with a kernel or production AOT binary. Preserve explicit `--compiler=source` enabled-hook execution and default-disabled/release-disabled checks. Release builds must remain hook-free after reusing a development build directory. Fixture caching is local compiler-output reuse, never cached test success.

Use the existing explicit ServiceGates for synchronization where the wait is incidental. Keep real timing/backoff tests and process-lock/EOF/PCM semantics unchanged. Benchmark test concurrency, partitioning long files and scheduling only after measuring CPU, memory and storage; do not start competing Flutter commands in one workspace. Any shard must contribute fresh events, coverage and process-boundary results to the same aggregate. Add sharding only when measured savings exceed setup/coverage merge cost.

Run paired ordinary samples on both platforms. Measure setup, native compilation, core, desktop, release compilation and subprocess tails separately. A ccache experiment is secondary to the longer test phases; if justified, keys include real compiler/SDK inputs and only dedicated main jobs publish shared outputs. Preserve the SDK, compiled dependency outputs and compatible current builds.

Acceptance requires unchanged full test/skip inventories, native root CMake inventory, Dart/desktop coverage thresholds, compiled service/MCP integration, real desktop/service integration on an isolated display and both libc++/libstdc++ behavior for any shutdown-sensitive changes. Revert fixture/scheduler changes on new races or regressions; retain original timings and failed logs.

## P8 Retire transitional Arch stages

Archive a retirement evidence index naming sources, runs, attempts, executed suite inventories, checksums, timing/size samples and final aggregate results. Require two consecutive green actual nightly-checks and one green Arch drift, all on the active replacement closure; source changes affecting that closure require renewed qualification. Include the positive #158 direct-preview route, actual package lifecycle acceptance, archive/fork-style transport and separate active tooling-recipe change exercise. Do not substitute mocks or local tests for hosted Docker/Apple execution.

Once those gates hold, remove `linux-native` from ordinary PR/main application tiers and from P1's aggregate contract together. Keep daily Arch drift and installer Arch contracts. Retire stage-result cache machinery only after extracting the Git/archive helpers needed by retained sanitizer/native-work consumers into `tools/ci_git.py` and migrating every caller/test. Under the three-PR delivery, that extraction and every retained caller/test migration land in PR 2 with legacy behavior preserved; PR 3 deletes only the qualified obsolete machinery.

Delete old writers only after the P3 replacements have actual successful consumers. Keep the separate frozen dependency-seed attempt-1 verifier unless its deliberate migration is part of a separately validated change. Record net CI code deletion against the frozen baseline, without deleting provenance assertions to reach a line target.

Rollback re-enables the previous stage chain and its aggregate mapping from one reviewed change; required check names remain stable. New replacement-suite failures pause retirement rather than trigger deletion.

## P9 Selection and final simplification

Implement WS3's explicit path sets and two-way dependency closure. Give editorial/portable quality-only changes the cheap unconditional tier; packaging selects the current bundle plus consumers; application/build-tooling and unknown paths select all application checks. Notices, entitlements, host-sensitive tests and nested subprocess/inference fixtures have explicit owners. Keep per-phase acceptance narrowing observe-only until its historical zero-miss replay and four green weeks pass.

Test that every repository path referenced by workflows/actions and real host inventories has an owner. Replay at least 50 merged PRs, including known portability and acceptance escapes #102, #110, #112, #119, #137 and #144. Verify both positive selection and absence of unnecessary jobs. Implement the previously planned live-label `ci:full` behavior and its rerun semantics; no implementation exists at the source baseline. Read labels live with `pull-requests: read`, test labels added after the event snapshot, and document rerun/push activation without granting PR jobs write permissions.

Remove proven obsolete helpers and stale workflow names after a reference audit; retain producer trust and historical fixture coverage. Rename the primary workflow file only in a separate provenance migration, not cosmetic cleanup. Update the original progress table and performance guide with final measured configuration and remaining limits.

Rollback selects the broader application gate set and its required-owner closure before reverting narrowing rules. Preserve stable required check names and the ability to force fresh validation. Restoring Arch after P8 must work without assuming retired stage-result caches still exist.

## Verification and operational completion

Every implementation PR must satisfy the applicable AGENTS.md checks before push:

- Review current PR head, threads and actual failed-step output; batch valid related findings. Use actionlint 1.7.7 with ShellCheck 0.11.0 confirmed on PATH, plus repository Ruff, mypy and timeout checks.
- Run affected contract tests and the exact quality coverage command below with its existing 95% threshold, from the working source and a complete source export without `.git`. Frozen historical fixtures must not depend on local HEAD or deep history.
- Run artifact/cache fixtures under explicit unrelated-PR, main and unset-ref metadata, including original attempts and cached copies of verified artifacts. Preserve byte-level checks and original provenance.
- For native/protocol/product/test-boundary changes, run the complete required native, Dart core, desktop, compiled service/MCP and isolated real desktop suites. Record counts/skips and existing coverage thresholds. Exercise every runner/consumer touched, including source compiler hook defines and release hook exclusion.
- Run real Docker cache/handoff/no-rebuild/recipe exercises and Apple signing/mount/relocation contracts on capable hosts. A local capability limit must be reported and the hosted gate remains required.
- Check storage/quota first; use private disk-backed temporary roots. Preserve failed command and subprocess output. Infrastructure failure requires correcting the environment and rerunning affected tests, not deleting dependency caches.

```sh
command -v shellcheck
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
ruff check .
mypy
python tools/check_subprocess_timeouts.py
python -m pytest --cov --cov-config=.coveragerc --cov-report=term --cov-report=xml --durations=20 --junitxml=coverage/python/junit.xml
```

Completion requires landed behavior, qualified hosted gates, measured targets or a clearly tracked failed target, and a reconciled main/nightly status. Plan review convergence is separate from implementation validation and does not certify runtime improvements.

## Plan review convergence

The native review team covers trust/gates, runtime/cache behavior and validation/rollout. Claude CLI and Agy CLI independently review the plan against current repository source. Reviewers must identify concrete missing implementation contracts, unsafe sequencing, unsupported claims or incomplete verification, with file/section references.

For each round, freeze the plan's SHA256, collect all five reviews before revision, verify every finding against current code, and record accepted, rejected or duplicate disposition with reasons. Repeat on the revised plan. Convergence requires all five reviewers to review the same final substantive revision and report no unresolved actionable findings. A missing/failed reviewer is recorded as incomplete, never agreement. Editorial review-log updates after convergence do not change implementation requirements.
