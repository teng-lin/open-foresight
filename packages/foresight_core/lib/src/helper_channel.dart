import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart' show ClientTransportConnector;
import 'package:grpc/grpc_connection_interface.dart';
// grpc exposes its adapter interfaces publicly, but not its reusable HTTP/2
// connection. This override targets the pinned 4.3.1 implementation; tests bind
// its header/codec and shutdown behavior without copying connection policy.
// ignore: implementation_imports
import 'package:grpc/src/client/http2_connection.dart';
import 'package:http2/transport.dart';

import 'helper_transport.dart';

/// Keep gRPC's connection/reconnect policy, while owning the request writer.
/// grpc 4.3.1 leaves its HTTP/2 forwarding subscription alive after peer EOF;
/// a buffered request can then throw from an already closed HTTP/2 sink.
class HelperChannel extends ClientChannel {
  final ClientTransportConnector? _transportConnector;

  HelperChannel(
    super.host, {
    super.port,
    super.options,
    ClientTransportConnector? transportConnector,
  }) : _transportConnector = transportConnector;

  @override
  ClientConnection createConnection() {
    final address = host;
    final connector =
        _transportConnector ??
        (address is InternetAddress && address.type == InternetAddressType.unix
            ? HelperTransportConnector(address.address)
            : null);
    return connector == null
        ? _HelperConnection(host, port, options)
        : _HelperConnection.fromConnector(connector, options);
  }
}

class _HelperConnection extends Http2ClientConnection {
  ClientTransportConnection? _transport;

  _HelperConnection(super.host, super.port, super.options);

  _HelperConnection.fromConnector(
    ClientTransportConnector connector,
    ChannelOptions options,
  ) : super.fromClientTransportConnector(connector, options);

  @override
  Future<ClientTransportConnection> connectTransport() async =>
      _transport = await super.connectTransport();

  @override
  GrpcTransportStream makeRequest(
    String path,
    Duration? timeout,
    Map<String, String> metadata,
    ErrorHandler onRequestFailure, {
    CallOptions? callOptions,
  }) {
    final compression = callOptions?.compression;
    final headers = Http2ClientConnection.createCallHeaders(
      credentials.isSecure,
      authority,
      path,
      timeout,
      metadata,
      compression,
      userAgent: options.userAgent,
      grpcAcceptEncodings:
          (callOptions?.metadata ?? const {})['grpc-accept-encoding'] ??
          options.codecRegistry?.supportedEncodings,
    );
    return HelperTransportStream(
      _transport!.makeRequest(headers),
      onRequestFailure,
      options.codecRegistry,
      compression,
    );
  }
}

/// A request owns its forwarding subscription until cancellation or sink EOF.
/// Serializer/framing/write failures are delivered to this request's error
/// handler, including synchronous writes racing a remote HTTP/2 shutdown.
class HelperTransportStream extends GrpcTransportStream {
  final TransportStream _transport;
  final ErrorHandler _onError;
  final StreamController<List<int>> _outgoing = StreamController();
  late final StreamSubscription<List<int>> _forwarding;
  bool _ended = false;
  bool _failed = false;
  Future<void>? _termination;

  @override
  final Stream<GrpcMessage> incomingMessages;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoing.sink;

  HelperTransportStream(
    this._transport,
    this._onError,
    CodecRegistry? codecRegistry,
    Codec? compression,
  ) : incomingMessages = _transport.incomingMessages
          .transform(GrpcHttpDecoder(forResponse: true))
          .transform(grpcDecompressor(codecRegistry: codecRegistry)) {
    _forwarding = _outgoing.stream.listen(
      (payload) {
        try {
          _transport.outgoingMessages.add(
            DataStreamMessage(frame(payload, compression)),
          );
        } catch (error, stack) {
          _fail(error, stack);
        }
      },
      onError: _fail,
      onDone: () {
        _ended = true;
        unawaited(_closeWrites());
      },
      cancelOnError: true,
    );
    unawaited(
      _transport.outgoingMessages.done.then<void>((_) {
        if (!_ended && _termination == null) {
          _fail(
            GrpcError.unavailable('Helper transport closed during request'),
            StackTrace.current,
          );
        }
      }, onError: _fail),
    );
  }

  Future<void> _closeWrites() async {
    try {
      await _transport.outgoingMessages.close();
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_failed || _termination != null) return;
    _failed = true;
    // Start cleanup before the error callback, which may reenter terminate().
    unawaited(terminate().catchError(_fail));
    _onError(
      error is GrpcError
          ? error
          : GrpcError.unavailable('Helper request transport failed: $error'),
      stack,
    );
  }

  @override
  Future<void> terminate() => _termination ??= _terminate();

  Future<void> _terminate() async {
    await _forwarding.cancel();
    _transport.terminate();
    await _outgoing.close();
  }
}
