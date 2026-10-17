# Original note enhancement producer

Target: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis uses IDA Pro and the matching Dart snapshot reader. The complete
3,982-line producer at `0x100a2bd08` is retained in
`test-results/reference-functions/ida/note-enhance-stream-producer-*.json`.
The stream consumer is documented in [note saving](reference-note-save.md).

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

## Remaining producer work

These helpers are reconstructed but not yet wired into generation. Current
Application generation still uses one bounded transcript prompt. Original
`enhanceStream` additionally embeds transcript chunks and shorthand, ranks
by cosine similarity, uses RemoteTokenizer budgeting, assembles excerpt
references and previous enhancements, creates a conversation per batch, and
parses/merges batch responses into complete output snapshots. The exact prompt
fragments are retained as selected public PP34602–34609; the batch parser and
prompt builder have complete retained decompilations. Parameter bindings,
ranking limits, parsing/merge rules, and full integration remain incomplete.

The newest IDA batches (50, 51, 56 and 58) ran through the owned Node process
launcher because REA process capture could not start. Their raw IDA JSON and
terminal logs are retained; each dispatcher closed with exit 0. These results
are static analysis, not a successful new REA process capture or a live app
comparison. No application configuration map or API credential was extracted.
