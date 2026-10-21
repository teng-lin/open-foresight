# Meeting AI workflows

This change implements five work packages on top of the separate meeting Summary change: structured Action Items, Enhanced Notes reliability, Live Q&A deployment/scheduling, attachment preparation, and Chat/knowledge integration. The [reference investigation](../research/foresight-ai-workflows.md) and [parity plan](../plans/2026-10-20-foresight-ai-parity-plan.md) distinguish recovered behavior from product choices. Summary remains a separate pipeline and artifact.

## Action Items

The meeting Actions panel extracts explicit commitments from every final transcript row and handwritten notes. Inputs are split into overlapping, scalar-safe windows under a conservative UTF-8 byte budget. Each output task must carry a real evidence ID and a verbatim quote. Owners and due expressions are optional; when present their literal text must appear in that task's quotes. Audio channel labels cannot become owners. Invalid JSON, unsupported evidence, a failed window, changed input, or cancellation prevents acceptance of the extraction.

Tasks have stable keys based on normalized task text and owner. Regeneration merges matching keys and preserves manual details and completion. Missing old tasks remain visibly stale rather than silently disappearing. Later matching explicit cancellations can supersede an earlier extraction. This is lexical identity, not semantic entity resolution: paraphrased commitments or changed owners can create a new task. Dates remain quoted expressions; this change does not infer calendar dates or time zones. Evidence validation establishes quotation support, not a general guarantee that a model interpreted the quote correctly.

`actions` and `action_items` operations write the canonical `actions` artifact kind. Schema 15 migrates legacy aliases without modifying their generated/edited bodies. Task state, artifact history, manifest, and stable derived source commit in one SQLite savepoint. Use typed task editing for the current structured artifact; editing historical Markdown remains available. The latest task edits update its searchable derived source.

Foresight's recovered PP24724 is a Markdown Overview/Action Items/Details brief with high-confidence assignees. Typed task JSON, completion controls, evidence validation, and stable task records are Open Foresight additions. Production instructions live in `meeting_actions.dart`; the exact recovered literal remains in the research catalog and frozen checksum fixture.

## Enhanced Notes

The existing note planner, per-note excerpt selection, batch clustering, standard/concise prompts, conversation protocol, stream parser, and merge behavior remain in use. A public Notes request owns its exact active native child (`parent-batch-N`). User cancellation, lease cancellation, raw-note revision changes, or a current-artifact edit prevents late acceptance. Cancellation while a worker is stalled reaches that child. Prior accepted text and manual edits survive failed or cancelled work.

Successful output records the note/transcript revisions and a `notes-v2` manifest. Failed or omitted batch outputs retain reference fallback bullets and disclose affected note indices through `failed_batches` and `degraded`; the desktop warns when fallback text was retained. Cancellation is checked before fallback handling so it cannot masquerade as successful degraded generation.

Live candidates retain the reference recent-50-chunk policy. Final enhancement can rank candidates from the complete saved transcript, reusing vectors by identical text. The reference global missing-vector fallback remains: if any candidate vector is unavailable, selection falls back to the earliest candidates. Complete candidate retention therefore does not guarantee that every decision is selected for every note. Reference ranking fixtures remain unchanged.

Production no longer sends embedding-tokenizer IDs as generation stop IDs. Textual `</output>` stopping/parser behavior remains. Native stop-sequence support and reference producer fixtures remain available for a future generation-bound tokenizer. This is a deliberate correction, not a claim of original token-level runtime parity.

## Live Q&A

The detector remains a dedicated raw-completion model with the exact leading ` <ctrl1>` prompt. It never falls back to general Chat. The existing durable question jobs, cursors, duplicate suppression, retry and answer linkage remain. Status exposes configuration/readiness, backend, decoder policy, queue length, oldest queue age and active stage. Settings and Live Q&A explain missing setup and retain retry access.

The new `raw_query_jsonl_v1` backend imports a user-selected local detector model and executable worker on macOS or Linux. Setup validates the supplied lowercase model SHA-256, probes the raw protocol with a 15-second deadline, and only then replaces registration. A failed setup preserves the prior registration. This is a deployment interface; no redistributable detector weights or alternate inference engine are bundled or downloaded by it. The existing platform-specific acquisition path is retained separately.

The executable is launched as:

```
/path/to/worker --model /path/to/dedicated-model
```

