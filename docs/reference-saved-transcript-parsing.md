# Saved transcript parsing

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Static IDA Pro evidence was retained through REA process capture
`ev_aa3da4245079ebe654c9dc785bc08246cdbb806aa86b2346e3976d897325515f`.
Additional bounded disassembly/decompilation is retained under ignored
`test-results/reference-functions/ida/`. This is static reconstruction; original
malformed-input behavior was not exercised at runtime.

`parseStructuredTranscript` (0x1006eb7c0) trims for the leading `[` probe,
JSON-decodes a list and eagerly converts every segment. Its error landing pad
0x1006eb8e8 retries the original input as legacy text. Segment conversion
0x1006ec2e0 reads nullable `segment_title`, `turns`, `duration_seconds`; title
falls back to `Untitled Segment`, turns to an empty list and numeric duration
uses `toInt`. Turn conversion 0x1006ec5c4 reads nullable `speaker`/`text`, with
`Unknown`/empty defaults. Invalid field types invalidate the complete JSON path.
Default strings here use the original English messages.

Legacy parsing 0x1006eb91c splits on LF, trims lines and skips blanks. Exact
`--- [` / `] ---` wrappers introduce segments; the interior title is preserved.
Other lines split at the first `: `, retaining subsequent delimiters. Lines
without a delimiter use speaker `Transcript`. An initial ordinary line creates
the default `Transcript` segment; empty headings remain represented.

Formatting 0x10090709c writes the heading, one LF-terminated line per turn and
one blank line per segment. Speaker text is trimmed; turn text is preserved.
`isGenericSpeakerLabel` 0x100907360 strips leading `[(*` and trailing `])*`, then
trims/lowercases and omits empty, microphone, remote, speaker, unknown and
transcript labels. Named speakers retain the `: ` prefix. Public snapshot-pool
slots were read using a bounded local Dart snapshot reader to resolve these
literal values; credential slots were excluded.

Saved extraction 0x100906fc0 probes trimmed input starting with `[` or starting
with `{` and containing the exact quoted `"turns"` token. It formats nonempty
parsed segments; otherwise it returns the original record, preserving ordinary
text. The object probe still delegates to the list-only parser and therefore
uses its legacy fallback. `loadSavedTranscriptFrom` 0x100906e9c trims extracted
records, filters empties and joins with two LFs. Application saved-note loading
now applies this extraction before its existing trim/filter/join. Live segment
formatting remains its separate original path.

Tests cover the schema/defaults, fractional duration, complete-input fallback,
CRLF and blank lines, headings, exact delimiters, speaker normalization and the
saved extraction gate. No new project configuration is required.
