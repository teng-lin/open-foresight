# Desktop UX recovery — October 17, 2026

Worktree: `open-foresight-desktop-ux-recovery`.
Branch: `fix/desktop-ux-recovery`, stacked on PR #32 (`967a35d` after merging
main through `0f62348`). PRs #26, #27 and #30 are already in that main revision.

## Requested fixes

| Finding | Result | Verification |
| --- | --- | --- |
| Legacy meeting answers appear in general Ask | Exclude answers linked through `meeting_answers`, including older rows whose conversation defaulted to `desktop`. No stored answers are removed. Use a noncorrelated subquery to avoid scanning links separately for every answer. | Seed a legacy answer with the desktop default and a meeting link; general Ask excludes it while meeting Chat retains its history. |
| New or streaming answers can be below the viewport | Follow latest output while the reader stays at the bottom. After the reader scrolls up, preserve the offset and offer Show latest answer. New submissions return to the output. Respect user scroll updates from touch, wheel/scrollbar and keyboard rather than only drag events. Recheck dimensions as lazy content lays out. | Variable-height history, streaming growth, deliberate scrolling away, stable offset, and explicit return to latest. Existing scoped-chat tests remain passing. |
| URL import closes before success and lacks Enter submission | Validate HTTP(S) addresses inline, submit with Enter, retain the URL on failure, and dismiss only after successful import. Preserve the existing text-style OK action. | Invalid scheme makes no service call; failed valid import retains its address and error; refocusing and Enter retries successfully. |
| Source edits can lose their draft on save failure | Keep the editor open through save/indexing and expose errors beside the retained draft. Disable editing and repeated submissions while writing. | A failed write leaves the original source unchanged and the typed draft available; retry stores/indexes the same draft. Also exercise 640×400 at 1.4× text size. |
| Generated artifact saves lack progress, duplicate protection and recovery | Reuse the recoverable editor with progress, inline errors, Cancel, and retry. Preserve generated originals and existing manual-edit timestamps. Keep the prior text-style save action. | Gate the write, verify disabled input/save and a single call, fail it, then retry with the exact draft. Existing enhancement timestamp tests still pass. |
| Blank organization label submits silently do nothing | Explain that a label name is required; keep the dialog open and support Enter. Assignment errors also retain the draft. | Whitespace submission shows validation without label/cluster writes; explicit cancellation closes cleanly. Existing successful assignment workflow passes. |
| Bulk imports lack retry of failures | Local folder imports and Find files use per-file tasks. Drive selection and last-year import use the same failed-task results dialog. Retry only unsuccessful tasks, retaining counts/errors; repeated clicks cannot repeat an active retry. | Mixed local batch calls the successful path once and the failing path twice, with a gated retry and eventual success. Existing real local-file folder import, modification-date and paused-import regressions pass. |
| Source deletion is immediate | Confirm the selected source before deleting, in list and grid views. Failed deletion stays in the dialog with a retry action. This adds confirmation rather than an Undo/storage restoration contract. | Cancellation performs no deletion; confirmation attempts it; a failed attempt can retry successfully. |

Drive folder retry retains the existing recursive import implementation: unchanged
indexed children are skipped using cached metadata. The retry UI counts selected
folders as tasks, not individual descendants. This pass does not replace its
subscription/refresh semantics or claim live Google validation.

## Additional issues caught during verification

The short-window regression exposed fixed footer/Meetings controls overflowing
behind a dialog. In short windows, sidebar items and footer scroll together;
Meetings controls and entries also share a scroll view. Normal-height windows
retain pinned controls/footer and the existing layout.

Waiting inside a save/retry modal while source work is already paused would
prevent reaching the main resume control. Source/URL saves and batch retries now
offer an explicit Resume and continue / Keep paused choice before starting that
work. Keeping it paused retains the draft or failures. No automatic resume is
performed. The source-edit fixture exercises both choices.

Shared recoverable dialogs retain their input controllers until the route has
finished departing, announce errors, and support Command/Ctrl+Enter. Successful
submission remains locked during dismissal so a second click cannot write again.

## Validation and limits

- Full desktop suite: **125 passed, 10 existing opt-in skips**.
- Eight focused workflow/viewport tests passed; desktop analysis and
  `git diff --check` are clean.
- Four selected regressions were also run on the unchanged PR #32 base and
  failed as expected: legacy history isolation, URL recovery, blank-label
  feedback, and source-delete confirmation.
- Logs are local `/tmp/foresight-recovery-*.log`; no user content is committed.

Reproduce from `apps/desktop`:

```sh
flutter test test/ux_recovery_workflow_test.dart \
  test/chat_history_viewport_test.dart test/chat_navigation_workflow_test.dart
flutter test
flutter analyze
```

These fixes address reproduced port-side UX defects. The original application
still had no Computer Use-accessible window during the preceding investigation;
no new original UI or live Google account comparison is claimed. See the
[previous UX pass](desktop-ux-parity.md) for the remaining live-reference,
physical-recording, model-lifecycle and native-dialog verification boundaries.
