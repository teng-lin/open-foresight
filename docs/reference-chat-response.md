# Original chat response processing

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis uses REA with IDA Pro and the matching Dart snapshot reader.

## Recovered transformations

`normalizeTimestampFormatting` at `0x10090fdc8` applies 15 ordered regex
replacements. The public expressions are PP[30753] through PP[30781]; their
14 distinct replacement closures are retained as
`ida/chat-cleanup-closure-<address>.json`. The transformations repair duplicated
year digits, malformed year fragments following month names, missing spaces,
three-digit hour errors, overlong minutes, extra seconds preceding AM/PM,
range separators, and overlong day numbers. This is the original bounded
string-repair policy; it does not parse or validate arbitrary dates.

`alignResponseNumbersWithContext` at `0x10090ec70` compares a number and up to
four neighboring words with the first matching phrase in the supplied context.
It tries successively shorter prefixes for a number before words, or suffixes
for a number after words. The minimum phrase length is three UTF-16 units.
Its 41-entry `shouldIgnore` list skips phrases starting with time/calendar
terms. This prevents this general alignment pass from replacing schedule
digits already handled by timestamp normalization. The prefix check is literal:
for example, `to` also matches the beginning of `total`.

A different context number can replace the response number. When the response
number begins with that context number, more than two additional digits are
left unchanged. Duplicate start/end spans are suppressed. Replacements apply
from the end of the string so earlier offsets remain valid. The original
algorithm does not choose the closest numeric value or compare every matching
context phrase.

The original send path normalizes and aligns the assistant response before
adding it to history (`0x10090bce4`, `0x10090c31c`, `0x10090c914`). Citation
selection and display renumbering follow history insertion. The separate
`sanitizeChatResponse` path removes wrappers, thought traces and terminal
repetition, balances unescaped quotes, and normalizes timestamps again. That
processor is also implemented. Streamed JSON-field extraction and conversation
streaming/cache lifecycle comparison remain open.

## Evidence

- `ev_c2db9756a6a5818d64aab519248c3aa445106a84b5586312d84e83a272ce0721`:
  exact public regex strings, ignore-term list and replacement closure offsets.
- `ev_fa6e3b8f8de25a4a9e1f478bfe5adc7e98c3b2824bbd229d4044838e79717696`:
  additional scalar separators and public export constants.

The full alignment function is retained in
`ida/chat-align-response-context.json` and
`ida/chat-align-response-context-tail.json`. The closure batch completed and
closed IDA; its REA wrapper reported an unrelated process-environment cleanup
inspection failure. Retained decompilations are analysis results, and that
wrapper failure is not represented as a successful process-capture record.

## Application integration and verification

Web-enabled sends normalize provisional visible text. At completion, Domain
normalizes the response and aligns its numbers against the same bounded
3,000-unit retrieved local context used by the original. Web-search tool
results are not substituted for this context. The structured assistant message
receives the corrected text before memory insertion. Final display sanitation
and source selection/renumbering follow. Existing nontext metadata is preserved
without mutating the model's original map.

The original final-cleanup call at `0x10090c940`–`0x10090c948` loads the aligned
plain text from stack slot -1032, with the decoded raw text at -1016 as an
empty-result fallback (`0x10090c954`). This confirms a narrow original edge:
the plain-text trailing regex `[\s\}\],]+$` removes a final `]`, including the
closing bracket of a bare terminal `[Source:2]`. A sentence ending in
`[Source:2].` retains its citation. The port preserves this behavior; a focused
regression covers both cases. Existing history/link fixtures use punctuated
sentences to keep testing valid citation transport. This is established by
static call/regex evidence, not an original-app live output comparison.

Sanitizer delegation is retained in
`ida/chat-sanitize-delegate-<address>.json`; additional helpers are
`chat-clean-three-digit-hour.json`, `chat-words-equal.json`, and
`chat-skip-punctuation.json`. Exact thought/channel search arguments are bound
by `chat-thought-search-arguments.json` and
`chat-sanitize-channel-arguments.json`. Constructor argument descriptor PP[566]
binds the regex flags: caseSensitive argument 2, dotAll 4, multiLine 1,
and unicode 3. `chat-time-group-disassembly.json` confirms the AM/PM-with-seconds
replacement uses groups 1, 2, and 4.

Thirteen focused response tests cover wrappers, internal metadata, thought
traces, incomplete markers, loop cleanup, punctuation-only formatting, quote
balancing, malformed dates/times/hours, number alignment and metadata
preservation. Application checks cover corrected date/time text before citation
compaction and history replay, and numeric repair against fixture RAG context.
The complete native-enabled core suite passed **187 tests, three opt-in tests
skipped**. No real model or Google/ODML request was needed by these fixtures.

Additional public snapshot evidence:
`ev_8bdcb6587b015d1703269f15f982c84adfc73b1c1bd3ddc7c6d01806b2714fe9`
retains the selected scalar separators, keyword list and class metadata.
The evidence does not establish end-to-end streaming or cached-conversation
parity, and those remain unfinished.
