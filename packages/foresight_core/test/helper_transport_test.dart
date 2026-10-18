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

void main() {
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
