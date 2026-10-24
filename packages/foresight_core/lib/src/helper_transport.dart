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
  bool _shuttingDown = false;
  ClientTransportConnection? _connection;
  Future<void>? _closing;

  HelperTransportConnector(
    this.path, {
    HelperSocketFactory? connectSocket,
    this.connectTimeout = const Duration(seconds: 3),
    this.authority = 'localhost',
  }) : _connectSocket = connectSocket ?? Socket.connect;

  @override
  Future<ClientTransportConnection> connect() async {
    if (_shuttingDown) {
      throw GrpcError.unavailable('Helper transport is closing');
    }
    // Ownership transfers to the transport or test teardown.
    // ignore: close_sinks
    final socket = await _connectSocket(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: connectTimeout,
    );
    _socket = socket;
    final done = socket.done.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) => socket.destroy(),
    );
    _done = done;
    if (_shuttingDown) {
      await _closeSocket(socket, done);
      throw GrpcError.unavailable('Helper transport is closing');
    }
    // Ownership transfers to the transport or test teardown.
    // ignore: close_sinks
    final outgoing = _DisconnectSink(socket);
    _done = outgoing.done;
    return _connection = ClientTransportConnection.viaStreams(socket, outgoing);
  }

  @override
  Future<void> get done => _done;

  @override
  void shutdown() {
    _shuttingDown = true;
    (_closing ??= _closeTransport()).ignore();
  }

  Future<void> _closeSocket(Socket socket, Future<void> done) async {
    socket.destroy();
    try {
      // Dart Socket.destroy closes its FD but does not close an unused IOSink.
      // Its done future settles only after explicitly closing that sink.
      await socket.close();
    } catch (_) {
      // Disconnection is already reported by the owning RPC.
    }
    await done;
  }

  Future<void> _closeTransport() async {
    final socket = _socket;
    final done = socket == null ? null : _done;
    final connection = _connection;
    if (connection != null) {
      // An attached HTTP/2 connection owns both halves of the socket. Let its
      // subscriptions and writer settle without racing another raw close.
      await connection.terminate();
      if (socket != null) await done;
    } else if (socket != null) {
      await _closeSocket(socket, done!);
    }
  }

  /// The connection owner joins pending connect attempts before this call.
  Future<void> close() async {
    shutdown();
    await _closing;
  }
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
