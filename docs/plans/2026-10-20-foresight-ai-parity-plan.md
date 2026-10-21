# Open Foresight AI workflow implementation plan

Complete the recovered Foresight AI workflows on top of Open Foresight's existing application service, local inference, storage, and desktop. AI Summary is the first implementation, replacing the generic prompt over sampled transcript sections. Preserve the substantial Enhanced Notes, Live Q&A, retrieval, and graph implementations and fix demonstrated gaps.

Status: Summary implemented on source `053673dd`; the remaining work packages are proposed. Research compared source `02d572fbd66022bb125d188dfa296ba7f2bf85bc` with Foresight 1.0.0.28.20261005. The [Summary implementation contract](../architecture/meeting-summary.md) describes the shipped code and acceptance limits. The [research report](../research/foresight-ai-workflows.md), [original prompt catalog](../research/foresight-ai/prompts.json), and [evidence manifest](../research/foresight-ai/evidence.json) define the historical baseline.

## Intended product behavior

A user can record microphone and system audio, write shorthand, receive grounded enhancements and automatic answers, and finish with a useful brief and separately inspectable action items. They can see partial progress, cancel work, correct notes, regenerate after transcript changes, reopen the profile, and export results without losing original input or accepted edits.

Core generation remains local. Optional web search is explicit. Microphone/Remote remain audio channels; names and action ownership require actual evidence. Recovered original behavior, deliberate Open Foresight changes, and unresolved reference behavior must stay distinguishable in tests and documentation.

## Architecture to retain and extend

Retain `Application`, profile SQLite ownership, the newline-framed service protocol, request leases, existing native workers, MCP tools, model readiness, migrations, and desktop controllers. Extend existing modules rather than introduce a second service or rewrite capture/retrieval.

| Layer | Proposed responsibility | Existing integration points |
| --- | --- | --- |
| Pure core planners | Summary dispatch, window planning, prompt assembly, output parsing, checkpoint validity | `reference_note_*` patterns; `text_budget.dart` |
| Generation adapters | Separate system/user inputs, configured limits, tokenizer, stop sequences, streaming, native cancellation | `native.dart`, `native_note_enhancement.dart`, inference conversation protocol |
| Application service | Immutable input snapshots, operation ownership, prioritization, cancellation, recovery, final commit | `application.dart`, `service.dart`, `operations.dart` |
| Store | Generation manifests, summary checkpoints, artifact versions, derived source provenance | `store.dart`, existing meeting artifacts and source revisions |
| Desktop and MCP | Progress, cached/stale/degraded results, retry, export, explicit scope | `meetings_controller.dart`, current RPC/MCP operations |

Introduce a small generation manifest, shared by artifacts rather than by every live token. Record operation and parent/child request IDs; meeting/transcript/raw-note revisions; evidence source IDs and revisions; prompt, planner, parser, and policy versions; model/tokenizer digests; backend and effective settings; input coverage; timestamps; terminal outcome; and any fallback/error classification. Store sensitive source text in existing owned records, not diagnostics.

Persist summary checkpoints with the prior brief, cleaned input length, and input fingerprint. Only append-compatible input with compatible prompt/planner/parser/policy versions and model/tokenizer identity may use incremental update. Define an explicit policy before permitting reuse across models. Original length-only behavior remains a reference fixture; fingerprint validation is an explicit Open Foresight improvement. A workspace epoch, canceled request, superseded revision/model, or deleted meeting must prevent a late final commit.

## Work packages and order

Each row is a reviewable PR boundary. Split rows when implementation size warrants it; preserve the dependency order. Runtime acceptance is a deliverable, not an implied result of writing helpers.

| Order | Work package | Depends on | Completion condition |
| --- | --- | --- | --- |
| 1 | Prompt and workflow fixtures plus provenance | None | Original byte/hash fixtures and explicit adaptation versions; no secrets or local-history dependency |
| 2 | Summary planning and pure core algorithms | 1 | Full/incremental/map/reduce, wrappers, sanitizer, and boundary fixtures match recovered contracts |
| 3 | Summary service, persistence, desktop, and MCP | 2 | Real worker streaming, cancellation, checkpoint recovery, artifact history, derived indexing, process/UI acceptance |
| 4 | Explicit Action Items contract | 1, 3 | Calendar-page reference route documented; separate typed extraction evaluated as a product addition |
| 5 | Enhanced Notes reliability and fidelity | 1; manifest from 3 | Existing pipeline retained; cancellation, stale edits, fallback status, and long-meeting behavior verified |
| 6 | Live Q&A deployment and scheduling | 1, 3 | Dedicated detector works on supported distributions; real capture-to-answer acceptance and queue behavior pass |
| 7 | Attachment preparation briefs | 1, 3 | Confirmed document/event contracts integrated with revision-aware caches, cancellation, and grounded output |
| 8 | Chat memory, citations, graph, and export integration | 3, 5–7 as relevant | Explicit scopes, stable provenance/citations, correct derived-source updates, complete user journeys |

