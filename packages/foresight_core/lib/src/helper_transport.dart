import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';

typedef HelperSocketFactory =
    Future<Socket> Function(
      InternetAddress address,
      int port, {
      Duration? timeout,
    });

/// The helper's private, insecure Unix-domain transport.
class HelperTransportConnector implements ClientTransportConnector {
  final String path;
  final Duration? connectTimeout;
  @override
  final String authority;
  final HelperSocketFactory _connectSocket;
  Socket? _socket;
  late Future<void> _done;

  HelperTransportConnector(
    this.path, {
    HelperSocketFactory? connectSocket,
    this.connectTimeout = const Duration(seconds: 3),
    this.authority = 'localhost',
  }) : _connectSocket = connectSocket ?? Socket.connect;

  @override
  Future<ClientTransportConnection> connect() async {
    // Ownership transfers to the transport or test teardown.
    // ignore: close_sinks
    final socket = await _connectSocket(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: connectTimeout,
    );
    _socket = socket;
    // Ownership transfers to the transport or test teardown.
    // ignore: close_sinks
    final outgoing = _DisconnectSink(socket);
    _done = outgoing.done;
    return ClientTransportConnection.viaStreams(socket, outgoing);
  }

  @override
  Future<void> get done => _done;

  @override
  void shutdown() => _socket?.destroy();
}

/// grpc 4.3.1 and http2 2.3.1 attach discarded .then()/whenComplete() futures
/// to transport completion notifications without handling errors. Treat failed
/// writes as disconnection there, while preserving the incoming socket's errors
/// and EOF so pending RPCs still fail through the HTTP/2 transport.
class _DisconnectSink implements StreamSink<List<int>> {
  final Socket socket;
  late final Future<void> _done = _disconnected(socket.done);

  _DisconnectSink(this.socket) {
    // Observe failures immediately, before the transport subscribes to done.
    unawaited(_done);
  }

  Future<void> _disconnected(
    Future<dynamic> completion,
  ) => completion.then<void>(
    (_) {},
    onError: (Object error, StackTrace stack) {
      // A write-side error must also end reads; otherwise an outstanding RPC
      // could wait forever on an otherwise silent, unusable connection.
      socket.destroy();
    },
  );

  @override
  void add(List<int> data) => socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _disconnected(socket.addStream(stream));

  @override
  Future<void> close() => _disconnected(socket.close());

  @override
  Future<void> get done => _done;
}
