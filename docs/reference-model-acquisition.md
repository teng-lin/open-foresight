# Original model acquisition protocol

The reconstructed protocol is backed by retained IDA Pro analysis of Foresight
(`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`).
The inspected app's `CFBundleShortVersionString` is `1.0.0`.
`packages/foresight_core/lib/src/model_acquisition.dart` implements the public
metadata RPC and blob transport. It is not yet connected to model setup or the
desktop UI. Existing guided import remains the supported installation path.
No live metadata or blob request was made during this reconstruction.

## Metadata and shared distribution credential

`OdmlService.fetchConfig` at `0x1006720ec` calls unary gRPC
`/ai_edge.foresight.service.ForesightService/GetSharedConfig` on
`odml.pa.googleapis.com:443`. The request has app version (string, tag 1),
platform (`macos`, string, tag 2), and fallback mode
`FALLBACK_CLOSEST_LOWER` (enum value 1, tag 3). The version getter at
`0x1006a2670` initializes package information and reads its version field. The native plugin at
`0x100526548` maps `version` to `CFBundleShortVersionString`; the
new service requires the caller to supply an explicit internal version.

`ForesightSharedConfig` has repeated model metadata at tag 1. Metadata contains
model type (enum, tag 1), name (string, tag 2), version (string, tag 3), blob ID
(string, tag 6), and size (int64, tag 8). Unused tag gaps are retained in
`proto/foresight/web_content.proto`. The generated bindings represent the two
enum fields as wire-compatible integers to avoid inventing unrecovered enum
names. The detector model type is the recovered value 4,
`MODEL_TYPE_QUERY_DETECTOR` (PP25030).

The original metadata RPC, web summarization RPC, and HTTP blob downloader use
the same credential pool entry PP9019. Only the static references and public
header name `X-Goog-Api-Key` were inspected; the credential value was not read.
Release integration can reuse the existing internally supplied
`FORESIGHT_WEB_CONTENT_API_KEY`. No end-user API project configuration is
needed. No valid remote credential, detector blob ID, advertised model version,
or live service availability has been established.

Evidence: `ida/model-config-{fetch,request-public-schema,rpc-route-initializer,
response-public-schema,reference-app-version}.json`,
`ida/model-metadata-public-schema.json`, `ida/query-asset-reader.log`,
`ida/search-summary-call-options.json`, and
`ida/query-odml-download-media.json` beneath the ignored reference results.

## Blob transport and observed edge cases

The URL builder at `0x10066d500` constructs
`https://odml.pa.googleapis.com/v1/medias/foresight/<blobId>:download`, with
`alt=media` and the same injected key as query parameters. Exactly one leading
slash is removed from the blob ID. Empty IDs or nonpositive expected sizes
produce an empty result without transport.

Ranges are inclusive. For N parallel slots, chunk size is `ceil(size/N)`, start
is `slot*chunkSize`, and end is `min(start+chunkSize-1,size-1)`. Surplus slots do
not issue requests. Each GET carries `Range: bytes=<cursor>-<end>`; the cursor
advances only after its received block has been written. Interrupted transfers
retry from that cursor rather than repeating accepted bytes.

HTTP 206 is accepted. HTTP 200 is accepted only when the original assigned
range covers the complete object; a split range receiving 200 fails without
retry. HTTP 429, 500, 502, 503, and 504 are retryable. Other unsuccessful statuses
are not. The recovered exception allowlist includes ClientException,
_ClientSocketException, RequestAbortedException, SocketException, and
TimeoutException. Progress callbacks are throttled to 250 ms. The standalone
component requires explicit parallelism until its original default is bound.
Its default retry policy allows five total attempts, a 500 ms factor, and a
10 s cap. Attempt n multiplies the factor by `2^min(n,31)` and then by
`1 + (nextDouble()*2-1)*0.25`, using two sequential Duration multiplications
and their separate rounding. Nonpositive attempts return zero without drawing
randomness. Final transport failures expose only the exception type,
because an original HTTP exception may contain the authenticated URL.

The original stream loop does not assert that successful EOF reaches the end
of its assigned range. A short successful body therefore leaves zero-filled
bytes in the preallocated memory buffer. The transport preserves this observed
behavior; callers must authenticate the downloaded asset before registration.
The existing detector import checks the complete fixed SHA-256 and size and
preserves a valid registration on failure. This transport alone must not be
treated as authenticated installation.

Evidence: `ida/model-download-{http-flow,partition-closure,
chunk-request-closure,retryability,retry-exception-handler,on-retry,
range-header-arguments,channel-call-arguments}.json` and
`ida/model-acquisition-range-retry-pool.txt`,
`ida/model-download-retry-delay.json`, and
`ida/model-acquisition-range-retry-fields-pool.txt`.

## Validation and remaining integration

`model_acquisition_test.dart` uses independent fixed protobuf wire bytes, a
loopback gRPC server, and real loopback HTTP sockets. It checks credential and
request fields, concurrent partition assembly, status classification,
interrupted-body resume, the short-EOF behavior, and cancellation without
closing an injected shared HTTP client. No external service is contacted.

Automatic acquisition remains incomplete: bind original parallelism
default, finish metadata selection/update policy, connect the distribution
credential and bundled runtime to existing model setup, authenticate the
supported plaintext before atomic registration, and verify actual service
access separately. Original local encryption and temporary decryption have
been recovered elsewhere; this component does not claim to reproduce that
persistence lifecycle.