Summary work should lead. Notes and Q&A are audits/completion tasks, not greenfield rewrites. Graph/capture foundations should change only when a concrete finding or new workflow requires it.

## Work package 1 Prompt and contract fixtures

Create small frozen public fixtures from the recovered catalog. Keep exact original strings and reconstructed assemblers separate from production policy additions. For every prompt define the input schema, selected mode, surrounding messages, tokenizer assumptions, stop behavior, expected output form, parser, and evidence binding.

Suggested modules include `reference_summary_prompt.dart`, `reference_summary_plan.dart`, `reference_summary_chunking.dart`, and `reference_summary_output.dart`; names are proposals. Keep the catalog as evidence rather than importing the entire research JSON into the application.

Fixtures must cover original whitespace, leading control-token space, XML/newline framing, literal Unicode, standard/concise note modes, and complete summary wrappers. Preserve current untrusted-content rules in production under a distinct prompt/policy version. Do not silently replace the hardened Chat policy with original model-directed network access.

Completion checks: recovered UTF-8 hashes and UTF-16 lengths match; assembled prompts have exact source-derived fixtures; tests run without `.git`, deep history, local models, or the installed original. Mark unresolved templates by static reachability and avoid claiming runtime selection.

## Work package 2 Summary algorithms

Implement a dedicated `SummaryPlan` with cached, full, incremental, and map/reduce outcomes. Retain the reference's 100-word non-refresh admission, half-context word threshold, separate system/user prompts, and typed context settings in compatibility fixtures. Production refresh must verify input-prefix compatibility before choosing the incremental path.

Use the recovered defaults:

```
chunkWords = max(1500, floor(0.375 * context))
strideWords = max(1200, floor(0.8 * chunkWords))
maxChunkTokens = max(3000, floor(0.75 * context))
```

Implement tokenizer-adjusted advancement, sequential MAP, and one final REDUCE, including zero/singleton results and character-capped joining. Reference fixtures should retain fallback behavior when tokenization/truncation is unavailable. Production admission must independently bound the full actual prompt and fail or repartition actionably when it cannot fit; do not confuse a serialized native input setting with an enforced budget. The first implementation uses a conservative UTF-8 byte budget because the helper tokenizer belongs to the embedding model. Generation-bound tokenization remains a follow-up for better context utilization. Budget-driven reduction clipping is explicit in the manifest and UI.

Add ordered attribution sanitation, preserving ordinary text and real names. Keep PP37755's Overview/Details brief separate from PP24724's Action Items template. Rich structured decisions and coverage-preserving hierarchical reduction are optional subsequent product improvements; do not describe them as the original algorithm.

Boundary cases: 0/99/100 words; half-context ±1; cached versus refresh; unchanged input; appended input; prefix edits with equal/greater length; short/empty/large suffix; 0/1/many map outputs; tokenizer unavailable, null, empty, or over-budget output; overlap after truncation; non-ASCII and surrogate boundaries; reducer cap and many tiny summaries; channel-label rewrites versus real names.

## Work package 3 Summary operation lifecycle

Replace the summary branch of generic `generateMeeting` with a dedicated orchestrator using the existing native owner. Leave other operation behavior stable until separately migrated. Carry separate system/user messages and effective settings through the real runner protocol. Recover the original high-priority/120-second request contract without treating the context setting as an output limit.

Add operation progress for cleaning, planning, map i/n, reducing, and committing. Distinguish streamed preview from accepted output. A failed/canceled regeneration preserves the last accepted brief; no partial or superseded result becomes a successful artifact.

Use parent-owned child requests for every map/reduce/native conversation. Cancellation must reach the exact active child, stop queued phases, join/close resources, and prevent late persistence. Test cancellation during tokenizer work, a stalled map, reduction, final token, source indexing, and a client disconnect. Establish a bounded response time through fixtures and measure it with the real worker.

Write the accepted brief, checkpoint, artifact history, and manifest atomically where they share store ownership. Preserve edits/history and invalidate the checkpoint on incompatible transcript, prompt/policy, or model/tokenizer changes. Exercise model replacement and a late commit after model switching. Update the derived summary source and embedding under its own revision, linked to the original transcript. Avoid retrieval loops in which an old generated summary is used as fresh transcript evidence.

