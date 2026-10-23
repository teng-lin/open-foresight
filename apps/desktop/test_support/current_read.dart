import 'dart:async';

import 'package:foresight_core/desktop.dart';

/// A bounded query can settle busy or preview while its input revision changes.
/// Polling acceptance predicates may retry that state within their own deadline.
final class IntegrationReadPending implements Exception {
  const IntegrationReadPending(this.projection);
  final String projection;
  @override
  String toString() => 'Read is not current: $projection';
}

Future<T> currentRead<T>(StoreReader reader, ReadQuery<T> query) async {
  final result = await reader.read(query);
  if (result.error != null) throw result.error!;
  if (!result.current) throw IntegrationReadPending(query.projection);
  return result.value as T;
}

Future<bool> currentReadCondition(
  FutureOr<bool> Function() condition, {
  DateTime? deadline,
}) async {
  try {
    if (deadline == null) return await condition();
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return false;
    return await Future<bool>.sync(
      condition,
    ).timeout(remaining, onTimeout: () => false);
  } on IntegrationReadPending {
    return false;
  }
}
