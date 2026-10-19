# CI restructuring plan: tiers, build once, test once (2026-10-19, revision 7)

This plan makes every PR cheaper and faster. It removes duplicated and wasted work, gives each platform one build and one test pass per commit, and moves checks that a PR cannot plausibly break to a post-merge sweep, the nightly and pre-release. It is written for an engineer or coding agent working without other context.

- **Base:** `main` at `b62e5e02`. That is #148 squash-merged; its tree is identical to #148's head `c7f5ae39`. The plan branch is `plan/ci-tiering`.
- **Review:** revision 7 incorporates six review rounds: four Claude reviewers plus the Codex CLI and the Agy CLI. Appendix B records how each finding was handled.
- **Policy change (WS-P):** the owner asked to loosen the cost-avoidance parts of AGENTS.md while keeping its integrity rules.

## 1. Evidence

### 1.1 Current configuration (runs since #143 merged at 2026-10-19T13:57Z)

| Measure | Current |
|---|--:|
| App-PR push to green, final green commit, p50 (n=6) | **36.9 min** |
| All green PR commits, p50 / p90 (n=11) | 37.2 / 56.6 min |
| Runner-minutes per app-PR push, p50 (n=20) | 85 |
| macOS minutes per app-PR push, p50 (range) | 31.6 (27–44) |
| macOS jobs per app-PR push | 6: four stages, the app job and the DMG contract |
| Time at the 5-concurrent-macOS-job cap | 59 of 264 min (22%) |
| Main runner-minutes per identical-tree merge | 84–91. Example: `482e7c57`, about 84.4 in total: platform 63.2 ([39273967883](https://github.com/teng-lin/open-foresight/actions/runs/39273967883): Arch 14.0, `linux-bundle` 9.3, macOS 30.1, packaging 8.7, other 1.1), acceptance 16.7 (39281415628), quality/RPC 4.5. Dependency promotions add 16–24 when triggered; native merges add about 9.4 of sanitizers. |
| Acceptance-chain floor | ~29.5 min: `ubuntu-application` p50 11.9, then `ubuntu-package` 17.2 |
| Failure rates | `ubuntu-package` 9/26 (5 at the application restore, 3 in virtual audio); `native-macos` 5/25 |
| Main acceptance | 6/6 recent merges accepted. `88cf883e` (the main head before #148) is **red in virtual audio and untracked** (run 39298669543). |

#148's acceptance runs also waited 4.5 and 26.5 min to *start*. They sat behind superseded runs in a non-cancelling group (`integration-acceptance.yml:15-17`).

### 1.2 Longer, mixed-configuration window

The window is 87.4 h (Oct 16 02:26Z – Oct 19 17:49Z): 2,016 runs and 8,343 jobs. The report is at `/tmp/claude-1000/-home-blackmyth/d5bd3e39-f32c-4f2b-a22e-25a6ece8c2ed/scratchpad/ci-stats/report.md`, and WS0 checks the script into the repo. 55% of its minutes come from job shapes that no longer exist, so it is used only for these structural facts:
- Main re-validated identical trees in 67 of 105 merges. In the current configuration, 2 of the last 6 diverged.
- Merges run at 19–50 per day.
- The repository is public and owned by a personal account. Minutes are free. What it costs is latency, the free plan's limits (20 concurrent jobs, 5 of them macOS), and flaky failures that each cost a coding-agent iteration.
- Merge queue isn't available to personal-account repositories.

### 1.3 Duplication and waste, verified on current code

| # | Finding | Evidence |
|---|---|---|
| D1 | The Linux suites run twice per app commit: in the Arch stage chain and in the Docker `tested` stage (`packaging/build.Dockerfile:41-46`, `build.sh` with stage `all`). Both run the same CTest (29), core (1,048 / 10), desktop (246 / 17), analysis, AOT compile and release build. They differ in toolchain and test environment. Docker has no Linux UI-test environment, so `tests/service` shows 20 passed + 1 skipped against Arch's 21. Only Arch runs the capture-failure gate and the Linux host Python contracts. | Docker: run 39286141009, job 118172753694. Arch: run 39286141129, jobs 118174987910 and 118174987680. `linux-platform-stages.yml:50-51` |
| D2 | `ubuntu-application` deletes the preinstalled Android, .NET, GHC and CodeQL toolchains: median 96 s, max 354 s (n=36). It uses no model fixtures, and `linux-bundle` builds the same targets without any cleanup. | `integration-acceptance.yml:107` |
| D3 | Of the 427 s Docker step, about 2 min is compilation, about 4 min re-runs D1's tests, and about 1.5 min is Docker plumbing. | job 118172753694 |
| D4 | Core coverage is enforced only on macOS: 508 s covered vs 118 s plain on Linux. Desktop coverage is collected on all three hosts (`--coverage` is hard-coded at `tools/build_dart_gates.sh:78`) but enforced only on Linux. Linux core coverage has never been measured. | macOS core stage |
| D5 | `dart analyze` runs 4× per commit and `flutter analyze` 3×. | RPC, stages, Docker |
| D6 | The RPC workflow's 49 Dart tests are a subset of every full core run, and the workflow has no path filter. | `rpc-contracts.yml:34-40` |
| D7 | PR package contracts package an **older main candidate**, never this PR's build. | `tools/package_contract_candidate.py:13-55` |
| D8 | Whenever both run, acceptance's DEB build-and-install covers everything the platform DEB contract does. | `package-contracts.yml:43-64`; `integration-acceptance.yml:365-390` |
| D9 | Main re-runs every *test* stage. It reuses no test results (`tools/ci_stage_cache.py:214-222`), only compiled native objects (`:225-232`). | runs 39273967883, 39295337302 |
| D10 | The nightly preview re-runs every gate on its stamped build. That is legitimate once it *is* the nightly test of the bytes it ships (WS-N). | `preview-packages.yml:68-82` |
| D11 | Main acceptance runs once per candidate through `workflow_run`, and a red result goes untracked. | `integration-acceptance.yml:16,314-317` |
| D12 | PR stage-result reuse hit in 5 of 79 stage jobs, and never on main. The key includes the UTC date and the host package list (`tools/ci_stage_environment.py:48,155`), and Arch jobs run `pacman -Syu`. | stage logs |
| D13 | On main, the dependency promotions compile nothing but still spend 47–344 s on cleanup and about 100 s on namespace resolution: 11–17 min wall, 16–24 runner-minutes. | `ci-dependencies.yml:262,396,530,666`; run 39294921183 |
| D14 | Smaller repeats: `test_macos_tools.py` runs again in `macos`; `test_native_process.py` runs both in CTest and explicitly; `answer_failure_test.dart` runs 4×; the explicit `check_integration_inventory.py` step duplicates a pytest. | trace |
| D15 | Six macOS jobs per app push, each with its own setup (21–93 s), and they hand stage artifacts to one another. Removing core coverage alone saves about 1.3 min, because `desktop-macos` (p50 9.2 min) then becomes the critical stage. Native compiles were warm (1–2 s) only through stage reuse. | job data |

### 1.4 Constraints the design must respect

**Path-based exclusion of macOS or acceptance does not pay off for app PRs.**
- Replaying the last 50 merged PRs, 35 of 37 app PRs would select macOS anyway.
- macOS-only defects came from tooling and test portability:
  - bash 3.2 in `build.sh` (#112);
  - make 3.81 (#119);
  - `TMPDIR` in the relocated smoke test (#110);
  - `/private/tmp` (#144).
- #112 and #119 were caught by the **macOS host Python contracts** (`tools/platform_python_tests.py --platform macos`).
- UI-only changes broke virtual-audio acceptance twice (#102, #137).

**The provenance validators name their producers.**

| Validator | Accepts |
|---|---|
| Restore (`tools/integration_application.py:29,46,140-200`) | `ubuntu-application` from `integration-acceptance.yml` on `pull_request` |
| Candidate lookup (`tools/ci_artifacts.py:290-307,368-384,587`) | `macos.yml` jobs `linux-bundle`/`macos` from main pushes or dispatches. Identity covers version, build number and revision, but not the label. |
| Preview reuse | `tools/preview_reuse.py:33-35` |
| Release-acceptance reuse | `tools/reuse_release_acceptance.py:17-29` |
| Sanitizer trust and cache origin (`tools/ci_sanitizer_artifacts.py:442-462,568-575`) | push and dispatch only; `schedule` is rejected |
| Release coordinator | `tools/release_acceptance_report.py:155-163` |

Today the preview and candidate names are kept apart (`macos.yml:477-509`).

**SDK and build environment.**
- SDK-input PRs and forks get a `docker-archive`, loaded locally as `foresight-sdk:pr` (`tools/linux_sdk_artifacts.py:221`). `--discard-archive` deletes it (`:462`).
- Dependency reuse needs `/src/build/_deps`, built with Unix Makefiles (`tools/ci_app_dependency_seed.py:40-47`; `build.Dockerfile:34`).
- Several steps call Git unless told the revision, and the build export has no `.git`:
  - CMake identity needs `FORESIGHT_BUILD_REVISION` (`cmake/ForesightBuildIdentity.cmake:4`);
  - `tools/package.py` needs `--revision` (`:89`);
  - `ci_artifacts.pack` always calls `git rev-parse` (`:214`).
- `FORESIGHT_PYTHON` is set only in the `tested` stage (`build.Dockerfile:44`).
- Make compares timestamps. A fresh checkout makes sources newer than restored objects. The existing helpers `source_times`/`restore_source_times` (`tools/ci_stage_artifacts.py:133-148`) handle this.
- Rebuilding an image on another runner after a cache miss does not reproduce its ID.
- The macOS native stage passes the qualified SDK prefix, ICU root and ignored Homebrew prefixes (`macos-platform-stages.yml:105-109`). `build.sh` does not.

**GitHub Actions semantics.**
- Required checks are matched by name (ruleset 25347254): `python`, `format`, `contracts`, `platform-checks`, `acceptance-checks`.
- Called-workflow jobs report as `caller / job`.
- A skipped job reports success, and by default it also skips its dependents.
- `needs` waits for the entire job.
- A called workflow fails to start if any of its jobs requests more permissions than the caller grants.
- Concurrency does not order arrivals.
- A job that calls a reusable workflow cannot run steps.
- Installer attestations are signed by the reusable workflow (`linux-packages.yml:163`, `macos-release.yml:148`), not by its caller.

**Tree equality.** `merged_source` is not a tree-equality proof: it returns true for any ancestor of main (`tools/ci_artifacts.py:423`).

## 2. Principles

1. **One build and one test pass per platform per commit.** Platform-neutral checks run once, on Linux.
2. **Test the bytes we ship.** Linux builds in the pinned Ubuntu SDK environment. The tests run against those exact compiled outputs, and acceptance and packaging consume the same bundle. A candidate is tested only when every gate of its producing run passed.
3. **App PRs keep every suite that has caught a PR-caused defect, in its cheapest form.** Only external-drift, cross-distribution, full-release and duplicate checks leave the PR tier.
4. **Unknown paths select the full PR tier.** Rules combine as a union. Selecting a producer job also selects its in-run consumers.
5. **The safety net comes first.** The nightly (WS-N) and post-merge evidence (WS5a) land before any check leaves the PR tier, and each is tracked by an issue.
6. **Release verifies bytes and never rebuilds them. Preview bytes never become release bytes.**
7. **Integrity is strict; cost avoidance is a default** (WS-P).
8. **Every workstream reports measured before and after values** from at least 5 hosted runs, and deletes what it made obsolete (§6).

## 3. Target tiers

| Tier | Trigger | Runs | Target |
|---|---|---|---|
| **T0 local** | `tools/ci_local.sh` | `ci_changes.py --explain`; ruff, mypy, timeout lint, format; actionlint with ShellCheck; analyze and tests for the changed Dart package; native build and tests when native files changed | < 5 min |
| **T1 PR, always** | every PR push | Quality (lint, mypy, full pytest at 95%), format, workflow lint, `contracts`, inventories. Aggregates always report. | ≤ 4 min |
| **T1 PR, app** | app, build tooling, native and unknown paths; packaging paths only where an explicit rule selects T1 app | `linux-build`, `linux-test`, acceptance, `macos` and the document sandbox, detailed below | p50 ≤ 22, p90 ≤ 30 min |
| **T2 PR, conditional** | packaging paths, native paths, `ci:full` | **Packaging:** DEB, RPM and Arch lifecycle plus Debian 13 on this PR's bundle, and the DMG contract. **Sanitizers:** a standalone path-filtered workflow, not required (as today); `ci:full` doesn't reach them, so dispatch them instead. **Dependency SDK producers** on their own paths. | when selected |
| **T3 post-merge** | push to main | `main-evidence.yml` writes a per-job chained receipt (WS5a), or else dispatches `main-sweep` (the T1-app tier on the newest head) | identical-tree p50 ≤ 6 runner-min |
| **T4 nightly** | `preview-packages.yml`, daily when HEAD changed | The stamped preview, built and tested in-run: every T1 and T2 suite, full acceptance plus Debian 13, every installer, and a macOS coverage report. An always-running `nightly-checks` aggregate. The `ci-nightly` issue is opened, updated or closed. | ≤ 90 min |
| **T4 drift** | independent schedules | `arch-drift.yml` (daily); sanitizers (daily, consume-only); OSV and live services (advisory, unchanged) | |
| **T5 pre-release** | `release.yml` | `preflight` resolves the source and decides reuse. `candidates` (a `workflow_call` into `macos.yml`, `tier: release`) builds stamped candidates and runs every gate, including full acceptance, the package matrix and sanitizers (consume-only). Then draft installers, `release-acceptance` (installed models and cloud, upgrade from the previous release) and GPU evidence. | required |
| **T6 release** | `release.yml publish_only` | Re-verify T5 from the APIs and attestations, then publish | |

The T1 app tier runs these jobs:
- **`linux-build`:** native, service and MCP, Flutter release, and bundle assembly.
- **`linux-test`:** CTest; core with the 90% coverage gate; desktop with the 90% gate; service and MCP with native UI under Xvfb; fast integration including capture failure; the Linux host Python contracts.
- **Acceptance**, each needing `linux-build`: `acceptance-cpu`; `acceptance-audio`, which includes software Vulkan; `acceptance-deb`.
- **`macos`:** host Python contracts, native, core ‖ desktop without coverage, service, app assembly, and the relocated MCP smoke test.
- **Document sandbox.**

### 3.1 What leaves the PR tier

| Check | Today | Moves to |
|---|---|---|
| Arch rolling-toolchain stage chain | every app PR | `arch-drift.yml` (daily) |
| Docker `tested` re-run of every suite | every app PR | deleted |
| 4 split macOS stages, the app job and coverage | every app PR | one macOS job without coverage; coverage reported nightly |
| Package contracts on an old main candidate | every app PR | T2 packaging on the PR's own bundle; nightly |
| Debian 13 cross-install | every app PR | T2 packaging; nightly; T5 |
| Repeated analysis and RPC tests | 3–4× per commit | once |
| Main re-validation of identical trees | every merge | a receipt chained per job |
| Per-merge candidate builds | every merge | T5 on demand, plus the nightly preview (decision 2) |
| Per-phase acceptance skipping | n/a | observe-only until the WS3 replay criterion is met |

## 4. Workstreams

Every workstream:
- keeps the required check names;
- updates `docs/platforms/ci-performance.md`;
- updates the workflow-structure tests (`tests/test_pull_request_workflows.py`, `test_linux_stage_workflows.py`, `test_ci_dependencies.py`, `test_ci_stage_setup.py`, `test_platform_python_tests.py`);
- updates AGENTS.md where behaviour changes;
- states its deletions and net line change.

### WS-P: Reuse policy (documentation-only PR, owner approval)

Replace the AGENTS.md section "Reuse SDKs, libraries, and build caches before rebuilding" with:

> **Integrity (mandatory).**
>
> **Sources.**
> - SDKs and dependency outputs may come from:
>   - `main`;
>   - the consumer's own PR;
>   - the final head of a merged same-repository PR, if its producer-control files are byte-identical (including file modes) to reviewed main source and its component identity matches. Verify the authoritative merged-tree and main-reachability proof. This exception lapses if [decision 7](docs/plans/2026-10-19-ci-restructure-plan.md#8-owner-decisions) drops PR-produced SDK promotion.
> - Application candidates come only from stamped `release`-tier runs of reviewed main source. Transition ([WS5b](docs/plans/2026-10-19-ci-restructure-plan.md#ws5b-candidates-on-demand-and-release-gates-three-prs-before-ws5a)): until WS5b-1 lands, today's per-merge main-push candidates remain the release source. Between WS5b-1 and WS5b-3, they remain the source only for sources below `RELEASE_SOURCE_FLOOR`, through a legacy trust row that expires at WS5b-3.
> - Preview bytes never become release bytes.
> - PR bundles serve only that PR's checks.
>
> **Verification.** For every consumed artifact, check:
> - the repository;
> - the workflow path and event;
> - the producer source commit, component/build-input identity, and artifact upload window;
> - that the producer job **succeeded in the attempt that uploaded the artifact**, as recorded by the receipt;
> - the receipt, including tier and label where its producer contract defines them; legacy schema-1 producer rows remain valid only within their documented transition and expiry;
> - the content checksum.
>
> Never present stamped or older bytes, including SDKs, as a new compilation.
>
> **Who may write.**
> - Only main-ref runs (dependency-SDK producers on main push, dispatch or monthly refresh; main sweeps; cache-publish dispatches; the scheduled nightly preview; release; preview) write to shared registries, registry caches, or caches that main reads.
> - They do so only from dedicated publish jobs.
> - Every PR run, same-repository included, is read-only toward those.
> - The target enforcement is job permissions: no job that can actually execute on `pull_request` declares any `write` scope. Main-only jobs in PR-triggered workflows must have explicit main-ref and event guards. Other scheduled drift runs are consume-only.
>
> **Release bytes.**
> - Release publishes exactly the bytes that passed pre-release acceptance.
> - Identity stamping is recorded as its own step, carrying the original producer's provenance.
>
> **Compatibility.**
> - Fail on incompatible bytes (ABI, toolchain or version).
> - Keep each component's cache key limited to its real inputs.
>
> **Rollout.** Existing guarded publish jobs and stage-result caches remain until their replacements land in WS2b and WS2c. Do not remove PR checks before the plan's hosted safety gates pass. The dependency-seed legacy attempt-1 qualification remains until its verifier is deliberately migrated.
>
> **Cost (defaults).**
> - **Reuse.** Prefer reuse. A miss on a content-addressed key is sufficient reason for CI to rebuild; investigate only if the miss rate rises.
> - **Cancellation.** Superseded PR runs may be cancelled, including in-flight application builds. Dedicated SDK and instrumented-SDK producer jobs stay non-cancelling.
> - **Waiting.** Do not wait more than 30 minutes for another run's producer; build, or fail with an actionable message. Release coordination is exempt.
> - **Test results.** Per-stage test results are not cached across runs; compiler outputs and SDKs are. Main skips re-testing only through a verified, per-job chained identical-tree receipt.
> - **Expiry.** Artifact expiry or a cache-key change may cause one rebuild. Do not build migration paths to avoid it.
>
> **Agent hygiene.**
> - Do not delete caches, clean builds or restart successful dependency jobs to troubleshoot an unrelated failure. Rerun only failed jobs first.
> - Justify SDK or toolchain input changes in one line of the PR description.

### WS0: #148 follow-ups

1. **Platform Python inventory.**
   - Drop `tests/test_rpm_scriptlets.py` from the Linux list; it already runs, with `rpmspec`, in the Fedora contract (`package-contracts.yml:45`).
   - Run `tests/test_acceptance_image_cache.py` with `FORESIGHT_DOCKER_CACHE_TEST=1` in a Docker-capable job that has the pinned base, or delete it.
   - Fail when a platform-assigned file is wholly skipped on its platform.
   - Add a test that each platform list runs in exactly one required job.
2. **Acceptance selection** diffs `base...HEAD` (`integration-acceptance.yml:30-60`).
3. **Acceptance cron** goes back to weekly.
4. **Add `tools/ci_stats.py`** to MAINTENANCE.
   - Push-to-green requires the full required-check set and excludes closed PRs.
   - It reports per push and per merge: the identical-tree p50, the identical-tree share, the divergent count with sweep cost, and the mean per merge.
   - It classifies removed job shapes separately and reads `workflow_run` candidates from the logs.
   - `--lines` counts code lines.
   - Record §1.1 as the baseline.

### WS1: Quick wins

1. **Cleanup.**
   - Remove the cleanup step from `ubuntu-application`.
   - In the promotion jobs (`ci-dependencies.yml:262,396,530,666`), move cleanup after the reuse probe and gate it on a miss.
   - Add `df -h / /mnt` and `docker system df` at the start and end of `ubuntu-package` and of the compile jobs. Keep compile-job cleanup until the data shows headroom.
   - If space is short, use `docker/setup-docker-action` with `runtime-basedir: /mnt/...`.
2. **Cancel superseded PR runs** (needs WS-P).
   - Set `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` in `macos.yml` and `integration-acceptance.yml`, with group names distinct per caller.
   - Losing inline macOS dependency compiles or fork SDK builds is accepted.
3. **Bounded wait.**
   - Keep polling only while a `ci-dependencies` run for the same head SHA is queued or running, for at most 1,800 s. Otherwise fail at once, naming the missing identity and the producer.
   - Dependabot PRs fail red with a step summary and `::error`.
4. **Fold RPC into Quality** as a job named `contracts`, running `check_dart_bindings.py` and the descriptor tests. Delete `rpc-contracts.yml`, its `dart analyze` and its duplicate Dart tests.
5. **Remove the D14 repeats.**
   - Remove the explicit `test_native_process.py` steps and update `tests/test_ci_stage_setup.py:161`.
   - Remove the explicit `check_integration_inventory.py` step from `changes`.
   - In `macos`, keep only `CompiledMacComponentTests`.
   - Delete the dead `packaging/ci/` branch in `ci_changes.py`.
6. **Transparency.** `changes` writes a step summary and `ci-selection.json`. Add `tools/ci_changes.py --explain <range>`.

### WS-N: Safety net (two PRs, before anything leaves the PR tier)

**WS-Na: aggregate, issues and concurrency.**
1. **`nightly-checks`.** Add an always-running aggregate to `preview-packages.yml`. A night is green only if every selected test suite ran and passed in *this* run.
   - The "HEAD already has a nightly" skip reads `nightly-checks`.
   - Until WS2b, main acceptance is still covered by the per-candidate `workflow_run`. Each step states the aggregate's actual scope.
2. **Red night on an unchanged HEAD.**
   - The nightly plan reruns the original run's failed jobs once (`POST /actions/runs/{id}/rerun-failed-jobs`, `actions: write`) and **exits without waiting**. The original run's `nightly-checks` and issue job report the result.
   - Delete the recovery, reuse and revalidation paths of `preview-packages.yml` (the recovery plan outputs and steps; `reuse-linux`, `reuse-macos`, `revalidation`), `tools/preview_reuse.py` (309 lines) and its test (358), together with its trust row. Rerunning failed jobs in the original run replaces them.
3. **Issues.**
   - A final job (`issues: write`, with its logic in a unit-tested script) opens or updates one `ci-nightly` issue: the failing jobs, the commit range since the last green `nightly-checks`, and the PRs in that range. It closes the issue with a summary on green.
   - A dispatch input `exercise_failure_path` runs plan → a synthetic failing check → the issue job, with no build or publish. Those runs are named distinctly and excluded from the skip logic, the rerun logic and build-number allocation.
4. **Concurrency.**
   - Preview gets its own group, `preview-packages`.
   - `release.yml` retains workflow-level `distribution-packages` serialization, independent of the preview group. Serializing only its draft/publish jobs lets a newer queued draft cancel an older pending publication, so the whole official release remains serialized.
   - Build numbers already use compare-and-swap (`tools/build_sequence.py:77`).

**WS-Nb: drift.**

5. **Sanitizers.**
   - Add a daily schedule to `native-sanitizers.yml`, in concurrency group `native-sanitizers-${{ github.event_name }}-${{ github.ref }}`.
   - Scheduled runs are **consume-only**: no cache save and no SDK upload. The verifier, which rejects scheduled producers, stays unchanged.
   - Push and dispatch remain the producers. Failures use the issue path.
6. **`arch-drift.yml`.**
   - Runs daily regardless of SHA.
   - Runs `tools/build.sh` and `platform_python_tests.py --platform linux` in the pinned Arch container, with the pacman toolchain list inlined.
   - In the PR that introduces it, it has a temporary `pull_request` trigger limited to its own path.

**Acceptance criteria:**
- `exercise_failure_path` opens and then closes the issue without affecting real nights.
- A red night is retried once in its original run.
- Two consecutive green nightlies.
- `release.yml` can start while a nightly runs.

### WS2: Linux in the SDK environment; acceptance consumes the bundle

**WS2-0: trust-table refactor (behaviour-neutral, lands before WS2a).**
- Merge the allowlists into one tested table.
- Rows are **scoped by consumer**: PR in-run handoff, fork-SDK handoff, release candidate.
- Each row records the workflow path, event and job name (with any caller prefix), plus the required receipt tier.
- Use today's names. Every row keeps the repository, source, original-attempt, upload-window and checksum checks.

**WS2a: shadow (not required).**

1. **`build.sh` modes.**
   - `--build-only` builds native, service and MCP AOT, and `flutter build linux --release`.
   - `--test-only` runs CTest and the core, desktop and service gates against an existing tree, and **asserts that the build dry-run is empty**.
   - `build_dart_gates.sh` passes `--coverage` only when a gate or report needs it.
2. **`ci` target in `packaging/build.Dockerfile`.**
   - Built FROM `application-dependencies`, with `ENV FORESIGHT_PYTHON=/opt/dev-python/bin/python`.
   - Adds test packages from the pinned snapshot (Xvfb, xauth, dbus, mesa, poppler, unrtf) and the `gh` CLI.
   - Its **input identity** is recorded as: SDK image ID + dependency-seed qualification digest + content hash of the `ci` stage recipe + snapshot.
3. **`linux-build`** (`ubuntu-24.04` host).
   1. Resolve the SDK with `ci_artifacts.py pull` and `linux_sdk_artifacts.py resolve --load`.
      - Ordinary archive-SDK PRs: consumers pull the same verified producer artifact.
      - Fork-local SDKs: upload the archive as an in-run artifact *before* discarding it.
   2. Build `ci` with the qualified `appdeps_seed`, reading the existing registry cache. There is no run-scoped cache, because it would churn the 10 GB Actions cache. On a registry miss, `linux-test` rebuilds the image, which the input-identity check allows.
   3. Run `docker run --rm -e <env> -v "$PWD:/workspace:ro" -v "$OUT:/out" <ci> bash /workspace/tools/linux_container_build.sh`. Use the `/workspace` path because `/src` doesn't contain `tools/` until the script's copy step. This is one checked-in script, used both by CI and by a local wrapper that replaces the documented `docker build --target artifact` (`README.md:222`; `docs/platforms/linux-packaging.md:103,231`). The script:
      1. Copies `/workspace` into `/src`, excluding `.git`, `build/`, `dist/` and `.venv`.
      2. Runs `tools/build.sh --build-only -DFORESIGHT_BUILD_REVISION=$SHA`.
      3. Assembles by reproducing the `builder` stage's invocation exactly (`build.Dockerfile:59-73`):
         - `tools/package.py --revision $SHA --litert-library /opt/litert-extensions/liblitert-lm.so --litert-extensions-manifest /opt/litert-extensions/build-manifest.json --generation-backend gpu --whisper-gpu-runtime /opt/whisper-runtime/whisper-cli --whisper-gpu-device 0`
         - On stamped tiers: `--google-client` from the mounted secret, `--require-google-client`, and the search and web-content API keys exported from mounted secrets. The step fails closed when distribution config is required (today `REQUIRE_GOOGLE_CLIENT=1` on main, `macos.yml:459`).
         - `packaging/check_abi.py dist/open-foresight --max-glibc 2.39 --report dist/abi.json`. The report ships as `dist/packages/abi.json` and is attested by `linux-packages.yml:81-82`.
         - `packaging/package_linux.py --bundle dist/open-foresight --format tar --version $VERSION --release $RELEASE`
      4. Writes one tar of `/src`, without `_deps`, to `/out`. The tar holds the exact source export and build tree with timestamps preserved, plus a checksum manifest.
      5. Copies `/src/dist/packages` to `/out/packages`.
      6. Runs `chown -R <runner uid> /out`.

      Copying into `/src` keeps `/src/build/_deps`, Unix Makefiles and timestamps, so `verify_app_dependency_reuse.py`'s dry runs (`build.sh:61-63`) apply unchanged.
   4. **Stamped tiers** (`tier: release`/`preview`): before building, stamp the identity (`preview_packages.py stamp`), and mount the distribution config and secrets read-only into the container. Secrets are never written to an image layer or cache.
   5. On the host: run `ci_artifacts.py pack` from the verified checkout, then upload `linux-bundle-<run_id>-<attempt>` (the receipt records tier and label) and `linux-src-build-<run_id>-<attempt>`.
4. **`linux-test`** (needs `linux-build`).
   1. Rebuild `ci` from the same inputs, using the registry cache. Restore the SDK by the same route; for a fork SDK, use the in-run archive.
   2. **Assert that the input identity equals `linux-build`'s.** Image IDs may differ after a cache miss; the shipped bytes come from `linux-build`'s tree.
   3. Restore the `/src` tar and verify its checksum manifest. There is no fresh checkout copy, so timestamps match.
   4. Under `xvfb-run -a dbus-run-session`, run `build.sh --test-only`, the fast suite (`FORESIGHT_CAPTURE_STATE_TEST`) and `platform_python_tests.py --platform linux`.
   5. Run the Docker fixture on the host. `chown` the outputs.
   - Environment:
     - `FORESIGHT_COVERAGE=1`, `FORESIGHT_CORE_COVERAGE_MIN=90`
     - `FORESIGHT_LINUX_UI_TEST=1`, `FORESIGHT_REQUIRE_NATIVE_UI_TEST=1`
     - `FORESIGHT_FLUTTER_EXECUTABLE`, `LIBGL_ALWAYS_SOFTWARE=1`
     - `FORESIGHT_PARALLEL_GATES=1`, `FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE=1`
   - Budget: ≤ 11 min. Measure the tar size.
5. **Coverage benchmark first.** Record the Linux core figure with #148's `core_coverage_benchmark`. If excluding macOS-only tests puts Linux below 90%, name those tests and decide the threshold explicitly.
6. **Shadow comparison.**
   - Per-test JUnit pass/skip sets must equal the Arch chain's on the same commit, except documented platform skips.
   - `tests/service` must have 0 skips.
   - `makepkg` tests move to the Arch package contract.
   - A fixture proves the handoff passes from separate runners with real Unix Makefiles.

**WS2b: switch.**

1. `linux-build` and `linux-test` become required inside `platform-checks`.
2. **Acceptance jobs move into `macos.yml` as top-level jobs.**
   - `acceptance-cpu`.
   - `acceptance-audio`: virtual audio and meeting UI, plus software Vulkan.
   - Both test the portable bundle in the acceptance image.
   - `acceptance-deb`: DEB lifecycle, plus Debian 13 when run as `acceptance: full` or when packaging is selected.
   - Each job:
     - restores the SDK the same way `linux-test` does;
     - declares `needs: [changes, linux-build, linux-bundle]`;
     - has `if: ${{ !cancelled() && needs.linux-build.result == 'success' && contains(fromJSON('["success","skipped"]'), needs.linux-bundle.result) }}`.
   - On PRs, `linux-bundle` is skipped and the jobs consume the in-run bundle. **On main pushes, until WS5b-3, they consume the stamped `linux-bundle` candidate**, as today.
   - Fixtures prove PR acceptance actually runs and that failed producers block it. `acceptance-checks` stays a top-level aggregate.
3. **Delete `integration-acceptance.yml`.**
   - #148's observe-only `ci_acceptance_plan.py` moves into `changes`.
   - The fork-SDK save/restore (`integration_application.py:113-200`) moves to the in-run, by-ID path, using its trust row.
4. **Artifact names.**
   - PR and sweep bundles never use `ci-linux-app-*` or `ci-macos-app-*`.
   - **Until WS5b-1**, main pushes keep uploading today's per-merge `ci-*-app` candidates, which are today's release path.
   - **From WS5b-1**, per-merge main pushes upload `main-linux-bundle-*` and `main-macos-app-*`. These are used only by main acceptance until WS5b-3 deletes them, and only the release tier uploads `ci-*-app` names, with a receipt recording `tier: release` and an empty label.
   - Preview uses `preview-*` names. Lookup ignores artifacts without a receipt.
5. **Caches.**
   - A dedicated **`publish-caches`** job (`needs: linux-build`, `if:` main-ref events only) is the only job holding `packages: write`. It publishes the `application-dependencies`, `ci` and `acceptance-dependencies` registry caches from secret-free stages.
   - `linux-build`, `linux-test`, `macos` and the `acceptance-*` jobs hold at most `packages: read`.
   - A workflow-structure test asserts that no job that can run on `pull_request` declares any `write` scope.
   - The dependency seed producer (`tools/ci_app_dependency_seed.py:95-112`, which today accepts only `linux-bundle` on a `push` run) gets a row in the WS2-0 trust table naming the post-switch main-ref producer, so the seed can be requalified after WS5b-3 and WS5a.

**WS2b-2: package contracts on the in-run bundle.** `package-contracts.yml` gets `needs: linux-build` and consumes the in-run bundle. Delete `package_contract_candidate.py`. Packaging stays selected by today's catch-all until WS3.

**WS2c: Arch out of the PR tier.**
- Prerequisites: two green `nightly-checks` runs and one green `arch-drift.yml`.
- Delete `linux-platform-stages.yml` and `setup-linux-stage`.
- Extract the retained helpers into `tools/ci_git.py`: `ensure_commit`, the Git/archive utilities used by `ci_sanitizer_artifacts.py:26`, and `source_times`/`restore_source_times` if any consumer remains.
- Then delete `run_ci_stage.py`, `ci_stage_artifacts.py`, `ci_stage_cache.py`, `ci_stage_environment.py` and their tests.

**Acceptance:**
- `linux-build` p50 ≤ 7 min and `linux-test` ≤ 11.
- Acceptance starts once `linux-build` completes.
- No SDK, LiteRT or Whisper compile; the fingerprints are stated.
- Archive-SDK, fork-style and `build.Dockerfile`-changing runs pass when hosted.
- Main candidates stay accepted throughout.

### WS4: One macOS job

1. **Job `macos` on `macos-15`**, in this order:
   1. `platform_python_tests.py --platform macos`, including the SDK source guards.
   2. `tools/build.sh` (stage `all`, `FORESIGHT_PARALLEL_GATES=1`, no `--coverage`) with the qualified configuration:
      ```
      -G Ninja
      -DCMAKE_PREFIX_PATH=$PWD/build/sdk
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
      -DCMAKE_OSX_ARCHITECTURES=arm64
      -DICU_ROOT=$(brew --prefix icu4c)
      '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local'
      ```
      Assert from `CMakeCache.txt` that Protobuf, gRPC and ICU resolved from the qualified prefixes.
   3. App assembly, bundled-runtime verification, and the relocated MCP smoke test.

   If memory pressure on the 3-CPU / 7 GB runner makes the parallel gates flaky, run them sequentially (about +3 min).
2. **Cold compile.** Record the cold native compile on the first hosted runs. If the macOS p50 exceeds 19 min, add `ccache`, keyed on toolchain plus SDK digest and saved only by main-ref runs.
3. **One shape in every tier.** The nightly sets `FORESIGHT_COVERAGE=1` for a non-gating report. Delete `macos-platform-stages.yml` and the stage roles of `setup-macos-stage`.

**Acceptance:**
- `macos` p50 ≤ 20 min.
- One macOS job per app push, plus the DMG contract until WS3.
- At the macOS cap for ≤ 5% of the time.

### WS5b: Candidates on demand and release gates (three PRs, before WS5a)

**WS5b-1: on-demand path. Per-merge candidates keep running.**

1. **`preflight` job (read-only).** It validates that the dispatch ref is `main`, then validates the tag. It resolves the immutable product SHA and checks that it is reachable from reviewed main; a release tag may be behind current main.
   - It also **decides reuse**: it looks for an existing tested candidate whose receipt records `tier: release`, an empty label, the same `source`, and a green latest attempt.
   - **Compatibility floor.** The release source must descend from the WS5b-1 merge commit, recorded as `RELEASE_SOURCE_FLOOR`. That guarantees the `ci` target, the `build.sh` modes and `tools/linux_container_build.sh` exist.
     - Until WS5b-3, a source below the floor is released through a **legacy path**. `preflight` routes it to today's per-merge candidates through a legacy trust row (`macos.yml`, event `push`, jobs `linux-bundle`/`macos`, `ci-*-app` names, source below the floor). The row expires, and is deleted, at WS5b-3.
     - After WS5b-3, sources below the floor cannot be released, and preflight fails with an actionable message.
     - The behind-main fixture runs the real candidate commands on a source just above the floor. A second fixture covers the legacy path.
   - Outputs: `source`, `reuse`, and the reused run ID.
   - A new dispatch mode, `candidates_only`, needs no tag and stops after `candidate-receipt`. It is used to prove the path, and to pre-build candidates before release day.
2. **`candidates` job.**
   - `if: !publish_only && needs.preflight.outputs.reuse != 'true'`.
   - It calls `macos.yml` through `workflow_call` with `source`, `request_id` and `tier: release`, with `secrets: inherit` and the union of the permissions its called jobs request.
   - `tier: release` does the following:
     - `linux-build` stamps and produces the Linux candidate, and `macos` produces the macOS candidate;
     - every gate is forced: full acceptance, Debian 13, the package matrix and the macOS coverage report;
     - sanitizers are called consume-only, with checkout of `inputs.source`;
     - every job checks out `inputs.source`.
   - `macos.yml` keeps `source` as a `workflow_call` input, together with its main-ancestor guard (`macos.yml:249-257`).
3. **`prepare`.**
   - `prepare` runs when `!cancelled()`, provided `candidates` either succeeded or was skipped because of a verified reuse.
   - `require_coordinator` (`release_acceptance_report.py:155-163`) adds `candidates`, and accepts `skipped` only when `preflight` recorded reuse.
4. **Trust rows.** Add release-candidate rows for caller `release.yml`, event `workflow_dispatch`, jobs `candidates / linux-build` and `candidates / macos`.
5. **`candidate-receipt` job.** It needs every gate and writes `tested: true`, the tier, label, run, attempt and digests.
   - It asserts that the stamped Linux candidate digest equals the bundle that `linux-test` and acceptance consumed.
   - `prepare_release.py` refuses any candidate without such a release-tier receipt from a successful producer job.
   - `candidate_identity.number()` and `prepare_release.candidate_runs` count only candidates that have a tested release-tier receipt. Per-merge `main-*` bundles never block allocation (`tools/candidate_identity.py:31-40`).
   - Negative tests and fixtures:
     - a preview candidate for the release SHA is refused;
     - `candidates_only` succeeds on a SHA that already has per-merge bundles.

**WS5b-2: evidence and publish gate.**

6. **T5 evidence.** A draft-release asset records the source, the suite version, the candidate producer run and attempt, the `release-acceptance` run, and **each installer's packaging run, job and attempt** with its digest.
   - The asset is **only an index**. At publish time, including `publish_only` (the publish job adds `actions: read`), the gate:
     - recomputes candidate digests from the recorded run and attempt through the API;
     - verifies each installer's attestation with signer workflow `linux-packages.yml` or `macos-release.yml` at the expected ref;
     - separately checks that the certificate's run-invocation URI is the recorded `release.yml` run;
     - requires the packaging receipts to name the candidate digests;
     - treats the latest attempt of each job as authoritative.
   - Fixtures cover reused candidates, `publish_only`, an untested candidate, missing or invalid evidence, the wrong signer, the wrong run, a preview candidate, and a release tag behind main. Both special modes schedule zero build or package mutations.
7. **`release-acceptance`** adds an upgrade install from the previous release.

**WS5b-3: switch to option B** (after one hosted `candidates_only` run and one release, or two `candidates_only` runs, succeed).

8. Stop per-merge candidates.
   - Re-point the nightly's Linux packaging (`preview-packages.yml` `linux` job) and preview-tier acceptance at `linux-build`'s `preview-*` bundle.
   - Update `README.md` and `docs/platforms/linux-packaging.md` to use the local wrapper.
   - Delete:
     - `linux-bundle` and the Docker `tested`, `builder`, `artifact` and `integration` stages;
     - the per-merge `main-*` bundle uploads;
     - `linux-bundle` from the acceptance jobs' `needs:` list and `if:` condition;
     - the `candidates / linux-bundle` row and the legacy below-floor trust row;
     - per-merge `distribution-number` (stamped tiers only from here on);
     - `prepare_release.require_candidates` polling (`:58-111`) and its dispatch guidance;
     - the dispatch-only candidate inputs of `macos.yml` (`platforms`, `rebuild_reason`, manual `request_id`) and `ci_changes.py --platforms`;
     - `ci_app_build_transport.py`, only if nothing still uses it.

**Acceptance:**
- `candidates_only` produces tested candidates.
- `release.yml` refuses to publish without valid evidence, including with `publish_only`.
- Preview or unreceipted candidates are refused.

### WS5a: Post-merge evidence

1. **`main-evidence.yml`.** It is never called by another workflow.
   - Triggers: `push` to main, and `workflow_run` (completed) of sweeps.
   - Permissions: `contents: read`, `pull-requests: read`, `checks: read`, `actions: write`, `issues: write`.
   - Concurrency: per SHA, non-cancelling.
   - WS5a removes `macos.yml`'s `push: main` trigger. Main pushes go through `main-evidence.yml` only.
   - `macos.yml` requests only what its jobs need:
     - `pull-requests: read` for `changes`;
     - `contents: write` only on `distribution-number`, which runs only on stamped tiers;
     - `packages: write` only on `publish-caches` (WS2b.5), which runs only on main-ref events.

     It needs no `issues` or `actions: write`. Workflow-structure tests assert that each caller (`preview-packages.yml`, `release.yml`) grants the union, and that no job that can run on `pull_request` declares a `write` scope.
   - **Cache freshness.** When a receipt merge touches cache-input paths (SDK identity, `packaging/build.Dockerfile`, `packaging/acceptance.Dockerfile`, the snapshot in `tools/pins.json`, the `pubspec.lock` files), `main-evidence.yml` dispatches a cache-only publish on `main`. `ci_stats.py` reports cache hit rates.
2. **On push**, it writes a **`validated-tree` receipt** when all of these hold:
   - the main HEAD tree equals the PR's final head tree (compared directly, not via `merged_source`);
   - the PR is from this repository and not from Dependabot;
   - HEAD is the PR's `merge_commit_sha`, or the last commit of its rebased series (`commits/{sha}/pulls`);
   - for each required check name, the **latest** check run on the PR head is from app 15368, belongs through its check suite to the expected workflow path and event `pull_request`, and concluded `success`;
   - **per-job app evidence holds.** For each T1-app job (`linux-build`, `linux-test`, `macos`, each `acceptance-*`), either:
     - the jobs API shows `conclusion == success` for that job in the PR head's latest platform run (a skipped job does not count; a fixture covers a PR that skipped `macos`); or
     - the selection that HEAD's own classifier recomputes over `before..HEAD` did not select it, *and* the push's `before` SHA already has evidence for that job.

   Otherwise it dispatches a sweep for HEAD. It dispatches only while its SHA is still HEAD.
3. **`main-sweep`** runs `macos.yml` dispatched with `sweep: true`.
   - `macos.yml`'s concurrency expression maps `inputs.sweep` to group `main-sweep`, with `cancel-in-progress: false`.
   - `sweep: true` selects exactly the T1-app tier, not the forced selection used by other dispatches.
   - Its first step exits as superseded if that SHA is not HEAD, or if a sweep for the same SHA is already running or complete.
   - Sweeps are marked in `macos.yml`'s `run-name` (`Main sweep <sha>`). A superseded or duplicate exit records `superseded: true` in the run's `ci-selection.json`.
   - **Sweep evidence** is a sweep with `superseded: false` whose `platform-checks` and `acceptance-checks` succeeded on its latest attempt. The run must also be a `workflow_dispatch` of `.github/workflows/macos.yml` on branch `main` whose `head_sha` equals the swept SHA. The title is only a filter.
4. **Reconciliation.**
   - `main-evidence.yml`'s `workflow_run` trigger acts only on sweeps, identified by `github.event.workflow_run.display_title`, because the event payload doesn't carry dispatch inputs. It ignores other dispatches such as `core_coverage_benchmark`.
   - Whether `workflow_run` fires for sweeps dispatched with `GITHUB_TOKEN` must be proven by a hosted fixture. The fallback is to reconcile on every push and in the nightly plan.
   - On each sweep completion, `main-evidence.yml`:
   - makes sure HEAD has a receipt or a queued, running or complete sweep, and dispatches one if not;
   - updates the `ci-main` issue (open/update on red, close on green).

   Response policy: revert first within about 2 h when the sweep isolates one PR; otherwise fix forward within one working day.

   The nightly plan reports main SHAs since the last nightly that have no receipt or sweep (for example `[skip ci]` merges).

**Acceptance:**
- Identical-tree p50 ≤ 6 runner-min.
- A docs-only merge, or a packaging-only merge, on top of an unswept divergent merge gets no receipt for the jobs it didn't run.
- A stale or duplicate sweep cannot leave HEAD unvalidated or run twice.
- A `[skip ci]` merge is caught.

### WS3: Selection rules, label, local tier

`tools/ci_changes.py` becomes a union of rules plus a two-way closure (item 9).

1. **Installed-payload and platform-input exceptions** (these override rule 2):
   - `packaging/notices/**` → T1 app (including `macos`, `package_macos.py:222`) and packaging.
   - `packaging/macos/**` → `macos` (entitlements, `package_macos.py:267`) and the DMG contract.
   - `packaging/acceptance.Dockerfile` → acceptance.
   - `packaging/{minimal,sanitizer}-grpc.cmake` → sanitizers and SDK producers.
2. **Editorial:** `docs/**`, issue templates, and `*.md` outside rule 1 → T1 always. This rule wins over the others.
3. **Quality-only:** root `tests/test_*.py` outside the host inventories, plus MAINTENANCE → T1 always.
4. **Release-only:** an explicit, tested `RELEASE_ONLY` set → T1 always + T2 packaging, with WS5b's negative tests.
5. **Explicit job sets.** For example, `tools/ci_package_sandbox.sh` → packaging, and tools used only by `ci-dependencies` → SDK producers.
   - A test asserts that every repository path referenced by `package-contracts.yml`, the `RELEASE_ONLY` workflows and `.github/actions/**` belongs to a set.
   - Build and stage tooling (`tools/build*.sh`, `verify_app_dependency_reuse.py`, `ci_timing.sh`, `pins.json`, `macos.yml`) maps to T1 app.
6. **Packaging:** `packaging/**`, `tools/package*.py`, `packaging/check_abi.py`, `packaging/app-dependencies/**` and `packaging/build.Dockerfile` → T2 packaging + `linux-build`.
7. **Native and sanitizer paths** → T1 app + T2 sanitizers. The list is exactly `native-sanitizers.yml`'s `paths:`, checked by an equality test.
8. **Everything else, including unknown paths** → T1 app.
9. **Closure in both directions.**
   - *Prerequisites first:* selecting a job selects the jobs it `needs`. For example, packaging selects `linux-build`.
   - *Then consumers:* selecting `linux-build` selects `linux-test`, the `acceptance-*` jobs and the sandbox.
   - A fixture covers a change to `tools/ci_package_sandbox.sh` only.

**Supporting changes:**
- **`ci:full`.** `changes` reads labels live (`gh pr view --json labels`, needing `pull-requests: read`). After adding the label, rerun the platform workflow or push again. For sanitizers, run `gh workflow run native-sanitizers.yml --ref <branch>`.
- **Per-phase acceptance narrowing** stays observe-only. It needs a zero-miss replay of every acceptance failure since Oct 12 and four green weeks of WS-N.
- **`tools/ci_local.sh` (T0):**
  1. `ci_changes.py --explain origin/main...HEAD`;
  2. the T1-always checks, with the hosted tool versions;
  3. the selected T1-app suites that can run on the developer's OS;
  4. a printout of what CI will add.

**Acceptance (replay of the last 50 merged PRs):**
- Editorial and quality-only PRs take ≤ 4 min.
- Release-only and packaging PRs select `linux-build` + packaging + closure, about 18 min.
- App and build-tooling PRs select T1 app.
- Every known escape (#102, #110, #112, #119, #137, #144) selects `macos` and acceptance.
- `test_ci_changes.py` covers every rule, the closure and the reference sets.

### WS7: Identity at assembly (optional, decision 4)

Moving the version, build number, label and revision into a resource file written at assembly would let the nightly and release re-stamp an already-tested build of the same source without recompiling. The stamping is recorded separately, and preview bytes still never become release bytes. Its value is modest after WS5b, so it is deferred until measured.

### WS8: Remaining simplification

1. **SDK migration bridges, after the originals expire** (Linux Oct 31, macOS Jan 16). Delete:
   - `tools/sdk_approval_bridge.py` (380 lines);
   - `create_sdk_approval.py` (174);
   - `sdk_approved_legacy.json` (273);
   - `approved_original` (`ci_artifacts.py:661`);
   - their tests (443 + 306 + 86).
2. **Decision 7: PR-produced SDK promotion**, for both ordinary and instrumented SDKs. If main is to build its own SDKs:
   - First extract the shared `approved_final_heads` proof, and migrate or remove its sanitizer consumer (`ci_sanitizer_artifacts.py:498`).
   - Then delete `tools/sdk_final_approval.py` and the SDK paths through `merged_source`.
   - The WS-P "Sources" exception then lapses.
3. **Producer-wait remnants.**

## 5. Sequencing and expected effect

Estimates come from current-config step medians; each PR reports its measured values.

| Order | Workstream | Depends on | App-PR p50 | macOS jobs / min per app push | Runner-min per app push | Main per identical-tree merge |
|---|---|---|--:|--:|--:|--:|
| – | Baseline | – | 37 | 6 / 32 | 85 | 84–91 |
| 1 | WS-P | owner | 37 | 6 / 32 | 85 | 84–91 |
| 2 | WS0 | – | ~36 | 6 / ~30 | ~83 | ~88 |
| 3 | WS1 | WS-P | ~33 | 6 / ~30 | ~80 | ~85 |
| 4–5 | WS-Na, WS-Nb | WS0 | ~33 | 6 / ~30 | ~80 | ~85 |
| 6 | WS2-0 | – | ~33 | 6 / ~30 | ~80 | ~85 |
| 7 | WS2a | WS1, WS2-0 | ~33 | 6 / ~30 | ~98 (shadow) | ~85 |
| 8 | WS2b | WS2a | ~26–28 | 6 / ~30 | ~89–92 | ~104–111 |
| 9 | WS2b-2 | WS2b | ~26–28 | 6 / ~30 | ~89–92 | ~104–111 |
| 10 | WS4 | WS2b-2 | **~20–22** | **2 / ~20** | ~80 | ~91–98 |
| 11–12 | WS5b-1, WS5b-2 | WS4 | ~20–22 | 2 / ~20 | ~80 | ~91–98 |
| 13 | WS5b-3 | hosted `candidates_only` + decision 2 | ~20–22 | 2 / ~20 | ~80 | ~80–86 |
| 14 | WS5a | WS5b-3 | ~20–22 | 2 / ~20 | ~80 | **≤ 6** (divergent sweep ~84) |
| 15 | WS2c | 2 green nightlies, 1 green arch-drift | ~20–22 | 2 / ~20 | ~66 | ≤ 6 (sweep ~70) |
| 16 | WS3 | WS2c | ~20–22 (editorial ≤ 4; packaging ~18) | **1 / ~19.5** | **~61** | ≤ 6 (sweep ~65) |
| 17 | WS7, WS8 | decisions 4 and 7; artifact expiry | ~20–22 | 1 / ~19.5 | ~61 | ≤ 6 |

**Critical path once WS4 lands.** The longest of three paths:
- **Linux + acceptance:** `linux-build` ~6.5, then `acceptance-cpu` (~3 setup + 0.4 models + 5.5 run) ≈ 15.5 min.
- **Linux tests:** ~6.5 + ~10.5 ≈ 17 min.
- **macOS:** setup 1.2 + Python contracts 1.8 + native ~1.5 (cold) + core ‖ desktop ~8.3 + service 3.3 + assembly and smoke 1.6 + overhead 0.5 ≈ 18.5–20 min.

So push to green is about 20–22 min at p50 and 26–28 min at p90.

**Runner-minutes per app push after WS3** total about 61:

| Job | Minutes |
|---|--:|
| T1 always | 4 |
| `linux-build` | 6.5 |
| `linux-test` | 11 |
| `acceptance-cpu` | 8.5 |
| `acceptance-audio` | 8 |
| `acceptance-deb` | 2.7 |
| `macos` | 19.5 |
| Sandbox and aggregates | 1.1 |

The acceptance jobs start without cleanup and only log `df`.

## 6. Deletion budget and end state

| Workstream | Deleted |
|---|---|
| WS1 | `rpc-contracts.yml`; the `check_integration_inventory.py` step |
| WS-Na | Preview recovery/reuse/revalidation jobs and steps; `tools/preview_reuse.py` (309) + test (358) |
| WS2b | `integration-acceptance.yml` (435); `ubuntu-application`; the cross-run restore in `integration_application.py` and its share of the test (696). `ci_acceptance_plan.py` moves into `changes`. |
| WS2b-2 | `tools/package_contract_candidate.py` (78) + test (124) |
| WS2c | `linux-platform-stages.yml` (301); `setup-linux-stage`; `run_ci_stage.py`, `ci_stage_artifacts.py` (398), `ci_stage_cache.py` (951), `ci_stage_environment.py` (188) + tests (~1.9k), after extracting `tools/ci_git.py` |
| WS4 | `macos-platform-stages.yml` (373); the stage roles of `setup-macos-stage` |
| WS5b-3 | `linux-bundle`; Docker `tested`/`builder`/`artifact` stages; per-merge `distribution-number`; `require_candidates` polling; dispatch-only candidate inputs; `ci_changes.py --platforms` |
| WS8 | SDK migration bridges (~1.6k with tests); final approval only under decision 7 |

**Target:** net CI code (`tools/ci_*`, the CI helpers, `tests/test_ci_*` and the workflows) falls by ≥ 30% from the WS0 baseline, measured with `ci_stats.py --lines`.

**End-state workflows:**

| Workflow | Role |
|---|---|
| `quality.yml` | `python`, `format`, `contracts` |
| `macos.yml` | `changes` (selection, acceptance observer), workflow lint, `linux-build`, `linux-test`, `macos`, `acceptance-*`, sandbox, `publish-caches` (main-ref only), `platform-checks`, `acceptance-checks`. Modes: PR, `sweep`, cache-publish dispatch, `tier: release`, `tier: preview`. |
| `package-contracts.yml` | Called; package lifecycle on the in-run bundle |
| `main-evidence.yml` | New: receipts, sweep dispatch and reconciliation, `ci-main` issue |
| `ci-dependencies.yml` | SDK producers |
| `native-sanitizers.yml` | Path-filtered; daily consume-only run |
| `preview-packages.yml` | Nightly with `nightly-checks`, rerun of failed jobs, issues |
| `arch-drift.yml` | New |
| `release.yml` | `preflight`, `candidates`, prepare, draft, `release-acceptance`, publish, `candidates_only` |
| `release-acceptance.yml`, `linux-packages.yml`, `macos-release.yml`, `linux-registry.yml`, `live-services.yml`, `osv-scan.yml` | Roles unchanged |

The only composite action left is `setup-macos-stage`, slimmed to SDK and Flutter setup.

## 7. KPIs

`tools/ci_stats.py` reports these weekly.

| KPI | Baseline | Target |
|---|--:|--:|
| App-PR push to green, final green commit, p50 / p90 | 37 / 57 min | ≤ 22 / ≤ 30 |
| Runner-min per app-PR push, p50 | 85 | ≤ 62 |
| macOS jobs / min per app push | 6 / 31.6 | 1 / ≤ 20 |
| Share of time at the 5-macOS cap | 22% | ≤ 5% |
| Main runner-min per identical-tree merge, p50 | 84–91 | ≤ 6 |
| Main runner-min per merge, mean (identical share × receipt + divergent share × sweep) | ~85 | ≤ 30 after WS3 (assumes decision 2, option B) |
| Red main heads untracked for more than 2 h | 1 (`88cf883e`) | 0 |
| Cleanup seconds in non-compile jobs, median | 96 | 0 |
| Producer waits over 5 min | 0 in current shapes | 0 |
| Nightly green rate (`nightly-checks`) | n/a | ≥ 90% |
| Escapes (first caught after merge) | n/a | Each fixes its rule in the same PR; more than 2 per suite per month returns that suite to the PR tier |
| Net CI code lines | WS0 baseline | −30% |

## 8. Owner decisions

1. **WS-P text:** approve.
2. **Candidate cadence:** option B is recommended. Candidates are built on demand by `release.yml`/`candidates_only` and by the nightly preview, but preview bytes are never released. Option A keeps per-merge candidates. Each would then have to be a stamped, fully tested release-tier run, costing about 55–75 runner-min more per merge than the ≤ 6 receipt and missing the ≤ 30 mean.
3. **Arch:** keep a daily drift check only (recommended), or drop it.
4. **WS7:** defer (recommended).
5. **Optional: transfer to an organisation for merge queue.** It invalidates SDK reuse once, because the repository name is hard-coded and provenance compares `head_repository.full_name`.
6. **Strict required status checks:** keep off.
7. **PR-produced SDK promotion** (ordinary and instrumented): keep the final-approval check, or drop it so main builds its own SDKs (recommended for simplicity).
8. **Sanitizers on PRs:** keep them non-required (recommended), or make them required when selected.

## Appendix A: Measured step timings

**`ubuntu-application`, PR #146, 15.6 min total:**
- cleanup 348 s (median 96, max 354)
- Docker 16 s
- SDK 53 s
- seed 20 s
- build step 427 s: cache and dependency layers ~23, `COPY` 7, `build.sh` 366, assembly 3, export 22
- `docker cp` 7 s
- tar 46 s
- pack and upload ~13 s

**`ubuntu-package`, 17.4 min total:**
- cleanup 95 s
- restore 9 s
- Docker 12 s
- SDK 12 s
- tools 73 s
- DEB 113 s
- Debian 13 51 s
- models 23 s (2.5 GB)
- CPU 332 s
- Vulkan 62 s
- audio 240 s

**macOS inputs to WS4:**
- setup ~70 s
- Python contracts 109 s
- native stage 85 s, which includes 50–56 s of CTest; compile was 1–2 s, only through reuse
- core 508 s covered (plain ~200–330, to be measured)
- desktop 265 s + release 110 s
- service 196 s
- assembly and smoke ~95 s

**Dependency workflow on main** (39294921183, no compilation): 17.1 min wall, 23.8 runner-min.
- core 5.9 min (cleanup 146 s, namespace 96 s)
- whisper 8.8 min (cleanup 344 s)
- litert 5.8 min
- assemble 2.2 min

## Appendix B: Review log

Reviewers: R1 Actions feasibility, R2 risk and policy, R3 evidence, R4 completeness and simplicity, Codex, and Agy.

**Rounds 1–3** were addressed in revisions 2–4:
- Safety net first.
- Host `docker run` for Linux.
- Provenance validators updated alongside producers.
- macOS and acceptance kept on app PRs.
- `linux-build`/`linux-test` split.
- Direct tree comparison for post-merge receipts.
- Sanitizers standalone, with scheduled runs consume-only.
- Host contracts kept.
- Union rules with payload exceptions and consumer closure.
- WS-P integrity text.
- `nightly-checks`.
- One trust table.
- `workflow_call` T5 with preflight, mode guards and an evidence index.
- `main-evidence.yml` with chained receipts.
- Revised sequencing.
- Current-config baselines and re-derived estimates.

**Round 4 → revision 5:**

| Reviewer | Findings | Resolution |
|---|---|---|
| R1 H, R4 M-B, Codex F1 | Image-ID equality fails on a cache miss | Assert input identity instead (the run-scoped BuildKit cache added here was dropped in revision 6) |
| R4 M-A, Codex F2, Agy 3 | A fresh checkout makes sources newer than the restored objects | Hand over the exact `/src` export with timestamps and a checksum manifest; fixture with real Make |
| Codex R3-N1, Agy 2 | Revision handoff gaps | `package.py --revision`; `/src/dist/packages` copied out; archive uploaded before discard; fork-only forwarding (R1 I, Agy 7) |
| Codex F3, Agy 1, R1 M | Acceptance could start before its prerequisites | Explicit `if:` with `!cancelled()`, plus fixtures |
| R1 M | Release reuse | Reuse decided in `preflight`; `candidates` gated; `prepare` guarded; `source` input and guard kept |
| Agy 6 | Coordinator rejects reuse | `require_coordinator` accepts a verified-reuse skip |
| R2 R4-1 | A preview candidate could be released | Receipts record tier and label; release reuse requires the release tier with an empty label; rows scoped per consumer; WS-P says preview bytes never become release bytes; negative test |
| R2 R4-3, Codex F4, Agy 5 | Attestations bound to the wrong identity | Signer is the reusable workflow, run URI is `release.yml`; per-installer packaging run recorded; fixtures |
| R4 M-C | Release redesign landing in one PR | WS5b split into three PRs with a `candidates_only` mode; per-merge candidates continue until it is proven |
| R4 M-D | Stamped Linux candidate produced outside `linux-build` | `linux-build` stamps on stamped tiers; `linux-bundle` and the Docker stages deleted in WS5b-3 |
| R2 R4-2, R4 L-E, R1 J | Receipt chaining and selection | Per-job chaining via the jobs API; chain to the push's `before`; selection recomputed with HEAD's classifier |
| R1 K | Duplicate sweeps | Dispatch only while the SHA is HEAD; the sweep exits on a same-SHA run |
| Agy 4 | Permissions for dispatch and issue updates | Reconciliation and the `ci-main` issue moved into `main-evidence.yml`; `macos.yml` stays read-only |
| R1 L | Nightly trigger waiting on itself | The nightly trigger exits without waiting |
| R4 L-F | Exercise runs polluting real nights | Exercise runs are marked and excluded |
| R4 L-G | Leftover preview recovery and D14 step | Preview recovery deleted; `check_integration_inventory` step removed |
| R4 L-H | WS-P exception status | The WS-P exception is tied to decision 7 |
| R3 1–3 | Transitional numbers and KPI shape | §5 transitional main cells corrected; the main KPI is split into identical-tree p50 and mean; packaging-only PRs ≈ 18 min |

**Round 5 → revision 6.** R1, R2, R3 and Agy converged. Changes:

| Finding | Change |
|---|---|
| R4 N-1 (medium) | Per-merge main pushes use `main-*` names from WS5b-1. Candidate counting requires a release-tier receipt. Fixture: `candidates_only` on a SHA with per-merge bundles. |
| Codex 1 (medium) | Prerequisite closure runs before consumer closure. Fixture: `ci_package_sandbox.sh`. |
| Codex 2 (medium) | Release-source compatibility floor (`RELEASE_SOURCE_FLOOR`). |
| R4 L-1, Agy 1 | Checked-in `tools/linux_container_build.sh` with the exact builder invocation; local wrapper and docs; `integration` stage deleted. |
| R4 L-2 | Preview packaging re-pointed in WS5b-3. |
| R2 L1, R4 L-3 | WS-P transition clause. |
| R4 L-4, R1 N1 | Run-scoped cache dropped. |
| R4 L-5 | `push: main` removed from `macos.yml`; `workflow_run` filtered to sweeps. |
| R1 N3 | Sweep evidence defined. |
| R1 N4 | Permission wording, plus a caller-union test. |
| R1 N5 | `sweep: true` selects only T1-app. |
| Agy 3 | Concurrency maps sweeps to `main-sweep`. |
| R2 L2 | `conclusion == success`, with a skipped-`macos` fixture. |
| R1 N2, R2 L3 | Hosted fixture for `workflow_run` on dispatched sweeps, with a fallback. |
| Agy 2 | `needs: changes`. |
| R3 1 | §1.1 example breakdown corrected. |
| R3 2 | Option A cost corrected; the mean target assumes option B. |

**Round 6 → revision 7.** R1, R3, R4 and Agy converged. Codex's round-6 run was stopped by the host for low memory and did not report; its round-5 findings were addressed in revision 6. Changes:

| Finding | Change |
|---|---|
| R2 N6-1 (medium), R4 L-e | Registry publication moved to a dedicated main-ref-only `publish-caches` job; build and test jobs hold at most `packages: read`; structure test: no `pull_request`-runnable job declares a write scope; WS-P wording updated |
| R1 D3, R4 L-a, R2 N6-2 | A single rule for below-floor sources: a legacy trust row until WS5b-3, then not releasable; WS-P transition clause aligned; fixture |
| R1 D1, R4 L-b, R2 N6-4 | Script invoked via `/workspace`; `check_abi --report`; stamped-tier Google client and API keys, failing closed |
| R1 D2 | Sweeps marked in `run-name`; `superseded` recorded; evidence requires `superseded: false` |
| R1 D4, R4 L-d, Agy 1 | Run-scoped cache text removed from WS-P and Appendix B; WS5b-3 removes `linux-bundle` from acceptance `needs` |
| R3, R4 L-c | Cache freshness: main sweeps and cache-publish dispatches may write; `main-evidence.yml` dispatches a cache-only publish when a receipt merge touches cache inputs; hit rates reported |
| R2 N6-3 | Dependency-seed producer row in the trust table |
| Agy 2 | Closure wording |
| R2 round 7: L7-1, L7-2 (it confirmed convergence) | Sweep evidence bound to a `macos.yml` dispatch on `main` with a matching `head_sha`; dependency-SDK producers on main push added to WS-P's list of allowed writers |

**Not adopted:**
- R4 round-1 L12 (unmatched paths → T1 only).
- Agy's round-2 premise that `GITHUB_TOKEN` cannot create `workflow_dispatch` runs.
- R1 round-2 N1's polling alternative.
- Codex F1's image export/import fallback: the input-identity assertion makes it unnecessary.
