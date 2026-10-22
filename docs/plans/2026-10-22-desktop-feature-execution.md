# Desktop feature refactor execution

The source of requirements is revision 23 of
[the plan](2026-10-20-core-desktop-refactor-plan.md). This record does not replace
its acceptance criteria. PR 8 and the follow-ups explicitly marked separate
remain outside the feature moves. All desktop extraction, final Linux and
HanSolo matrices, reviews, hosted checks and PR publication remain outstanding.

## Starting point

- Integration branch: `refactor/core-desktop-plan`, initially `a29e8c4d`.
- Fetched `origin/main`: `75898380ac68a0a98dc4a9fdcfc38afc99d133d5`.
- The newer local documentation commit `a29e8c4d` is retained.
- Separate implementation worktrees: `of-reader-prereqs`, `of-status-prereqs`,
  and `of-desktop-fixes`, each branched from `a29e8c4d`.
- Pinned local SDK: `/tmp/foresight-flutter`, Flutter 3.35.7 / Dart 3.9.2.
- Temporary storage: private `/var/tmp/of-pr7/t`, plus private agent roots.

## Implemented prerequisites awaiting full acceptance

| Item | Integration commit | Focused evidence |
|---|---|---|
| F-3 immutable typed v1 presentation decoders and additive connection extensions | `5e8bb301` | Core analyze clean; status and existing desktop boundary tests 7/0. Independent native-agent review found no actionable issue. Claude CLI review pending |
| F-8 MCP isolation, plain schema maps, shared filesystem metadata, core read-model naming and test-only recording setters | `73110d39` | Core analyze clean; schema, frozen policy, MCP protocol, socket, preflight and boundary tests 261/0. Independent review pending. `meta` is now a direct dependency solely for `visibleForTesting`; no resolved package version changed |
| F-2 bounded initial delivery for every reader subscriber; F-12 nine typed factories and prepared-model helpers | `dd0c51c9` | Agent: analyze clean, 45 focused tests passed, no skips. Integrated full-core run pending |
| F-4 bounded trailing status broadcasts, command/stream terminal ordering and settled-preview removal; F-10 data-identity invalidation | `464d5be8` | Agent: analyze clean, 11 final service/socket cases passed. Earlier relevant regression batches 34/0 and 134/1 documented macOS-only skip. Integrated new test import adapted to F-8 rename |
| F-1a hosted acceptance closure | This record's companion closing entry in the historical progress file | Current GitHub API confirms exact `75898380` run 39830379125 completed successfully with all named acceptance and package jobs successful |

The root native build freshly compiled the project's C++ outputs from this
worktree at `5e8bb301` into `/var/tmp/of-pr7/build`, using the retained dependency
SDK. Full root CTest passed 30/30, with no skips. Subsequent changes so far are
Dart and documentation only. This diagnostic build is not the final Git-free
export acceptance or an F-1b responsiveness result.

Logs, including earlier failed attempts, remain under `/var/tmp/of-pr7`,
`/var/tmp/of-readers`, `/var/tmp/of-status-check` and `/var/tmp/of71`.
An accidental repository-root `dart analyze` ran before other packages had
resolved dependencies and failed with missing-package/Flutter errors; the
required package-scoped core analysis subsequently passed. That repository-root
invocation is not an acceptance command.

## Remaining execution

- Finish F-1b's provenance-checking runner, frozen-source baseline/head
  measurements, and the full Linux matrix for 7.0.
- Finish and review 7.1's desktop behavioral fixes and hermetic environment.
- Resolve P0.1 as a separate security change before 7A.
- Execute 7A, 7B-1 through 7B-6 and 7C-1 through 7C-4 in plan order.
- Run native-agent and Claude CLI reviews on frozen integrated changes and
  resolve every accepted finding.
- Run exact-source HanSolo Mac acceptance and final integration matrices.
- Publish reviewable PRs within the repository file budget, inspect hosted
  results and review threads, and integrate the verified changes.

HanSolo is reachable over SSH and reports Xcode 27.1. No Mac test result has yet
been produced for these changes.
