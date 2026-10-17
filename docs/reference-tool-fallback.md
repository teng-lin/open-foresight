# Original text tool-call fallback

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Investigation used REA captures of IDA Pro and the matching Dart snapshot reader.

## Extraction rules

`extractToolCalls` (0x100659e4c) first returns a shallow copy of a nonempty
root-level `tool_calls` list. Otherwise it examines `content` only when that
value is a list. In order, each map with `type == 'text'` contributes either:

- A string passed to `_parseToolCallsFromText` (0x10065a5f4).
- A map whose own `tool_calls` value is a nonempty list.

The first successful item wins. Text fragments are not joined, arbitrary maps
are not recursively searched, and native argument strings are not decoded.
Malformed list members remain available to the existing dispatcher, which
produces model-visible errors.

The text parser trims for its initial guard, looking for `{`, the literal
lowercase JSON fence opener, or `"name"`. Matching
then uses the original untrimmed input. It prefers the first JSON fence:

````text
```json\s*([\s\S]*?)\s*```
````

Otherwise it tries the anchored prefix `^(\{"tool_calls":\s*\[[\s\S]*)`.
This deliberately does not accept whitespace before the opening brace or
between that brace and `"tool_calls"`. Captured text passes through `repairJson`
(0x10065ac9c), JSON decoding, and a map cast. A nonempty `tool_calls` list is
returned without filtering entries. A successfully decoded map without such a
list returns null; it does not trigger generic fallback.

When neither pattern matches, `_regexExtractToolCalls` (0x10065a9dc) tries the
original input. A decode/cast exception instead tries the **repaired capture**,
as verified in the exception handler at 0x10065a948–0x10065a9ac. It takes only
the first match of:

```text
"name"\s*:\s*"([^"]+)"[^}]*"arguments"\s*:\s*(\{.*?\}|"(?:[^"\\]|\\.)*")
```

The name remains captured text; the argument capture is JSON-decoded. A decode
failure returns null. Successful output is a one-element list containing
`{'function': {'name': name, 'arguments': decoded}}`. This helper does not repair
its argument capture and does not parse arbitrary native `call:...` syntax.
All patterns are case-sensitive. The generic and anchored patterns enable
dotAll; the JSON-fence pattern does not. Initializers are 0x10065ac00,
0x10065b108 and 0x10065b160.

## Literal JSON repair

The original counts every literal `{`, `}`, `[` and `]`, including those inside
quoted strings. Missing braces normally append `}`. If text ends in `]` and
the preceding character is not `}`, it inserts one `}` before that bracket and
appends any remaining missing braces. It then appends missing closing brackets
using the original counts. It never removes excess closing delimiters or fixes
quotes, commas or property names. For example, `{"x":[` becomes `{"x":[}]`, which
still fails JSON decoding. These limitations are retained in the port.

## Native integration

The parser is implemented once in Dart, in `reference_tool_parser.dart`.
Application-owned native requests set `delegate_tool_detection: true` alongside
system text and tool definitions. Both C++ and macOS Python workers retain their
conversation, emit each complete response as `model <JSON>`, and wait for the
owning Dart application to return either a user tool-result message or a finish
decision. A finish decision emits the original final response through the
existing `answer` frame. These private process frames are a port implementation
choice, not an assertion about original process boundaries.

The application checks native and text calls before finalizing an answer. It
executes at most 19 callback batches; a twentieth response containing calls
fails with the recovered max-turn error without executing that batch. A plain
twentieth answer remains valid. Existing request ownership, cancellation,
closure, deadlines and nonblocking reply transport apply to these decisions.
Legacy worker `tool` frames remain supported. LiteRT engine status now reports
`tools: true`; the GGUF backend retains `tools: false`.

Structured replay and [memory compression](reference-chat-history.md) are now
implemented. Streaming, original tokenizer configuration and conversation cloning
remain open.
This implementation receives each complete model turn before extraction.

## Verification

Seven parser fixtures cover extraction order, invalid shapes, exact patterns,
UTF-16 strings, repair limitations, JSON strings, generic matching and exception
fallback scope. Seven native Dart integration tests cover original system text,
legacy frames, text fallback, successful twentieth answers, 19-batch enforcement, pending-callback
cancellation, closure and timeout. Shared C++ and Python fixtures cover retained
conversation state, delegated decisions, finish/error handling and the existing
turn limit.

An opt-in `web_model_test.dart` was run with the installed local Gemma 4 E2B
LiteRT model and the source macOS GPU runner. The model generated the query
`current release code of the Open Foresight controlled parity fixture`. A
controlled SearchCallbacks result provided the nonce `CEDAR-8492`; the model
returned that value with `[Source:1]`, and Domain saved the completed answer,
source URL and excerpt. It passed in 21 seconds. The report and log are retained
under ignored `test-results/reference-functions/tool-model/`.

This is actual local-model tool selection and continuation with a deterministic
search provider. It does not establish live Google/ODML access, original model
equivalence, search quality or exhaustive model reliability. The ordinary suite
skips this model test unless `FORESIGHT_WEB_MODEL_TEST=1` and the native library,
runner and model environment variables are supplied.

REA evidence:

- `ev_5896d96f324db7d68ddbbb01b3ec30b28c5e195c767b4071f291a7ca0a34d875`: native/content extraction and history function addresses.
- `ev_9d66190e57a18f3131eae107e357fb467d3d160b5799a3908ec419b16cf01e0f`: private text parser and model-response decoding.
- `ev_a8e8732741ea6f17e2850727fe1efe2393f8e55f1875a5bf9dbc483e85fc5be1`: literal repair and parser guard assembly.
- `ev_2a74710e0f43543d1b0f78eca07fbf4f830dc75a90a447d572d11b568616f9bc`: generic extraction function.
- `ev_8992466947e399fcb50c6101a1f031d41ffd570f94baf393a725f54f97cfe367`: exact public regex constants.
- `ev_7ba6eb78279ed804f9d5b9fe0b17ea81b3e5695cd04867ab4cb24c16d9f18909`: regex flags, exception fallback and nested map key.
- `ev_0f7db347b629ec858ff63325eebdd1c1107b6ff93e0b5ab9846828bb7f45b942`: resolved String.contains dispatch, confirming that the initial guard checks containment.
- `ev_be89307e8bf69bd23b82a4b8d688d3b90156384ca28ac860548a84f0485b4395`: literal delimiter units and retained controlled model result.

IDA workers closed normally. Two initial symbol queries omitted a private-name
underscore and returned not found; later address-based queries supplied the
parser evidence. The first helper's printing error occurred after queries were
saved and did not leave an IDA worker running.

Final regression validation: **149 core tests passed, two opt-in model tests
skipped**; the new controlled web-model test separately passed with its opt-in
configuration. **168 desktop tests passed, 10 opt-in tests skipped**. All four
CTest groups passed, including seven Python runner fixtures. Core and desktop
analyzers reported no issues; `git diff --check` passed. This macOS validation
compiled the shared C++ protocol but did not build the complete Linux inference
executable.
