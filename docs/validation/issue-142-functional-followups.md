# Issue 142 functional follow-ups

This records the bounded fix and validation for [issue #142](https://github.com/teng-lin/open-foresight/issues/142). It does not close the remaining physical-device and live-account acceptance work.

## Findings and changes

- The original installed audit build predates merged PR #137. Current source already waits up to three minutes for model verification before declaring service startup failure, reports the startup log path, opens the current audio-only System Settings destination, and refreshes capabilities when the app resumes. Those changes are retained.
- Juniper's complete helper hit was reduced to its title paragraph by passage expansion. Plain documents within the existing 4,000-byte evidence bound now retain their complete contents. Longer semantic hits keep their complete matched paragraphs; lexical windows still expand to a complete paragraph. Structured section boundaries remain in force. A second cause affected the shorter question after a Cedar question: "it" imported the previous subject even though the question explicitly named Juniper. A title-verified subject followed by a local question clause ("and when does it launch?") now stands alone; comparisons, object pronouns and genuine follow-ups retain previous-turn context. The two Juniper questions and Cedar revision 2 have controlled regressions; no similarity threshold changed.
- Meeting artifacts had no generation timestamp and were absent from weekly statistics. Schema version 12 records the generation time of new artifacts. Completed answers and generated artifacts now use the same total and weekly accounting, with Monday boundaries in the local timezone. Editing generated output does not count as new generation. Future-dated output does not enter a week before its timestamp. Legacy artifacts with unknown dates remain in the lifetime total without an invented generation week.
- Ask clears the submitted draft after an accepted response or normal stream completion. An early rejection retains the draft, and a replacement draft is preserved. Drafts remain scoped to their conversation.
- Drive imports retain successful selections and offer **Retry failed files** for just the failed IDs. A controlled HTTP/OAuth fixture and real embedding helper exercise two file exports, a failed second download, restriction errors, retry, and retrieval of both indexed results. This does not establish live Google-account acceptance.
- Folder selection now opens a checked file review. Cancel imports nothing; Import reads only the selected files. The existing bounded scanner reports unreadable folders and scan limits.
- A completion regression verifies that streamed enhanced notes become the saved visible output without navigation. Existing cancellation and process tests retain their scope; no unproven enhancement implementation change is included.

Closing the last desktop window and explicit Quit retain the existing ownership cleanup. Continuing in the menu bar remains a separate product decision; independent headless service ownership is preserved.

## Baseline and build reuse

The latest completed main macOS application candidate used source `a739c640df122de1dc04c670fffc56838f8f8607`, version 0.1.2/build 19, produced by [run 39260157432](https://github.com/teng-lin/open-foresight/actions/runs/39260157432). The repository's candidate verifier checked its producer workflow, successful job/attempt, receipt, artifact digest and payload checksum before extraction. Its relocated desktop-first/MCP, persistence, graceful stop, upgrade and rollback smoke passed.

The local changed application uses that candidate's native, LiteRT and Whisper runtimes. Retained native compiler outputs were verified against their original receipt and unchanged native/helper/protocol/CMake inputs. Only the helper build identity was recompiled and relinked from verified original objects. Dart service/MCP executables and App.framework were compiled for the changed application code. The host initially linked the generated Dart assembly with a macOS 26 minimum; that assembly was recompiled/relinked for the project's macOS 15 minimum without rerunning Dart snapshot generation or compiling dependencies. The corrected bundle passed dependency/runtime checks, strict deep signature verification and the same relocated application smoke.

No SDK, gRPC/protobuf, LiteRT, Whisper, FlatBuffers or SentencePiece library was rebuilt. Existing model files were reused. Private test copies preserve the original application database and matching helper index; an application database copy alone does not preserve its embedding index.

## Local validation

- Root CTest inventory: **32 passed**, including inference/probe failures and release-hook checks.
- Dart core: **992 passed, 8 opt-in skips**; **91.02%** line coverage, exceeding the 90% gate. Enabled development hooks were separately tested with the source compiler.
- Desktop: **188 passed, 9 opt-in skips**, with hooks both disabled by default and explicitly enabled; **82.39%** line coverage, exceeding the 76.35% gate. The real-helper Google protocol test was additionally enabled and passed.
- Compiled service/MCP: **20 passed**, including the real macOS desktop/service integration, capture ownership, final transcript persistence, worker recovery and independent profile boundaries.
- Calendar-week tests cover America/New_York (including the DST boundary), UTC and Asia/Shanghai. Core and desktop analysis passed.
- Current-main and changed local packages passed relocated desktop/service/MCP smoke with minimal environments, document extraction, persistence, idle upgrade and rollback.
- Real helper retrieval and Gemma synthesis passed both Juniper prompts (**7 November 2026 / Mira Chen**) and Cedar revision 2 (**12 November 2026 / Rowan Vale**), each with a saved citation. These used the installed model files and matching copied helper index, with the reported `litert-lm-cpu-native` generation backend. The original profile was not modified.

Initial failed test output and corrected runs remain in the task's private validation logs. A temporary-directory permission error was corrected before rerunning core coverage. Three review agents examined retrieval/statistics, desktop flows and issue acceptance. Their lexical-paragraph and follow-up-reference findings were reproduced, fixed, and covered by regressions; the final review had no remaining findings.

## CI follow-up

The first PR run exposed two additional failures. Acceptance ran main's updated workflow against the branch's older `ci_app_build_transport.py`, which rejected `--acceptance` before any package work. Merging main's `fdac229` keeps the workflow, transport CLI and acceptance image recipe together. Linux core's first helper-adoption fixture missed the 400 ms production probe and attempted its deliberately invalid second-helper executable. The fixture now establishes an RPC-ready channel before exercising adoption; the production deadline and compatibility assertions remain unchanged, and teardown is registered before the readiness wait.

The corrected fixture passed on Linux with one CPU, cached Dart packages and a complete source export without `.git`. Core again passed 992 tests at 91.02% coverage. The full offline Python suite passed 2,444 tests with 25 opt-in skips at 96.14% coverage, above its 95% gate. The relevant CI/tooling tests passed from that export with another PR ref, main and no inherited ref (111 tests per run); the real offline BuildKit cache fixture also passed. Workflow lint used actionlint 1.7.7 with ShellCheck 0.11.0 on PATH; ruff, mypy and subprocess-timeout checks passed. The successful native/SDK producers and running macOS service validation were preserved; neither failure required recompiling dependencies.

## Remaining acceptance

Do not treat these fixture/process results as physical microphone or system-audio acceptance. A fresh packaged run still needs a controlled audible fixture, actual macOS consent/status refresh, pause/resume/stop, final speech text, and speaker/channel inspection. A live Google account must still complete a two-file batch, restricted/mixed selection and retry. Window automation was intermittent (`cgWindowNotFound`), so manual cold-launch/reopen and citation-navigation acceptance must be completed on the final installed package. Linux isolated-display and other selected hosted platform checks must pass before merge. Keep issue #142 open until these acceptance items and the background-lifetime product decision are resolved.
