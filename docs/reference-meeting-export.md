# Original meeting-note export contract

Target: installed Foresight `1.0.0.28.20261005`, main executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
The follow-up analysis uses IDA Pro, with retained outputs under
`test-results/reference-functions/ida/`.

## Markdown assembly

`composeExportMarkdown` at `0x100a3a910` iterates the already selected items.
For each item it writes a heading, a date line (optionally a Markdown link), a
blank line, and the trimmed note body followed by one newline. Before each
item after the first it writes three additional blank lines. Thus adjacent
records have four newline characters between the first body's final character
and the next heading. It does not rewrite interior whitespace in a note.

The initial port retained note-edge whitespace and joined records with only two
newline characters. `composeMeetingExport` now matches the recovered trimming
and separator behavior while preserving the stored note text. The captured
single-note fixture remains byte-identical. The fixture's explicit 30-minute
event range is now represented in its test data; an item without an event no
longer receives a fabricated end time.

Retained static evidence: `export-compose-markdown.json` (complete 155-line
decompilation). The IDA dispatcher closed after analysis. The REA process
capture reported an environment process-ownership cleanup error, so this batch
does not have a successful canonical capture evidence ID; its retained target
analysis is not being described as a live app observation.

## Ordering, dates and filtering

The sort closure at `0x100a46e2c` compares the right item's start time with the
left item's start time, ordering items newest first. The port previously
exported the oldest first. Equal-date tie ordering remains unverified.

`ExportMeetingNoteItem.formatDateTime` (`0x100a3abf8`) converts its dates to local
time and uses `MMM d, yyyy` plus lowercased `h:mma`. It appends ` - ` and the end
clock only when the end is nonnull. Fetch's no-event branch explicitly supplies
a null end. The optional URL renders as `[date line](url)`. The retained
`export-event-link-arguments.json` and selected PP9735 bind its metadata key to
`htmlLink`; the port now includes that calendar link without modifying its text.
Fetch uses the first linked event and emits one item per note. The port now
selects one linked event rather than duplicating a note for every calendar row.
Its choice of the first persisted row still needs comparison if a note has
multiple different event associations.

The follow-up `EventDocument.queryEventsByDocumentId` trace at `0x10092e1a4`
(`export-event-association-order.json`) has no explicit database ordering. It
filters by document, ignores empty event IDs, deduplicates IDs with an
insertion-ordered map, and replaces a duplicate ID's title when a later row has
a nonempty title. Updating that title keeps the ID's original map position.
There is no recovered chronological or alphabetical priority to reproduce.
Controlled comparison of duplicate IDs and multiple distinct event
associations remains pending because the original association table and port's
calendar cache have different representations.

The formatter now uses the same `intl` date patterns as the original instead of
hardcoded English month names. French locale data is exercised explicitly in a
test. This binds formatting after a locale is configured; it does not establish
the original application's locale initialization policy.

`ExportDateRangeSelection.matches` at `0x100a3ae98` starts from local midnight.
Its Today/7/30/90-day presets subtract respectively 0/6/29/89 **elapsed 24-hour
days**, not calendar-day constructors. The lower comparison is strictly after
that instant minus one millisecond. The upper comparison is before local
23:59:59.999 plus one millisecond. This includes both endpoints at the port's
millisecond storage precision. Across daylight-saving changes the lower preset
boundary can be 01:00 or 23:00 local time. Custom selections instead construct
calendar midnights from the selected dates and include the entire final day.
The port now preserves that distinction.

Public pool constants are retained in `parity-pool-expanded.txt` under REA
evidence `ev_0729d7453527b0cdd781d0537a60548180e3908bcc450b5cbd29f925671d6818`.
The subsequent reader output binds date patterns (PP28443/28495) and durations
(PP28497–28500) to 1,000, 518,400,000,000, 2,505,600,000,000 and
7,689,600,000,000 microseconds. These selected public values contain no account
or distribution credentials.

## Enhanced-note preference

The complete `fetchExportNotes` (`0x100aa4f80`) decompilation is retained as
`export-fetch-notes.json`. `Note.fromRecord` at `0x10072c780` copies record slots
23 and 31 into the corresponding note fields. `NoteRecord.toJson (_2)` at
`0x10062ec00` and the selected public constants in
`parity-stream-export-pool.txt` bind these slots to `content` (PP9089) and
`enhancedContent` (PP19633). `$NotesTableTable.map` at `0x100b3d81c` independently
binds the second field to SQL `enhanced_content` (PP18673).

