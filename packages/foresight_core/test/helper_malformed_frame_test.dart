import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

// Service <-> helper, malformed and partial frames. The production Helper,
// its channel and transport talk over a real Unix socket to a hostile peer
// that writes raw bytes: this is a fixture peer, not the real ForesightHelper,
// so it establishes how the client side settles, not the helper's behavior.
//
// What each scenario shows about the client:
//  - a peer that closes mid-frame fails the pending call promptly;
//  - a peer that never completes a frame or a handshake leaves the call
//    pending until its own deadline (the Helper's default is 45 s, here 3 s),
//    and never past it;
//  - nothing escapes into the error zone; and
//  - the same channel serves a valid replacement at the same socket.

/// A valid, empty HTTP/2 SETTINGS frame: the peer's side of the handshake.
final settings = Uint8List.fromList([0, 0, 0, 4, 0, 0, 0, 0, 0]);

class PingService extends RagServiceBase {
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true, version: 'replacement');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef Misbehave = void Function(Socket socket);

const deadline = Duration(seconds: 3);

({String name, Misbehave peer, bool prompt}) scenario(
  String name,
  Misbehave peer, {
  bool prompt = false,
}) => (name: name, peer: peer, prompt: prompt);

final scenarios = [
  scenario(
    'bytes that are not HTTP/2 at all',
    (socket) => socket.add('HTTP/1.1 500 nope\r\n\r\n'.codeUnits),
  ),
  scenario('a peer that accepts and closes before any frame', (socket) {
    socket.destroy();
  }),
  scenario(
    'a handshake followed by a frame header that announces a huge payload '
    'and never delivers it',
    (socket) =>
        socket.add([...settings, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1]),
  ),
  scenario(
    'a handshake followed by half a frame header, then silence',
    (socket) => socket.add([...settings, 0, 0, 8, 0, 0]),
  ),
  scenario('a handshake followed by half a frame header, then EOF', (socket) {
    socket.add([...settings, 0, 0, 8, 0, 0]);
    Timer(const Duration(milliseconds: 300), socket.destroy);
  }, prompt: true),
  scenario('a handshake followed by EOF', (socket) {
    socket.add(settings);
    Timer(const Duration(milliseconds: 300), socket.destroy);
  }, prompt: true),
];

void main() {
  for (final hostile in scenarios) {
    test('${hostile.name}: the pending call settles as a typed error, nothing '
        'escapes, and the same channel serves a replacement', () async {
      final uncaught = <Object>[];
      final done = Completer<void>();
      unawaited(
        runZonedGuarded(() async {
          try {
            await _exercise(hostile, uncaught);
            done.complete();
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        }, (error, stack) => uncaught.add(error)),
      );
      await done.future;
      expect(uncaught, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}

Future<void> _exercise(
  ({String name, Misbehave peer, bool prompt}) hostile,
  List<Object> uncaught,
) async {
  final root = createTestTempDirectorySync('of-hostile-');
  final path = '${root.path}/helper.sock';
  final sockets = <Socket>[];
  final listener = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  listener.listen((socket) {
    sockets.add(socket);
    socket.listen((_) {}, onError: (_) {}, onDone: () {});
    hostile.peer(socket);
  });
  final helper = Helper(path, root.path, manageProcess: false);
  Server? replacement;
  try {
    final watch = Stopwatch()..start();
    final error = await helper.client
        .ping(PingRequest(), options: CallOptions(timeout: deadline))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<GrpcError>(), reason: hostile.name);
    final code = (error as GrpcError).code;
    if (hostile.prompt) {
      // The peer closed: the call does not wait for its deadline.
      expect(watch.elapsed, lessThan(deadline), reason: '$code $error');
      expect(
        code,
        anyOf(StatusCode.unavailable, StatusCode.unknown),
        reason: '$error',
      );
    } else {
      // Nothing settled the call but its own deadline, and that was enforced.
      expect(code, StatusCode.deadlineExceeded, reason: '$error');
      expect(watch.elapsed, greaterThanOrEqualTo(deadline));
      expect(watch.elapsed, lessThan(deadline * 3));
    }

    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.close();
    if (File(path).existsSync()) File(path).deleteSync();
    replacement = Server.create(services: [PingService()]);
    await replacement.serve(
      address: InternetAddress(path, type: InternetAddressType.unix),
      port: 0,
    );
    // The channel may be backing off after the failure; it must come back
    // without being rebuilt.
    late PingResponse response;
    await eventually(() async {
      try {
        response = await helper.client.ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(seconds: 2)),
        );
        return true;
      } on GrpcError {
        return false;
      }
    }, timeout: const Duration(seconds: 60));
    expect(response.version, 'replacement');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(uncaught, isEmpty);
  } finally {
    await helper.close();
    await replacement?.shutdown();
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.close().catchError((Object _) => listener);
    root.deleteSync(recursive: true);
  }
}
