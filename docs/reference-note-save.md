# Original note save scheduling and protection

Reference: Foresight 1.0.0.28.20261005. Analysis uses REA with IDA Pro and
the matching Dart snapshot reader.

`MeetingTabsViewState._scheduleSave` (`0x1006eab20`) cancels the previous timer
and starts a new one calling `_saveNote`. Selected PP1129 is a Duration with
1,000,000 microseconds, confirmed using its unboxed bitmap and raw field.
The capture is `ida/note-save-debounce-pool.txt`, successful REA evidence
`ev_844d09c27d5cffddf74b020ed9fcf08e6231cd0eda438496e93cbd2c848b39cf`.

The shorthand, enhanced, and title controller listeners compare the new text
with their previous text before scheduling. User edits mark state slot 343
true; programmatic enhanced-controller writes schedule without marking it.
Load and accepted save reset the flag. `flushSaveNote` cancels the timer and
awaits save. Widget replacement cancels timers and saves before loading the
next note. Dispose cancels timers, snapshots all three controllers, and saves
only when the dirty flag is true.

These paths are retained in `ida/note-save-scheduler.json`,
`ida/note-flush-save.json`, `ida/note-widget-update-state.json`,
`ida/note-dispose-flush-state.json`, `ida/note-shorthand-change.json`,
`ida/note-enhanced-change.json`, `ida/note-title-change.json`, and
`ida/note-enhanced-controller-write.json`. Load/lifecycle capture REA evidence
is `ev_637e4f503bedec28f4f8d155807e867eb60c0db71de74671eea61f1b3c1af6d8`;
controller-change capture evidence is
`ev_df8f55f42c7d1e7ac19395e9ccc479f9ac11ed60828fb3dadc534b0c5f4179a8`.

The port now debounces editor changes for one second and captures the meeting
ID and text before a switch. Queued saves remain ordered; preview close,
return to the meeting collection, explicit enhancement, and workspace disposal
flush pending drafts. Disposal drains pending commands before closing their
transport and storage. Failed drafts remain available to retry; newer edits
supersede older failed snapshots. Explicit flush and close observe in-flight
write failures; a failed save keeps explicit navigation on the editor until
retry succeeds. Automatic failures appear in the workspace error state, and a
failed final disposal save is reported through Flutter before teardown.
Persistence commands themselves still apply accepted writes immediately.

Local workspace teardown now also closes its Application. Owned timers are
cancelled before asynchronous proactive/query-runtime shutdown, and storage
remains open until shutdown completes. A remote client leaves the service's
Application ownership intact.

The original additionally protects clean saves against stale state. In
`_saveNote` (`0x100630f84`), only an existing note with dirty flag false enters
that guard. It declines a write when the stored enhanced body is nonempty but
the proposed enhanced body is empty, or when the first nonnull stored date
from `lastEnhanced` (Note slot 47), `lastManualEdit` (slot 55), and save timestamp
(slot 39) is newer than local `lastManualEdit` (state slot 127) or fallback
`lastEnhanced` (slot 119). A mounted view reloads the stored note instead. There is no general
same-body skip. `_recordManualEdit` compares current raw/enhanced bodies with
the loaded note and updates local `lastManualEdit` when either differs.
The exact names are bound by `NoteRecord.toJson` plus selected PP21086–21088,
retained in `ida/note-edit-timestamp-fields-pool.txt`, successful REA evidence
`ev_2f1664083a6d221c14152e01f7d585ce92a44139d75ec52bcf62bc70e1dd8df0`.

Literal timestamp-guard integration remains pending the enhancement timestamp
writer lifecycle and representation in the port. The port saves raw drafts separately
from enhancement artifacts, so inserting a guessed save-time comparison into
the command handler would not reproduce the original combined-note guard.
The debounce change makes no such approximation.

Six new tests cover deadline reset, captured cross-note drafts, ordered
in-flight disposal, retry of failed drafts, supersession of failed snapshots,
editor switch/disposal persistence, and rejected in-flight saves blocking
explicit navigation until retry. Existing workspace and collection fixtures
also pass in the focused ten-test run; 19 core application,
dedicated-runtime, and proactive tests also pass after the teardown correction.
