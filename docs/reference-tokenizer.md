# Original helper tokenizer and chat memory costs

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis uses REA captures of IDA Pro, packaged JSON and read-only Encode calls
to the two already-running helpers. No recording or model replacement occurred.

## Recovered behavior and integration

RemoteTokenizer.encode (0x10091701c), its request closure (0x10091712c) and
response continuation send text unchanged through BackgroundAgentProxy to
`/research.xeno.labs.foresight.launch_agent.proto.RagService/Encode`.
EncodeRequest.text is field 1; EncodeResponse.tokens is repeated int32 field 1.
History estimates use the returned list length. This helper tokenizer is
independent of generation tokenization. Chat page initialization (0x100a94b54)
binds a nullable tokenizer when its background service/model holder is available.
A null tokenizer selects the recovered rounded word estimate.

ReferenceRemoteTokenizer now sends unchanged text and counts IDs. Domain binds
it when helper State.tokenizerReady is true. That flag is the port mapping to
the original nullable binding; exact original recovery/binding timing remains
unverified. Bound RPC failures propagate. Request cancellation cancels pending
Encode calls and prevents stale answer/checkpoint commits.

Original history entries retain individual costs. The additive nullable
conversation_memory.token_counts column caches these costs across readiness
changes. Migration preserves existing messages and answer IDs; missing costs
are estimated once. Concurrent turns merged at commit receive missing costs for
their next replay. Checkpoint and answer writes remain atomic. This durable
checkpoint format is a port lifecycle choice.

Chat native admission now checks input against context 4096 without adding a
full 1024-token output reserve and 256 extra tokens. The engine context/output
cap still apply. This removes a port rejection that prevented an admitted
compressed conversation from generating. It does not establish original native
accounting or behavior at every context boundary.

## Evidence and verification

REA `ev_74a1a9dd0d4b4fb764e354a3c0badeb79fb79555c64ae3b5f767972f95be0af0`
retains IDA tokenizer/binding analysis.
REA `ev_3dbe097f04850de73c2ea11f1dbc7763647f357a6c19ffd3a1f21ff695460ecf`
retains artifact hashes, public packaged defaults and live comparison results.
Raw JSON/session bundle are under ignored test-results/reference-functions/ida.

Five live probes returned identical original/port IDs: padded English, Chinese
plus emoji, empty text, whitespace/newline/tab, and a citation with accented text.
This is bounded evidence, not exhaustive tokenizer identity. Helper SHA-256:

- Original: `c96e3fbbd5769932dc5dac04b95a185af06f9e40eb2b51a7168841b7c69c1a0e`
- Port: `141d52b074197065bc5f6c6e43c4f097e7fbfe5563f5b0eeaa10a573c970fba8`

Original bundled on_device_model_configure.json SHA-256:
`c487e534262f81fedd0f55a4846dce201b023917d6ecefb31c116b8f7adf3679`.
Gemma 4 12B, E4B and E2B defaults all use context 4096, temperature 0.4, topK 40,
topP 0.9 and repetitionPenalty 1.05, matching the port defaults. The original
also enables speculative decoding and KV-cache channel-content filtering and
disables thinking. Those flags do not prove equivalent port runtime behavior;
runtime overrides and cache implementation remain separate questions.

Loopback tests cover unchanged input, empty output, RPC errors and cancellation.
Domain tests cover non-Latin compression, cached costs across readiness changes
and legacy migration. A real GPU Gemma E2B run with the live port Encode helper
passed search, cited persistence, follow-up and compression. Controlled oldest
history entries use 90 repetitions to cross the helper-tokenized threshold;
the earlier 75-repeat word-estimate fixture did not cross it. The generated memo
retained the theme color and the follow-up answered violet without another
search. This uses a controlled search provider and does not validate live Google
or remote summary access.

Validation: 169 core tests passed with native fixtures (three opt-in tests
skipped); 10 Python runner tests and four native CTest groups passed. Core and
desktop analyzers were clean; the desktop suite passed 168 tests with 10 skips.
The opt-in live Encode and real-model tests also passed separately.
