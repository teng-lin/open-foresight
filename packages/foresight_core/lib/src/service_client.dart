import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'operations.dart';
import 'client_diagnostics.dart';
import 'diagnostics/session.dart';
import 'rpc_error.dart';
import 'service_diagnostics.dart';
import 'service_framing.dart';

// Closing owners flush within two seconds; leave scheduling margin.
const _retiredConnectionGrace = Duration(seconds: 5);

// Only the local transport can create this marker. A peer's serialized error
// remains an ordinary RpcError, even if it copies the disconnect message.
class _ServiceTransportLost extends RpcError {
  _ServiceTransportLost(RpcErrorReason reason)
    : super(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: reason,
      );
}

/// A local transport failure cannot be forged by a serialized peer error.
bool isServiceTransportLost(Object error) => error is _ServiceTransportLost;

/// The operations [ServiceClient.cancelAnswers] cancels.
final cancellableAnswers = {
  Operation.meetingsPrepare.wire,
  Operation.answerStream.wire,
  Operation.answer.wire,
  Operation.meetingsGenerate.wire,
  Operation.meetingsEnhance.wire,
};

/// Newline framed, multiplexed local RPC. No network listener is opened.
///
/// Every failure reaches callers as an [RpcError]. A lost connection (EOF, a
/// socket error, a frame cut off by EOF, or a frame over the limit) fails
/// requests already written with [RpcErrorReason.outcomeUnknown] and later
/// ones with [RpcErrorReason.notSent]. A complete frame that is not a JSON
/// object is a protocol error, reported to every caller as `internal`, with
/// [RpcErrorReason.outcomeUnknown] for requests already written.
class ServiceClient {
  final Socket socket;

  /// The socket path this client connected to. A profile's endpoint record
  /// can name another runtime by the time a caller looks again, so callers
  /// derive the connected owner's runtime from this, never from a second
  /// read (L9).
  final String endpoint;
  final int _maxMessageBytes;
  final _methods = <int, String>{};
  final _requestIds = <int, String>{};
  final _pending = <int, StreamController<Map<String, dynamic>>>{};
  final events = StreamController<Map<String, dynamic>>.broadcast();
  int _next = 0;
  bool _closed = false;
  bool _retired = false;
  Timer? _retirement;
  RpcError? _failure;
  ClientDiagnosticConnection? _diagnostics;

  /// Whether no request is sent on this connection any more: it is closed,
  /// or [retire]d and waiting for its last answers.
  bool get isClosed => _closed || _retired;
  final _closedSignal = Completer<void>();

  /// Completes once this connection is closed, by either side.
  Future<void> get closed => _closedSignal.future;
  ServiceClient._(
    this.socket,
    this._maxMessageBytes,
    this.endpoint,
    this._diagnostics,
  ) {
    unawaited(socket.done.catchError((Object _) {}));
    final frames = ServiceFrameSplitter(_maxMessageBytes);
    socket.listen(
      (chunk) {
        if (_closed) return;
        final complete = frames.add(chunk);
        if (complete == null) {
          return _lose();
        }
        for (final frame in complete) {
          if (_closed) return;
          _receive(frame);
        }
      },
      onError: (Object _) => _lose(),
      onDone: _lose,
      cancelOnError: true,
    );
  }

