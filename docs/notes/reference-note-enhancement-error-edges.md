# Note enhancement cleanup and error edges

The port already uses the original producer's nested cleanup structure. This
pass verifies that structure and adds error-path acceptance tests; it does not
change successful enhancement output or add a second recovery handler.

Static evidence is from the macOS ARM64 Foresight executable with SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
The matching, existing IDA Pro database was queried read-only through its MCP
server, using REA process capture
`ev_b038b032e4c0b8e5af3f400bebec895524c6b2011dd5f5a779f2957d300f1a72`.
The owned HTTP client exited 0. The shared IDA process and database were left
open for their owner.

| Original producer instructions | Observed structure | Port contract |
| --- | --- | --- |
| `0x100a310d8–0x100a31128` | Common conversation close, await, then increment batch index and branch back | Close must finish before another conversation is created. |
| `0x100a319a4–0x100a31a00` | Save thrown object and stack, cancel active stream iterator, await, reload both and `ReThrow` | Iterator cleanup happens before batch error handling/conversation cleanup. |
| `0x100a31a04–0x100a31a50` | Save thrown object and stack, close conversation, await, reload both and `ReThrow` | An error escaping batch recovery still closes the conversation and preserves its stack if close succeeds. |
| `0x100a31a54–0x100a31c28` | Concurrent-modification throw and compiler bounds/stack-overflow stubs through function end | The previously uninspected tail adds no separate user-level fallback or outer logging block. |

The first and third rows were recaptured in this pass. The second also reuses
`note-enhance-outer-tail-instructions.json` from the earlier matching binary
investigation. Raw local captures are in ignored
`test-results/reference-functions/ida/enhancer-{identity,common-close,final-tail}.json`
and `enhancer-close-rea-capture.json`.

The close operation is outside per-batch recovery. In the reconstruction,
close errors therefore escape, stop subsequent batches, and do not emit the
final merged body or terminal active-index reset. A generation error already
handled by batch recovery is still logged once and falls back before close.
A secondary close failure replaces a pending exception according to Dart's
`finally` semantics; a successful close preserves the pending error and stack.

Sixteen focused enhancer tests pass, including seven new cases for awaited
close ordering, close failure following successful/recovered batches, a failing
error handler, secondary close failure, stop-cancellation failure, and failure
to create a conversation. Targeted Dart analysis reports no issues.

These tests execute the port using controlled conversation adapters. The
original cleanup instructions are static evidence, not an observation of
original application error execution. Original Dart exception table metadata
was not decoded; the structured `try`/`finally` interpretation and secondary
exception precedence are supported reconstruction rather than a traced
original double-failure run. This pass does not claim equivalent native
transport failures or production-model responses.
