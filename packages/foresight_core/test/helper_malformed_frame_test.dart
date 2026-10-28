import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

// Service <-> helper, malformed and partial frames. The production Helper,
// its channel and transport talk over a real Unix socket to a hostile peer.
// The peer is a fixture, not the real ForesightHelper, so these tests show how
// the CLIENT side settles; they say nothing about the helper's own reception
// of bad frames.
//
// The contract, for every scenario:
//  - the pending call settles with a GrpcError, bounded by a small multiple of
//    its deadline (a peer that closes settles it promptly, a stalled peer
//    only at the deadline);
//  - a second call made while the hostile peer is still attached settles the
//    same way: promptly with a non-deadline code for a closing peer, and at
//    its own, shorter deadline for a stalled one. This shows the second call
//    is not stuck for the first call's deadline; a call queued behind a
//    stalled connection would also end at its own deadline, so it does not by
//    itself rule out a wedged connection;
//  - nothing escapes into the error zone, including after teardown; and
//  - the same Helper serves a valid replacement at the same socket within a
//    few seconds, without being rebuilt, which is what shows the channel
//    recovers.
// Two known deficiencies are characterized separately.

/// A valid, empty HTTP/2 SETTINGS frame: the peer's side of the handshake.
final settings = Uint8List.fromList([0, 0, 0, 4, 0, 0, 0, 0, 0]);

const deadline = Duration(seconds: 3);
const shortDeadline = Duration(seconds: 1);
const recoveryBound = Duration(seconds: 10);

