# Original structured chat history

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Investigation uses REA captures of IDA Pro and the matching Dart snapshot reader.

## Recorded and replayed messages

`ChatHistory.add` (0x10090e9dc) appends a message/token-count entry and increments
the aggregate token count. `ChatHistory.messages` (0x10090ebd4) returns its
messages in order. `ChatService.initialize` appends these messages after its
system instruction message before creating a conversation
(0x10091ebd4–0x10091ed34).

The text-query send path builds a **plain user query** message at
0x10090c758–0x10090c870, then adds it and the structured assistant response at
0x10090c8c8 and 0x10090c914. It does not store the enriched current-date and
retrieved-context prompt as the historical user message. Tool exchange
intermediates are not added by these history calls.

History insertion precedes final citation selection/renumbering. Consequently,
the displayed answer alone cannot reproduce its original assistant history:
an answer citing Source:2 can later display Source:1 after source compaction.
The original also has response-number alignment/sanitation before insertion;
those transformations have not yet been fully reproduced by this port.

## Implementation

Web-enabled Domain sends now pass a list of user/assistant message maps to
`NativeRuntime.generateWithTools(messages: ...)`. The current query remains a
separate user prompt; the previous textual `Conversation: User: ... Assistant:`
prefix is removed for this path. Both C++ and macOS Python backends install the
list through LiteRT's conversation-config messages API. Message structure and
Unicode are preserved, and the initial history counts toward native context
admission. The pinned C API declaration is
`third_party/litert_lm/c/conversation.h:117`; its Python implementation also
forwards map messages directly rather than parsing their contents as JSON.

The native final delta now includes the structured model response. Completed
web answers save it in the additive nullable `answers.model_response` column,
within the existing atomic answer/meeting-link operation. It preserves model
source labels before display renumbering. Existing database rows retain their
text and citations and get null for this column; replay converts them into
plain text message maps. Failed answers are excluded, and SQL conversation
scope prevents other meetings/general Ask from entering the replay.

This column is port storage for replay, not a claim about the original database
schema or restart persistence. Ordinary local-only answering retains its prior
prompt path.

**Replay still uses the port's four-answer window.** The original automatic
memory policy below remains to be integrated. Conversation cloning/cache reuse,
full response alignment/sanitation, original tokenizer/model configuration and
history lifecycle/reset behavior also remain open. This change establishes
structured replay and the response data needed by that next integration; it
does not establish exhaustive history parity.

## Recovered memory policy, not yet integrated

`_getTokenLimitForModel` (0x100916094) uses the model's configured token limit;
without a model config it returns 4096. `_maybePruneHistory` (0x100914228)
computes `floor(limit * 0.55)` and compares existing history tokens plus the
incoming message estimate against it. The exact double at PP[30828] is
0.55000000000000004.

Above that threshold, it takes `floor(entryCount * 0.5)` oldest **entries**,
not necessarily complete user/assistant pairs. When that count exceeds one, it
formats them through the closure at 0x100916150, joins with `\n---\n`, and calls
`_simpleLlmExecutor` with an archivist instruction requesting a bulleted Context
Memo. The exact public prompt is retained in the snapshot evidence. A nonempty
summary replaces those entries with a user message whose text starts
`**Context Memo from previous turns:**\n\n`.

It then removes first entries until the estimated history plus incoming message
fits, or history is empty. An insufficient entry count or failed/empty
compression falls back to the same FIFO removal. The memo itself can therefore
be removed if it is too large. `_estimateMsgTokens` (0x1009164b8) has tokenizer
and word-count fallback branches; its 632-line decompilation is only retained
through line 500 in this pass, so its full contract remains under investigation.
This policy must replace the four-answer window before long-history parity can
be claimed.

## Verification and evidence

Application fixtures verify pre-renumbered response persistence, plain-query
replay, full legacy text without the old byte/character clipping, failed-answer
exclusion and conversation isolation. A migration fixture opens an original
answers-table layout and verifies preservation of IDs, timestamps and citations
while adding response storage. Native FFI fixtures verify separate current-query
and history transport. C++/Python fixtures check config installation, invalid
roles and inclusion of history in context admission.

The opt-in local Gemma 4 E2B GPU test now performs two turns. The first uses the
controlled search result and saves CEDAR-8492 with a source citation. The second
asks `What was that code? Reply with just the code.` and returns `CEDAR-8492`
without another search. This run passed in 12 seconds. It demonstrates actual
model replay through the new native path, with a deterministic provider; it
does not test live Google services or prove long-history compression.

REA evidence:

- `ev_c6113a91748f9d26c01eddbe387f237b57dd5b67e40e2c6e2e6a3cdd692bf11a`: history functions and ordered message projection.
- `ev_fd80d88ffe892cb23d389b2359a2eec17aed5b1cc6e4e0e8abe039c97d067c93`: paginated send path, plain-query history construction and insertion order.
- `ev_1e61b38db8b05fc9daad07d41a28bbe2603045d08eaa7d1565929e863f6d6966`: initialization replay into conversation configuration.
- `ev_1c167b0cca8b2b18286b9f7d5746535b512aee96415697674ecedf5a4290cf28`: exact threshold, memo prompt/labels and worker shutdown verification.
- `ev_221ab18d43a0bc4ede41c9c063421f6ae1d0a72ec18ab1a747712491ae84cda9`: retained pruning/estimation decompilation hashes, branches and shutdown verification.

The pruning batch saved its query outputs and closed IDA normally. REA's outer
capture reported inability to inspect the ownership tokens of five other live
processes, so that batch has no successful inline process-capture result. The
follow-up capture retains the file hashes and confirms the worker's terminal
shutdown log; no still-running worker was restarted.

Final validation: **153 core tests passed, two opt-in model tests skipped** in
the regular native-enabled suite. The new two-turn local-model check separately
passed with its opt-in environment. **168 desktop tests passed, 10 opt-in tests
skipped**. All four CTest groups passed, including eight Python runner fixtures.
Both analyzers are clean and `git diff --check` passed. As in prior macOS passes,
the shared C++ protocol was compiled/tested; the full Linux inference executable
was not built.