Desktop Summary should show preview, phase progress, retry/cancel, stale-input state, and versions through existing components. Existing service/MCP generation operations should expose the same outcomes. Test a reopen/restart and export from the persisted artifact, not only an in-memory callback.

## Work package 4 Action Items

The calendar-page reference trace already establishes PP24724's high-confidence assignee/task format, handwritten-note input, timestamp-triggered regeneration, single pass through 2500 whitespace units, long-input map/reduce, and Markdown persistence inside `notes_map.meetingBrief` with `briefLastModified`. Turn those static contracts into fixtures and determine live UI selection with a synthetic meeting before making runtime parity claims. Preserve the ineffective default prompt replacement as evidence rather than silently describing it as successful instruction rewriting.

For Open Foresight, define explicit structured action output containing task text, evidence spans, optional owners, optional due expression/normalized date, and extraction confidence/status. Unknown owners/dates stay null. A proposed due date, question, completed task, hypothetical suggestion, and actual commitment must remain distinguishable.

Extract across all relevant transcript chunks, deduplicate repeated tasks, apply later corrections/cancellations, and preserve user edits/completion state across regeneration. Do not infer completion or ownership from audio channels. Store task identity independently of output order. Normalize public `actions`/`action_items` aliases to one canonical stored kind while preserving historical artifacts.

Completion requires reviewed synthetic examples with implicit/explicit assignments, shared ownership, no-action meetings, relative dates/time zones, corrections, reopened tasks, disagreement, multilingual input, and malicious source instructions. A typed task feature is an explicit product addition even when its display resembles the reference.

## Work package 5 Enhanced Notes

Reuse the existing transcript cache, input planner, ranker, clusterer, prompt assembler, conversation adapter, parser, and merge helpers. Verify their current wiring against fresh/historical same-binary contracts rather than replacing them with a generic prompt.

First reproduce the suspected parent/batch cancellation mismatch: enhancement uses child IDs such as `${parent}-batch-N`, while some service cancellation paths supply the parent to an exact-ID native cancel API. Use a stalled batch to establish the behavior, then repair ownership if confirmed. Source inspection alone is not a reproduced bug.

Keep reference fallback bullets but record which batches failed and which notes were preserved without model enhancement. Expose degraded completion rather than labeling all fallback text enhanced. Resolve the semantics of raw edits during generation: preserve raw input and show stale enhanced output or remap/requeue safely using immutable note revisions.

Evaluate latest-50-chunk retention, global empty-vector fallback, similarity ranking, optional missed topics, and standard/concise prompts on long meetings. If full-history retrieval or better missing-vector handling is adopted, version it as an improvement and retain the original algorithm fixtures. Verify native token-level stop sequences with the current tokenizer/backend and cumulative-stream conversion, including cleanup on error.

## Work package 6 Live Q&A

Retain the dedicated raw-completion detector interface and the exact ` <ctrl1>` protocol. Keep its weights/runtime distinct from the general Chat model. Expose model readiness and a retry path; a missing detector must not silently become a generic chat/JSON call.

Keep fixtures for the original last-200-whitespace-unit window and the port's current CJK-aware/1000-scalar preparation. Measure detection differences explicitly; the latter is not recovered original window behavior.

Define a supported distribution path for every promised platform. Current macOS credential-dependent acquisition is not Linux deployment. Prefer a redistributable compatible local model/runtime; an alternate model or multilingual decoder needs its own prompt/parser version and quality evaluation. Preserve the reference ASCII mode as compatibility behavior, not the default quality goal for every language.

Retain durable question jobs and cursor transactions. Validate interim suppression, repeated/expanding questions, silence, final corrections, queue retention when Automatic answers is disabled, restart recovery, deletion, failure/retry, and answer linkage. The answer source scope must be visible and deliberate: meeting only, selected sources, workspace, or explicit web. Do not describe workspace retrieval as transcript-only.

Measure detector and answer queue age under live notes, manual Ask, and Summary load. Introduce a small explicit priority/fairness policy only where needed, preserving single-owner model semantics and capture independence. Automatic work should yield to user operations without losing durable jobs. Record detection recall, false-positive rate, duplicate rate, unsupported-answer rate, and end-to-end latency by stage.

## Work package 7 Attachment preparation

