# Exact desktop UI behavior

Target: Foresight `1.0.0.28.20261005`, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
This pass used the reverse-engineer-anything workflow with IDA Pro 9.3. The
REA IDA provider was unavailable in the existing investigation, so the bounded
owned IDA dispatcher was reused directly. Every owned dispatcher exited with
status zero. These are static findings, not new observations of the original UI.
The original profile and cache were untouched.

## Corrections

| Behavior | Original evidence | Port change |
| --- | --- | --- |
| Meeting export preview | `_ExportMeetingNotesViewState.build` at `0x100a3911c`, nonempty branch `0x100a395e0`–`0x100a39790`, constructs a selectable `MarkdownBody` inside a scroll view. | Render headings, emphasis and lists with the existing selectable Markdown component instead of displaying raw Markdown. Copy and download still receive the unmodified composer output. |
| Native save name | `_downloadMarkdown (_2)` at `0x100a3b4b4` calls `getSaveLocation` at `0x100a3b8d4`. The latter supplies public PP28429, `meeting_notes.md`, to `SaveDialogOptions`; PP23968 and PP13373 are `Markdown` and `md`. Cancellation returns before writing. | Suggest `meeting_notes.md` through the existing native file selector; preserve cancellation and UTF-8 file writing. |
| Graph camera timing | `_animateCameraTo` at `0x100988ab4` defaults to PP36664, a `Duration` containing 350,000 microseconds. `_zoomByFactor` at `0x100989df4` passes PP11679, 250,000 microseconds. PP19617/PP19537 recover the existing cubic curves `.645,.045,.355,1` and `.215,.61,.355,1`. | Change center/fit duration from 300 to 350ms and zoom from 200 to 250ms. Curves already agree. |
| Recording gesture area | `AudioControlPillState.build`'s closure at `0x10098d370` wraps the complete pill container in `GestureDetector`, passing its widget callback at offset119. `GestureDetector`'s constructor at `0x10087e368` binds that callback to `onDoubleTap` (public PP25698). | Attach the existing immersive-view double-tap action to the whole pill, including the timer, instead of only its waveform. Child pause/resume/stop controls retain their actions. |

The original uses the framework's standard double-tap recognizer here. The
port's widget test now checks that isolated timer taps and taps 400ms apart do
not enter immersive view, while a 250ms pair does. This tests the reconstructed
recognizer; it is not a measurement of physical input latency in the original.
As with the recovered outer recognizer, single child-control taps wait for the
standard double-tap window to expire before their existing action runs; the
pause/resume regression explicitly advances that window.

Retained traces are `exact-ui-export-build.json`, `exact-ui-export-preview.json`,
`exact-ui-export-download.json`, `exact-ui-export-save-args.json`,
`exact-ui-native-save-wrapper.json`, `exact-ui-camera-animation.json`,
`exact-ui-camera-zoom.json`, `exact-ui-pill-build.json`, and
`exact-ui-gesture-constructor.json` under
`test-results/reference-functions/ida/`. `exact-ui-public-pool.txt` contains
only selected public UI constants. `exact-ui-evidence-manifest.json` records
their hashes. The selected-pool reader exits zero; its earlier diagnostic run
attempted to interpret an unboxed numeric pool slot as an object and crashed.
That slot was removed before the successful retained capture.

## Labels and graph restoration

The label implementations already agree with the recovered callback order:
`_addLabelToSelectedDocument (_2)` at `0x10097ee28` rejects blank trimmed input,
awaits document-label insertion, clears the controller, awaits propagation,
reloads data and runs organization. `_removeLabelFromSelectedDocument (_2)` at
`0x100988ee4` awaits per-document removal then reloads; it does not propagate or
run organization. The existing editor's focus-loss draft retention is covered
in [the label trace](../research/reference-source-labels.md).

`_loadData` at `0x1009880fc` uses `DocumentGraphDataLoader.loadData`
(`0x10094b7f0`), whose recovered calls acquire persisted document embeddings,
clusters and labels; the view recomputes in-memory edges. This supports the
existing restoration route. This pass does not claim an exact match for every
original graph state or projection from those calls alone.

The expanded restart regression executes document-label removal through the
inspector, checks that another document's provenance/rationale and the global
cluster survive, cancels then confirms global deletion, and reopens the profile.
Deleted labels/clusters stay absent; saved coordinates restore with no repeated
embedding request, including an unavailable helper followed by a new process
and model path. Adding another document requests only its missing vector.
No new label storage policy or graph algorithm was introduced.

## Verification and remaining comparisons

Focused desktop verification covers export formatting/filtering, localized
multi-note preview, actual file writing after a mocked native-selection result,
cancel/error handling, generated-content rendering, graph motion/restoration,
label editing/deletion and recording controls. The desktop export test enters
through the Meetings button, checks the file-selector method arguments, cancels
one selection, then writes a chosen temporary file and compares its full text
with the exact preview Markdown. The native selector boundary is mocked;
AppKit/portal dialog presentation is not exercised by that test.

Controlled original-app multi-note/locale output, label edits/deletion followed
by restart, graph visual restoration, rendered-preview appearance, native OS
save dialogs and physical gesture latency still need live comparison. Original
locale initialization policy, pixel-level renderer parity and all graph input
sensitivity constants are not established by this pass. The existing single-note
original export capture and recovered composer contract remain documented in
[the export trace](../notes/reference-meeting-export.md).

Validation: 31 desktop tests pass across `meeting_export_test`,
`graph_workflow_test`, `graph_restore_workflow_test`,
`graph_label_controls_test`, `organization_label_workflow_test`,
`recording_controls_test` and `generated_content_test`, with
`TZ=America/New_York` and the existing native test fixture. The changed Dart
files pass focused analysis, and `git diff --check` is clean.
