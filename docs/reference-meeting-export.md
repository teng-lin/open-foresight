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

## Remaining bindings

The complete `fetchExportNotes` (`0x100aa4f80`) decompilation is retained as
`export-fetch-notes.json`. Fetch trims two note fields, preferring the first
nonempty field, retrieves event metadata, and sorts the results. The note-field
names still need explicit binding before changing those behaviors. The existing
live single-note experiment alone does not establish
enhanced-note selection or multiple-note ordering; the ordering correction above
is supported by static code analysis.

The caller requests 1,000 notes from `DataStore.queryAllNotes` before filtering;
`Note.queryAll` adds database ordering and a limit before mapping rows. The port
does not yet reproduce that acquisition cap because the original database
ordering column and row-field mapping still need binding. The correct row
mapper is the constant closure at PP14906 (`0x10072c8c0`), not the ordering
closure at `0x10092e688`. The current port continues to export all eligible
stored notes.

Verification for the corrections: ten desktop export tests pass with
`TZ=America/New_York`,
including exact captured-file comparison, a two-note Markdown boundary case,
date filtering, copy/download behavior, save cancellation/error recovery, and
preservation of raw stored notes. These checks verify the port; they are not a
new live comparison with the original app.
