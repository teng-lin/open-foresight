# Service lifecycle fixes: execution plan

This plan says **how** the [service lifecycle fix plan](2026-10-19-service-lifecycle-fix-plan.md) is carried out across two machines. The fix plan says **what** changes. Read both before starting a step.

Instead of six reviewed GitHub PRs, each fix-plan PR becomes a local **step**. A step is implemented and reviewed on Linux, verified on macOS, and merged locally into the integration branch `open-foresight-services`. At the very end, the integration branch becomes one large PR to `main`.

## Roles

| Role | Where | Responsibilities |
|---|---|---|
| **Implementer** | Linux host `msi`, Herdr workspace `open-foresight`, pane "Service shutdown and reconnect" (Claude) | Implements each step in its own worktree, runs Linux verification, runs an independent review and fixes the findings, sends the branch to the Mac, merges approved steps into `open-foresight-services`, opens the final PR. The only one who writes merge commits or pushes to GitHub. |
| **Mac verifier** | `SkyWalker` (macOS 26), Herdr workspace `open-foresight`, tab `foresight-claude` (Claude) | Verifies each step on macOS in its own worktree. May commit **small macOS-specific fixes** on the step branch. Reports results in the format below. Never merges into the integration branch except by fast-forward, never pushes to GitHub, never opens PRs. |
| **Codex** (`msi`, pane "Test on Mac before PR") | — | Owns PR #150 (`codex/ci-restructure`), which is **paused**. Does not touch `service.dart` or the service tests while these steps run. #150 resumes after the final PR merges (fix plan 0.3). |

## Branches and worktrees

Both machines use the same layout under `~/src` (`/home/blackmyth/src` on Linux, `/Users/blackmyth/src` on macOS). The main checkout `~/src/open-foresight` holds the shared object store on each machine.

| Branch | Base | Linux worktree | Mac worktree |
|---|---|---|---|
| `open-foresight-services` (integration) | `origin/main` `18b67da9` | `~/src/open-foresight-services` | `~/src/open-foresight-services` |
| `svc/pr0-handoff` | integration tip | `~/src/ofs-pr0` | `~/src/ofs-pr0-mac` |
| `svc/pr1-wedges` | integration tip after step 0 | `~/src/ofs-pr1` | `~/src/ofs-pr1-mac` |
| `svc/pr2-harness` | integration tip after step 1 | `~/src/ofs-pr2` | `~/src/ofs-pr2-mac` |
| `svc/pr3-closing-protocol` | integration tip after step 2 | `~/src/ofs-pr3` | `~/src/ofs-pr3-mac` |
| `svc/pr4-profile-identity` | integration tip after step 3 | `~/src/ofs-pr4` | `~/src/ofs-pr4-mac` |
| `svc/pr5-commit-safety` | integration tip after step 4 | `~/src/ofs-pr5` | `~/src/ofs-pr5-mac` |

The fix plan's branch names (`fix/service-handoff`, `fix/service-wedges`, and so on) map to these step branches. PR 0 cherry-picks the seven commits onto the integration branch's base. Because the integration branch starts at `origin/main` `18b67da9`, the fix plan's "from current `origin/main`" holds.

Remove a step's worktrees on both machines after it merges.

## Moving code between machines

The Mac never needs network access to Linux. The Linux side does all transfers over SSH (`SkyWalker.local`), with a Git remote named `skywalker` pointing at the Mac's main checkout:

```
git remote add skywalker SkyWalker.local:/Users/blackmyth/src/open-foresight
```

- **Linux to Mac (a step):** `git push skywalker svc/prN-…`. The Mac creates `~/src/ofs-prN-mac` on that branch at the exact hash named in the request.
- **Mac to Linux (fixes):** the Mac commits on the step branch in its worktree, with messages prefixed `mac:`. Linux then runs `git fetch skywalker svc/prN-…`, reviews the new commits, and fast-forwards its step branch. If a fix is easier as a patch, the Mac writes it to `~/src/ofs-handoff/prN-mac.patch`, and Linux copies it over with `scp` and applies it with `git am`.
- **Integration sync:** after merging a step, Linux runs `git push skywalker open-foresight-services:svc/integration`. The Mac then runs `git merge --ff-only svc/integration` in `~/src/open-foresight-services`. A failed fast-forward means the branches diverged: stop and report it instead of merging.
- **Nothing goes to GitHub** until the final PR. Pushing step branches to `origin` would start CI for no reason.

## Step lifecycle

Each step moves through these states in order:

