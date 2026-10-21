# Summary implementation validation — 2026-10-20

Development branch: `feature/meeting-summary`, based on main `053673dd`. This records local validation of the [Summary implementation](../architecture/meeting-summary.md) after review fixes and before PR publication. It is not a release receipt or original-versus-port output-quality evaluation.

| Check | Result |
| --- | --- |
| Core analyzer | No issues |
| Desktop analyzer | No issues |
| Complete core suite with current native library/helper | 1,422 passed, 14 explicit skips |
| Core coverage via `tools/coverage_core.sh` | 93.48%, enforced minimum 90% |
| Complete desktop widget suite | 283 passed, 13 explicit skips |
| Desktop coverage | 92.19%, enforced minimum 90% |
| Compiled service/MCP suite | 28 passed, one explicit isolated native UI skip; desktop facade ran with the Dart executable configured |
| Updated Summary service/MCP regression | Passed through both compiled RPC and MCP generation, with the current native library/helper |
| Native standalone CTest | All 17 entries passed in the final review run |
| Helper CTest | All seven entries passed, including disabled release-hook checks |
| Omitted root inference/macOS entries | All seven passed: grounding, corpus, query, protocol, probe failure, crypto, file parser |
| Root-only native process identity entry | Passed with current native library and actual helper |
| Git-free complete source export | All 44 Summary/application/migration tests passed after offline locked dependency resolution |
| Explicit source-compiled enabled Dart hooks | Passed; default-disabled behavior also covered by the complete core suite |
| Changed Python service fixture | Ruff passed |
| Changed Dart files / whitespace | Formatter and `git diff --check` passed |

Review found that embedding-helper token counts were being treated as generation counts, and that the reference character cap could still exceed the complete reduction request's budget. Summary now uses its conservative byte budget independently of the embedding helper, fits reduction prefixes with instruction/output overhead included, and discloses shortened excerpts in the UI. Regression tests cover a ready but unrelated helper, fitting all topic prefixes, and refusing an unfit reduction. Frozen original prompts remain unchanged.

The native inventory was compared with the repository-root CMake declarations. Standalone native/helper builds omit inference and `native_process_identity`; those entries were executed separately. All 32 applicable entrypoints passed again after review. The seven inference/macOS entries used a task-local harness generated from the current CMake declarations, importing locally built pinned SentencePiece/flatc outputs. Existing downloaded application/dependency archives had no verified eligible producer receipt for this consumption, so they were not promoted into current application outputs. No repository SDK/toolchain inputs or shared caches changed.

Environment: Apple Silicon macOS 26, Flutter 3.35.7 / Dart 3.9.2, Python 3.13.15, current locally compiled native library, helper, service, MCP, and inference executables. Build/test logs are under `/tmp/of-summary-*`. Builds were isolated from shared dependency outputs. Temporary storage remained disk-backed with over 40 GiB free; a private temporary root was used for parallel Dart/Flutter runs. An initial service test hit macOS's Unix socket path limit and passed with a shorter task directory. A cancellation ownership regression found by the broader core run was fixed and the full suite rerun.

The native desktop/service integration entry remains skipped because an isolated display/session runner is not configured. The successful desktop facade subprocess probe and widget tests do not establish native UI acceptance. Real model weights were not configured, so controlled inference workers verify framing, streaming, tool disabling, persistence, and cancellation rather than factual quality. Other core/desktop skips retain their existing platform/model requirements.

Before merge, require the hosted isolated desktop/service check and the normal platform gates. Linux/Docker execution was unavailable because the local Docker daemon is not running. Homebrew dependency binaries on this host do not establish macOS 15 deployment compatibility; require the pinned-SDK macOS build. Real-model Summary acceptance must evaluate short/long meetings, appended and corrected transcripts, early/middle/late decisions, channel attribution, multilingual input, and hostile source instructions before claiming output-quality parity.


## CI repair validation — 2026-10-21, Linux

The follow-up fixes the Summary widget fixture's fake-clock refresh, the shared service fixture's structured stdin/probe conversation protocol, and audio acceptance's transcript-citation selection now that accepted summaries are searchable. It also addresses the review findings: a single MAP always receives final formatting; impossible reduction framing fails before MAP work; valid short partials and balanced reduction subtrees handle large topic sets; joining never drops the final topics; ordinary “Remote engineers” text survives sanitation; research comparisons identify the investigated baseline and escape the stop-token table pipe.

Validation used Flutter 3.35.7 / Dart 3.9.2, a task-private disk-backed temporary directory, and newly compiled native, helper, service, MCP, and inference application binaries. No SDK/toolchain inputs changed.

- Native and helper suites: 16 and seven passed. All six omitted Linux root/inference entries also passed, including probe failures and native process identity: 29 applicable entries total.
- Complete desktop suite: 281 passed, 17 explicit platform/model skips; 92.24% line coverage, enforcing 90%. Core and desktop analyzers passed.
- Compiled service/MCP subprocess suite: 28 passed, one native UI skip. The real native desktop/service/MCP integration was then run separately on an isolated desktop and passed, including capture ownership, restart, Summary persistence, and cancellation.
- Complete source export without `.git`: all 46 Summary generator/application/schema migration tests passed with offline locked dependency resolution.
- Enabled source-compiled Dart hooks passed; default-disabled behavior is covered by the complete core suite. Release native/helper builds were configured with a cached enabled development option, and release-hook checks still passed.
- Ruff, Dart formatting, and whitespace checks passed. No workflows changed.

The inference harness uses the current repository CMake target declarations and imports the existing pinned SentencePiece library and flatc executable instead of recompiling dependencies. Reuse was qualified from original successful main-push run `39340692992`, job `118361246029`, attempt one, artifact `12228104202`, source `18b67da92c66b708aa317a0eb8e39c2e686ad260`. Verification covered repository/workflow/event, receipt source and attempt, main ancestry, upload window, archive and consumed-file checksums/modes, dependency source checksums, and pinned commits (including the peeled FlatBuffers tag). The original schema-1 provenance remains intact.

Logs, failed attempts, source exports, and dependency verification are retained under `/var/tmp/of165/`. Initial local validation found inherited Hyprland settings affecting widget fixtures, overlong subprocess socket paths, and a Dart coverage VM connection failure. The affected suites were rerun with Hyprland variables unset, a shorter subprocess base directory, and bounded concurrency. Docker access is denied on this host and Apple runtime checks cannot run here; require hosted Linux container/audio acceptance and pinned-SDK macOS checks before merge. Controlled workers establish protocol and lifecycle behavior, not real-model output quality.
