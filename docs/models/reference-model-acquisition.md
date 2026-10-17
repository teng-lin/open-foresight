# Original model acquisition protocol

The reconstructed protocol is backed by retained IDA Pro analysis of Foresight
(`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`).
The inspected app's `CFBundleShortVersionString` is `1.0.0`.
`packages/foresight_core/lib/src/model_acquisition.dart` implements the public
metadata RPC and blob transport. The existing Local models screen now connects
these to dedicated model setup, authenticated encrypted storage and private
plaintext runtime leases. Guided local import remains available.
The initial reconstruction made no live metadata or blob request. The subsequent
[original distribution configuration check](../chat/reference-live-cloud-services.md#original-distribution-configuration-follow-up)
successfully fetched both metadata and the fixed-digest detector blob using the
two original app-bundled settings.

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
the same credential pool entry PP9019. The initial protocol reconstruction
inspected only static references and the
public header name `X-Goog-Api-Key`. The later authorized distribution follow-up
recovered the bundled setting from the verified executable.
Release integration can reuse the existing internally supplied
`FORESIGHT_WEB_CONTENT_API_KEY`. No end-user API project configuration is
needed. The distribution follow-up successfully authenticated metadata and fetched
the
advertised detector blob, verifying its fixed size and SHA-256.

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

The original slot count is `ceil(size/838860800.0)` clamped to 1 through 8
(800 MiB per slot). This uses double division, as in the original. The supported
179437568-byte detector therefore uses one slot. Explicit parallelism overrides
are available for protocol fixtures.

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
component calculates this original parallelism for each download. Its default
retry policy allows five total attempts, a 500 ms factor, and a
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
`ida/model-acquisition-range-retry-fields-pool.txt`. The slot-count divisor is
bound by `ida/model-acquisition-parallelism-pool.txt`, and its ceiling/clamps by
`ida/model-asset-download-selection.json` at `0x100669014` through `0x10066907c`.

## Distinct selection paths

`downloadModelsByType` at `0x1006685d4` builds a map keyed by model type in input
order, so later duplicates replace earlier ones. Its download operation then
passes `basename(metadata.blobId)` to the media helper. The pure
`referenceModelDownloadPlan` helper implements only these two download rules;
it makes no version comparison and does not imply that a later entry is newer.

The existing-model lookup has different semantics: `_getLocalModelPath` at
`0x1006452b8` scans ordered metadata and returns the first matching type whose
file exists, before a directory fallback. `_getLocalOnDeviceModel` at
`0x1008f0b54` returns the first matching metadata. These lookup and refresh
policies are not implemented by the download-plan helper.

## Validation and remaining integration

`model_acquisition_test.dart` uses independent fixed protobuf wire bytes, a
loopback gRPC server, and real loopback HTTP sockets. It checks credential and
request fields, concurrent partition assembly, status classification,
interrupted-body resume, the short-EOF behavior, and cancellation without
closing an injected shared HTTP client. No external service is contacted.

The existing Local models screen now connects acquisition to dedicated setup.
The service operation models.acquire_query uses the inspected compatibility
version 1.0.0, last advertised type-4 metadata and its blob basename. It rejects
incompatible advertised sizes before allocation, verifies the fixed plaintext
size/SHA-256, encrypts an owned candidate, reopens a private plaintext lease and
completes the real worker readiness fixture. Registration is the final step,
after worker shutdown and lease cleanup succeed. Failures preserve the prior
registration. Cancellation stops only owned RPCs, transfers, helpers and workers.
The download action is available when the distribution provides the existing
shared web-content credential; no additional user project or key setting exists.

native/model_crypto.swift reproduces the five-byte Tink prefix plus AES-256-GCM
nonce/ciphertext/tag with empty AAD. It reads or creates only the port-owned
com.openforesight.encryption / dataEncryptionKey entry, using a binary Tink keyset.
MacModelVault publishes new private encrypted candidates and opens unique 0700
plaintext leases. Lease cleanup waits for the owning worker to exit. The helper
is built and bundled as FORESIGHT_MODEL_CRYPTO. This vault flow never reads the
original application encryption key or API
credential; distribution configuration import is a separate explicit operation.

The native self-test passes fixed independent AES/Tink vectors, tamper rejection,
exclusive output and symlink checks without Keychain access. An explicit opt-in
integration test compiles the same source with only its service literal replaced
by a unique fixture service and signs the helper ad hoc. Separate real processes
proved Keychain persistence, key-ID reuse, distinct nonces, round trips, private
outputs, tamper rejection and destination preservation. The test deleted only its
unique fixture entry and passed under REA
ev_2b6f466912872bd7b54132dd85640c5f517b44e522afd19f4e0d81facda30457.
See tests/integration/test_model_crypto_keychain.py. This is not a Developer ID
or complete application-bundle Keychain acceptance test.

All four actual-detector tests passed with local transport and framing-only
vault fixtures, including acquisition/registration/reopen and forced plaintext
cleanup failure preserving the previous registration. Their retained log is
query-runtime/acquisition-cleanup-review-test-v2.log. These fixtures avoid
Keychain and are not cryptographic or live service oracles. Those initial fixture
runs made no live API call and extracted no credentials. Subsequent distribution
acceptance established live metadata/blob access. Full signed release acceptance
and broader GPU numerical parity remain unverified.

The ordered refresh catalog, first-existing path lookup, owned recursive fallback
and obsolete-model cleanup are now implemented and connected to distribution
acquisition and missing-registry recovery. Explicit download still uses its
distinct last-duplicate plan. See [model lifecycle](reference-model-lifecycle.md)
for exact policies, port ownership constraints, tests and remaining platform gates.

The [cloud acceptance command](../chat/reference-live-cloud-services.md) can now check
live shared metadata and optionally authenticate the downloaded detector blob
without modifying a profile. The initial host run was blocked by absent
distribution settings; the subsequent authorized run passed metadata and
fixed-digest detector download checks, as recorded in the linked follow-up.
