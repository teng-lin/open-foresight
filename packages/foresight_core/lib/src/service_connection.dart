import 'dart:async';
import 'client_diagnostics.dart';
import 'profile_paths.dart';
import 'rpc_error.dart';
import 'service_client.dart';
import 'service_startup.dart';
import 'service_diagnostics.dart';

/// Whether [error] says its request never took effect, so sending it once
/// more, after a handoff, is safe: a closing owner refused it before dispatch,
/// or it never reached a live socket. An `outcomeUnknown` request is never
/// resent.
bool _resendable(RpcError error) =>
    isClosingRefusal(error) || error.reason == RpcErrorReason.notSent;

/// Reattach on the next request after a disconnect; never replay a request
/// whose commit status is unknown.
class ServiceConnection {
  final ProfilePaths profile;
  ServiceClient? _client;
  // Replaced connections still waiting for their owner's answers.
  final _retired = <ServiceClient>{};
  Future<ServiceClient>? _connecting;
  bool _closed = false;
  ServiceDiagnosticEmitter? _diagnostics;
  ServiceConnection(this.profile)
    : _diagnostics = captureServiceDiagnosticEmitter();
  Future<ServiceClient> connect() async {
    if (_closed) throw StateError('Client closed');
    _diagnostics ??= captureServiceDiagnosticEmitter();
    final current = _client;
    if (current != null && !current.isClosed) return current;
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<ServiceClient> _open() async {
    final started = _diagnostics?.clockMicros();
    final client = await ensureService(profile);
    _diagnostics ??= client.diagnosticEmitter;
    if (_diagnostics case final owner?) client.adoptDiagnostics(owner, started);
    if (_closed) {
      await client.close();
      throw StateError('Client closed');
    }
    return _client = client;
  }

  /// A request refused by a closing owner, or never sent, before any result
  /// arrived is sent once more after [connect] hands off to the next owner
  /// (SL-9). Anything else, including `outcomeUnknown`, reaches the caller.
  /// Cancelling the stream cancels the request at once.
  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    late final StreamController<Object?> output;
    StreamSubscription<Object?>? request;
    var cancelled = false;
    ClientDiagnosticCall? diagnostic;
    var observationAttempted = false;
    Future<void> send({required bool resent}) async {
      final ServiceClient client;
      try {
        client = await connect();
      } catch (error, stack) {
        if (!cancelled) {
          diagnostic?.unwritten(error, resent ? 2 : 1);
          diagnostic?.release();
          output.addError(error, stack);
          unawaited(output.close());
        }
        return;
      }
      if (cancelled) return;
      if (!observationAttempted) {
        observationAttempted = true;
        diagnostic = ClientDiagnosticCall.begin(method, emitter: _diagnostics);
      }
      var received = false;
      var handedOff = false;
      request = client
          .streamAttempt(method, args, diagnostic, resent ? 2 : 1)
          .listen(
            (value) {
              received = true;
              output.add(value);
            },
            onError: (Object error, StackTrace stack) {
              if (!resent &&
                  !received &&
                  error is RpcError &&
                  _resendable(error)) {
                handedOff = true;
                // New requests go to the next owner. The closing owner
                // answers this connection's other requests itself, so it is
                // retired rather than closed: closing it would report them
                // as possibly completed, and never resend a refused one.
                if (identical(_client, client)) _client = null;
                _retire(client);
                unawaited(send(resent: true));
                return;
              }
              output.addError(error, stack);
            },
            onDone: () {
              if (!handedOff) {
                diagnostic?.release();
                diagnostic = null;
                unawaited(output.close());
              }
            },
          );
    }

    output = StreamController<Object?>(
      onListen: () {
        observationAttempted = _diagnostics != null;
        diagnostic = ClientDiagnosticCall.begin(method, emitter: _diagnostics);
        unawaited(send(resent: false));
      },
      onPause: () => request?.pause(),
      onResume: () => request?.resume(),
      onCancel: () {
        cancelled = true;
        diagnostic?.cancel();
        diagnostic = null;
        return request?.cancel();
      },
    );
    return output.stream;
  }

  void _retire(ServiceClient client) {
    _retired.add(client);
    unawaited(client.closed.then((_) => _retired.remove(client)));
    client.retire();
  }

  /// Close the connection and any replaced one still waiting for answers.
  Future<void> close() async {
    _closed = true;
    try {
      for (final retired in _retired.toList()) {
        await retired.close();
      }
      await _client?.close();
    } finally {
      _diagnostics = null;
    }
  }
}
