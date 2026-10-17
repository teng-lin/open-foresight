# Original note enhancement planning and merging

Target: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
These rules extend the [producer trace](reference-note-enhancement.md). They
are implemented as components; Application still needs the full producer
orchestration and runtime integration.

## Transcript windows

`TranscriptEmbeddingManager._chunkAndEmbed` (`0x1009062d4`) trims the source
text, then calls `chunkTranscript` (`0x1009068f0`). The selected PP24883 enum
is `TranscriptChunkMode.live`: live uses 120 words with 20 words of overlap;
the other branch uses 300 words and 40 words of overlap. Only the latest
50 resulting chunks are retained.

Chunking splits on PP11631 `\s+` and removes empty words. Empty input yields
no chunks. Input within the word limit is returned intact after outer trimming,
preserving its interior whitespace. Longer input is rejoined with single spaces.

For each nonfinal window, search backward from its final word through the
inclusive lower bound
`max(proposedEnd - min(overlap, 40), start + maxWords ~/ 3)`.
The latest word matching PP24900 ends the chunk:
`[\.\?\!\;]["\x27\)]?$`.
The exact case-sensitive expression accepts at most one closing quote or
parenthesis after terminal punctuation. When no match exists, keep the
proposed end. The next start is `end - overlap` when that advances beyond the
previous start, otherwise `end`. The final window ends at the final word.

The port implements this preparation in `chunkNoteEnhancementTranscript` and
`ReferenceNoteTranscriptCache`. Application embedding transport and producer
integration remain outstanding.

The recovered cache holds five meeting entries in access order. Scheduling and
successful cached reads promote the entry. Each meeting has one sequential
embedding drain and one replaceable pending request; callers share the running
future, and newer pending transcripts replace older pending transcripts. Results
are accepted only when the request's live/saved mode still matches the current
meeting mode after embedding completes.

Previous nonempty vectors are reused by exact chunk text. Later duplicate chunks
in the previous result win that lookup. Missing vectors are computed sequentially;
newly computed vectors are not memoized within the same pass. Empty vectors are
retried on a later saved read. Live reads await existing work without loading saved
transcripts. Saved reads reload when the entry is missing, in flight, live-mode,
empty, or contains an empty vector. Complete saved results are reused. Cached reads
return the stored list itself. The visible original drain clears its running future
on normal completion; an exception recovery policy is not established, and the port
retains a failed running future rather than inventing recovery.

Evidence: `ida/note-cache-schedule.json` (`0x1009060b8`),
`note-cache-drain.json` (`0x100906178`), `note-cache-entry.json`
(`0x100906d2c`), `note-cache-chunks-copy.json` (`0x100905c8c`, despite
its historical filename this returns the same list),
`note-cache-complete-predicate.json` (`0x1009074cc`), and
`note-cache-nonempty-vector-predicate.json` (`0x1009075c4`).

Evidence: `ida/note-enhance-transcript-chunker.json` (all 232 lines),
`ida/note-enhance-transcript-chunk-and-embed.json` (all 294 lines),
`ida/note-enhance-sentence-boundary-pattern.json`, and selected public pool
captures `note-enhancement-chunk-mode-public-pool.txt` and
`note-enhancement-sentence-public-pool.txt`.

## Batch priority and context

After greedy clustering, the producer sorts batches containing any note whose
original index is absent from the prior enhancement map before existing-only
batches. Empty stored enhancement text still counts as an existing map entry.
There is no secondary comparator or reordering inside a batch. The port
implements `prioritizeNoteEnhancementBatches`. Proof: PP34525 at
`0x100a33c08`, with both predicates PP34588/34589 sharing
`0x100a33cf4`, which negates containsKey on the original note index.

Relevant excerpts deduplicate by trimmed chunk text across the current batch.
First encounter assigns `E0`, `E1`, etc. Each snippet is written as
`<excerpt id="E0">\ntext\n</excerpt>\n`. Empty trimmed excerpts are omitted.
Per-note reference IDs preserve reference order and duplicates, joined with
exactly comma plus space (PP1211). References beyond the chunk list are skipped.

Each note uses a local one-based item ID, its raw shorthand text, optional
prior enhancement looked up by original note index, and the reference IDs.
Prior whitespace-only enhancement text is included; an empty enhancement is
omitted. Text is interpolated without XML escaping. Exact indentation, line
breaks and closing elements are implemented in
`buildNoteEnhancementBatchContext`, bound by PP34530–34546 and the
filter/map callbacks `0x100a33bcc` and `0x100a33b10`.

