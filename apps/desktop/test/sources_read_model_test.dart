import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/sources/read_model.dart';

class _Reader implements StoreReader {
  final queries = <ReadQuery<Object?>>[];
  final streams = <StreamController<ReadResult<Object?>>>[];
  int active = 0;
  bool failWatch = false;
  bool failIdentity = false;
  String _epoch = 'epoch';
  @override
  String get workspaceEpoch {
    if (failIdentity) throw StateError('identity unavailable');
    return _epoch;
  }

  set workspaceEpoch(String value) => _epoch = value;
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    if (failWatch) throw StateError('fixture bind failure');
    queries.add(query);
    final stream = StreamController<ReadResult<Object?>>.broadcast(
      sync: true,
      onListen: () => active++,
      onCancel: () => active--,
    );
    streams.add(stream);
    return stream.stream.map((value) => value.asType<T>());
  }

  void reply(
    int index,
    Object? value, {
    ReadFreshness freshness = ReadFreshness.current,
    RpcError? error,
  }) => streams[index].add(
    ReadResult(
      freshness: freshness,
      value: value,
      error: error,
      requestTag: 'test',
      sequence: index,
    ),
  );
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async {
    return ReadResult(
      freshness: nextFreshness,
      value: null,
      error: nextError,
      requestTag: 'single',
      sequence: 0,
    );
  }

  ReadFreshness nextFreshness = ReadFreshness.current;
  RpcError? nextError;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous projection: ${invocation.memberName}',
  );
}

class _Connection implements DesktopConnection {
  _Connection(this.store);
  @override
  final _Reader store;
  @override
  String? workspaceEpoch = 'epoch';
  @override
  Object clientSessionGeneration = Object();
  // Closed by each owning fixture after subscriptions retire.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late _Reader reader;
  late _Connection connection;
  late SourcesReadModel model;
  late int publications;
  setUp(() {
    reader = _Reader();
    connection = _Connection(reader);
    publications = 0;
    model = SourcesReadModel(
      connection: () => connection,
      changed: () => publications++,
    );
  });
  tearDown(() async {
    await model.dispose();
    for (final stream in reader.streams) {
      await stream.close();
    }
    await connection.events.close();
  });
  Future<void> settle() => Future<void>(() {});

  test(
    'eight typed watches remain stable across status and durable revisions',
    () async {
      model.start();
      expect(reader.queries.map((q) => q.projection), [
        'sources',
        'notes',
        'source_mimes',
        'labels',
        'clusters',
        'cluster_names',
        'graph_label_set',
        'model',
      ]);
      expect(reader.active, 8);
      reader.reply(0, [
        SourceSummary.fromRow({'id': 'a', 'title': 'First', 'revision': 1}),
      ]);
      reader.reply(7, null);
      await settle();
      expect(model.sources.single.title, 'First');
      expect(model.embedding, isNull);
      final snapshot = model.sources, count = publications;
      reader.reply(0, [
        SourceSummary.fromRow({'id': 'a', 'title': 'First', 'revision': 1}),
      ]);
      reader.dataRevision = '2';
      connection.events.add(null);
      await settle();
      expect(reader.queries.length, 8);
      expect(model.sources, same(snapshot));
      expect(publications, count);
      reader.reply(0, [
        SourceSummary.fromRow({'id': 'a', 'title': 'Changed', 'revision': 2}),
      ]);
      await settle();
      expect(model.sources.single.title, 'Changed');
    },
  );

  test(
    'preview registration displays but never certifies embedding readiness',
    () async {
      model.start();
      final registration = ModelRegistration.fromRow({
        'kind': 'embedding',
        'path': '/fixture/model',
        'digest': 'known',
      });
      reader.reply(7, registration, freshness: ReadFreshness.preview);
      await settle();
      expect(model.embedding, same(registration));
      expect(model.currentEmbedding, isNull);
      final count = publications;
      reader.reply(7, registration);
      await settle();
      expect(model.currentEmbedding, same(registration));
      expect(publications, count + 1);
      reader.reply(7, registration, freshness: ReadFreshness.preview);
      await settle();
      expect(model.embedding, same(registration));
      expect(model.currentEmbedding, isNull);
      expect(publications, count + 2);
      reader.reply(7, registration);
      reader.streams[7].addError(StateError('embedding unavailable'));
      expect(model.currentEmbedding, isNull);
    },
  );