Build a meeting-preparation operation around the established document/event flow. Import/extract attachments through existing source handling, summarize each document under its revision/model/prompt identity, and synthesize an event brief with attachment references. Event metadata, imported text, and generated partials remain untrusted source content.

Implement the recovered <=200-UTF-16-unit passthrough, empty-input branch, >50-million-unit refusal, document MAP/REDUCE prompts, caller budget formulas, safe joining, zero/single/multiple-summary synthesis, and per-document error aggregation as separate fixtures. Cover two cache levels, repeated document IDs, changed content, malformed legacy cache records, concurrent requests, and cancellation during every stage. Exercise actual token admission independently of the reference's character heuristics.

Cache by actual document revision and generation identity; changes to an attachment, calendar event, source deletion, model, or prompt must invalidate the affected result. Reuse document summaries across meetings only when their inputs/identity match. Preserve progress and parent-child cancellation across extraction, document MAP/REDUCE, event synthesis, and persistence.

Do not infer remote-document access or Google permissions from an attachment URL. The operation should use already-authorized imported sources, report unavailable attachments explicitly, and produce a grounded partial brief when policy permits. Distinguish a pre-meeting attachment brief from the post-meeting transcript summary in API, storage, desktop, and export.

## Work package 8 Chat and knowledge integration

Retain local citation validation, pinned excerpts, source revisions, structured answer storage, and meeting conversation isolation. Verify source numbering before/after display compaction, date/context framing, structured history, and the 55-percent Context Memo compression policy with the actual tokenizer.

Keep recovered prompts and production untrusted-content/web rules separately versioned. Source text must not enable tools or network access. Optional remote search/page summarization needs explicit user scope and configurable supported providers; client strings do not supply a server implementation.

Ensure summary/notes/action/attachment artifacts appear in search only through deliberate derived-source indexing. Regeneration updates embeddings without duplicating sources or overwriting original provenance. Preserve graph layout/labels across revision changes; do not rename similarity edges as extracted factual relationships. Exports should include accepted versions and disclose stale/degraded status where material.

## Evaluation and release gates

Use one small synthetic meeting corpus shared by features, with a reviewed fact/evidence ledger. Include short, long, early/middle/late decisions, changing decisions, user acronyms versus ASR mistakes, named/unnamed speakers, duplicated channels, multilingual speech, unrelated knowledge sources, and hostile instructions inside source text.

Compare deterministic contracts byte-for-byte: prompt assembly, windows, selected evidence, parser output, stop sequences, state transitions, manifests, and persistence. Evaluate natural-language output semantically; different backends need not produce identical text. Track factual support, required-fact coverage, action precision/recall, user-edit retention, Q&A recall/latency, and peak memory. Require no invented high-impact fact or unsupported assignee in the release acceptance set; record broader quality distributions rather than claim a universal guarantee.

Run controlled original-versus-port experiments with the same synthetic inputs where the original can be operated. Retain original version, exact input, prompt/model/settings when observable, output, timing, and limitations. Do not use historical passing tests as this change's verification, or client static analysis as evidence of server/runtime behavior.

Implementation PRs must run the repository-required complete native, Dart core, desktop, and coverage gates with current binaries and meaningful test counts/skips. Protocol/native input changes must exercise every runner/fixture. Service, capture, launch, and desktop-boundary changes also require the compiled service/MCP subprocess suite and real desktop/service integration on an isolated display, including production FIFO capture semantics. Run Git-free source-export and explicit CI-metadata fixtures where applicable. Exercise development hooks disabled/enabled and hook-free release builds.

Reuse verified dependency SDKs, libraries, and caches under AGENTS.md. Do not clean or restart successful dependency work for unrelated failures. Workflow changes, if any, require ShellCheck on PATH and actionlint. Apple, Linux, Docker, real audio, installer, or GPU paths that a host cannot execute remain required hosted/platform gates before their support claims or merge. Keep preview and release artifact provenance unchanged.

## Delivery decisions

The default sequence is Summary first, then task extraction, Notes reliability, Q&A deployability, and attachment/knowledge integration. Exact reference prompts are preserved for comparison; production keeps the project's untrusted-source policy. Fingerprint-checked incremental updates, explicit task records, full-coverage options, and multilingual alternatives are proposed improvements with their own versions.

The Summary implementation includes prompt/planner fixtures, real generation, persistence, parent-owned cancellation, and desktop progress through the existing service/MCP generation operation. Real-model output evaluation and isolated native desktop/service acceptance remain release gates; controlled workers establish protocol and lifecycle behavior, not model quality. Follow with task extraction after reviewing Summary's behavior on the acceptance corpus.
