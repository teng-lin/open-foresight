import 'dart:async';
import 'dart:io';

import 'package:foresight_test_support/poll.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart' show ServerTransportConnection;
import 'package:test/test.dart';

/// Own the listener, accepted sockets and serving futures of a fixture peer.
/// Graceful shutdown alone can wait for unfinished remote HTTP/2 streams.
final class OwnedRpcServer {
  OwnedRpcServer({required List<Service> services})
    : server = Server.create(services: services);
  OwnedRpcServer._(this.server);

  final Server server;
  ServerSocket? listener;
  StreamSubscription<Socket>? accepts;
  final sockets = <Socket>[];
  final serving = <Future<void>>[];
  Future<void>? closing;

  Map<ServerTransportConnection, Iterable<ServiceCall>> get handlers =>
      server.handlers;

  static Future<OwnedRpcServer> start(Server server, String path) async {
    final fixture = OwnedRpcServer._(server);
    await fixture.serve(
      address: InternetAddress(path, type: InternetAddressType.unix),
      port: 0,
    );
    return fixture;
  }

  Future<void> serve({
    required InternetAddress address,
    required int port,
  }) async {
    if (listener != null) throw StateError('Fixture already serving');
    final bound = listener = await ServerSocket.bind(address, port);
    addTearDown(close);
    accepts = bound.listen(
      (socket) {
        sockets.add(socket);
        final future = server.serveConnection(
          connection: ServerTransportConnection.viaSocket(socket),
        );
        // Keep the original future for the final join and observe early errors.
        future.ignore();
        serving.add(future);
      },
      onError: (Object error, StackTrace stack) {
        Zone.current.handleUncaughtError(error, stack);
      },
    );
  }

  Future<void> shutdown() => close();
  Future<void> close() => closing ??= _close();

  Future<void> _close() async {
    print('RPC_FIXTURE_CLOSE phase=0 sockets=${sockets.length}');
    await listener?.close();
    await accepts?.cancel();
    final connections = server.handlers.keys.toList();
    print('RPC_FIXTURE_CLOSE phase=1 connections=${connections.length}');
    for (final socket in sockets) {
      socket.destroy();
    }
    try {
      await Future.wait([
        ...serving,
        for (final connection in connections) connection.terminate(),
      ]);
      print('RPC_FIXTURE_CLOSE phase=2');
    } finally {
      await server.shutdown();
    }
    await eventually(() => server.handlers.isEmpty);
    print('RPC_FIXTURE_CLOSE phase=3');
  }
}
