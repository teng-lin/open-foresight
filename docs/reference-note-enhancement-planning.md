# Original note enhancement planning and merging

Target: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
These rules extend the [producer trace](reference-note-enhancement.md). They
are implemented as components; Application still needs the full producer
orchestration and runtime integration.

## Note input planning

`planNoteEnhancement` implements input classification at
`0x100a2c118–0x100a2cb98`. Split raw notes by LF, trim every line and keep
nonempty meaningful content. The shared PP34502 callback is a plain trim
(`0x100655884`), and PP34503 checks nonempty text before calling
`hasMeaningfulContent` (`0x1006ea5c0`). Original indices refer to this
filtered list, rather than raw source line numbers.

A line containing the case-sensitive topic heading starts topic stripping.
The heading is omitted, and subsequent star/dash lines are omitted; subsequent
prose and other bullet styles remain. If stripping leaves no notes, retain the
original meaningful-line list. Copy the prior enhancement map. A nonempty prior
map produces an initial formatted snapshot before classifying pending notes.

Notes outside an optional target-index set are preserved. With
`updateExistingWithTranscript` false (the default), prior-map entries and
recognized already-enhanced lines are also preserved. Even an empty prior-map
value counts as an existing entry. Preserved text uses the prior value when
present, otherwise the original note, and is written into the accepted map.
Remaining notes become pending records containing original index and text.
The skipped list retains encounter order. No-pending and empty-input stream
emissions remain the producer caller's responsibility.

Evidence: complete producer pages in `ida/note-enhance-stream-coverage.json`,
`ida/note-input-planning-callback-identities.txt`,
`ida/note-input-trim-callback.json`, and
`ida/note-input-meaningful-callback.json`.

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

The producer serializes a 2,048-token input setting: the producer writes tagged Smi
4096 at slot 31 (`0x100a2eb7c`), and `ConversationConfig.toJson`
(`0x100661978`) binds that slot to PP12760 `max_input_tokens`. This is not
an output-token limit. Complete native bridge coverage (1,306 lines of
`litert_lm_create_conversation_v2`, `0x1000cbe60`) shows that this bridge
has no `max_input_tokens` handling. The Dart handle retains the value, but
both send-entry and send-worker paths do not read that handle field. Thus the
recovered enhancement stream path does not establish an enforced 2,048-token
limit, and the port must not invent rejection or truncation from that setting.
It also encodes the literal `</output>` through the
remote tokenizer before configuring the conversation. The bridge explicitly
parses `stop_token_ids` as arrays of integer sequences and appends nonempty
sequences to `SessionConfig::GetMutableStopTokenIds`. This is native token
stopping, not only text cleanup. The pinned public LiteRT-LM 0.18 C/Python
configuration APIs do not expose a corresponding setter; runtime integration
still needs that capability.

Bridge evidence: `ida/note-runtime-create-conversation-v2.json` (0–599),
`note-runtime-create-conversation-v2-600.json` (600–1099), and
`note-runtime-create-conversation-v2-final.json` (1100–1305).
Dart evidence: `note-runtime-dart-create-conversation-worker.json`,
`note-runtime-conversation-handle-constructor.json`, and complete
`note-runtime-conversation-{stream,send}-{entry,worker}.json` captures.
Native batches 103, 108, 109, 114, 118 and 121 closed with retained exit-0 logs.
These are direct IDA captures through the owned launcher, not new successful
REA process captures.

## Preview versus accepted batch output

