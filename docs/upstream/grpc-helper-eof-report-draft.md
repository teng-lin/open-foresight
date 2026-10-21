# Draft: queued request writes can escape after HTTP/2 peer EOF

Local draft for `grpc/grpc-dart`; not submitted.

## Affected qualified versions

- Dart SDK supplied by the repository's pinned Flutter SDK.
- `grpc` **4.3.1**, `http2` **2.3.1**, exact pubspec and core lockfile versions.
- Native gRPC transport over a private Unix socket, without a proxy or TLS.

## Observed failure and expected behavior

A peer can close the HTTP/2 transport while a request still has queued outgoing
payloads. The forwarding subscription may subsequently write to a closed sink.
Synchronous sink errors and failed asynchronous half-close/completion futures
must fail the request exactly once, cancel forwarding and permit reentrant
termination. They should not escape to the zone as unhandled asynchronous errors,
leave pending requests waiting forever, or prevent a later request from succeeding.
A normal outgoing half-close must still permit the later response.

Our temporary adapter retains gRPC's connection/reconnect policy but overrides
`Http2ClientConnection.makeRequest` to own that forwarding subscription and route
all write failures through the request error handler. It also prevents failed
socket completion from escaping discarded upstream `.then`/`.whenComplete`
futures while preserving the socket's incoming error/EOF notification.

## Reproduction material to minimize before submission

The repository has deterministic fake-transport cases in
`packages/foresight_core/test/helper_channel_test.dart`, plus real Unix-socket
coverage in `helper_transport_test.dart`. Run from `packages/foresight_core`:

```sh
dart test test/helper_channel_test.dart test/helper_transport_test.dart
```

The relevant gates queue a payload, close the peer's outgoing sink before the
queued callback runs, and assert one `UNAVAILABLE` failure with no escaping zone
error. Separate cases inject synchronous `add` failure and asynchronous `close`
failure, call termination from inside the failure handler, cancel queued data,
and verify a fresh request succeeds. Header/compression and successful half-close
cases prevent changing ordinary request behavior to suppress failures.

These tests currently exercise the local adapter. Before publishing, attach a
standalone test against the stock pinned upstream transport showing the failing
case alongside the fixed behavior; passing adapter tests alone do not establish
that an upstream release fixes the issue.

## Existing-report search

On 2026-10-21, searched `grpc/grpc-dart` issues with `sink closed`, `EOF`,
`stream closed`, and `socket done`, then read the closest results. No exact report
covering this pinned native request-forwarding/write-completion race was found
within those searches.

- [#131](https://github.com/grpc/grpc-dart/issues/131) concerns an older cancelled
  response stream and was closed after an old HTTP/2 fix.
- [#202](https://github.com/grpc/grpc-dart/issues/202) concerns calls initiated
  while a connection is finishing; its discussion identifies an older fix.
- [#283](https://github.com/grpc/grpc-dart/issues/283) concerns a grpc-web/nginx
  path and lacks an actionable reproduction.
- [#802](https://github.com/grpc/grpc-dart/issues/802) concerns client-initiated
  GOAWAY interrupting active server streaming.

Those reports do not qualify removal of this workaround. Preserve the exact pins
and local regression gates until an upstream fix passes them. Publishing this
draft requires separate authorization to contact upstream.