The producer finds up to two unused chunks in transcript order matching the
case-insensitive PP34522 decision/action keyword expression. Usage is by chunk
index, not deduplicated text. `selectUncoveredNoteEnhancementExcerpts`
reproduces that selection. These excerpts and the optional missed-topic prompt
instructions are included only in the final non-live batch, and only when the
selection is nonempty (`0x100a2e548–0x100a2e594`).

The conversation input limit is 2,048 tokens: the producer writes tagged Smi
4096 at slot 31 (`0x100a2eb7c`), and `ConversationConfig.toJson`
(`0x100661978`) binds that slot to PP12760 `max_input_tokens`. This is not
an output-token limit. It also encodes the literal `</output>` through the
remote tokenizer before configuring the conversation; the exact runtime
configuration path still needs integration.

## Preview versus accepted batch output

`NoteEnhancementMerge.previewCleaned` reconstructs the original interim
merge. Each cumulative cleaned response is parsed with the batch note cap.
The returned note list maps through pending-note indices back to original
note positions. A new map is created on every snapshot. Display order follows
the original note list, with precedence current snapshot, previously accepted
enhancement, then original text. A shorter later parse therefore restores
prior accepted/original text for omitted positions instead of retaining stale
interim output.

Non-live previews append prior accepted topics, then independently rescan the
cleaned response by LF. They accept a line containing the literal topics
heading, or a star/dash line once any displayed line contains that heading.
Exact duplicate strings already in the display are omitted. Plain topic prose
is not included by this preview path. The active index is the last appended
topic's display index when one was appended, otherwise the last parsed
original note index (or the first batch note index when no note parsed).

Final batch acceptance parses again with `parseMissedTopics: !isLive`.
This time the parser's second list is used, including its heading, prose and
marker-only lines. Topics deduplicate against the accepted topic list only.
Parsed notes replace accepted values by original note index. Omitted notes
use putIfAbsent with `_toFallbackBullet`, preserving any prior accepted value.
That helper trims text, preserves any leading star/dash unchanged, and
otherwise prefixes `* `. Final output follows original order and appends
accepted topics only in non-live mode.

This caller independently proves both parser return values:
`ida/note-enhance-final-parser-pair-materialization.json` at
`0x100a30438–0x100a30458` consumes X0 and X1 and allocates a named two-field
record. The matching Dart SDK also explicitly supports unboxed record returns
as a pair of tagged registers. Record field names are not inferred from the
register names.

The snapshot topic predicate is PP34552 at `0x100a2bcc0`; disassembly binds
its contains argument to PP19651. Final omitted-note closure PP34565 at
`0x100a33a30` calls `_toFallbackBullet` at `0x100a31c2c`.
The accepted-map update is explicit at `0x100a30838`.

After each emitted snapshot, the original checks the accumulated raw response
for its four stop markers. A hit cancels conversation processing, cancels the
stream iterator, then closes the conversation. Caller cancellation during
emission cancels the iterator before closing the conversation. Normal
per-batch close is awaited. Full exception-handler orchestration and transport
integration remain outstanding.

## Verification and limits

All 69 producer component tests pass together, and core analysis is clean.
New tests cover context bytes and reference IDs, uncovered-topic gates,
sentence/window boundaries, latest-50 retention, batch priority, meaningful
content/fallback prefixes, fresh preview maps, ordered commits, and the distinct
preview/final topic handling.

These tests verify the reconstructed components, not a new live comparison
with original generation. IDA batches 77, 81, 87 and 89 used the owned Node
launcher because REA process capture could not start. Their complete raw IDA
results and exit-0 terminal logs are retained under
`test-results/reference-functions/ida/`. Public pool probes are bounded;
no configuration map or API credential was extracted.

The transcript cache additionally passes 12 focused tests, including pending-request
coalescing, post-await mode changes, exact vector reuse, sequential embedding,
five-entry LRU behavior, live/saved reads, in-flight saved reloads and error propagation.
The retained test log is `ida/note-transcript-cache-tests.log`. These tests do not
establish the still-unconnected Application producer integration. Cache tracing used
owned IDA batches 97 and 99, both with retained exit-0 terminal logs; these are direct
IDA results, not new successful REA process captures.
