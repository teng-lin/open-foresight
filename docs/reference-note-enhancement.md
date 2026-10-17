# Original note enhancement producer

Target: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis uses IDA Pro and the matching Dart snapshot reader. The complete
3,982-line producer at `0x100a2bd08` is retained in
`test-results/reference-functions/ida/note-enhance-stream-producer-*.json`.
The stream consumer is documented in [note saving](reference-note-save.md).

Coverage audit: the original fixed 600-line page requests had shorter replies
with cursors at 1758, 2340, 2923 and 3532, leaving gaps before the next fixed
offset. Those four gaps have now been captured explicitly in
`ida/note-enhance-stream-gap-*.json`. The checked
`ida/note-enhance-stream-coverage.json` manifest covers every line from 0
through 3981 exactly once. The earlier fixed-offset pages alone did not prove
complete coverage.


## Greedy note batches

`_clusterScribblesIntoBatches` at `0x100a328bc` receives per-note transcript
reference lists and a note list. Its result contains note indices. The port’s
`clusterNoteEnhancementBatches` preserves this algorithm:

1. Seed a batch with the earliest remaining note. Seed acceptance is unconditional.
2. Copy its transcript references into an insertion-ordered set. Scan remaining
   notes in order, accepting a candidate only if any reference belongs to that
   set and the proposed union fits the budget. Add its references to the set
   and remove the candidate from the remaining list. Earlier rejected candidates
   are not revisited when a later acceptance expands the union.
3. Stop scanning when the batch reaches four notes or the remaining list ends.
4. Only if the batch still has fewer than two notes, scan remaining notes again
   without requiring overlap, under the same budget and four-note cap.
5. Append the batch and repeat. There is no final index sorting.

Both scans accept exactly when
`350 * unionReferenceCount + 50 * proposedNoteCount + 300 <= 2000`.
Duplicate references count once. An oversized seed remains its own batch.

Evidence: the complete 563-line
`ida/note-enhance-cluster-batches-0.json`, callback binding PP34610 in
`note-enhancement-producer-public-pool-v2.txt`, and
`ida/note-enhance-cluster-overlap-predicate.json`. The callback’s shared code
at `0x1008fc498` calls set containment; its unrelated merged IDA name is not
used to infer behavior. The call-site dispatch offset +41834 resolves to
`ListBase.any` at `0x100878a5c`, independently retained in
`ida/note-enhance-cluster-any-dispatch.json`. Eight regressions exercise
overlap expansion/order, singleton fallback, union budgeting, deduplication,
four-note limits, input preservation, and oversized seeds.

## Model output cleanup

`_cleanModelOutput` at `0x100a322b0` finds the earliest occurrence of four
case-sensitive literal markers: `</output>`, `<turn|>`, `<eos>`, and
`<end_of_turn>`. It truncates before that occurrence, replaces matches of
`^\s*#+\s*Key\s*Notes\s*$` with empty text, and trims the result.
The expression is case-sensitive and not multiline: a Key Notes header above
real note content is preserved by this particular helper. The implementation
does not broaden that original behavior.

Evidence: `ida/note-enhance-clean-model-output.json`,
`ida/note-enhance-clean-marker-index-disasm.json` (PP34554 array binding),
and selected public PP34554/34593 in the v2 pool capture. The port implements
this as `cleanNoteEnhancementModelOutput`. Cleanup and existing consumer
helper tests pass together with the batch tests: 18 focused tests, with clean
core analysis.

## Batch output parsing

The parser at `0x100a31cc0` returns **two lists**, despite decompilation
showing only the first. The return sequence at `0x100a321a0` puts primary
notes in X0 and the separate missed-topic list in X1. This is bound by
`ida/note-enhance-parser-return.json`; dropping X1 would lose original
behavior. The port’s `parseNoteEnhancementBatchOutput` returns both lists.

Input splits on literal LF (PP1109), trims each line, and skips empty lines.
Before entering the missed-topic section, a line containing the case-sensitive
phrase `Potential Important Topics Not In Notes` either ends parsing
(default `parseMissedTopics=false`, PP34590), or becomes the first missed-topic
entry. Once enabled, that section retains every subsequent nonempty trimmed
line, including prose and marker-only lines, without the primary-note cap.

