import 'dart:math';

import 'rpc_error.dart';

/// The idempotency key of one user action, such as creating a note. A retry
/// after a failure that may have committed reuses it, so the service applies
/// the action at most once. Success or a definite rejection releases it, and
/// the next action gets a new key.
class PendingRequestKey {
  PendingRequestKey([Random? random]) : _random = random ?? Random.secure();
  final Random _random;
  String? _key;

  /// The key an unconfirmed attempt left for its retry, if any.
  String? get pending => _key;

  Future<T> run<T>(Future<T> Function(String key) send) async {
    final key = _key ??= [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    try {
      final result = await send(key);
      if (_key == key) _key = null;
      return result;
    } catch (error) {
      if (_key == key && _definite(error)) _key = null;
      rethrow;
    }
  }

  /// A different action starts; an earlier unconfirmed one is not retried.
  void reset() => _key = null;

  // The service answered: the action did not commit and a retry is a new
  // request. A lost connection or a local cancellation leaves it unknown.
  static bool _definite(Object error) =>
      error is RpcError &&
      error.code != RpcErrorCode.unavailable &&
      error.code != RpcErrorCode.cancelled;
}