1. **Implement (Linux).** Create the worktree from the integration tip. Write the regression tests first and confirm they fail on the base, then implement the fix-plan section.
2. **Verify (Linux).** Run [Linux verification](#linux-verification).
3. **Review (Linux).** Run independent reviewers on `git diff <base>..HEAD`. They look for correctness, lifecycle races, wire compatibility, test determinism, and drift from the fix plan. Fix the valid findings, then go back to step 2. Record the review results for the final PR description.
4. **Request Mac verification.** Push the branch to the Mac, then send the request (format below) to the `foresight-claude` pane.
5. **Verify (Mac).** The Mac verifier runs [Mac verification](#mac-verification) and reports. If it fixes something, it commits on the branch and reports the new head.
6. **Integrate (Linux).** Fetch and review any `mac:` commits. If code changed, rerun Linux verification. Merge with `git merge --no-ff svc/prN-… -m "Merge step N: <title>"` into `open-foresight-services`, then sync the Mac.

Linux may start implementing step N+1 while the Mac verifies step N. Steps still merge strictly in order, and step N+1 is rebased onto the integration tip before its Mac request.

## Message formats

**Request to the Mac** (sent with `herdr --machine SkyWalker agent prompt` to pane `w13:pR`):

```
MAC-VERIFY step=prN branch=svc/prN-… head=<full hash> base=<integration hash>
scope: <checks from the Mac verification list that apply to this step>
focus: <macOS-specific risks for this step>
```

**Report from the Mac**, written to `~/src/ofs-handoff/prN-result.md` on the Mac and repeated in its final reply:

```
MAC-RESULT step=prN head=<hash verified> status=pass|fail|blocked
environment: macOS version, Dart/Flutter versions, native/helper artifact paths and their provenance
commands: <exact commands run>
results: <per suite: passed/failed/skipped counts, skip reasons>
determinism: <loop counts and failures>
mac-commits: <hashes and one-line summaries, or none>
issues: <failures that are not macOS-specific or need the implementer, with log paths>
```

`blocked` means the environment could not run a required check, for example a missing native artifact. Say exactly what is missing. Never mark a check passed that did not run.

## Linux verification

Run this from the step worktree, following AGENTS.md ("Verify changes before pushing"). Use a disk-backed temporary root with a short path, `export TMPDIR=/var/tmp/ofs-prN/tmp FORESIGHT_TEST_TEMP_ROOT=/var/tmp/ofs-prN/t`. During the audit, `/tmp` hit its per-user quota (`EDQUOT`).

1. **Dart core:** the full `dart test` in `packages/foresight_core`, then `tools/coverage_core.sh` with its threshold enforced.
2. **Hook-enabled lifecycle files:** `dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source <lifecycle files>`. From step 2 on, this includes the hook-free check against the release binary.
3. **Determinism:** the lifecycle files 20 times with `--concurrency=1` and 5 times with `--concurrency=8`.
4. **Built service/MCP suite:**
   - Compile `bin/service.dart` and `bin/mcp.dart` into the step's own build directory.
   - Reuse the verified `ForesightHelper`, `model_worker_fixture` and `libforesight_native.so` from `~/src/open-foresight/build`. No rebuild is justified: these steps change only Dart and Python.
   - Run `pytest tests/service` with the variables from `tools/build_service_gate.sh`.
5. **Desktop** (from step 1 on, whenever a step touches `apps/desktop`): `flutter analyze`, then `flutter test --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true`, then the real desktop/service integration on an isolated display.
6. **Counts:** compare test counts and skip reasons with the step's base.

Tools: Dart 3.9.2 and Flutter 3.35.7 (`tools/pins.json`), at `/tmp/foresight-flutter/bin` on Linux.

## Mac verification

The first request also asks the Mac verifier to inventory its environment:
- the location of a Flutter 3.35.7 / Dart 3.9.2 SDK (it is not on the non-interactive `PATH`);
- reusable `libforesight_native.dylib`, `ForesightHelper` and `model_worker_fixture` builds, with their provenance;
- free disk space (`/System/Volumes/Data` is 92% used);
- a short, disk-backed `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT`, because macOS Unix sockets are limited to 104 bytes.

If no verified native or helper artifact exists, report it as `blocked` for the suites that need one and run everything else. Do not rebuild SDKs or vendor libraries. Rebuilding only the helper or native library from the step's sources is allowed only with a one-line justification in the report, as AGENTS.md requires.

Checks, by applicable step:

| Check | Steps |
|---|---|
| Full Dart core suite with the Mac TMPDIR | all |
| Hook-enabled lifecycle files (`--compiler=source`) and 10-run determinism loop | all |
| Built service/MCP suite (`pytest tests/service`) with locally compiled service and MCP | 0, 1, 3, 4, 5 |
| LaunchServices launch path: `serviceLaunchCommand` with `/usr/bin/open`, startup-environment file cleanup, the `service-startup.log` diagnostics | 0, 3 (3.6 startup status file) |
| Lock contention reported as `EAGAIN` = 35 and treated as "owner busy" | 0, 3 |
| Unix-socket path length under 104 bytes for every new socket or fixture | 2, 3, 4 |
| Per-profile runtime is **unchanged on macOS** (`$TMPDIR/of-<id12>`), and the identity check works | 4 |
| Desktop `flutter test` with hooks, and `flutter build macos --release` stays hook-free | 1, 5 |

## Final PR

After step 5 merges and both machines have synced:
1. Run the complete Linux verification and the complete Mac verification on the integration tip.
2. Run one more independent review across the whole branch diff against `origin/main`.
3. Push `open-foresight-services` to `origin` and open one PR to `main` titled "Fix service shutdown, reconnect and handoff lifecycle". The description gives:
   - the finding IDs closed, with tests;
   - one summary per step;
   - the decisions (D1–D6);
   - the Linux and Mac verification evidence, including counts, skips and determinism loops;
   - the reviews run;
   - the line "SDK/toolchain inputs: unchanged; no rebuild".
4. Then tell Codex that #150 can resume (fix plan 0.3).
