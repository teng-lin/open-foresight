import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';

/// Prepared preference values. Defaults preserve the existing controls while
/// their first asynchronous snapshots are being prepared.
final class IntegrationPreferences {
  const IntegrationPreferences._(this._values);
  static const defaults = {
    'quickShortcut': 'CTRL + SHIFT + F',
    'globalShortcut': 'false',
    'microphoneTarget': 'auto',
    'playbackTarget': 'auto',
  };
  static const initial = IntegrationPreferences._(defaults);
  final Map<String, String> _values;

  String value(String key) => _values[key]!;
  IntegrationPreferences withValue(String key, String value) =>
      _values[key] == value
      ? this
      : IntegrationPreferences._(Map.unmodifiable({..._values, key: value}));
}

/// One stable watch per query. Data revisions refresh those watches through the
/// reader; ordinary status events do not recreate subscriptions or admit SQL.
/// Owner changes discard prepared values and retire every old callback.
final class IntegrationPreferenceModel extends ChangeNotifier {
  IntegrationPreferenceModel(this.connection);
  final DesktopConnection connection;
  IntegrationPreferences _value = IntegrationPreferences.initial;
  IntegrationPreferences get value => _value;
  final _reads = <StreamSubscription<ReadResult<String>>>[];
  StreamSubscription<void>? _changes;
  FeatureRequestIdentity? _identity;
  int _generation = 0;
  bool _disposed = false;

  /// Actions may start before the widget's initial watches (startup shortcut
  /// installation does), so their inputs come from a fresh typed read.
  Future<String> readCurrent(String key) async {
    final identity = FeatureRequestIdentity.capture(connection);
    final result = await connection.store.read(
      StoreReadQueries.preference(key, IntegrationPreferences.defaults[key]!),
    );
    if (_disposed || !identity.isCurrent(connection, alive: true)) {
      throw RpcError(RpcErrorCode.cancelled, 'Preference owner changed');
    }
    if (result.error != null) throw result.error!;
    if (!result.current || result.value == null) {
      throw RpcError(RpcErrorCode.busy, 'Preference snapshot is refreshing');
    }
    return result.value!;
  }

  void start() {
    if (_disposed || _changes != null) return;
    _changes = connection.changes.listen((_) {
      if (!_current()) _subscribe();
    });
    _subscribe();
  }

  bool _current() =>
      !_disposed && (_identity?.isCurrent(connection, alive: true) ?? false);

  void _subscribe() {
    if (_disposed) return;
    final generation = ++_generation;
    for (final subscription in _reads) {
      unawaited(subscription.cancel());
    }
    _reads.clear();
    _identity = FeatureRequestIdentity.capture(connection);
    if (!identical(value, IntegrationPreferences.initial)) {
      _value = IntegrationPreferences.initial;
      notifyListeners();
    }
    for (final entry in IntegrationPreferences.defaults.entries) {
      final query = StoreReadQueries.preference(entry.key, entry.value);
      _reads.add(
        connection.store.watch(query).listen((result) {
          if (generation != _generation || !_current()) return;
          // A stale snapshot may remain useful inside the coordinator, but it
          // cannot replace the feature's current prepared values.
          if (!result.current || result.value == null) return;
          final next = value.withValue(entry.key, result.value!);
          if (identical(next, value)) return;
          _value = next;
          notifyListeners();
        }),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_changes?.cancel());
    for (final subscription in _reads) {
      unawaited(subscription.cancel());
    }
    _reads.clear();
    super.dispose();
  }
}