Preview cleanup first trims the accumulated raw response, then applies
`cleanNoteEnhancementModelOutput`. It strips one leading lowercase Markdown code fence (11 characters), otherwise
one generic three-backtick
fence, then strips one trailing three-backtick fence, trimming after each step.
It does not repeat model-output cleanup afterward. Final acceptance applies
only model-output cleanup and trimming to the raw response; it does not share
the preview fence stripping. `cleanNoteEnhancementPreviewOutput` preserves
this difference. PP34551 is bound to the exact lowercase Markdown fence by
`ida/note-transcript-fallback-and-fence-public-pool.txt`; caller instructions
are at `0x100a2f1e0–0x100a2f590` and `0x100a30104–0x100a3011c`.


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
per-batch close is awaited. The per-batch catch at `0x100a30d2c–0x100a31098`
logs the error, normalizes each current batch note through fallback formatting,
appends it to diagnostics, and unconditionally replaces its accepted map entry.
Unlike normal omissions, failure therefore overwrites prior accepted values.
Diagnostics also collect every nonempty trimmed terminal response line, retaining
duplicates; they are separate from displayed notes and accepted topics.
`NoteEnhancementMerge.failBatch` implements this recovery. The common awaited
close is followed by advancing to the next batch. Close-error and outer-handler
behavior, and full transport orchestration, remain unverified. This handler was
absent from the decompiler's 3,982 output lines: complete decompiled line coverage
did not establish complete native control-flow coverage. Bounded disassembly
`ida/note-enhance-batch-handler-instructions.json` supplies the missing range
(234 instructions), captured in owned IDA batch 127 with an exit-0 terminal log.

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
The retained test log is `ida/note-transcript-cache-tests.log`. These original component tests did not establish Application integration; the recovered producer is now connected as described below. Cache tracing used
owned IDA batches 97 and 99, both with retained exit-0 terminal logs; these are direct
IDA results, not new successful REA process captures.

Input planning additionally passes 10 tests, including meaningful-line filtering,
topic fallback, prior snapshot ordering, empty prior values, target indices and
reenhancement selection. A combined cache/input run passes 22 tests.

Preview cleanup adds four regression tests (14 tests in its helper file), covering
partial/case-sensitive fences, one-layer stripping, cleanup order and the distinct
final-acceptance behavior. Full core analysis is clean after these additions.

Latest combined note verification: **107 tests passed**, including producer
components, transcript caching, input planning, draft persistence and consumer
stream cancellation. Core analysis reports no issues. The retained log is
`ida/note-producer-component-tests-v4.log`. Three new merge regressions cover
failure overwrites, reordered batch indices and diagnostic order/duplicates.
Those component passes did not establish end-to-end recovered generation parity. The subsequent Application integration is described below.


## Application producer and edit-state integration

Application now composes the recovered input planner, transcript cache,
embedding/ranking/batching pipeline and per-batch native conversation adapter.
Helper embeddings are requested when the pipeline is ready; unavailable embedding
transport retains the recovered empty-vector path. The tokenizer supplies the
ordered closing-tag stop sequence when ready. Native cumulative previews are
converted to incremental producer text without repeating the terminal response.
Each batch gets a fresh conversation with the serialized input setting 2048 and
the runtime's default output limit. This does not add input truncation absent
from the traced native send path.

Manual generation passes the accepted prior map and updates existing notes with
transcript context; force regeneration omits that map. Successful completion
rebuilds ordinal map/pair state and full comparison snapshots from current raw
text. Shorthand saves use the recovered exact/normalized/ordinal matching,
controller rewrite and stale-bullet rules; current enhanced-text edits update
staleness without rebuilding successful snapshots. Cancellation restores formatted
prior notes and rebuilds map/pairs from current raw text while preserving success
comparisons. Historical artifact edits leave current mapping alone.

Workspace clearing cancels draft timers and discards ephemeral maps/cache entries.
Cache epoch guards prevent outstanding saved loads and live readers from
crossing into a cleared workspace whose integer IDs can be reused. These ownership
guards are port lifecycle policy, not a claim about the original view lifecycle.

A focused Application/edit/draft run passes 26 tests. The source-built stop-token
extension additionally passes the actual native configuration-copy test and a
deterministic SDK model check for an ordered two-token sequence; see
[stop-token evidence](reference-native-stop-tokens.md). That fixture does not
prove original production-model or GPU output equivalence. Targeted live edit
queueing, original service retry/reset, complete outer exception behavior and
production package/model acceptance remain open.


Current integrated regression: the full core suite passes **406 tests with 7 skipped**; core static analysis is clean. A subsequent stream regression file passes **10 tests**, including raw edits during generation followed by cancellation and reordering. The full core run also includes both workspace-reset cache regressions (saved load and live reader) and all 14 edit-mapping tests. Retained logs: `ida/note-application-full-core-tests.log`, `ida/note-cancellation-current-raw-tests.log`, and `ida/note-application-core-analysis.log`. Packaging verification passes 15 focused tests and verifies the actual source-built macOS wheel/library manifest; these checks do not establish complete copied-prefix signing/relocation or Linux runtime acceptance.

The final desktop regression passes **192 tests with 10 skipped**, and desktop analysis is clean. Retained logs: `ida/note-application-full-desktop-tests.log` and `ida/note-application-desktop-analysis.log`.