Fetch trims `enhancedContent` and uses it when nonempty; otherwise it uses the
trimmed raw `content`. A note with empty raw content can therefore still export
its enhancement. An empty current enhancement falls back to raw text instead of
resurrecting an older enhancement.

The port now applies this preference to its current enhanced-notes artifact
(the latest artifact, with its edited value when present), matching the enhanced
notes pane's existing storage representation. Export does not modify raw notes,
generated text, edits, or historical artifacts. Two additional regression cases
cover edited/latest preference, cleared enhancement fallback, enhanced-only
notes, and preservation of stored evidence. These are static-contract checks;
the earlier live single-note experiment did not exercise enhancements.

## Titles

Fetch trims the stored note title, uses linked event information when it is
empty, and ultimately falls back to the public PP28510 string `Untitled
meeting`. The selected string and `OrderingMode.desc` enum were captured in
`parity-stream-final-pool.txt` under REA evidence
`ev_df9f8183d07203dae49c5b22313d69f43279ece1b808f20275aa3ec7989e1fc7`.
The port now trims note titles and falls back to the linked calendar summary
and then that exact default. Stored titles are unchanged.

The original additionally consults the association record's title before the
current calendar event title. The port's calendar cache does not currently keep
a separate association-title snapshot. That distinction, including duplicate-ID
title replacement described above, remains a representation gap pending the
association field/schema binding.

## Remaining acquisition bindings

The caller requests 1,000 notes from `DataStore.queryAllNotes` before filtering;
`Note.queryAll` adds descending database ordering and a limit before mapping
rows. PP13325 is `OrderingMode.desc`; the ordering closure at `0x10092e688`
loads a late table field at offset 55 through the selected PP14907 descriptor.
The correct row mapper is the constant closure at PP14906 (`0x10072c8c0`).
`parity-export-order-field-pool.txt` binds PP14907 to
`Field <$NotesTableTable.timestamp>: late final`, completing the ordering
contract as `timestamp DESC LIMIT 1000`. That selected-field capture succeeded
under REA evidence
`ev_bbdc5555122c2a975255f87602edc619a84d1e864e0f52537b676dcffcea134b`.

Record slot 39 is `timestamp` (PP12416), copied into `Note.timestamp` by
`Note.fromRecord`. The save lifecycle is now bound: accepted saves in
`MeetingTabsViewState._saveNote` (`0x100630f84`) and the scaffold note callback
(`0x1009e96e0`) allocate `DateTime.now()` and replace that timestamp, including
when an existing note is saved. `Note.toCompanion` (`0x1006e8f64`) persists its
epoch milliseconds. `Note.insert` uses `InsertMode.replace`, confirmed by the
selected PP8915 capture in `parity-note-insert-enum-pool.txt`, REA evidence
`ev_9351f4fdb72e468ae0da0f83a07d430581fab9c2e5352c061ce72fa4f66680f1`.
The retained save, scaffold, and companion traces are
`note-meeting-first-save.json`, `note-scaffold-create.json`, and
`note-companion-persistence.json`.

The port now persists nullable save timestamps on standalone and meeting notes.
Accepted raw saves, current enhancement generation, and current enhancement
edits refresh the timestamp. Current enhancement writes update it atomically
with the artifact; edits to historical enhancements and summaries do not.
Migration leaves legacy timestamps unknown rather than inventing a date.
Unscheduled meeting exports use the saved note timestamp when known; legacy
rows retain the existing meeting-date fallback without writing a fabricated
timestamp back to storage. Linked calendar starts still take precedence.

The original acquisition cap remains unimplemented because legacy notes lack
recoverable save times. Applying it to meeting creation times could omit the
wrong notes. The port continues to export all eligible meeting notes; the
original standalone-note inclusion also remains pending. Capturing timestamps
for standalone saves prepares that work but does not add them to export.
Original UI save acceptance, stale-enhancement protection, and debounce/flush
triggers require separate parity work; the persistence change does not claim
to reproduce those guards.

Verification for the corrections: fourteen desktop export tests pass with
`TZ=America/New_York`,
including exact captured-file comparison, a two-note Markdown boundary case,
date filtering, copy/download behavior, save cancellation/error recovery, and
preservation of raw stored notes, and saved-time versus unknown legacy-time
filtering. Five new core regressions cover migration/reopening, accepted-save
refresh, enhancement scope, artifact IDs, and rollback after failed writes;
these pass alongside six application tests. These checks verify the port;
they are not a new live comparison with the original app.