Primary notes stop being appended at the supplied count limit. Lines matching
`^[*\-]+$` are ignored. A line beginning `**` gains the literal prefix
`* `; other lines starting `*` or `-` are retained unchanged, even without
a following space. Prose, headings, plus bullets and round bullets are ignored.
Continuation lines are not merged into a previous note. The topic check occurs
before the primary-note count cap. Exact prefix branches are retained in
`ida/note-enhance-parser-prefix-branches.json`. Five regression tests cover
these distinctions, including disabled/enabled topics and a zero note limit.

## Prompt assembly

`buildNoteEnhancementPrompt` reproduces the nine-piece concatenation at
`0x100a32740`: style instructions, optional missed-topic instructions, relevant
excerpt opening, relevant content, closing, uncovered content, shorthand
opening, shorthand content, and output opening. Caller-supplied uncovered
content remains present even when the optional instructions are disabled.
No escaping, trimming or extra separator is inserted.

Selected PP29539 is `NoteEnhancementStyle.NOTE_ENHANCEMENT_STYLE_CONCISE`,
confirmed by the bounded enum-field probe in
`note-enhancement-producer-public-pool-v3.txt`. It selects PP34602/34603; the
other branch selects PP34608/34609. PP34604–34607 are shared delimiters.
The literals reside in `reference_note_enhancement_prompt.dart`. Four tests
check exact standard/concise fixtures, section newlines, optional instructions,
and preservation of caller-supplied uncovered content. The fixtures derive
from the selected original public pool strings. All 27 parser/prompt/batching/
cleanup tests pass together, and core analysis reports no issues.

## Excerpt ranking

The port now implements `selectNoteEnhancementExcerptRefs` and
`noteEnhancementCosineSimilarity` in `reference_note_enhancement_ranking.dart`.
The producer chooses two excerpts per pending shorthand note, or one when
there are more than five pending notes (`0x100a2cf28`). Each pending note’s
text is embedded via RagOrchestrator.computeEmbedding, concurrently through
Future.wait. The callback PP34511 is bound to `0x100a33e4c`.

If that note’s embedding is empty, or **any** transcript chunk embedding is
empty, selection uses the first one/two chunk indices. Otherwise every chunk
is scored and sorted by descending Dart `double.compareTo`, then the first
one/two indices are taken. There is no minimum similarity threshold or
secondary index tie-break in this selection. With no chunks, each pending
note receives an empty reference list. The empty-vector predicate PP34513
uses the same +42110 list-isEmpty dispatch already bound in the reader.

The exact cosine function at `0x1006b4bb4` returns zero for empty vectors,
unequal dimensions, or either squared norm equal to zero. It accumulates dot
product and both squared norms in scalar order, then divides by the product
of their square roots. It adds no epsilon, clipping, or finite-value repair.
Nonfinite arithmetic is therefore retained. This is an algorithm reconstruction,
not proof of bitwise equivalence between Dart execution targets.

Evidence: `ida/note-enhance-embed-note-callback.json`,
`ida/note-enhance-empty-vector-predicate.json`,
`ida/note-enhance-stream-gap-1758.json`,
`ida/note-enhance-ranking-sort-arguments.json`,
`ida/note-enhance-cosine-arguments.json`, and
`ida/note-enhance-cosine-similarity.json`. Shared callback names from unrelated
merged IDA symbols are not interpreted as separate application behavior. Eight
new tests cover cosine sign/magnitude, degenerate inputs, nonfinite arithmetic,
the five/six-note threshold, and global versus per-note fallback. All 35
producer helper tests pass together, with clean core analysis.

## Remaining producer work

These helpers are reconstructed but not yet wired into generation. Current
Application generation still uses one bounded transcript prompt. Original
`enhanceStream` additionally embeds transcript chunks and shorthand, ranks
by cosine similarity, uses RemoteTokenizer budgeting, assembles excerpt
references and previous enhancements, creates a conversation per batch, and
parses/merges batch responses into complete output snapshots. The exact prompt
fragments are retained as selected public PP34602–34609; the batch parser and
prompt builder have complete retained decompilations. Prompt assembly and the two-list batch parser are now implemented as helpers.
Excerpt ranking and its math are now implemented as helpers. Transcript
chunking/cache integration, embedding transport, remaining token budgets, stream
merge rules, and full integration remain incomplete.

The newest IDA batches (50, 51, 56, 58, 61, 69, 70 and 71) ran through the owned Node process
launcher because REA process capture could not start. Their raw IDA JSON and
terminal logs are retained; each dispatcher closed with exit 0. These results
are static analysis, not a successful new REA process capture or a live app
comparison. No application configuration map or API credential was extracted.
