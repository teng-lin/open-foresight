import 'dart:async';
import 'dart:convert';

import 'package:foresight_core/desktop.dart';

import '../../feature_request_identity.dart';

/// Stable asynchronous subscriptions owned by the Sources feature. Widget
/// builders inspect these snapshots; the reader owns durable invalidation.
class SourcesReadModel {
  SourcesReadModel({required this.connection, required this.changed});
  final DesktopConnection Function() connection;
  final void Function() changed;
  List<SourceSummary> sources = const [];
  List<NoteSummary> notes = const [];
  Map<String, String> originalMimes = const {};
  List<DocumentLabel> labels = const [];
  List<DocumentCluster> clusters = const [];
  List<String> clusterNames = const [];
  String labelSet = '';
  ModelRegistration? embedding;
  Set<String>? searchMatches;
  String? problem;
  String _searchQuery = '';
  FeatureRequestIdentity? _owner;
  int _generation = 0, _searchGeneration = 0;
  bool _disposed = false, _queued = false;
  final _reads = <StreamSubscription<Object?>>[];
  StreamSubscription<void>? _changes;
  StreamSubscription<ReadResult<Set<String>>>? _search;
  final _values = <String, String>{};
  final _problems = <String, String>{};

  bool _current(int generation) =>
      !_disposed &&
      generation == _generation &&
      (_owner?.isCurrent(connection(), alive: true) ?? false);

  void start() {
    if (_disposed || _changes != null) return;
    _changes = connection().changes.listen((_) {
      if (!_current(_generation)) _bind();
    });
    _bind();
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
    _values.clear();
    _problems.clear();
    searchMatches = null;
    try {
      _owner = FeatureRequestIdentity.capture(connection());
      sources = const [];
      notes = const [];
      labels = const [];
      clusters = const [];
      clusterNames = const [];
      originalMimes = const {};
      embedding = null;
      labelSet = '';
      problem = null;
      final reader = connection().store;
      _watch(
        'sources',
        reader.watch(StoreReadQueries.sources()),
        generation,
        (value) => [
          for (final s in value)
            [
              s.id,
              s.title,
              s.mime,
              s.provenance,
              s.state,
              s.error,
              s.revision,
              s.deleted,
              s.locallyEdited,
              s.imported,
              s.changed,
              s.sourceUri,
              s.labels,
            ],
        ],
        (value) => sources = List.unmodifiable(value),
      );
      _watch(
        'notes',
        reader.watch(StoreReadQueries.notes()),
        generation,
        (value) => [
          for (final n in value) [n.id, n.title, n.revision],
        ],
        (value) => notes = List.unmodifiable(value),
      );
      _watch(
        'mimes',
        reader.watch(StoreReadQueries.sourceMimes()),
        generation,
        (value) => value,
        (value) => originalMimes = Map.unmodifiable(value),
      );
      _watch(
        'labels',
        reader.watch(StoreReadQueries.labels()),
        generation,
        (value) => [
          for (final l in value)
            [l.documentId, l.name, l.source, l.colorHex, l.rationale],
        ],
        (value) => labels = List.unmodifiable(value),
      );
      _watch(
        'clusters',
        reader.watch(StoreReadQueries.clusters()),
        generation,
        (value) => [
          for (final c in value) [c.id, c.label, c.summary, c.x, c.y, c.radius],
        ],
        (value) => clusters = List.unmodifiable(value),
      );
      _watch(
        'cluster_names',
        reader.watch(StoreReadQueries.clusterNames()),
        generation,
        (value) => value,
        (value) => clusterNames = List.unmodifiable(value),
      );
      _watch(
        'label_set',
        reader.watch(StoreReadQueries.graphLabelSet()),
        generation,
        (value) => value,
        (value) => labelSet = value,
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
                value.modelType,
              ],
        (value) => embedding = value,
      );
      _bindSearch();
      _notify();
    } catch (error) {
      _owner = null;
      for (final read in _reads) {
        unawaited(read.cancel());
      }
      _reads.clear();
      unawaited(_search?.cancel());
      _search = null;
      _problem('binding', error);
    }
  }

  void _problem(String key, Object? error) {
    if (error == null) {
      _problems.remove(key);
    } else {
      _problems[key] = error.toString();
    }
    final next = _problems.isEmpty ? null : _problems.values.join('\n');
    if (problem == next) return;
    problem = next;
    _notify();
  }

  Object? _ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _ordered(value[key])};
    }
    if (value is Iterable) return value.map(_ordered).toList();
    return value;
  }

  void _watch<T>(
    String key,
    Stream<ReadResult<T>> stream,
    int generation,
    Object? Function(T) signature,
    void Function(T) accept,
  ) {
    _reads.add(
      stream.listen(
        (result) {
          if (!_current(generation)) return;
          if (result.error != null) {
            _problem(key, result.error);
            return;
          }
          if (!(result.current || result.freshness == ReadFreshness.preview))
            return;
          try {
            final value = result.value as T;
            final next = jsonEncode(_ordered(signature(value)));
            _problem(key, null);
            if (_values[key] == next) return;
            _values[key] = next;
            accept(value);
            _notify();
          } catch (error) {
            _problem(key, error);
          }
        },
        onError: (Object error) {
          if (_current(generation)) _problem(key, error);
        },
      ),
    );
  }

  void search(String query) {
    final normalized = query.toLowerCase();
    if (_searchQuery == normalized) return;
    _searchQuery = normalized;
    if (_changes != null) _bindSearch();
  }

  void _bindSearch() {
    final generation = _generation;
    final searchGeneration = ++_searchGeneration;
    unawaited(_search?.cancel());
    _search = null;
    if (searchMatches != null) {
      searchMatches = null;
      _notify();
    }
    _problem('search', null);
    if (_searchQuery.isEmpty) return;
    try {
      _search = connection().store
          .watch(StoreReadQueries.sourceSearch(_searchQuery.toLowerCase()))
          .listen(
            (result) {
              if (!_current(generation) ||
                  searchGeneration != _searchGeneration)
                return;
              if (result.error != null) {
                _problem('search', result.error);
                return;
              }
              final next = result.value;
              if (next == null ||
                  !(result.current ||
                      result.freshness == ReadFreshness.preview))
                return;
              _problem('search', null);
              final previous = searchMatches;
              if (previous != null &&
                  previous.length == next.length &&
                  previous.containsAll(next))
                return;
              searchMatches = Set.unmodifiable(next);
              _notify();
            },
            onError: (Object error) {
              if (_current(generation) && searchGeneration == _searchGeneration)
                _problem('search', error);
            },
          );
    } catch (error) {
      if (_current(generation) && searchGeneration == _searchGeneration) {
        _problem('search', error);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _searchGeneration++;
    await Future.wait([
      if (_changes != null) _changes!.cancel(),
      if (_search != null) _search!.cancel(),
      for (final read in _reads) read.cancel(),
    ]);
    _reads.clear();
  }
}
