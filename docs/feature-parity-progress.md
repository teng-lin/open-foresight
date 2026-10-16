# Remaining original-app feature parity

This ledger tracks the features called out under **Not yet reproduced** and the
unverified behaviors in the root README. The full task remains open; passing the
export tests does not establish meeting, speaker, web-search, or label parity.

The initial implementation used `open-foresight-feature-parity` on
`feature/readme-parity`. Follow-up reconstruction is now in
`open-foresight-missing-functions`, branch `feature/missing-functions`.
Historical observations and validation counts below retain their original scope.

## Requirements and current evidence

| Requirement | Current evidence | Remaining work |
| --- | --- | --- |
| Speaker labels and echo cancellation | IDA proves a three-way channel lookup: Microphone, Remote, Unknown. That contract and macOS voice-processing lifecycle are implemented and tested. | Controlled physical echo/overlap and capture-recovery checks remain. Individual-person diarization is not established as an original feature by this trace. |
| Proactive answers | Automatic scheduling, rolling deduplication, queue replacement, meeting ownership and history are implemented. The dedicated detector protocol is recovered and tested. | Production still uses a generic chat detector; reproduce and integrate the original type-4 model loading/decryption and raw inference backend, then verify real capture/model behavior. |
| Meeting web-search fallback | Search transport, remote summary RPC, native tool generation, Ask/meeting wiring, shared citation numbering and persisted URL snapshots are implemented and tested. Release packagers accept bundled credentials. See [chat evidence](reference-chat-web.md). | Provision distribution credentials and verify real-model/live behavior, original prompts and streaming/textual-tool fallback. No separate user project setup has been added. |
| Recording pause/fullscreen gestures | Service pause/resume and immersive controls implemented in the follow-up worktree; native ABI/service/UI tests pass. See [investigation](missing-functions-investigation.md). | Compare exact reference gestures and elapsed-time behavior; validate real-device reacquisition and paused-audio exclusion on both platforms. |
| Rich generated-content previews | Implemented formatted selectable Markdown for enhanced notes, summaries, action items, previous versions and answers. Formatting, raw summary copy/edit, preserved generated originals, links and image handling have deterministic UI coverage. | Compare controlled generated content visually with the original; exact renderer parity remains unverified. |
| Cloud Gemini references | The optional web summary path is now proven to use a remote Foresight RPC with a fixed Gemini model ID. Its client is integrated into optional web-enabled Ask and meeting Chat when distribution credentials are present. | Ordinary answer generation remains local. Endpoint access and remote summary quality are unverified. |
| Meeting export format and filtering | Live original UI observed; a controlled single-note downloaded file is retained as a regression fixture. Filter/preview/copy/download implemented and tested. | Verify additional original scenarios: multiple-note ordering/separators, enhanced-note preference, custom-date boundary behavior and non-English formatting. Native development-app save-dialog comparison is also pending. |
| Label editing | Original Sources → Add label opens Create New Organization Label, explains automatic assignment/clustering, and offers Cancel / Create & Auto-Assign. Dialog was cancelled. Existing add/remove/organization-label tests pass in the desktop suite. | Observe document-label editing and persistence with a controlled fixture; compare state changes, cancellation, deletion and graph restoration. Viewing the creation dialog does not verify editing. |

## Reference identity and export observation

Observed on macOS, 2026-10-16, using the installed
`/Applications/Foresight.app`, bundle ID `com.google.AIEdgeForesight`, build
`1.0.0.28.20261005`. Main executable SHA-256, rechecked during this work:

```text
fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326
```

The original was operated through the computer-use accessibility interface.
Initial window lookup failed, but later access succeeded. REA opened the target
and reported the same hash; deep Hopper analysis failed because Apple Events
control of Hopper was not authorized. No decompiled export logic is claimed.

Observed sequence:

1. Meetings → Export meeting notes opens a preview with **Last 7 days** selected.
2. The filter offers Anytime, Today, Last 7 days, Last 30 days, Last 90 days,
   Custom, Cancel and Apply. Changing to Anytime still showed an empty result
   with the existing transcript-only meetings.
3. The initially empty note in the October 12, 15:19 `[New Meeting]` was given
   the synthetic text `Parity export fixture` through normal typing.
4. Export showed the title, `Oct 12, 2026 3:19pm - 3:49pm`, and the note.
   **Copy markdown** and **Download markdown** became available.
