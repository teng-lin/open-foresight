import 'dart:async';
import 'dart:convert';
import 'package:foresight_core/desktop.dart';
import '../../feature_request_identity.dart';

/// First-run presentation uses lifetime-owned watches, never reads in build.
class OnboardingReadModel {
  OnboardingReadModel({required this.connection, required this.changed});
  final DesktopConnection Function() connection;
  final void Function() changed;
  List<SourceSummary> sources = const [];
  ModelRegistration? embedding;
  bool complete = false;
  int step = 0;
  bool _completeReady = false, _stepReady = false;
  bool get preferencesReady => _completeReady && _stepReady;
  String? problem;
  Object ownerKey = Object();
  FeatureRequestIdentity? _identity;
  int _generation = 0;
  bool _disposed = false, _queued = false;
  final _reads = <StreamSubscription<Object?>>[];
  StreamSubscription<void>? _changes;
  final _signatures = <String, String>{};

  bool _current(int generation) =>
      !_disposed &&
      generation == _generation &&
      (_identity?.isCurrent(connection(), alive: true) ?? false);

  void start() {
    if (_disposed || _changes != null) return;
    _bind();
    _changes = connection().changes.listen((_) {
      if (!_current(_generation)) _bind();
    });
  }

  void retry() {
    if (!_disposed) _bind();
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
    final generation = ++_generation;
    for (final read in _reads) {
      unawaited(read.cancel());
    }
    _reads.clear();
    _signatures.clear();
    _identity = null;
    ownerKey = Object();
    complete = _completeReady = _stepReady = false;
    step = 0;
    sources = const [];
    embedding = null;
    problem = null;
    try {
      final owner = connection();
      _identity = FeatureRequestIdentity.capture(owner);
      final reader = owner.store;
      _watch(
        'complete',
        reader.watch(StoreReadQueries.preference('onboarding.complete')),
        generation,
        (value) => value,
        (value) {
          complete = value == 'true';
          _completeReady = true;
        },
        currentOnly: true,
      );
      _watch(
        'step',
        reader.watch(StoreReadQueries.preference('onboarding.step', '0')),
        generation,
        (value) => value,
        (value) {
          step = int.tryParse(value) ?? 0;
          _stepReady = true;
        },
        currentOnly: true,
      );
      _watch(
        'sources',
        reader.watch(StoreReadQueries.sources()),
        generation,
        (value) => [
          for (final s in value) [s.id, s.title, s.revision, s.state, s.error],
        ],
        (value) => sources = List.unmodifiable(value),
      );
      _watch(
        'embedding',
        reader.watch(StoreReadQueries.model('embedding')),
        generation,
        (value) => value == null
            ? null
            : [
                value.kind,
                value.path,
                value.digest,
                value.runtime,
                value.backend,
              ],
        (value) => embedding = value,
        currentOnly: true,
      );
    } catch (error) {
      problem = error.toString();
    }
    _notify();
  }

  void _watch<T>(
    String key,
    Stream<ReadResult<T>> stream,
    int generation,
    Object? Function(T) signature,
    void Function(T) accept, {
    bool currentOnly = false,
  }) {
    _reads.add(
      stream.listen(
        (result) {
          if (!_current(generation)) return;
          if (result.error != null) {
            final next = result.error.toString();
            if (problem != next) {
              problem = next;
              _notify();
            }
            return;
          }
          if (!result.current &&
              (currentOnly || result.freshness != ReadFreshness.preview))
            return;
          final value = result.value as T;
          final next = jsonEncode(signature(value));
          if (_signatures[key] == next) return;
          _signatures[key] = next;
          accept(value);
          _notify();
        },
        onError: (Object error) {
          if (!_current(generation) || problem == error.toString()) return;
          problem = error.toString();
          _notify();
        },
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await Future.wait([
      if (_changes != null) _changes!.cancel(),
      for (final read in _reads) read.cancel(),
    ]);
    _reads.clear();
  }
}
