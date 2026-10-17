# Original ChatService web sources and citations

Reference: Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Investigation used REA captures of IDA Pro and the focused Dart snapshot reader.

## Recovered contract

`ChatService.sendMessage` (0x1009082dc) reads and clears its source set at
0x100908550–0x100908554 for each send. Retrieved personal sources are added
before generation. The Google-search closure registered by initialize
(0x100920430) adds search sources to that same ordered set. Set equality compares
the entire `(title, URL)` record: exact duplicates retain their first number;
the same URL with a different title gets another number.

The callback formats each result as `[Source:N] result\n\n`, using its position
in the shared set plus one. This differs from the separate InferencePipeline
callback, which numbers each search from one. `truncateToolResult`
(0x10091da68) keeps the first 2000 UTF-16 units and appends the literal
`\n... [Content Truncated due to length] ...` when the combined result exceeds
2000 units. Exact-length results are unchanged.

The citation resolver (0x10090df50) matches
`\[Source\s*[:\s]?\s*[^\]]+\]`, case-insensitively. It extracts `\d+` from each
marker, accepts indices from one through the source count, and selects sources
in first-mention order. Final numbers are compacted from one in that order.
Repeated numbers within one marker remain repeated. The rewrite closure
(0x10090e55c) uses the whitespace-consuming pattern
`\s*\[Source\s*[:\s]?\s*[^\]]+\]` and emits ` [Source:1, 2]`, including one
leading space. A marker without valid numbers is removed with its preceding
whitespace. No-source answers have matching markers stripped. The source
selector is 0x10090e98c; number parsing is 0x10090e940. Regex initializer flags
were checked against the pinned Dart VM factory signature, rather than inferred
from the decompiler's bool constant labels.

## Application integration

`ReferenceChatSources` and `resolveChatCitations` implement those rules. Each
web-enabled send gets its own table; retrieved sources and concurrent search
callbacks share it. Completed answers persist only selected sources, with
compacted citation labels. Web entries retain title, URL, result excerpt, query
and retrieval time in the existing citation JSON. Personal entries retain their
document and revision metadata. Web links open through the existing platform
URI opener after HTTP(S) validation; personal links keep revision-aware lookup.

General Ask and each meeting have independent web toggles, initially off. The
service transports `web_search: true` on the existing owned answer stream;
meeting validation, conversation identity, cancellation and atomic answer/link
insertion still apply. Web mode can answer without imported sources and can
finish without calling search. Cancellation during a callback cannot save or
link its late result. Toggle persistence and exact original UI scope are not
proven; the port currently keeps toggle state only for the workspace lifetime.

The recovered instruction string and text-only date/context/query envelope are
now used for web-enabled sends; see the prompt section below. Structured message replay is now implemented; see [history evidence](reference-chat-history.md).
Its 55% memory compression/FIFO policy is integrated. Original tokenizer,
sampling and model/context configuration remain under investigation. The current tool path
publishes provisional previews while streaming and one authoritative final
answer. See [streaming and retained-worker evidence](reference-chat-streaming.md). The [textual tool-call fallback](reference-tool-fallback.md)
is now integrated and has a controlled-provider real-model check.

## Release credentials

There is no user Google-project setup screen. Both release packagers accept
distribution-owned `FORESIGHT_SEARCH_API_KEY` and
`FORESIGHT_WEB_CONTENT_API_KEY` from the packaging environment. Both must be
present to enable this feature. macOS writes scalar values into the main and
service bundles' runtime.json; Linux safely quotes literal values in its shared
desktop/service launcher. Neither value is printed by the packaging helper.
Without credentials, the web toggle is disabled with an unavailable-build
tooltip. These credentials are part of the release artifact and are not secret
from its recipient. No original credential has been copied into source.

Credential packaging support is complete; actual release provisioning and
successful live Google/ODML access remain unverified. The redacted
[cloud acceptance command](reference-live-cloud-services.md) checks search,
summary, shared configuration and optional detector download; the recorded host
run exits 2 before transport because distribution keys are absent. Fixtures
exercise the real search/summary clients separately;
application tests inject deterministic search callbacks rather than contacting
those services.

## Evidence and verification

REA captures (raw JSON and bundle are retained under ignored
`test-results/reference-functions/ida`):

