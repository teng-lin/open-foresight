import 'dart:async';

import 'package:foresight_core/desktop.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../feature_request_identity.dart';

/// Settings reads are prepared by feature lifetime, never by a widget builder.
/// Revision invalidation belongs to StoreReader; only owner replacement rebinds.
class SettingsReadModel {
  SettingsReadModel({required this.connection, required this.changed});
  final DesktopConnection Function() connection;
  final void Function() changed;
  static const defaults = {
    'updateNoticeEnabled': 'false',
    'serviceIdleMinutes': '30',
    'googleReminders': '',
    'noteStyle': 'Standard',
    'inactivity': '15',
    'echoCancellation': 'false',
    'globalShortcut': '',
    'quickShortcut': 'CTRL + SHIFT + F',
    'granolaCalendarRefreshMinutes': '10',
    'googleRefreshHours': '4',
    dedicatedQueryTermsKey: '',
  };
  List<ModelRegistration> models = const [];
  final Map<String, String> _preferences = {};
  bool modelsCurrent = false;
  String? problem;
  FeatureRequestIdentity? _identity;
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<void>? _changes;
  int _generation = 0;
  bool _disposed = false, _queued = false;
  int get generation => _generation;
  bool owns(int generation) =>
      !_disposed &&
      generation == _generation &&
      (_identity?.isCurrent(connection(), alive: true) ?? false);

  ModelRegistration? currentModel(String kind) =>
      modelsCurrent ? model(kind) : null;
  ModelRegistration? model(String kind) =>
      models.where((model) => model.kind == kind).firstOrNull;
  String preference(String key, [String fallback = '']) =>
      _preferences[key] ?? defaults[key] ?? fallback;

  void start() {
    if (_disposed || _changes != null) return;
    _bind();
    _changes = connection().changes.listen((_) {
      if (!(_identity?.isCurrent(connection(), alive: true) ?? false)) _bind();
    });
  }

  void _notify() {
    if (_queued || _disposed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_disposed) changed();
    });
  }

  void _bind() {
    final owner = connection();
    final generation = ++_generation;
    _identity = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    models = const [];
    _preferences.clear();
    modelsCurrent = false;
    problem = null;
    try {
      _identity = FeatureRequestIdentity.capture(owner);
    } catch (error) {
      problem = error.toString();
      _notify();
      return;
    }
    _watch(owner.store, StoreReadQueries.models(), generation, (result) {
      var changed = modelsCurrent != result.current;
      modelsCurrent = result.current;
      if (result.value != null &&
          (result.current || result.freshness == ReadFreshness.preview)) {
        final next = result.value!;
        if (!listEquals(
          models.map(_modelFields).toList(),
          next.map(_modelFields).toList(),
        )) {
          models = List.unmodifiable(next);
          changed = true;
        }
      }
      return changed;
    });
    for (final entry in defaults.entries) {
      _watch(
        owner.store,
        StoreReadQueries.preference(entry.key, entry.value),
        generation,
        (result) {
          if (result.value != null &&
              (result.current || result.freshness == ReadFreshness.preview)) {
            final changed = preference(entry.key) != result.value!;
            _preferences[entry.key] = result.value!;
            return changed;
          }
          return false;
        },
      );
    }
    _notify();
  }

  void _watch<T>(
    StoreReader reader,
    ReadQuery<T> query,
    int generation,
    bool Function(ReadResult<T>) accept,
  ) {
    _subscriptions.add(
      reader
          .watch(query)
          .listen(
            (result) {
              if (!owns(generation)) return;
              final changed = accept(result);
              final error = result.error?.toString();
              final errorChanged = error != null && problem != error;
              if (error != null) problem = error;
              if (changed || errorChanged) _notify();
            },
            onError: (Object error) {
              if (!owns(generation)) return;
              final next = error.toString();
              if (problem == next) return;
              problem = next;
              _notify();
            },
          ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _changes?.cancel();
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    _subscriptions.clear();
  }
}

/// Keep one owned subscription through ordinary revision catch-up. Preview is
/// display state; the coordinator's existing deadline still bounds this wait.
Future<ReadResult<T>?> readCurrentSetup<T>(
  StoreReader reader,
  ReadQuery<T> query, {
  bool Function()? ownerCurrent,
}) async {
  final epoch = reader.workspaceEpoch;
  bool owns() =>
      reader.workspaceEpoch == epoch && (ownerCurrent?.call() ?? true);
  if (!owns()) return null;
  final result = await reader
      .watch(query)
      .firstWhere(
        (result) => !owns() || result.current || result.error != null,
      );
  if (!owns()) return null;
  if (result.error != null) throw result.error!;
  return result;
}

/// A setup action needs a current registration from the same workspace.
Future<ModelRegistration?> readSetupModel(
  StoreReader reader,
  String kind,
) async =>
    (await readCurrentSetup(reader, StoreReadQueries.model(kind)))?.value;

/// The existing cache finder accepts only these registration hints. They carry
/// no persistence API and do not decode a row or issue a synchronous query.
Map<String, Object?>? cacheRegistration(ModelRegistration? model) =>
    model == null ? null : {'path': model.path, 'digest': model.digest};

Object _modelFields(ModelRegistration model) => (
  model.kind,
  model.path,
  model.digest,
  model.runtime,
  model.backend,
  model.modelType,
);
