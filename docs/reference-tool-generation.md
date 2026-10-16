# Reference search tool generation

Reference executable: Foresight 1.0.0.28.20261005, SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Native investigation uses REA captures of IDA Pro.

## Recovered behavior

`_googleSearchToolSchema` (0x10092097c) defines `google_search` with an object
parameter, a required nonnullable string `query`, and instructions to use search
only for unknown answers or current information. The exact description and
property strings are reproduced in `reference_tools.dart`.

`_handleToolCalls` (0x100658bec) maps calls to asynchronous callbacks and awaits
Future.wait. Calls start concurrently; returned results remain in input order.
Its adapter at 0x100659150 expects an outer map containing a `function` map,
whose `name` is a nullable string. Map arguments pass through. **String arguments
are wrapped verbatim as `{'query': arguments}`**, without JSON decoding. Invalid
shapes and unregistered tools return error records. A successful result records
tool_name, tool_response, status=success, type=tool_response, and original_query.
The exception handler at 0x1006597f8 catches execution failures and records the
exception's toString as an error message. A failed call does not erase successful
sibling results.

The combined text starts with:

```text
The search results for the previous request are provided below:
---
```

Each success adds `Result for tool "<name>":`, a newline, the callback result,
another newline, and `---` plus newline. Errors add
`Error from tool "<name>": <message>` and the separator. This is returned as
`{'role':'user','content':[{'type':'text','text':combinedText}]}`. Source numbering
inside a search callback is established separately in the search ledger.

The combined text is truncated to four times the configured maxTokens value,
measured in UTF-16 code units. The reference defaults that value to 20000 when
its conversation property is null. No additional marker or trimming is added.
The port's native backend currently has a 4096-token context and uses that value
for this bound; equivalence of model/context configuration is not established.

`sendMessage.<anonymous closure>` (0x1006585e0) permits at most 20 native model
turns. A final ordinary response on turn 20 is accepted. If turn 20 still
contains calls, it returns `Max turns reached after tool call detection` without
executing that batch. Thus at most 19 callback batches execute per send.

## Native integration

`NativeRuntime.generateWithTools` delegates tool batches to
ReferenceToolDispatcher and sends the recovered user message back to the same
native model conversation. Ordinary generate/schema calls retain their API and
behavior. The native ABI adds fs_generate_tools and fs_generation_tool_reply.
Replies must match the active request ID and are accepted once per batch.
Old, duplicate, cancelled and completed replies are rejected.

The native worker owns the model conversation throughout the exchange. Its
private line protocol sends `tool <JSON calls>` and `answer <JSON response>`;
stdin carries the response message. This framing is a port implementation
choice, not claimed as the original process protocol. Replies are queued and
written nonblocking through an owned socket, so a large response does not block
the Dart FFI thread. Native cancellation retains the existing process-group
ownership and reaping. Missing answers, invalid frame prefixes and unterminated
frames cannot finish successfully. Dart validates answer JSON before publishing.

The Linux C++ worker and packaged macOS compatibility adapter implement this
path. Mac uses the pinned 0.18.0 C API through its owned Python conversation
because Python Message.from_json would decode string arguments and change the
recovered behavior. The adapter disables automatic Python tool execution; all
callbacks belong to the application service. No credentials/network clients are
added to the model subprocess.

The public C API supports configuring tool definitions and keeping a conversation
across sends. The port uses its normal function-definition wrapper; this is
supported by the pinned upstream implementation, rather than inferred from
Google API documentation. See the [C API implementation](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.0/c/conversation.cc)
and [Gemma tool processor](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.0/runtime/conversation/model_data_processor/gemma3_data_processor.cc).

## Remaining work

Ask and meeting Chat now call this bridge when their web toggle is selected.
Source URLs and cited excerpts are persisted with each answer, and release
packagers can bundle distribution credentials. See [chat citation evidence](reference-chat-web.md).
Real-model tool behavior, provisioned release credentials and live service access
remain unverified.
The original also has textual tool-call extraction fallback; that parser and
the streaming variant still need comparison. This new tool path currently emits
its final answer as one delta. Generic model prompts, sampling and the port's
4096-token context have not been shown equivalent to the original.

No separate user project setup is introduced. Search and summary clients remain
internally configured, as established in the preceding search investigation.

## Verification and evidence

Reference-tool fixtures check exact result text, input order under concurrent
execution, invalid shapes, exceptions, string-argument handling and UTF-16 bounds.
Native ABI fixtures exercise a 100 KB Unicode reply, request ownership,
duplicate/stale reply rejection, cancellation and invalid/truncated worker output.
The C++ and Python conversation-loop fixtures cover retained conversation state,
20-turn behavior, message shape and owner disconnect.

Native Dart integration tests use the compiled library and owned child runner,
then execute the real SearchCallbacks and result formatting. They cover a cited
answer, pending-callback cancellation, late replies, runtime closure and deadline
handling. They deliberately do not contact Google or load a model.

```sh
cmake -S native -B /tmp/foresight-search-native-build -DBUILD_TESTING=ON
cmake --build /tmp/foresight-search-native-build -j4
ctest --test-dir /tmp/foresight-search-native-build --output-on-failure
cd packages/foresight_core
FORESIGHT_NATIVE_LIBRARY=/tmp/foresight-search-native-build/libforesight_native.dylib \
FORESIGHT_HELPER=/tmp/foresight-search-native-build/native_test_supervisor \
dart test
```

The standalone supervisor above is test-only on macOS; full application builds
use their actual helper. Linux uses its existing process-group implementation.
This pass built the macOS native library and compiled/tested the shared C++ tool
loop; it did not build the complete Linux inference executable.

REA evidence:

- `ev_5293ccea966055904ad0e3659b4354357b23d1f91b89cd27fe8a0eac6d82061e`: tool schema, result block and registration.
- `ev_719b16385eca332a9ff8bcc438c249f13a84beb3a36de941326fad0756ea73f8`: adapter and 20-turn send loop.
- `ev_1ac0d8ce3d089298e576e081797bfc639679c902c5e90442ff3d66798687ec83`: exception handler omitted from the decompiler's normal-flow body.
- `ev_82250b4512e59f3ab318750905acf666c5c9a3cbdf0666fb5aba28392fad8860`: schema strings, result labels and error text.
- `ev_aa9a95e9c09a10e64a6a26f71ff72dd7d494b0585f5e98f932e509a20f0a3fc2`: function key and exception prefix.
- `ev_28b95d7f4aed9c1c542d2d1f20d31c640efe690d698e5366dfc5bb7cd15748c5`: newline separator is one LF unit.

The first two IDA batches and the exception-path batch closed normally. A later
attempt to inspect the native wrapper hit the worker health timeout and exited
with -2; it supplied no wrapper evidence and is not used to claim parity.


Final validation: **126 core tests passed, one opt-in model test skipped** with
the native bridge enabled. All four CTest groups passed; both core and desktop
analyzers are clean. The default core run without a built native library passed
122 tests and skipped the model test plus the then-three native bridge tests;
the final configured run also includes the runtime-closure test. Physical model
generation, original streaming comparison and a complete Linux worker build
remain unverified.
