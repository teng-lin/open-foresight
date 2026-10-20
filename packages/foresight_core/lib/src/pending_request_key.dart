import 'dart:math';

import 'package:clock/clock.dart';

import 'request_errors.dart';
import 'rpc_error.dart';

/// The idempotency key of one user action, such as creating a note. A retry
/// after a failure that may have committed reuses it, so the service applies
/// the action at most once. Success or a definite failure releases it, and
/// the next action gets a new key. A key is a retry window, not a promise:
/// it lapses after [window], and the caller resets it when the user moves on.
class PendingRequestKey {
  PendingRequestKey({Random? random, this.window = const Duration(minutes: 5)})
    : _random = random ?? Random.secure();
  final Random _random;
  final Duration window;
  String? _key;
  Map<String, dynamic>? _arguments;
  DateTime? _started;
  // Whether an attempt under the key ended without a definite outcome.
  bool _uncertain = false;

  /// The key an unconfirmed attempt left for its retry, if any.
  String? get pending {
    _lapse();
    return _key;
  }

  /// Sends [arguments] with this action's key through [send]. A retry whose
  /// arguments changed never reuses the key for them: it first resends the
  /// original arguments under the key, to learn the outcome of the attempt
  /// that may have committed, then [amend] applies the new arguments to that
  /// result, for example as an edit of the note it created.
  Future<Object?> run(
    Map<String, dynamic> arguments,
    Future<Object?> Function(Map<String, dynamic> keyed) send, {
    Future<Object?> Function(Object? first, Map<String, dynamic> arguments)?
    amend,
  }) async {
    _lapse();
    final original = _arguments;
    if (_key != null && original != null && !_same(original, arguments)) {
      // A new key for the new arguments could create a second item.
      if (amend == null) {
        throw ArgumentError(
          'A retry with changed arguments needs amend: the first attempt may '
          'already have created its item.',
        );
      }
      final first = await _send(original, send);
      return amend(first, arguments);
    }
    if (_key == null) {
      _key = [
        for (var i = 0; i < 16; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      _arguments = Map.of(arguments);
      _started = clock.now();
    }
    return _send(arguments, send);
  }

  /// A different action starts; an earlier unconfirmed one is not retried.
  void reset() {
    _key = null;
    _arguments = null;
    _started = null;
    _uncertain = false;
  }

  Future<Object?> _send(
    Map<String, dynamic> arguments,
    Future<Object?> Function(Map<String, dynamic> keyed) send,
  ) async {
    final key = _key!;
    try {
      final result = await send({...arguments, 'idempotency_key': key});
      if (_key == key) reset();
      return result;
    } catch (error) {
      if (_key == key) {
        if (!definiteFailure(error)) {
          _uncertain = true;
        } else if (!_uncertain ||
            isWorkspaceCleared(error) ||
            isKeyConflict(error)) {
          // Once an attempt may have committed, only an answer about the
          // key itself settles it: a transport failure or a busy or failing
          // service says nothing about that earlier attempt.
          reset();
        }
      }
      rethrow;
    }
  }

  void _lapse() {
    final started = _started;
    if (started != null && clock.now().difference(started) > window) reset();
  }

  static bool _same(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length &&
      a.entries.every(
        (entry) => b.containsKey(entry.key) && b[entry.key] == entry.value,
      );

  /// Whether [error] proves the request did not commit: the service rejected
  /// it, refused it while closing, or it was never sent. A lost reply
  /// (outcomeUnknown, whatever its code), a lost connection without a reason
  /// or a local cancellation leaves the outcome unknown. So does an internal
  /// error: a keyed write can commit before a later step, such as indexing
  /// the imported text, fails, and a retry under the same key then replays
  /// the stored result instead of writing again.
  static bool definiteFailure(Object error) {
    if (error is! RpcError) return false;
    if (error.reason == RpcErrorReason.outcomeUnknown) return false;
    if (isClosingRefusal(error) || error.reason == RpcErrorReason.notSent) {
      return true;
    }
    return error.code != RpcErrorCode.unavailable &&
        error.code != RpcErrorCode.cancelled &&
        error.code != RpcErrorCode.internal;
  }
}