5. Download markdown opened a native save panel with suggested stem
   `meeting_notes`. Saving to `/tmp/foresight-parity-reference-export.md` produced
   the exact bytes in
   [`reference_meeting_export.md`](../apps/desktop/test/fixtures/reference_meeting_export.md).
6. The temporary note text was cleared through normal editing. Reopening
   export showed **No meeting notes found for the selected date range.** again.
   No reference recording or model download was started.

The experiment proves a plain saved-note export and exclusion of the existing
transcript-only meetings. It does not prove how enhanced notes, multiple notes,
time zones, or international date formatting are handled by the original.

## Implementation and verification

`apps/desktop/lib/meeting_export.dart` implements a notes-only Markdown composer
and preview dialog. The dialog starts with Last 7 days, applies or cancels filter
changes, supports custom dates, and copies or saves the selected output. The
desktop awaits saving the currently edited notes before opening export. Empty
results disable copy/download; cancelled save requests do not report success;
write failures remain visible and allow retry.

Calendar event start/end times take precedence over local creation times.
Unscheduled meetings retain the existing UI's 30-minute default duration.
Inclusive local calendar dates and English date/time formatting are current
implementation choices; only the single-note format above has direct reference
comparison. Raw notes, artifacts and transcripts remain unchanged in storage.

Validation on the current implementation:

- Full Flutter desktop suite: **159 passed, 10 skipped**.
- Export tests: **7 passed**, also run with `TZ=America/New_York` to exercise the
  November daylight-saving transition. Includes exact captured-file equality,
  filtering at midnight boundaries, preservation of stored evidence, transcript
  exclusion, clipboard payload, save cancellation/failure/retry, filter
  cancellation and a 640 × 480 window.
- Flutter analyzer: no issues.
- `git diff --check`: passes.

Commands (with the Flutter SDK available on PATH):

```sh
cd apps/desktop
TZ=America/New_York flutter test --no-pub test/meeting_export_test.dart
flutter test --no-pub
flutter analyze --no-pub
```

The opt-in tests remain skipped because their real-model/capture prerequisites
were not supplied to this run. No claim of exhaustive parity is made.

## Rich preview implementation

`apps/desktop/lib/generated_content.dart` renders Markdown through the pinned
`flutter_markdown_plus` 1.0.12 dependency. Its
[maintainer documentation](https://pub.dev/packages/flutter_markdown_plus/versions/1.0.12)
describes the Markdown renderer and selection integration. A shared SelectionArea
supports text selection across rendered blocks. Existing artifact editing still
uses the raw Markdown; Summary and Action items now have explicit copy actions.
Enhanced notes retain their existing copy action. Citation source controls remain
separate from rendering.

Generated images render their alternative text without loading remote URLs or
local files. Only explicit clicks on HTTP(S) links launch the platform opener;
file, script, data and relative links do not. Opening errors appear in the UI.

The full desktop suite after this change passed **162 tests, 10 skipped**, and
Flutter analysis reported no issues. Three new tests verify headings, bold and
italic spans, lists and tables at narrow and wide widths, image/link behavior,
and editing/copying a meeting summary while preserving its generated original.
An optional headless capture is saved under `test-results/rich-preview.png` and
was inspected for layout. Headless font fallback does not reproduce installed
system fonts; this capture is not a reference screenshot comparison.

```sh
cd apps/desktop
flutter test --no-pub test/generated_content_test.dart
```

## Meeting conversation audit

The desktop previously sent every meeting question through the `desktop`
conversation and then linked the most recent desktop answer to the meeting.
Consequently, follow-up retrieval and generation could use a different meeting's
history or general Ask history; concurrent clients could also cause the UI to
link an unrelated answer.

Meeting Chat now passes its meeting ID through the remote domain and application
service. The service validates the meeting and forces `meeting:<id>` as the
conversation. Answer insertion and the exact meeting-answer association use one
synchronous SQLite savepoint. General Ask continues to use `desktop`, and old
saved conversations are preserved. This changes conversation history and answer
ownership; retrieval still searches shared indexed sources. No claim of
reference evidence-scope parity or automatic question answering is made.

Verification: **33 core tests passed**, **163 desktop tests passed, 10 skipped**,
and both Dart and Flutter analysis reported no issues. New tests exercise
follow-up retrieval queries and model prompts with distinct conversation
markers, concurrent remote clients against a real service socket, ordinary and
meeting answer commands, invalid meeting rejection, and manual Chat submission
in two meeting workspaces plus general Ask.
