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

The port's web prompt, history/context bounds, sampling and 4096-token native
context have not been shown equivalent to the original. The current tool path
publishes its final model answer in one delta; original streaming and textual
tool-call fallback remain to be reproduced.

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

Actual release provisioning and successful live Google/ODML access remain
unverified. Fixtures exercise the real search/summary clients separately;
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