It must emit a UTF-8 JSON line `{"type":"ready"}`, then read request lines and reply with the matching ID:

```json
{"id":"owned-request","prompt":" <ctrl1>...","max_output_tokens":512}
{"type":"result","id":"owned-request","text":"Who owns launch?"}
```

Errors use `{"type":"error","id":"owned-request","message":"..."}` or a startup `fatal` frame. Stdout is reserved for JSONL; diagnostics belong on stderr. No chat formatting, tool calling or shared process ownership is implied. The transport bounds frames and deadlines, kills only its owned worker on cancellation, and reaps it at close. A worker that launches descendants must arrange their lifetime itself.

`unicode-v2` is the production decoder default and preserves multilingual question punctuation; `reference-ascii` selects the recovered ASCII behavior through `queryOutputPolicy`. Existing CJK-aware rolling input and reference window fixtures remain distinct. Protocol tests establish interoperability, not detection quality for arbitrary weights. Real-model recall, false positives, duplicates and latency remain release evaluation work.

Foreground Ask, Summary, Actions, preparation and manual Notes can preempt automatic answering and live Notes. Owned cancellation is joined before claiming generation; durable Q&A jobs are requeued, and interrupted live Notes retry later. Active workflows reserve the generation owner between their map/reduce calls. Capture continues independently. Stalled helper retrieval has a 15-second deadline and checks request ownership during the wait.

## Preparation

The Preparation panel explicitly selects one to 100 already-imported local sources. No remote URL is fetched and no Drive permission is inferred. Document summaries are cached by source revision, content/title digest, model/runtime settings and prompt identity. They can be reused across meetings. A separate meeting fingerprint includes selected documents, meeting title and calendar metadata. Changed/deleted sources and event edits invalidate acceptance.

The document path retains recovered empty-input handling, <=200 UTF-16-unit passthrough, >50-million-unit refusal, and exact MAP/REDUCE wrappers. Longer text uses overlapping scalar-safe byte windows. Reduction preserves a prefix of each partial if clipping is required, and records clipping. Multiple document summaries are synthesized with untrusted meeting context; a single summary follows the short-circuit path. Individual failed documents are listed as unavailable in a partial brief and its manifest. All-failed, cancelled or stale-input runs preserve the prior accepted brief. Cache rows, the accepted artifact and its stable derived source commit together.

Preparation is a document-based brief, distinct from the post-meeting transcript Summary. The accepted result supports history, manual editing, search and existing export paths.

## Chat and knowledge

Meeting Chat and Live Q&A expose Meeting, Selected sources and Workspace scopes. Automatic Q&A defaults to Meeting; manual Chat preserves its Workspace default. Selected empty scope stays empty. Retrieval document IDs, previous-question context, and conversation history are filtered to the captured scope identity. Changing scope during an answer rejects late persistence. Explicit web mode remains a separate user choice and does not grant source content authority to issue network calls.

Web memory checkpoints use `web-memory-v2` keys including generation registration, context length, byte-count policy and source scope. The reference 55-percent compression/FIFO policy remains; production text counts use UTF-8 byte upper bounds rather than the unrelated embedding tokenizer. The original history/token-estimation fixtures remain. This change does not claim exact generation-token admission for the complete web/system framing.

Accepted summary, enhanced-note, task and preparation artifacts have stable derived source IDs with provenance. Edits to the latest accepted artifact refresh that source; edits to old versions cannot replace current searchable text. Indexing remains asynchronous and resumable through existing source handling, so acceptance and embedding completion are separate states. A source soft delete retains document-summary cache rows physically; revision/content keys and deleted/revision revalidation make them unreachable. Workspace clear removes tasks, caches, scope preferences and memory markers. Graph similarity/layout algorithms are unchanged.

## Validation boundaries

The accompanying tests cover deterministic prompts/checksums, evidence and Unicode handling, migrations, rollback, cache invalidation, manual edit retention, stale/cancelled commits, source-scope privacy, foreground preemption, desktop controls, and compiled service/MCP ownership. The [validation record](../validation/2026-10-20-meeting-ai-workflows.md) records this worktree's runs and remaining platform gates. Controlled workers test protocol and persistence, not natural-language quality. Original Foresight feature execution, real detector/model quality, isolated desktop/service integration, and Linux runtime behavior must not be inferred from static recovery or mocked widget tests.
