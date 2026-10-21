# Meeting AI workflows validation

Worktree: `feature/meeting-ai-workflows`, initially based on Summary commit `b34a5cd3e991088894bbcc482a97fe3294f58f20`. Summary is a separate prerequisite and remains outside this diff.

## Reuse and environment

macOS arm64; Flutter 3.35.7 / Dart 3.9.2. Dependencies were resolved offline with enforced lockfiles. Existing task-local native/helper/inference builds were reused: native and service producer source trees and root CMake inventory are unchanged from the parent. No SDK, toolchain, vendor library, CI cache contract or workflow input changed. No shared artifact/cache was published. Service and MCP are newly compiled from this worktree and use the current reused native library/helper.

Private disk-backed temporary storage is used for Dart/Flutter runs; capacity was checked before the suites. Logs, including failed commands and corrected fixture expectations, are retained under `/tmp/of-workflows-*` on the implementation host.

## Results

| Check | Result |
| --- | --- |
| Core analyzer | No issues |
| Desktop analyzer | No issues |
| Complete core suite from a complete Git-free source export | 1,452 passed, 14 explicit platform/model skips |
| Core coverage via `tools/coverage_core.sh` | 93.02% (12,199 / 13,115 lines), enforced minimum 90% |
| Focused workflow/source-scope/Notes/cache/web tests from that export | 88 passed |
| Complete desktop widget suite | 284 passed, 13 explicit platform/model skips |
| Desktop coverage | 90.96% (6,071 / 6,674 lines), enforced minimum 90% |
| Compiled current service/MCP subprocess suite | 31 passed, 1 isolated native UI skip |
| Standalone native CTest inventory | All 17 passed |
| Helper CTest inventory | All 7 passed |
| Root-only inference/macOS entries | All 7 passed |
| Root-only native process identity entry | Passed with current native library and actual helper |
| Explicit source-compiled enabled Dart hooks | Passed; default-disabled behavior covered by full core/native/helper suites |
| Changed Python fixture | Ruff passed |
| Dart formatting / whitespace | Formatter and `git diff --check` passed |

Core export sources were compared byte-for-byte with the worktree before the full coverage run. Export dependency resolution was offline with enforced lockfiles. Native inventory was compared with repository-root CMake; standalone projects omit the seven inference/macOS entries and native-process identity, which were executed separately. This totals 32 applicable native entrypoints. Current service/MCP binaries were compiled separately after the final production edits; no parent/stamped application executable was represented as a new compilation.

Compiled regressions verify Actions/MCP edits/preparation persistence, plus both public cancellation and client disconnect while a real native Notes child is stalled. The unrelated connection cannot cancel that child. Review also found and fixed missing transcript evidence IDs, ignored owner-only task edits, and cancellation waiting on Notes preparation. Existing tests were updated to reject stale Notes output, opt into workspace scope for imported interim-answer context, and verify byte-counted generation-scoped web memory rather than unrelated embedding-tokenizer counts.

## Remaining hosted/runtime gates

The isolated desktop/service integration requires a configured platform/display runner. This host has no isolated macOS display session configured; widget tests and synthetic approval hosts do not establish that boundary. Docker's daemon is unavailable. Linux process/UI, Docker and applicable Apple/package checks remain hosted gates before merge. Native C++ source is unchanged, so no new libc++/libstdc++ stream-shutdown policy is introduced.

No real generation/detector weights were selected for this work. Controlled subprocesses establish ownership, protocol, rollback and persistence only. The portable detector requires a separately supplied compatible raw-completion model/worker and model digest. Real-model semantic acceptance and original-versus-port feature runtime comparisons remain release evaluation gates; no detection recall or output-quality claim is made.

## CI repair validation, 2026-10-21

The real-model web history fixture now reads the generation/scope-versioned `web-memory-v2` checkpoint. Its historical turns still exceed the conservative UTF-8 pruning budget, while the recent turns leave room for the compressed memo. The real-model assertions still require the memo and final answer to retain the early color preference.

The branch also includes the prerequisite Summary CI repairs. Combined checks from a complete Git-free source export passed: 61 core/workflow/Summary tests, five desktop widgets including streamed Summary cancellation, and 31 compiled current service/MCP subprocess tests. The subprocess suite's isolated desktop test was run separately on an owned headless desktop and passed with the current service, MCP, helper and native binaries. Native/helper inputs are unchanged from the verified prerequisite builds and were reused. Dependencies resolved offline with enforced lockfiles; logs are retained under `/var/tmp/ofs-fix-166` on the repair host.

No real model weights are installed on this repair host, and Docker access and Apple execution are unavailable. Their hosted checks, including CPU and audio acceptance, must pass before merge. The local byte-budget exercise verifies memo retention for 64–1,024-byte simulated summaries; it does not establish real-model output quality.

The first main-targeted hosted run passed CPU/model acceptance, including the corrected memory fixture, and every Linux stage and package check. Two remaining fixture assumptions were corrected together: audio acceptance now explicitly selects the raw transcript through the production Chat source controls before asserting its exact citation/revision, and service lifetime tests distinguish promptly cancelled retrieval from native generation cleanup that still owns the busy lifetime. The same source-selector helper passed three focused desktop widget tests from both the worktree and a complete Git-free export. The full service lifetime file passed 47 tests with one explicit platform skip in both locations; scoped analyzers and formatting passed. Real PipeWire/model audio and Apple execution remain final hosted gates.
