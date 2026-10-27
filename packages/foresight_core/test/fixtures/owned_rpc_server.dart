import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart' show ServerTransportConnection;
import 'package:test/test.dart';

/// Own the listener and accepted sockets as well as gRPC's serving futures.
/// Graceful shutdown alone can wait for remote HTTP/2 IO after the body ends.
final class OwnedRpcServer {
  OwnedRpcServer(this.server, this.listener);

  final Server server;
  final ServerSocket listener;
  final sockets = <Socket>[];
  final connections = <ServerTransportConnection>[];
  final serving = <Future<void>>[];
  StreamSubscription<Socket>? accepts;
  Future<void>? closing;

  static Future<OwnedRpcServer> start(Server server, String path) async {
    final listener = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final fixture = OwnedRpcServer(server, listener);
    addTearDown(fixture.close);
    fixture.accepts = listener.listen(
      (socket) {
        fixture.sockets.add(socket);
        final connection = ServerTransportConnection.viaSocket(socket);
        fixture.connections.add(connection);
        final serving = server.serveConnection(connection: connection);
        // Preserve the same future for the final join, while observing early errors.
        serving.ignore();
        fixture.serving.add(serving);
      },
      onError: (Object error, StackTrace stack) {
        Zone.current.handleUncaughtError(error, stack);
      },
    );
    return fixture;
  }

  Future<void> close() => closing ??= _close();

  Future<void> _close() async {
    await listener.close();
    await accepts?.cancel();
    for (final socket in sockets) {
      socket.destroy();
    }
    await Future.wait([
      ...serving,
      for (final connection in connections) connection.terminate(),
    ]);
    await server.shutdown();
  }
}