class PingService extends RagServiceBase {
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true, version: 'replacement');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Watches what the client writes to the peer and reports when a complete
/// HTTP/2 HEADERS frame (a request) arrived, so peers act on a barrier rather
/// than a timer.
class Client {
  Client(this.socket, {bool listen = true}) {
    if (!listen) return;
    socket.listen(
      _read,
      onError: (Object _) {},
      onDone: () {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }
  final Socket socket;

  /// Errors the fixture swallowed on this socket (a failed flush, a broken
  /// pipe). A scenario asserts there were none while the peer was active, so a
  /// swallowed EPIPE cannot turn "half a header then EOF" into a plain EOF.
  final swallowed = <Object>[];
  final _buffer = <int>[];
  final _request = Completer<void>();
  final _closed = Completer<void>();
  // Client connection preface (24 bytes), then frames.
  int _position = 24;

  /// Completes when a HEADERS frame has fully arrived.
  Future<void> get requestSeen => _request.future;
  Future<void> get closed => _closed.future;

  void _read(Uint8List data) {
    _buffer.addAll(data);
    while (_buffer.length - _position >= 9) {
      final length =
          (_buffer[_position] << 16) |
          (_buffer[_position + 1] << 8) |
          _buffer[_position + 2];
      if (_buffer.length - _position < 9 + length) return;
      if (_buffer[_position + 3] == 1 && !_request.isCompleted) {
        _request.complete();
      }
      _position += 9 + length;
    }
  }
}

typedef Misbehave = void Function(Client client);

class Scenario {
  const Scenario(this.name, this.peer, {required this.settlesWhenPeerCloses});
  final String name;
  final Misbehave peer;

  /// Whether the peer closes, so the call settles before its deadline.
  final bool settlesWhenPeerCloses;
}

final scenarios = [
  Scenario(
    'a handshake, then EOF once the request has arrived',
    (client) {
      client.socket.add(settings);
      unawaited(client.requestSeen.then((_) => client.socket.destroy()));
    },
    settlesWhenPeerCloses: true,
  ),
  Scenario(
    'a handshake, half a frame header, then EOF once the request has arrived',
    (client) {
      client.socket.add(settings);
      unawaited(
        client.requestSeen.then((_) async {
          client.socket.add([0, 0, 8, 0, 0]);
          // Flush first: destroying at once may discard the unsent bytes and
          // turn this into a plain EOF. On macOS the bytes arrive either way
          // (probed); the delivery test below pins them for other platforms.
          await client.socket.flush().catchError((Object error) {
            client.swallowed.add(error);
          });
          client.socket.destroy();
        }),
      );
    },
    settlesWhenPeerCloses: true,
  ),
  Scenario(
    'a handshake followed by half a frame header, then silence',
    (client) => client.socket.add([...settings, 0, 0, 8, 0, 0]),
    settlesWhenPeerCloses: false,
  ),
  Scenario(
    'a handshake followed by a frame header that announces a huge payload '
    'and never delivers it',
    (client) =>
        client.socket.add([...settings, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1]),
    settlesWhenPeerCloses: false,
  ),
];

/// A valid HTTP/2 response whose gRPC message is malformed: the transport is
/// well formed and the failure is in the message layer.
class MalformedMessage {
  const MalformedMessage(this.name, this.body, {this.trailers = true});
  final String name;

  /// The DATA payload: a 5-byte gRPC prefix followed by the message.
  final List<int> body;
  final bool trailers;
}

const malformedMessages = [
  // Prefix says 100 bytes follow; three do, then the stream ends.
  MalformedMessage('a message shorter than its length prefix', [
    0,
    0,
    0,
    0,
    100,
    1,
    2,
    3,
  ]),
  // A complete frame whose protobuf payload cannot decode.
  MalformedMessage('a message that is not valid protobuf', [
    0,
    0,
    0,
    0,
    3,
    0xff,
    0xff,
    0xff,
  ]),
  // A compressed frame although no compression was negotiated.
  MalformedMessage('a compressed message without a negotiated codec', [
    1,
    0,
    0,
    0,
    2,
    1,
    2,
  ]),
];

void main() {
  for (final hostile in scenarios) {
    test(
      '${hostile.name}: the call settles with a GrpcError, a second call '
      'settles as this peer implies, nothing escapes, and a replacement is '
      'served',
      () => _guarded((uncaught) => _exercise(hostile, uncaught)),
    );
  }

  for (final malformed in malformedMessages) {
    test('a valid HTTP/2 response carrying ${malformed.name}: the call fails '
        'with a GrpcError, nothing escapes, and the channel is reusable', () {
      return _guarded((uncaught) => _malformedMessage(malformed, uncaught));
    });
  }

  test('a peer that sends its handshake and closes at once, then calls made '
      'after the channel observed the closure: every call settles with a '
      'GrpcError and nothing escapes', () {
    return _guarded(_closedBeforeWrite);
  });

  group('the fixture delivers the bytes its scenarios claim', () {
    // A raw client that completes the preface and sends one HEADERS frame, then
    // reads everything the hostile peer writes until it closes.
    final preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'.codeUnits;
    final request = [0, 0, 1, 1, 4, 0, 0, 0, 1, 0x82];
    Future<List<int>> received(Scenario scenario) async {
      final peer = await _Peer.start(scenario.peer);
      addTearDown(() async {
        await peer.listener.close().catchError((Object _) => peer.listener);
        peer.root.deleteSync(recursive: true);
      });
      final socket = await Socket.connect(
        InternetAddress(peer.path, type: InternetAddressType.unix),
        0,
      );
      addTearDown(socket.destroy);
      socket.add([...preface, ...settings, ...request]);
      return socket
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
          .timeout(const Duration(seconds: 10));
    }

    test('EOF once the request arrived: the handshake, then nothing', () async {
      expect(await received(scenarios[0]), settings);
    });

    test('half a frame header then EOF: the handshake plus the five header '
        'bytes reach the client before the close', () async {
      expect(await received(scenarios[1]), [...settings, 0, 0, 8, 0, 0]);
    });
  });

  group('known deficiencies (characterized, not endorsed)', () {
    // Both end only at the call deadline. The Helper's default is 45 s, and
    // 30 minutes for indexDocument. If grpc starts reporting these promptly,
    // these tests fail and the inventory should be updated.
    test('KNOWN DEFICIENCY: bytes that are not HTTP/2 are reported only at '
        'the deadline', () {
      return _guarded((uncaught) async {
        final outcome = await _callAgainst(
          (client) => client.socket.add('HTTP/1.1 500 nope\r\n\r\n'.codeUnits),
          uncaught,
        );
        expect((outcome.error as GrpcError).code, StatusCode.deadlineExceeded);
        expect(outcome.elapsed, greaterThanOrEqualTo(deadline));
      });
    });

    test('KNOWN DEFICIENCY: a peer that closes before any frame is reported '
        'only at the deadline', () {
      return _guarded((uncaught) async {
        final outcome = await _callAgainst(
          (client) => client.socket.destroy(),
          uncaught,
        );
        expect((outcome.error as GrpcError).code, StatusCode.deadlineExceeded);
        expect(outcome.elapsed, greaterThanOrEqualTo(deadline));
      });
    });
  });
}

/// Run [body] in its own error zone; the first uncaught error fails the test.
Future<void> _guarded(Future<void> Function(List<Object> uncaught) body) async {
  final uncaught = <Object>[];
  final done = Completer<void>();
  void fail(Object error, StackTrace stack) {
    uncaught.add(error);
    if (!done.isCompleted) done.completeError(error, stack);
  }

  unawaited(
    runZonedGuarded(() async {
      try {
        await body(uncaught);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    }, fail),
  );
  await done.future.timeout(
    const Duration(minutes: 2),
    onTimeout: () => throw TimeoutException('hostile-peer scenario hung'),
  );
  // Errors can arrive after the body, for example from teardown: the zone's
  // handler keeps recording, and a final settle barrier checks what it saw.
  await Future<void>.delayed(const Duration(milliseconds: 600));
  if (uncaught.isNotEmpty) {
    throw StateError('Errors escaped after the scenario finished: $uncaught');
  }
}

class _Peer {
  _Peer._(this.root, this.path, this.listener);
  final Directory root;
  final String path;
  final ServerSocket listener;
  final clients = <Client>[];

  /// Errors swallowed on any fixture socket so far.
  List<Object> get swallowed => [for (final c in clients) ...c.swallowed];

  // ignore: close_sinks
  final accepted = StreamController<Client>.broadcast();

  static Future<_Peer> start(Misbehave? behave, {bool watch = true}) async {
    final root = createTestTempDirectorySync('of-hostile-');
    final path = '${root.path}/helper.sock';
    final listener = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final peer = _Peer._(root, path, listener);
    listener.listen((socket) {
      // EPIPE or ECONNRESET on the fixture's own side is not the client's fault.
      final client = Client(socket, listen: watch);
      unawaited(
        socket.done.catchError((Object error) {
          client.swallowed.add(error);
        }),
      );
      peer.clients.add(client);
      peer.accepted.add(client);
      behave?.call(client);
    });
    return peer;
  }

  /// Replace the hostile listener with a valid helper at the same path.
  Future<Server> replace() async {
    for (final client in clients) {
      client.socket.destroy();
    }
    await listener.close();
    if (File(path).existsSync()) File(path).deleteSync();
    final server = Server.create(services: [PingService()]);
    await server.serve(
      address: InternetAddress(path, type: InternetAddressType.unix),
      port: 0,
    );
    return server;
  }
}

/// Run each cleanup step even if another fails; the first failure is thrown
/// only when the test body itself did not fail.
Future<void> _cleanup(
  List<Future<void> Function()> steps,
  Object? primary,
) async {
  Object? first;
  StackTrace? firstStack;
  for (final step in steps) {
    try {
      await step();
    } catch (error, stack) {
      first ??= error;
      firstStack ??= stack;
    }
  }
  if (first != null && primary == null) {
    Error.throwWithStackTrace(first, firstStack!);
  }
}

Future<({Object? error, Duration elapsed})> _timedPing(
  Helper helper,
  Duration timeout,
) async {
  final watch = Stopwatch()..start();
  final error = await helper.client
      .ping(PingRequest(), options: CallOptions(timeout: timeout))
      .then<Object?>((_) => null, onError: (Object e) => e);
  return (error: error, elapsed: watch.elapsed);
}

Future<void> _serveReplacement(Helper helper, _Peer peer) async {
  final server = await peer.replace();
  addTearDown(server.shutdown);
  Object? lastError;
  final watch = Stopwatch()..start();
  late PingResponse response;
  try {
    await eventually(() async {
      try {
        response = await helper.client.ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(seconds: 2)),
        );
        return true;
      } on GrpcError catch (error) {
        lastError = error;
        return false;
      }
    }, timeout: recoveryBound);
  } catch (_) {
    throw StateError(
      'The channel did not serve the replacement within $recoveryBound; '
      'last error: $lastError',
    );
  }
  expect(response.version, 'replacement');
  expect(watch.elapsed, lessThan(recoveryBound));
}

Future<void> _exercise(Scenario hostile, List<Object> uncaught) async {
  final peer = await _Peer.start(hostile.peer);
  final helper = Helper(peer.path, peer.root.path, manageProcess: false);
  Object? primary;
  try {
    final first = await _timedPing(helper, deadline);
    expect(first.error, isA<GrpcError>(), reason: hostile.name);
    final code = (first.error as GrpcError).code;
    expect(first.elapsed, lessThanOrEqualTo(deadline * 2), reason: '$code');
    if (hostile.settlesWhenPeerCloses) {
      expect(first.elapsed, lessThan(deadline), reason: '$code ${first.error}');
    }
    // The peer is still attached, or its socket is dead. A closing peer fails
    // the second call promptly with a code that is not the deadline; a stalled
    // one ends it at its own, shorter deadline, not the first call's.
    final second = await _timedPing(helper, shortDeadline);
    expect(second.error, isA<GrpcError>(), reason: hostile.name);
    final secondCode = (second.error as GrpcError).code;
    final secondReason = '$secondCode after ${second.elapsed}';
    if (hostile.settlesWhenPeerCloses) {
      expect(second.elapsed, lessThan(shortDeadline), reason: secondReason);
      expect(
        secondCode,
        isNot(StatusCode.deadlineExceeded),
        reason: secondReason,
      );
    } else {
      expect(secondCode, StatusCode.deadlineExceeded, reason: secondReason);
      expect(
        second.elapsed,
        greaterThanOrEqualTo(shortDeadline - const Duration(milliseconds: 100)),
        reason: secondReason,
      );
      expect(
        second.elapsed,
        lessThan(shortDeadline * 1.5),
        reason: secondReason,
      );
    }
    // The fixture's own writes succeeded; only teardown may swallow errors.
    expect(peer.swallowed, isEmpty, reason: hostile.name);
    await _serveReplacement(helper, peer);
    expect(uncaught, isEmpty);
  } catch (error) {
    primary = error;
    rethrow;
  } finally {
    await _cleanup([
      helper.close,
      () async {
        for (final client in peer.clients) {
          client.socket.destroy();
        }
      },
      () => peer.listener.close().then<void>((_) {}),
      () async => peer.root.deleteSync(recursive: true),
    ], primary);
  }
}

/// One call against a peer that behaves as [behave], with the replacement
/// check; returns how the call settled.
Future<({Object? error, Duration elapsed})> _callAgainst(
  Misbehave behave,
  List<Object> uncaught,
) async {
  final peer = await _Peer.start(behave);
  final helper = Helper(peer.path, peer.root.path, manageProcess: false);
  Object? primary;
  try {
    final outcome = await _timedPing(helper, deadline);
    expect(outcome.error, isA<GrpcError>());
    await _serveReplacement(helper, peer);
    expect(uncaught, isEmpty);
    return outcome;
  } catch (error) {
    primary = error;
    rethrow;
  } finally {
    await _cleanup([
      helper.close,
      () async {
        for (final client in peer.clients) {
          client.socket.destroy();
        }
      },
      () => peer.listener.close().then<void>((_) {}),
      () async => peer.root.deleteSync(recursive: true),
    ], primary);
  }
}

/// A peer that is a real HTTP/2 server answering every request with [bad].
Future<void> _malformedMessage(
  MalformedMessage bad,
  List<Object> uncaught,
) async {
  final peer = await _Peer.start(watch: false, (client) {
    final connection = ServerTransportConnection.viaSocket(client.socket);
    connection.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((message) {
        if (message is! HeadersStreamMessage) return;
        try {
          stream.sendHeaders([
            Header.ascii(':status', '200'),
            Header.ascii('content-type', 'application/grpc'),
          ]);
          stream.sendData(bad.body);
          stream.sendHeaders([
            Header.ascii('grpc-status', '0'),
          ], endStream: true);
        } on Object {
          // The client went away first; that is not what this test observes.
        }
      }, onError: (Object _) {});
    }, onError: (Object _) {});
  });
  final helper = Helper(peer.path, peer.root.path, manageProcess: false);
  Object? primary;
  try {
    for (var round = 0; round < 2; round++) {
      final outcome = await _timedPing(helper, deadline);
      expect(outcome.error, isA<GrpcError>(), reason: '${bad.name} #$round');
      expect(outcome.elapsed, lessThan(deadline), reason: '${outcome.error}');
    }
    await _serveReplacement(helper, peer);
    expect(uncaught, isEmpty);
  } catch (error) {
    primary = error;
    rethrow;
  } finally {
    await _cleanup([
      helper.close,
      () async {
        for (final client in peer.clients) {
          client.socket.destroy();
        }
      },
      () => peer.listener.close().then<void>((_) {}),
      () async => peer.root.deleteSync(recursive: true),
    ], primary);
  }
}