  void _receive(Uint8List frame) {
    final value = decodeServiceFrame(frame);
    if (value == null) {
      emitServiceDiagnostic(
        DiagnosticEvent.invalidFrame,
        connection: _diagnostics?.identity,
        fields: () => {
          DiagnosticField.category: DiagnosticCategory.protocol,
          DiagnosticField.bytes: frame.length.clamp(0, 0x7fffffff),
        },
      );
      const message = 'Application service sent an invalid reply';
      // Requests already written may have taken effect.
      return _fail(
        RpcError(
          RpcErrorCode.internal,
          message,
          reason: RpcErrorReason.outcomeUnknown,
        ),
        RpcError(RpcErrorCode.internal, message),
        category: DiagnosticCategory.protocol,
      );
    }
    if (value['event'] != null) {
      events.add(value);
      return;
    }
    final controller = _pending[value['id']];
    if (controller == null) return;
    controller.add(value);
    if (value['done'] == true) {
      // Map lookup historically also accepts an integral JSON double. Logging
      // must not make that successful business reply throw a cast exception.
      final id = value['id'];
      final diagnostic = ClientDiagnosticCall.forWire(
        _diagnostics?.identity,
        id is int ? id : (id as num).toInt(),
      );
      if (diagnostic != null) {
        Object? failure;
        if (value['error'] != null) {
          try {
            failure = RpcError.from(value['error'] as Object);
          } catch (_) {
            failure = RpcError(
              RpcErrorCode.internal,
              'Invalid reply error',
              reason: RpcErrorReason.outcomeUnknown,
            );
          }
        }
        diagnostic.settle(failure);
      }
      _pending.remove(value['id']);
      _methods.remove(value['id']);
      _requestIds.remove(value['id']);
      unawaited(controller.close());
      _closeIfSettled();
    }
  }

  /// Stop sending on this connection, but let the requests already written
  /// settle. A closing owner that refused one of them answers every other
  /// itself, with a refusal or its own outcomeUnknown, before it ends the
  /// connection. Closing at once would fail them all locally as
  /// outcomeUnknown, so a refused one would never be sent to the next owner
  /// and its caller would be told it may have completed. Later requests fail
  /// at once as notSent. The connection closes when its last pending request
  /// settles, or after [grace].
  void retire({Duration grace = _retiredConnectionGrace}) {
    if (_closed || _retired) return;
    _retired = true;
    _diagnostics?.record(
      DiagnosticOutcome.withdrawn,
      category: DiagnosticCategory.closing,
      count: _pending.length,
    );
    _retirement = Timer(grace, () => unawaited(close()));
    _closeIfSettled();
  }

  void _closeIfSettled() {
    if (_retired && _pending.isEmpty) unawaited(close());
  }

  /// Bound each reply frame; the default matches the service's 16 MiB limit.
  static Future<ServiceClient> connect(
    String path, {
    int maxMessageBytes = maxServiceMessage,
    Duration connectTimeout = const Duration(seconds: 2),
  }) async {
    if (maxMessageBytes < 1) {
      throw ArgumentError.value(maxMessageBytes, 'maxMessageBytes');
    }
    final address = InternetAddress(path, type: InternetAddressType.unix);
    final diagnostics = ClientDiagnosticConnection.begin();
    try {
      // The client owns the connected socket and its existing close paths.
      // ignore: close_sinks
      final socket = await Socket.connect(address, 0, timeout: connectTimeout);
      diagnostics?.record(DiagnosticOutcome.ready);
      return ServiceClient._(socket, maxMessageBytes, path, diagnostics);
    } on OSError catch (error, stack) {
      diagnostics?.close(
        DiagnosticOutcome.failed,
        DiagnosticCategory.transport,
      );
      // A connect that waited and then failed, for example because a closing
      // owner's listener went while it waited, reports the socket's pending
      // error as a bare OSError. Callers expect a SocketException.
      Error.throwWithStackTrace(
        SocketException('Connection failed', osError: error, address: address),
        stack,
      );
    } catch (_) {
      diagnostics?.close(
        DiagnosticOutcome.failed,
        DiagnosticCategory.transport,
      );
      rethrow;
    }
  }

  void _lose() {
    _fail(
      _ServiceTransportLost(RpcErrorReason.outcomeUnknown),
      _ServiceTransportLost(RpcErrorReason.notSent),
    );
  }