  test(
    'value-equal MIME maps preserve identity independent of key order',
    () async {
      model.start();
      reader.reply(2, {'a': 'text/plain', 'b': 'text/html'});
      await settle();
      final snapshot = model.originalMimes, count = publications;
      reader.reply(2, {'b': 'text/html', 'a': 'text/plain'});
      await settle();
      expect(model.originalMimes, same(snapshot));
      expect(publications, count);
      reader.streams[2].addError(StateError('mime unavailable'));
      await settle();
      expect(model.problem, contains('mime unavailable'));
      reader.reply(2, {'a': 'text/plain', 'b': 'text/html'});
      await settle();
      expect(model.problem, isNull);
      expect(model.originalMimes, same(snapshot));
    },
  );

  test(
    'held search and retired owner replies cannot replace current snapshots',
    () async {
      model.start();
      model.search('First');
      expect(
        reader.queries.last.key,
        StoreReadQueries.sourceSearch('first').key,
      );
      reader.reply(8, {'a'});
      expect(model.searchMatches, {'a'});
      model.search('SECOND');
      reader.reply(8, {'stale'});
      expect(model.searchMatches, isNull);
      reader.reply(9, {'b'});
      expect(model.searchMatches, {'b'});
      reader.streams[9].addError(StateError('search unavailable'));
      expect(model.problem, contains('search unavailable'));
      reader.reply(9, {'b'});
      expect(model.problem, isNull);
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      await settle();
      expect(reader.active, 9);
      expect(model.sources, isEmpty);
      expect(model.searchMatches, isNull);
      reader.reply(0, [
        SourceSummary.fromRow({'id': 'old', 'title': 'Retired'}),
      ]);
      reader.reply(9, {'stale'});
      expect(model.sources, isEmpty);
      expect(model.searchMatches, isNull);
      reader.reply(18, {'new'});
      expect(model.searchMatches, {'new'});
      reader.workspaceEpoch = connection.workspaceEpoch = 'replacement';
      connection.events.add(null);
      await settle();
      expect(reader.queries.length, 28);
      expect(reader.active, 9);
      await model.dispose();
      expect(reader.active, 0);
      final count = publications;
      reader.reply(27, {'late'});
      await settle();
      expect(publications, count);
    },
  );

  test(
    'failed replacement binding clears retired snapshots before capture',
    () async {
      model.start();
      reader.reply(0, [
        SourceSummary.fromRow({'id': 'retired', 'title': 'Retired source'}),
      ]);
      expect(model.sources, hasLength(1));
      reader.failIdentity = true;
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      await settle();
      expect(model.sources, isEmpty);
      expect(model.embedding, isNull);
      expect(model.currentEmbedding, isNull);
      expect(model.problem, contains('identity unavailable'));
      reader.failIdentity = false;
      connection.events.add(null);
      await settle();
      expect(model.problem, isNull);
      expect(reader.active, 8);
    },
  );

  test(
    'binding and search admission failures surface and recover on owned events',
    () async {
      reader.failWatch = true;
      model.start();
      await settle();
      expect(model.problem, contains('fixture bind failure'));
      reader.failWatch = false;
      connection.events.add(null);
      await settle();
      expect(reader.active, 8);
      expect(model.problem, isNull);
      reader.failWatch = true;
      model.search('fail');
      expect(model.problem, contains('fixture bind failure'));
      reader.failWatch = false;
      model.search('recover');
      reader.reply(8, {'recovered'});
      expect(model.problem, isNull);
      expect(model.searchMatches, {'recovered'});
    },
  );
}