- `ev_fd80d88ffe892cb23d389b2359a2eec17aed5b1cc6e4e0e8abe039c97d067c93`: paginated ChatService.sendMessage and final marker cleanup.
- `ev_0c9d1d0685820e6779fb509ab1d2eb8d1a1312d35ab59ad649ac8fdb304fde1a`: resolver, source selection and isEmpty dispatch verification.
- `ev_2f2ca18bf9d0bc740f88ecce5387e7ac6a8dbc4cdb311b573e9347643c931152`: registered Google callback and request-wide source numbering.
- `ev_d8541be53ec544cf7aa4251e37af87af4230c795200237f8b7e0af59e3a1be5c`: rewrite, selection, parsing and truncation functions.
- `ev_c69547187bd1354f0ef159a8b4b0420dcbc172914d6c086709aa419eea7cbd87`: public regex constants and dispatch entries.
- `ev_2f03c3f22af99eab5589b2f9f747e2c202c57805cfd385171438d0add3286b96`: digit regex and function entries.
- `ev_d5ee1cb2717657e4e98d9497607d37a7ab47913d693d413692d24d2509595bbe`: exact prefix, separator and truncation suffix units.

Five citation fixtures cover shared numbering, pair deduplication, truncation,
permissive marker syntax, invalid indices and remapping. Five application tests
cover no-import and mixed personal/web answers, no-tool answers, cancellation,
URL snapshot persistence, and a real service socket with meeting ownership.
Three desktop widget tests cover routing, per-conversation selection,
unavailable builds and citation behavior. Two packaging tests cover partial
credential rejection, scalar macOS serialization and literal Linux shell
transport including quotes, newlines and command-substitution characters.

Final validation for this integration: **136 core tests passed, one opt-in model
test skipped** with the native bridge configured; **168 desktop tests passed,
10 opt-in tests skipped**. Core and desktop analyzers reported no issues. Both
release credential tests passed. Live Google access, real-model tool selection
and physical reference comparison are outside those fixture results.

## Chat prompt reconstruction

IDA pagination of `ChatService.initialize` (0x10091dadc, 1518 lines) shows an
initial system message built at 0x10091ea20–0x10091eb34 using PP[31008]. The full
6479-byte UTF-8 string is reproduced in `reference_chat_prompt.dart`; SHA-256 is
`71a908bf5b041da7cff1c7ad1d397a62b2fc3d433774bad7dcaf26a351762f78`.
It requires concise Markdown, personal-context priority, internal knowledge for
certain general facts, native-tool fallback, source tags, passive treatment of
context, and the `<|"|>` string delimiter in tool calls. It explicitly forbids
JSON wrappers. Calendar answers have additional formatting rules, including
suppressing source tags.

The text-only message built at 0x100908994–0x100908b00 uses
`DateFormat('EEEE, MMMM d, yyyy')`, a local DateTime.now, and this envelope:

```text
[Current Date: Friday, October 16, 2026]

Here is some context from the local knowledge base that might be relevant:
<gathered context>
Query: <verbatim query>
```

The context header and its terminating newline are omitted when context is
empty. The original caps the entire gathered context at 3000 UTF-16 units with
the same truncation suffix used by search (0x100908750–0x1009087a4). The port now
applies that cap after collecting source entries rather than imposing its prior
per-excerpt byte cap in web mode. Its retrieval/ranking and gathered-source
formatting still differ from the original InsightService and need comparison.
No audio attachment path has been added by this text-only change.

The native tool request now carries separate system-message and tool-definition
fields. The C++ and macOS Python backends install those instructions as the
conversation's system message and send the user prompt separately. Legacy
array-only native requests keep their generic system default. Prompt admission
counts system and tool-definition tokens as well as user text and output reserve.
Structured user/assistant replay, retained workers, base-conversation cloning
and streaming are now implemented;
see [worker evidence](reference-chat-streaming.md). Controlled tokenizer probes
and bundled sampling defaults match within the recorded scope; alternative
model configurations and broader original runtime comparison remain open. See
[cloud/runtime settings evidence](reference-live-cloud-services.md).
The [history ledger](reference-chat-history.md) describes implemented memory
compression, FIFO fallback and durable checkpoints. Tests verify the recovered instruction hash,
date/query envelope, optional context and UTF-16 truncation, plus its use by the
application's web-generation call.

Additional REA evidence:

- `ev_1e61b38db8b05fc9daad07d41a28bbe2603045d08eaa7d1565929e863f6d6966`: complete initialize pagination and date-format call-site assembly; IDA closed normally.
- `ev_6eab863ec659bc7e95814ae838c62c7801fb230beaf6ea06bb27ca0dfabdcbe7`: exact public instruction/envelope/date constants decoded by the matching snapshot reader.

Prompt/role follow-up validation: **139 core tests passed, one opt-in model test
skipped**. The native tool integration fixture additionally verifies the exact
recovered system-string hash crossing the FFI/child boundary separately from
user text. All four CTest groups passed, including shared C++ request parsing
and five macOS runner tests. Four focused desktop tests passed; both analyzers
are clean. This macOS pass did not build the complete Linux inference worker or
load a real model.
