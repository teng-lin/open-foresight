# Desktop UI parity validation

Validated on macOS on 2026-10-16 against the installed Foresight 1.0.0 application. Both windows were observed and operated with macOS Accessibility automation and CoreGraphics mouse events at 1300 × 820 logical pixels. Screenshots are saved locally under `test-results/ui-parity/`.

The development app used an isolated profile with synthetic meetings and transcripts. Existing model registrations pointed to the user's installed model assets. No new model download was requested. The installed user application and its profile were not modified.

## Changes supported by the comparison

| Area | Observation and correction |
| --- | --- |
| Window and header | Removed the extra opaque macOS title bar and grouped heading actions on the right. |
| Meetings | Group meetings under one readable date heading, show times and transcript badges, replace red attachment badges with inline counts, and provide a working Now marker and search reset. |
| Saved meeting navigation | Add the reference's side preview with Notes, AI summary, Transcript, expand, close, and selected-row highlighting. Narrow windows show the preview on its own. |
| Notes | Preview exposes formatting, enhancement style, Enhance, and the enhanced notes panel. Notes persist when expanding the meeting. |
| Transcript | A single selectable saved transcript supports selection across segment boundaries and offscreen text. Copy full transcript includes every saved segment for the selected meeting. Live provisional text remains separate. |
| Model setup | Current models show Done. Cached models can be selected without another download, including registered assets outside the cache when a runner needs repair. Local assets still undergo size and SHA-256 verification before activation. Cached embedding setup says Use rather than Download. |
| Calendar connection | Missing OAuth configuration previously silently disabled Connect Google. The action now opens setup instructions and client-JSON import, with an inline explanation. Meetings also offers Connect Calendar. Configured builds keep the browser sign-in flow. |
| Ask and Sources | Compared both screens; adjusted Ask margins and shared heading/search styling. |
| Stats and Settings | Compared layouts; fixed repeated zero-usage chart ticks and removed the macOS-inaccurate Linux prototype version label. |
| Start existing meeting | Recording from a list row now explicitly targets that meeting, checks setup and permissions, and prevents duplicate starts. |

## Automated validation

- Full Flutter desktop suite: **152 passed, 10 skipped**. Opt-in integration tests retain their existing prerequisites.
- Core Dart suite: **31 passed**.
- Follow-up tests after final preview/layout adjustments: meeting collection, workspace, and generation-model setup passed.
- Flutter analyzer: no issues.
- Native macOS debug app: builds successfully.
- `git diff --check`: passes.

Regression coverage includes 80-segment multilingual selection and copying beyond the viewport, exclusion of other meetings, external cached-model reuse without HTTP, rejection and preservation of corrupted cached files, cached embedding labels, model runtime repair, Google setup cancellation, mocked Google OAuth and Calendar synchronization, date grouping, cancelled Calendar status preservation, preview notes persistence, narrow preview/expansion, short-window Google setup, recording permission cancellation, and all main screens at multiple window sizes.

Review also replaced the meeting list's per-meeting transcript scans with a single grouped transcript-metadata query.

## Native app observations

- Opening generation setup selected the existing Gemma 4 E2B as Current model with Done.
- Opening transcription setup selected the existing Whisper Medium as Current model with Done.
- Connect Google was enabled with missing configuration and opened the actionable setup dialog.
- Native Copy full transcript matched the database text exactly.
- Native Command+A / Command+C included all saved segments. The previous clipboard contents were restored after validation.
- App restart retained the synthetic meetings and existing model registrations without onboarding/download prompts.

Native clipboard assertions are saved in `test-results/ui-parity/native-clipboard-check.json`.

## Screenshots

| Screen | Reference | Development app |
| --- | --- | --- |
| Meetings | `reference-meetings.png` | `open-meetings-after.png` |
| Saved meeting preview | `reference-meeting.png` | `open-preview-after.png` |
| Transcript | — | `open-transcript-after.png`, `open-transcript-selected.png` |
| Ask | `reference-ask.png` | `open-ask-after.png` |
| Sources | `reference-sources.png` | `open-sources-after.png` |
| Stats | `reference-stats.png` | `open-stats-after.png` |
| Settings | `reference-settings.png` | `open-settings-after.png` |
| Current models | — | `open-generation-current.png`, `open-speech-current.png` |
| Google setup | — | `open-google-settings.png`, `open-google-setup.png` |

The reference uses its existing content; the development app uses synthetic content. These are layout and interaction comparisons, not pixel-equality assertions. Open Foresight retains its own branding and reports its own local output statistics.

## Remaining verification boundaries

Live Google account authorization requires an application-owned OAuth Desktop client configuration; this installed build has none. The setup UI and mocked OAuth/Calendar workflow were validated, but an actual Google account connection was not completed. Physical microphone/system-audio accuracy and model throughput were not part of this UI validation. No claim of exhaustive feature or pixel parity is made.

Audio retention and additional transcript export controls are outside this change.
