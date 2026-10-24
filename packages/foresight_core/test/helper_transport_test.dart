import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/helper_channel.dart';
import 'package:foresight_core/src/helper_transport.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class ControlledSocket extends Stream<Uint8List> implements Socket {
  final incoming = StreamController<Uint8List>();
  final closed = Completer<void>();
  final requestWritten = Completer<void>();
  final failedWrite = Completer<void>();
  bool destroyed = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) {
    if (!requestWritten.isCompleted) requestWritten.complete();
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      Future.any([stream.forEach(add), failedWrite.future]);

  @override
  Future<void> get done => closed.future;

  void reset(String failure) {
    const error = SocketException('controlled helper connection reset');
    if (failure == 'write stream') {
      failedWrite.completeError(error, StackTrace.current);
      return;
    }
    if (failure == 'read and write') incoming.addError(error);
    closed.completeError(error, StackTrace.current);
  }

  @override
  Future<void> close() async {
    if (!closed.isCompleted) closed.complete();
    unawaited(incoming.close());
  }

  @override
  void destroy() {
    destroyed = true;
    unawaited(close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PingService extends RagServiceBase {
  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(success: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HeldCloseSocket extends ControlledSocket {
  final releaseClose = Completer<void>();
  @override
  Future<void> close() async {
    await releaseClose.future;
    await super.close();
  }
}

void main() {
  test('termination joins a late connect and its socket closure', () async {
    final entered = Completer<void>();
    final release = Completer<Socket>();
    final socket = HeldCloseSocket();
    final connector = HelperTransportConnector(
      '/held-helper.sock',
      connectSocket: (address, port, {timeout}) {
        entered.complete();
        return release.future;
      },
    );
    final channel = HelperChannel(
      InternetAddress('/held-helper.sock', type: InternetAddressType.unix),
      port: 0,
      transportConnector: connector,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final failed = expectLater(
      RagServiceClient(channel).ping(PingRequest()),
      throwsA(isA<GrpcError>()),
    );
    try {
      await entered.future;
      var settled = false;
      final closing = channel.terminate().then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        settled,
        isFalse,
        reason: 'The socket factory still owns a connect',
      );
      release.complete(socket);
      await Future<void>.delayed(Duration.zero);
      expect(socket.destroyed, isTrue);
      expect(settled, isFalse, reason: 'Socket close has not settled');
      socket.releaseClose.complete();
      await closing.timeout(const Duration(seconds: 5));
      await failed;
      expect(settled, isTrue);
      await expectLater(connector.connect(), throwsA(isA<GrpcError>()));
    } finally {
      if (!release.isCompleted) release.complete(socket);
      if (!socket.releaseClose.isCompleted) socket.releaseClose.complete();
      await channel.terminate();
    }
  });

  test(
    'canceling a connecting channel closes the actual late Unix peer',
    () async {
      final root = createTestTempDirectorySync('late-helper-');
      final path = '${root.path}/helper.sock';
      final address = InternetAddress(path, type: InternetAddressType.unix);
      final listener = await ServerSocket.bind(address, 0);
      final accepted = Completer<void>();
      final eof = Completer<void>();
      final peers = <Socket>[];
      final subscription = listener.listen((peer) {
        peers.add(peer);
        accepted.complete();
        peer.listen((_) {}, onDone: eof.complete, onError: eof.completeError);
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      final connector = HelperTransportConnector(
        path,
        connectSocket: (address, port, {timeout}) async {
          entered.complete();
          await release.future;
          return Socket.connect(address, port, timeout: timeout);
        },
      );
      final channel = HelperChannel(
        address,
        port: 0,
        transportConnector: connector,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      final failed = expectLater(
        RagServiceClient(channel).ping(PingRequest()),
        throwsA(isA<GrpcError>()),
      );
      try {
        await entered.future;
        var settled = false;
        final closing = channel.terminate().then((_) => settled = true);
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        release.complete();
        await closing.timeout(const Duration(seconds: 5));
        await failed;
        await accepted.future.timeout(const Duration(seconds: 5));
        await eof.future.timeout(const Duration(seconds: 5));
        expect(settled, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        await channel.terminate();
        // Observe the peer even in the unfixed negative control before disposing
        // the listener; otherwise a late connect could outlive its test owner.
        await accepted.future.timeout(const Duration(seconds: 5));
        await eof.future.timeout(const Duration(seconds: 5));
        for (final peer in peers) {
          peer.destroy();
        }
        await subscription.cancel();
        await listener.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final failure in [
    'read and write',
    'write completion',
    'write stream',
  ]) {
    test(
      '$failure reset abandons transport, fails RPC, and stays handled',
      () async {
        final uncaught = <Object>[];
        final finished = Completer<void>();
        // Completion is observed by the owning lifecycle or test fixture.
        // ignore: unawaited_futures
        runZonedGuarded(
          () async {
            final socket = ControlledSocket();
            final connector = HelperTransportConnector(
              '/unused-helper.sock',
              connectSocket: (address, port, {timeout}) async {
                expect(address.type, InternetAddressType.unix);
                expect(port, 0);
                expect(timeout, const Duration(seconds: 3));
                return socket;
              },
            );
            final channel = HelperChannel(
              InternetAddress(
                '/unused-helper.sock',
                type: InternetAddressType.unix,
              ),
              port: 0,
              transportConnector: connector,
              options: const ChannelOptions(
                credentials: ChannelCredentials.insecure(),
              ),
            );
            final ready = channel.onConnectionStateChanged.firstWhere(
              (state) => state == ConnectionState.ready,
            );
            final idle = channel.onConnectionStateChanged.firstWhere(
              (state) => state == ConnectionState.idle,
              orElse: () => ConnectionState.shutdown,
            );
            final client = RagServiceClient(channel);
            final failed = expectLater(
              client.ping(PingRequest()),
              throwsA(
                isA<GrpcError>()
                    .having((error) => error.code, 'code', StatusCode.unknown)
                    .having(
                      (error) => error.message,
                      'message',
                      startsWith('HTTP/2 error: Connection error:'),
                    ),
              ),
            );
            await ready;
            await socket.requestWritten.future;
            // A separate observer on the original Future does not protect grpc's
            // discarded .then() Future. The connector must guard its own `done`.
            var originalErrorObserved = false;
            unawaited(
              socket.done.catchError((Object error) {
                originalErrorObserved = true;
              }),
            );
            socket.reset(failure);
            await failed;
            await Future<void>.delayed(Duration.zero);
            // Report escaped library completions before waiting for the state
            // change that the original broken completion handler never emits.
            if (uncaught.isNotEmpty) {
              await channel.terminate();
              finished.complete();
              return;
            }
            expect(await idle, ConnectionState.idle);
            await connector.done;
            await channel.terminate();
            await Future<void>.delayed(Duration.zero);
            expect(originalErrorObserved, failure != 'write stream');
            expect(socket.destroyed, isTrue);
            finished.complete();
          },
          (Object error, StackTrace stack) {
            uncaught.add(error);
            if (error is! SocketException && !finished.isCompleted) {
              finished.completeError(error, stack);
            }
          },
        );
        await finished.future.timeout(const Duration(seconds: 5));
        expect(uncaught, isEmpty);
      },
    );
  }

  test(
    'connector preserves explicit authority and connection timeout',
    () async {
      final socket = ControlledSocket();
      const timeout = Duration(milliseconds: 17);
      final connector = HelperTransportConnector(
        '/configured-helper.sock',
        authority: 'configured-helper',
        connectTimeout: timeout,
        connectSocket: (address, port, {timeout}) async {
          expect(address.address, '/configured-helper.sock');
          expect(timeout, const Duration(milliseconds: 17));
          return socket;
        },
      );
      final connection = await connector.connect();
      expect(connector.authority, 'configured-helper');
      await connection.terminate();
      connector.shutdown();
      await connector.done;
    },
  );

  test(
    'an established channel closes both owned halves and the real peer',
    () async {
      final root = createTestTempDirectorySync('ready-helper-');
      final path = '${root.path}/helper.sock';
      final address = InternetAddress(path, type: InternetAddressType.unix);
      final listener = await ServerSocket.bind(address, 0);
      final received = Completer<void>();
      final eof = Completer<void>();
      final peers = <Socket>[];
      final subscription = listener.listen((peer) {
        peers.add(peer);
        peer.listen(
          (_) {
            if (!received.isCompleted) received.complete();
          },
          onDone: eof.complete,
          onError: eof.completeError,
        );
      });
      final channel = HelperChannel(
        address,
        port: 0,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      final ready = channel.onConnectionStateChanged.firstWhere(
        (state) => state == ConnectionState.ready,
      );
      final request = RagServiceClient(channel).ping(PingRequest());
      final failed = expectLater(request, throwsA(isA<GrpcError>()));
      try {
        await ready.timeout(const Duration(seconds: 5));
        await received.future.timeout(const Duration(seconds: 5));
        await request.cancel();
        await failed;
        await channel.terminate().timeout(const Duration(seconds: 5));
        await eof.future.timeout(const Duration(seconds: 5));
      } finally {
        await channel.terminate();
        for (final peer in peers) {
          peer.destroy();
        }
        await subscription.cancel();
        await listener.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  test('connect errors remain errors', () async {
    const error = SocketException('missing helper socket');
    final connector = HelperTransportConnector(
      '/missing-helper.sock',
      connectSocket: (address, port, {timeout}) async => throw error,
    );
    await expectLater(connector.connect(), throwsA(same(error)));
  });

  test('the same helper channel reconnects to a replacement owner', () async {
    final root = createTestTempDirectorySync('helper-transport-');
    final path = '${root.path}/helper.sock';
    final helper = Helper(path, root.path, manageProcess: false);
    var server = Server.create(services: [PingService()]);
    try {
      await server.serve(
        address: InternetAddress(path, type: InternetAddressType.unix),
        port: 0,
      );
      expect((await helper.client.ping(PingRequest())).success, isTrue);
      final disconnected = helper.channel.onConnectionStateChanged.firstWhere(
        (state) => state == ConnectionState.idle,
      );
      await server.shutdown();
      await disconnected;
      if (File(path).existsSync()) File(path).deleteSync();
      server = Server.create(services: [PingService()]);
      await server.serve(
        address: InternetAddress(path, type: InternetAddressType.unix),
        port: 0,
      );
      expect((await helper.client.ping(PingRequest())).success, isTrue);
    } finally {
      await helper.close();
      await server.shutdown();
      root.deleteSync(recursive: true);
    }
  });
}