/// The peer sends its handshake and closes at once. The calls that follow are
/// issued after the client's channel reported the closure (a connection-state
/// barrier), so they race a connection the client already knows is gone. The
/// ordering is: the peer closed, the channel observed it, then the calls.
/// Whether the first call's request was written before or after the EOF is
/// not ordered.
Future<void> _closedBeforeWrite(List<Object> uncaught) async {
  final peer = await _Peer.start((client) {
    client.socket.add(settings);
    unawaited(client.socket.flush().then((_) => client.socket.destroy()));
  });
  final helper = Helper(peer.path, peer.root.path, manageProcess: false);
  Object? primary;
  try {
    // The first call is what dials. Subscribe to the channel's states before
    // it, so the closure cannot be missed.
    final observed = helper.channel.onConnectionStateChanged.firstWhere(
      (state) =>
          state == ConnectionState.idle ||
          state == ConnectionState.transientFailure,
    );
    final first = _timedPing(helper, deadline);
    final client = await peer.accepted.stream.first.timeout(
      const Duration(seconds: 10),
    );
    await client.closed.timeout(const Duration(seconds: 10));
    await observed.timeout(const Duration(seconds: 10));
    // Calls made right after the peer's EOF, concurrently and then again.
    final calls = [
      for (var i = 0; i < 3; i++)
        helper.client
            .ping(PingRequest(), options: CallOptions(timeout: shortDeadline))
            .then<Object?>((_) => null, onError: (Object e) => e),
    ];
    for (final error in await Future.wait(calls)) {
      expect(error, isA<GrpcError>());
    }
    expect((await first).error, isA<GrpcError>());
    final later = await _timedPing(helper, shortDeadline);
    expect(later.error, isA<GrpcError>());
    expect(uncaught, isEmpty);
    await _serveReplacement(helper, peer);
  } catch (error) {
    primary = error;
    rethrow;
  } finally {
    await _cleanup([
      helper.close,
      () async {
        for (final client in peer.clients) {
          client.socket.destroy();
        }
      },
      () => peer.listener.close().then<void>((_) {}),
      () async => peer.root.deleteSync(recursive: true),
    ], primary);
  }
}
