# Reference web-content service

This supersedes the earlier inference that search summaries use a local native
model, or that three candidates are always requested. The inspected original is
Foresight 1.0.0.28.20261005, executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis used REA process captures of IDA Pro.

## Request and response

`OdmlService.fetchWebContent` (0x1008e705c) calls TLS gRPC at
`odml.pa.googleapis.com:443`, method
`/ai_edge.foresight.service.ForesightService/FetchExternalWebsite`.
`_apiKeyOptions` (0x1006a1e48) supplies `X-Goog-Api-Key` metadata from a bundled
pool entry. Credential entries 9019 and 27425 are excluded from the reader. No
credential values are copied into the repository. `new OdmlService` is a
singleton constructor; `_fClient` lazily retains its channel/client.

| Request field | Tag/type | Value used by search |
| --- | --- | --- |
| url | 1 / string | Result URL, unchanged |
| useTrawler | 2 / bool | false, explicitly set |
| summarizeContent | 4 / bool | true |
| maxSummarizationWords | 5 / int32 | 100; schema default also 100 |
| modelId | 6 / string | models/odml-gemini-v4p1xs-supernova-one-shot |
| summaryTimeoutMillis | 8 / int32 | -1 |
| maxInputTokens | 9 / int32 | 131072 |

Tags 3 and 7 are unused. Response fields are title (tag 2), content (3),
mimeType (5), summary (7), and summaryConfidenceScore (8 / double). Other
inspected response slots are unused. BuilderInfo constructors are 0x100b888b8
and 0x100b88a40; BuilderInfo.aI uses int32, not int64.
`proto/foresight/web_content.proto` transcribes this subset, without claiming
the entire service or original source/edition metadata has been recovered.

On a successful fetch, the original sanitizes **content** only, leaving
summary/title unchanged, and overwrites MIME with `text/html`. If title is empty
and sanitized content is nonempty, title becomes its first 60 UTF-16 code units
(0x1008e7268), without parsing an HTML title element. The sanitizer repairs
UTF-16, removes U+FFFD, then retains printable ASCII and CR/LF. This same routine
is used by the query detector; it is now shared in `reference_text.dart`.

## Selection and errors

`summarizeWebContent` (0x1008e65fc) defaults to
`enableCandidateRanking=false`, `candidateRankingCount=3`, and
`summaryTimeoutMillis=-1`. With ranking disabled it makes **one** fetch task.
With ranking enabled it makes at least one task, repeating the same options
until reaching the candidate count. Tasks run concurrently, preserving input
indices. Selection starts at score -1 and replaces the result for equal or
higher scores: equal-score later inputs win regardless of completion order.
Null responses are ignored.

This default correction is bound by decoded parameter names, the branch at
0x1008e679c, and measured boolean/null offsets in the matching VM: true +0x20,
false +0x30. The branch tests bit 4 and skips extra candidates for false. The
search caller passes no named overrides (0x1008e6504).

Each fetch failure is caught by `_parallelizeTasks` and leaves a null result.
All failed/missing candidates produce an empty WebsiteSummaryResult, so search
uses the snippet. The outer five-second callback timeout still propagates;
an unfinished summary past that deadline fails the callback.

## Implementation boundary and verification

`WebContentService` implements this RPC and postprocessing with an internally
supplied distribution credential. It shuts down its default channel; injected
channels remain caller-owned. `summarizeSearchPage` connects to SearchCallbacks'
provider interface. No request is made until a caller invokes it.

The subsequent [native tool bridge](reference-tool-generation.md) now connects
generation callbacks to search. Production activation, citation persistence and
release credentials remain outstanding.
This is a remote Gemini summary path, distinct from ordinary local generation.
Adding this client does not enable remote requests in the application, and no
separate user project configuration UI has been added.

`web_content_test.dart` uses fixed wire bytes and a loopback gRPC server to check
field presence, negative int32 encoding, one-request default, metadata, response
postprocessing, concurrent ranking/ties, fetch-error snippet fallback, empty
URLs and channel ownership. These fixtures do not establish endpoint access,
credential validity or live summary quality.

Bindings were generated with protoc 36.2 and protoc_plugin 22.5.0, compatible
with the project's protobuf 5.1.0, with the matching Dart SDK on PATH:

```sh
protoc --plugin=protoc-gen-dart=/path/to/protoc-gen-dart \
  --dart_out=grpc:packages/foresight_core/lib/src/generated \
  --proto_path=proto/foresight web_content.proto
```

Current core validation: **116 passed, one opt-in skipped**. Core and desktop
analyzers are clean. Eight new wire/gRPC tests pass.

## REA evidence

Raw responses and the exported bundle are under ignored
`test-results/reference-functions/ida/`. IDA workers closed normally.

- `ev_a68a54303b40c0ebee8d724f5b8390387653cca1ecbb3de35b6220a5084c5493`: fetch request/response processing and selected summary fields.
- `ev_92250aece610359be2fc6aaf2a1aac7e1a2f2ce0c66bcb90b96fd4abc490d11e`: message BuilderInfo, RPC method and model-ID formatting.
- `ev_22d181114fced6c6e2e23555f52506c755601480246efc0f0cfd855b9fa24e2f`: channel, metadata construction, request values and integer field type.
- `ev_7dc3b8f19fcb335ce2c9337296a573b3e566b4b28802991f4b394e541c944c7a`: singleton/channel construction and port.
- `ev_dd954f0cb01ffcedeff033ce8568daaaf03af950cd6883bb1cf7bfccb6b33c90`: model, RPC path, parameter and field names.
- `ev_5d071106843d4d291345197a00dcb637cf360419ed73862baf114434f4d4f1ee`: title fallback and ranking branch.
- `ev_93377985b17b36bbd4b665851b071ae474aeae855bac74c209cca572124dd6bf`: endpoint, header name, MIME and boolean/null offsets.
