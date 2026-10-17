# Desktop UX parity follow-up — October 17, 2026

Worktree: `open-foresight-desktop-ux-parity`; branch: `fix/desktop-ux-parity`.
Base: main at `30ad88b`.

## Evidence and changes

This pass reproduces port interaction defects and uses retained reference
contracts to guide conversation boundaries and Google entry points. It does not
claim a new live comparison: Computer Use could find the running original
Foresight app, but could not bind a window (`cgWindowNotFound`). No original
profile, account, notes, recording or application settings were changed.

| Workflow | Reproduced problem | Change and evidence |
| --- | --- | --- |
| Ask / meeting Chat navigation | A draft typed in Alpha appeared in Beta and general Ask. Streaming text and the Cancel answer control were global. General Ask selected every saved answer, including meeting conversations. | Keep a controller per conversation, display streaming text and its cancellation control only in the owning conversation, and filter general history by its existing `desktop` conversation identity. Preserve drafts when navigating away and back. The retained [chat history contract](../chat/reference-chat-history.md) establishes separate general/meeting conversation replay; it does not establish original draft persistence. Per-conversation draft retention is a port UX correction, not a recovered original persistence policy. |
| Drive search / recovery | Submit a newer search before the first completes; a late response replaced newer results. An older failure could also replace the current state. Empty results had no explanation, and retry required resubmitting search. | Accept results/errors/loading completion only for the latest request, clear stale rows while loading, and provide an empty message and explicit retry. Error content scrolls in short windows. These are reproduced asynchronous-state defects; exact original picker behavior remains unverified. |
| Google sign-in cancellation | Imports could open browser consent while cancellation was only exposed in Settings. Explicit cancellation surfaced as a global operation error and could leave the instruction to complete browser sign-in visible. | All entry points share a progress dialog with Cancel sign-in and Escape. Wait for auth cleanup before dismissal/retry, report explicit cancellation without an operation error, and retain actual browser/auth failures. An already-completed connection is kept as success. Existing [Google evidence](google-import-parity.md) establishes direct browser consent using bundled application configuration; the progress dialog is a port recovery design, not claimed as a pixel-exact original dialog. |

The application-owned OAuth configuration, read-only scopes, PKCE and service
transport are unchanged. No account connection or real Google API request was
performed. Synthetic auth fixtures do not prove live consent or reconnect parity.

## Validation

- The new navigation and Drive regressions were run against unchanged main in
  a disposable checkout. All three failed: draft leakage, stale results, and
  missing retry. The corrected branch passes them.
- Full desktop suite before the final error-layout refinement and additional
  success fixture: 113 passed, 10 existing opt-in skips.
- Final focused workflow suite: six passed, including cancellation/retry through
  Settings, Calendar and all three Drive import actions, keyboard Escape,
  browser-launch failure and successful consent at 640×400 with 1.4× text.
- This branch merges cleanly with PR #26 (Ask toggle), PR #27 (Meetings),
  and PR #30 (desktop visual audit). The final combined checkout passed the
  full desktop suite: 118 tests, 10 existing opt-in skips. Static analysis and
  diff checks pass.

Reproduce from `apps/desktop`:

```sh
flutter test test/chat_navigation_workflow_test.dart \
  test/google_picker_workflow_test.dart test/google_sign_in_workflow_test.dart
flutter test
flutter analyze
```

## Remaining comparisons

| Area | Status |
| --- | --- |
| Live Google authorization, reconnection and file/calendar import | Controlled existing transport tests and new cancellation fixtures; real account flow remains unverified. |
| Generated answers and enhanced notes | Conversation/navigation corrected; identical-content visual and selection/stream timing comparison with the original remains open. Existing renderer and note lifecycle tests retained. |
| Graph / label editing and restart | Existing recovered contracts and workflow tests retained. No new live inspector, gesture sensitivity or visual restoration claim. |
| Physical recording | Existing recording tests retained; device disconnect, echo/overlap and physical gesture latency require hardware/reference comparison. |
| Multi-meeting export / native save dialogs | Existing export behavior and tests retained; live locale output and AppKit/portal appearance remain open. |
| Model interruption / switching / cleanup | Existing setup and lifecycle coverage retained; original refresh/cleanup policy and broader original failure/retry comparison remain open. |

These remaining items are verification boundaries, not newly demonstrated defects.
