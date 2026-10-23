import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/settings/read_model.dart';

class _Reader implements StoreReader {
  final queries = <ReadQuery<Object?>>[];
  final streams = <StreamController<ReadResult<Object?>>>[];
  int active = 0;
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
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
  test(
    'Settings retains stable factory watches across data events and retires an old owner',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      var publications = 0;
      final model = SettingsReadModel(
        connection: () => connection,
        changed: () => publications++,
      );
      model.start();
      final count = 1 + SettingsReadModel.defaults.length;
      expect(reader.queries.length, count);
      expect(reader.active, count);
      expect(reader.queries.first.key, StoreReadQueries.models().key);
      final registration = ModelRegistration.fromRow({
        'kind': 'speech',
        'path': '/fixture/model',
        'digest': 'known',
        'runtime': '/fixture/runner',
      });
      reader.reply(0, [registration]);
      await Future<void>(() {});
      expect(model.currentModel('speech'), same(registration));
      reader.reply(0, [registration], freshness: ReadFreshness.preview);
      expect(model.model('speech'), same(registration));
      expect(model.currentModel('speech'), isNull);
      reader.reply(1, '120');
      expect(model.preference('serviceIdleMinutes'), '120');
      expect(model.preference('unknown', 'fallback'), 'fallback');
      reader.dataRevision = '2';
      connection.events.add(null);
      expect(reader.queries.length, count);
      final oldGeneration = model.generation;
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      await Future<void>(() {});
      expect(reader.queries.length, count * 2);
      expect(reader.active, count);
      expect(model.owns(oldGeneration), false);
      expect(model.models, isEmpty);
      reader.reply(0, [registration]);
      expect(model.models, isEmpty);
      reader.reply(count, [registration]);
      expect(model.currentModel('speech'), same(registration));
      expect(publications, greaterThan(0));
      await model.dispose();
      expect(reader.active, 0);
      final published = publications;
      reader.reply(count, []);
      await Future<void>(() {});
      expect(publications, published);
      for (final stream in reader.streams) {
        await stream.close();
      }
      await connection.events.close();
    },
  );

  test(
    'prepared model actions refuse preview and failed reads rather than certify readiness',
    () async {
      final reader = _Reader();
      expect(await readSetupModel(reader, 'speech'), isNull);
      reader.nextFreshness = ReadFreshness.preview;
      await expectLater(
        readSetupModel(reader, 'speech'),
        throwsA(isA<RpcError>()),
      );
      reader.nextError = RpcError(
        RpcErrorCode.unavailable,
        'fixture model failure',
      );
      await expectLater(
        readSetupModel(reader, 'speech'),
        throwsA(same(reader.nextError)),
      );
    },
  );
}
