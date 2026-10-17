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

The port now stores nullable `last_enhanced` and `last_manual_edit` on meeting
notes, preserving unknown legacy values. Raw editor drafts capture manual-edit
time when their body differs from the loaded baseline, and carry that same time
through debounce, retries, and accepted saves. Current enhanced-note edits
capture manual-edit time; unchanged bodies preserve it. Generation completion
sets `last_enhanced`, while historical artifact edits and summaries leave both
current-note dates alone. These writes retain the existing atomic enhancement
artifact/save-time transaction and preserve raw revisions.

The clean editor now checks changed stored snapshots without requiring a note
ID change. It reloads when the stored enhanced body is nonempty but the local
enhanced body is empty, the exact stored-priority date is strictly newer than the
local-priority date, or either raw/enhanced body differs. Dirty drafts, including
failed and in-flight writes, block reload. The programmatic-write flag also
blocks it; this is original state slot 87, set during explicit enhancement,
separate from cancellation slot 103. Equal timestamps do not imply newer data,
and unknown local dates do not acquire invented fallback times. Accepted saves
refresh the loaded baseline only after the latest queued draft succeeds.

The original comparison uses String equality followed by a false-result branch:
body **differences**, not equality, trigger the extra reload paths at
`0x100a89afc` and `0x100a89b60`. This interpretation is consistent with the
captured Dart Boolean offsets and the controller-change equality guard.

Generation timestamps are established by the full parent traces
`ida/note-manual-enhancement-parent-{0,600,1200}.json` and
`ida/note-live-enhancement-parent-{0,600,1200}.json`, successful REA evidence
`ev_a3c43988e7ac006cfb8fbc6431913072ecb121fb0193d182f8da9a324bbfdd43`.
Noncancelled completion allocates the date at `0x100a4aaac`/`0x100a4c338`,
stores state slot 119, and saves the note. The separate start/state callbacks
are retained under REA
`ev_0342282af278de53d909c340c193c42c7de50b68c855b5b15ac5bb4e7c08c4f7`.
The failed `py_eval` batch is not evidence for these statements.

Raw commands remain independent of enhancement artifacts, so the original
combined-note empty-enhancement overwrite guard is not inserted into those
commands. No unsaved-draft generation invalidation policy was inferred from
these traces. The former port-only revision-discard check on enhancement
completion has been removed: completion preserves current raw notes and accepts
the generated enhancement, as the captured parent does.

Completed enhancement output now uses the original `NotesEnhancer.cleanTags`
(`0x1006ec7e4`) before the accepted artifact write. It removes PP19671, PP19672,
and PP19673 regex matches in order, without trimming unrelated content or
repairing partial indices. The original explicitly supplies four false RegExp
flags, including `caseSensitive`; this is bound by
`ida/note-clean-tags-regexp-call.json` and
`ida/note-clean-tags-regexp-constructor.json`. Patterns are retained in
`ida/note-enhancer-public-constants-pool.txt` and replacement order in
`ida/note-enhancer-clean-tags.json`. Fixtures cover case-insensitive line tags,
indexed markers, incomplete tags, preserved markup/whitespace, and accepted
generation persistence without changing raw notes.

The recovered streaming consumer additionally distinguishes the three status
strings `Evaluating notes...`, `Scanning the transcripts...`, and
`Structuring notes...` before writing cleaned content snapshots. The cancel
button only sets state slot 103 (`ida/note-enhance-cancel-state.json`); the
stream consumer then cancels its iterator and restores the prior extracted
bullets through `formatNotesWithSpacing`.

The port now carries meeting/request-specific progress over the existing
application change channel. Local workspaces subscribe directly; remote clients
receive the same capture state. The editor displays the initial raw copy,
cleaned accumulated output, and exact status snapshots. The initial raw copy is
bound by `note-enhance-start-state-6.json` at `0x100a4b4d8`; it is not a guessed
fallback. The cancel action identifies its request, so an old button cannot
cancel a later generation. It sets the cancellation flag and stops on the next
event through iterator cleanup, without introducing a separate native-cancel
policy.

`meeting_notes.enhanced_body` is the current enhanced field. Legacy NULL reads
the latest artifact; a stored empty string remains empty. Programmatic updates
restart a one-second save timer and update this field plus the accepted-save
timestamp, preserving raw text/revision and manual/enhancement dates. They do
not create artifacts. Completion cancels the timer and synchronizes a final
artifact/current field atomically, stamping `last_enhanced`. Current manual
artifact edits synchronize the same field and stamp only `last_manual_edit`;
historical edits leave it alone. Export and editor loading both prefer the
current field. Closing cancels programmatic timers before teardown and performs
no additional programmatic autosave.

Cancellation restores the prior extracted bullets, rather than copying the
prior document verbatim. Extraction splits on literal LF, trims and discards
empty lines, and stops at the first line containing the case-sensitive phrase
`Potential Important Topics Not In Notes`, before heading/prefix filtering.
Lines starting `#` are omitted. The recognized bullet prefixes or
`isAlreadyEnhancedLine` predicate retain the remaining eligible lines. Spacing
trims nonempty entries and joins them with exactly two newlines; its final
dynamic call is a shared identity closure. Proofs include
`note-extract-stop-pattern-arguments.json`,
`note-extract-stop-pattern-pool.txt`, `note-enhancer-extract-bullets.json`,
`note-enhancer-already-enhanced-line.json`, and
`note-format-spacing-string-dispatch.json`. In particular, the extraction
dispatch at `0x100d20a34` is `String.contains`, not `isEmpty`. The restored field
is visible immediately and saved after one second without stamping completion.

This implements the stream consumer, persistence, and cancellation behavior.
The original `NotesEnhancer.enhanceStream` producer remains separate parity
work: it embeds/ranks transcript material, clusters shorthand into batches,
budgets tokens, builds per-batch conversations/prompts, and parses model output.
The port still uses its existing generation prompt; these consumer changes do
not reproduce the original content pipeline.

Six new tests cover deadline reset, captured cross-note drafts, ordered
in-flight disposal, retry of failed drafts, supersession of failed snapshots,
editor switch/disposal persistence, and rejected in-flight saves blocking
explicit navigation until retry. Existing workspace and collection fixtures
also passed in the focused ten-test run. The metadata/reload additions extend
focused coverage to fifteen desktop tests and seven core note tests, including
legacy migration, exact date priority, clean external refresh, dirty protection,
keypress-time transport, retry preservation, and manual enhancement editing.
The complete suites passed with 227 core tests (five skipped) and 189 desktop
tests (ten skipped); the changed core and desktop files also pass analysis.

Latest streaming-consumer validation: 34 focused core tests and the local
streaming/cancellation widget test pass. The full current suites pass with
277 core tests (seven skipped) and 192 desktop tests (ten skipped); both
analyzers report no issues. This includes canonical empty-field migration,
partial-draft deadlines, current versus historical manual edits, cancellation
restoration, initial raw display/save, shutdown, and export preference. Logs
are retained under `test-results/reference-functions/note-consumer/`.