  /// Fail requests already written with [inFlight] and every later one with
  /// [later]. The first failure wins.
  void _fail(
    RpcError inFlight,
    RpcError later, {
    DiagnosticCategory category = DiagnosticCategory.transport,
  }) {
    if (_closed) return;
    _closed = true;
    _retirement?.cancel();
    _closedSignal.complete();
    _failure ??= later;
    ClientDiagnosticCall.forConnection(
      _diagnostics?.identity,
    )?.settle(inFlight);
    _diagnostics?.close(
      category == DiagnosticCategory.closing
          ? DiagnosticOutcome.completed
          : DiagnosticOutcome.failed,
      category,
    );
    _diagnostics = null;
    for (final c in _pending.values) {
      c.addError(inFlight);
      unawaited(c.close());
    }
    _pending.clear();
    _methods.clear();
    _requestIds.clear();
    unawaited(events.close());
    socket.destroy();
  }

  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) => streamAttempt(
    method,
    args,
    ClientDiagnosticCall.begin(method, ownsLifetime: true),
    1,
  );

  /// Internal connection handoff: observation adds no wire data or retries.
  Stream<Object?> streamAttempt(
    String method,
    Map<String, dynamic> args,
    ClientDiagnosticCall? diagnostic,
    int attempt,
  ) {
    final id = ++_next;
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController(
      onCancel: () {
        _methods.remove(id);
        _requestIds.remove(id);
        if (_pending.remove(id) != null && !_closed) {
          ClientDiagnosticCall.forWire(_diagnostics?.identity, id)?.cancel();
          socket.writeln(jsonEncode({'cancel': id}));
          _closeIfSettled();
        }
      },
    );
    final List<int>? frame;
    try {
      frame = isClosed
          ? null
          : utf8.encode(jsonEncode({'id': id, 'method': method, 'args': args}));
    } catch (error) {
      diagnostic?.unwritten(error, attempt);
      diagnostic?.release();
      rethrow;
    }
    if (frame == null) {
      diagnostic?.unwritten(
        _failure ?? _ServiceTransportLost(RpcErrorReason.notSent),
        attempt,
      );
      controller.addError(
        _failure ?? _ServiceTransportLost(RpcErrorReason.notSent),
      );
      unawaited(controller.close());
    } else if (frame.length + 1 > maxServiceFrame) {
      diagnostic?.unwritten(
        RpcError(RpcErrorCode.invalidArgument, 'Request exceeds frame limit'),
        attempt,
      );
      // The service drops a connection whose request exceeds its limit, which
      // for the desktop also stops recording. It counts bytes per read too.
      controller.addError(
        RpcError(
          RpcErrorCode.invalidArgument,
          'Request exceeds ${maxServiceFrame ~/ (1024 * 1024)} MiB; '
          'send less data.',
        ),
      );
      unawaited(controller.close());
    } else {
      diagnostic?.attach(_diagnostics?.identity, id, attempt);
      _pending[id] = controller;
      _methods[id] = method;
      if (args['requestId'] is String) {
        _requestIds[id] = args['requestId'] as String;
      }
      socket
        ..add(frame)
        ..add(const [10]);
    }
    return controller.stream
        .where((v) => v.containsKey('result') || v.containsKey('error'))
        .map((v) {
          if (v['error'] != null) throw RpcError.from(v['error'] as Object);
          return v['result'];
        });
  }

  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    Object? result;
    await for (final value in stream(method, args)) {
      result = value;
    }
    return result;
  }

  bool cancelAnswers({String? requestId}) {
    final ids = _methods.entries
        .where(
          (entry) =>
              cancellableAnswers.contains(entry.value) &&
              (requestId == null || _requestIds[entry.key] == requestId),
        )
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      ClientDiagnosticCall.forWire(_diagnostics?.identity, id)?.cancel();
      socket.writeln(jsonEncode({'cancel': id}));
      final pending = _pending.remove(id);
      _methods.remove(id);
      _requestIds.remove(id);
      pending?.addError(RpcError(RpcErrorCode.cancelled, 'Answer cancelled'));
      if (pending != null) unawaited(pending.close());
    }
    if (ids.isNotEmpty) _closeIfSettled();
    return ids.isNotEmpty;
  }

  Future<void> close() async {
    _fail(
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.outcomeUnknown,
      ),
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.notSent,
      ),
      category: DiagnosticCategory.closing,
    );
  }
}
