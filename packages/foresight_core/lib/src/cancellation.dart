import 'dart:async';

import 'rpc_error.dart';

RpcError operationCancelled([String message = 'Operation cancelled']) =>
    RpcError(RpcErrorCode.cancelled, message);

/// An independently disposable waiter on shared, uncancelled work.
class CancellationWatch {
  final bool Function() current;
  final _signal = Completer<void>();
  final void Function(CancellationWatch) _remove;
  CancellationWatch(this.current, this._remove);
  Future<void> get future => _signal.future;
  void dispose() => _remove(this);
  void check() {
    if (!current() && !_signal.isCompleted) {
      _signal.completeError(operationCancelled());
    }
  }
}

/// Preserve the existing 20ms native-call cancellation poll. This helper owns
/// only its timer and cancellation signal, never the shared/native operation.
Future<T> awaitCancellable<T>(
  Future<T> work, {
  required void Function() ensureCurrent,
  required Future<void> Function() cancel,
}) async {
  final interrupted = Completer<T>();
  final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
    if (interrupted.isCompleted) return;
    try {
      ensureCurrent();
    } catch (error, stack) {
      interrupted.completeError(error, stack);
      unawaited(cancel());
    }
  });
  try {
    final response = await Future.any([work, interrupted.future]);
    ensureCurrent();
    return response;
  } catch (_) {
    ensureCurrent();
    rethrow;
  } finally {
    monitor.cancel();
  }
}
