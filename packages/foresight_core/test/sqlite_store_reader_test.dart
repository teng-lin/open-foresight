import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/read_models.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_read_worker.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/store_read_queries.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

final class GatedWorker implements ReadWorker {
  final pending = <Completer<ReadWorkerReply>>[];
  final started = StreamController<int>.broadcast();
  int closes = 0;
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) {
    final reply = Completer<ReadWorkerReply>();
    pending.add(reply);
    started.add(pending.length);
    return reply.future;
  }

  @override
  Future<void> close() async {
    closes++;
    await started.close();
  }
}

void main() {
  late Store writer;
  late String path;
  setUp(() {
    final directory = createTestTempDirectorySync('reader-');
    path = '${directory.path}/application.db';
    writer = Store(path);
    addTearDown(() {
      writer.close();
      directory.deleteSync(recursive: true);
    });
  });

  SqliteStoreReader gated(GatedWorker worker) {
    final store = Store.readOnly(path);
    addTearDown(store.close);
    final reader = SqliteStoreReader.borrow(store, worker: worker);
    addTearDown(reader.close);
    return reader;
  }

  void futureSchema() {
    writer.db.execute('BEGIN IMMEDIATE');
    writer.db.execute('ALTER TABLE preferences RENAME TO future_preferences');
    writer.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    writer.db.execute('COMMIT');
  }

  ReadQuery<String> fixture(String name) =>
      ReadQuery(projection: name, decode: (value) => value as String);

  test('schema and multi-query projection use the same read snapshot', () {
    final id = writer.importText('Before', 'body', 'text/plain', 'fixture');
    final reader = Store.readOnly(path);
    addTearDown(reader.close);
    final oldEpoch = writer.workspaceEpoch;
    final revision = reader.dataRevision;
    readSnapshot(reader.db, () {
      expect(reader.workspaceEpoch, oldEpoch);
      writer.db.execute('BEGIN IMMEDIATE');
      writer.renewWorkspaceEpoch();
      writer.db.execute('UPDATE sources SET title=? WHERE id=?', ['After', id]);
      writer.db.execute('COMMIT');
      expect(reader.sourceSummaries.single['title'], 'Before');
      expect(reader.workspaceEpoch, oldEpoch);
    }, supportedVersion: Store.schemaVersion);
    expect(reader.db.autocommit, isTrue);
    expect(reader.dataRevision, isNot(revision));
    expect(reader.sourceSummaries.single['title'], 'After');
  });

  test(
    'guard refuses future schema before dependent SQL and preserves caller transaction',
    () {
      final reader = Store.readOnly(path);
      addTearDown(reader.close);
      reader.db.execute('BEGIN');
      readSnapshot(reader.db, () {
        expect(reader.workspaceEpoch, writer.workspaceEpoch);
      }, supportedVersion: Store.schemaVersion);
      expect(reader.db.autocommit, isFalse);
      reader.db.execute('ROLLBACK');
      futureSchema();
      var queried = false;
      expect(
        () => readSnapshot(reader.db, () {
          queried = true;
          return reader.preference('irrelevant');
        }, supportedVersion: Store.schemaVersion),
        throwsA(isA<IncompatibleReadSchema>()),
      );
      expect(queried, isFalse);
      expect(reader.db.autocommit, isTrue);
    },
  );

  test(
    'future identity table before dispatch retires without starting a worker',
    () async {
      final worker = GatedWorker();
      final reader = gated(worker);
      final result = reader.read(fixture('first'));
      futureSchema();
      final failure = await result;
      expect(failure.freshness, ReadFreshness.failed);
      expect(failure.error!.code, RpcErrorCode.unavailable);
      expect(failure.value, isNull);
      await reader.close();
      expect(worker.pending, isEmpty);
      expect(worker.closes, 1);
      final later = await reader.read(fixture('later'));
      expect(later.error!.code, RpcErrorCode.unavailable);
      expect(later.value, isNull);
    },
  );

  test(
    'future identity table between snapshot and acceptance cannot publish old rows',
    () async {
      final worker = GatedWorker();
      final reader = gated(worker);
      final epoch = reader.workspaceEpoch;
      final started = worker.started.stream.first;
      final result = reader.read(fixture('first'));
      await started;
      futureSchema();
      worker.pending.single.complete(
        ReadWorkerReply(epoch, 'retired snapshot'),
      );
      final failure = await result;
      expect(failure.error!.code, RpcErrorCode.unavailable);
      expect(failure.value, isNull);
      await reader.close();
      expect(worker.pending, hasLength(1));
      expect(worker.closes, 1);
    },
  );

  test(
    'sync adapter failure retires every caller but joins actual reads',
    () async {
      final worker = GatedWorker();
      final reader = gated(worker);
      final epoch = reader.workspaceEpoch;
      final started = worker.started.stream.firstWhere((count) => count == 2);
      final first = reader.read(fixture('first'));
      final second = reader.read(fixture('second'));
      await started;
      futureSchema();
      expect(
        () => reader.preference('example'),
        throwsA(isA<IncompatibleReadSchema>()),
      );
      for (final failure in await Future.wait([first, second])) {
        expect(failure.error!.code, RpcErrorCode.unavailable);
        expect(failure.value, isNull);
      }
      expect(reader.busy, isTrue);
      expect(worker.closes, 0);
      worker.pending.first.complete(ReadWorkerReply(epoch, 'old first'));
      await Future<void>.delayed(Duration.zero);
      expect(worker.closes, 0);
      worker.pending.last.complete(ReadWorkerReply(epoch, 'old second'));
      await reader.close();
      expect(reader.busy, isFalse);
      expect(worker.closes, 1);
      expect(worker.pending, hasLength(2));
    },
  );

  test(
    'worker schema failure retires all queries and discards retained view',
    () async {
      final worker = GatedWorker();
      final reader = gated(worker);
      final received = <ReadResult<String>>[];
      final failed = Completer<void>();
      var started = worker.started.stream.first;
      final subscription = reader.watch(fixture('first')).listen((event) {
        received.add(event);
        if (event.freshness == ReadFreshness.failed) failed.complete();
      });
      await started;
      worker.pending[0].complete(
        ReadWorkerReply(reader.workspaceEpoch, 'valid old view'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.single.value, 'valid old view');
      started = worker.started.stream.first;
      reader.invalidate();
      await started;
      worker.pending[1].completeError(
        IncompatibleReadSchema(Store.schemaVersion + 1, Store.schemaVersion),
      );
      await failed.future;
      await reader.close();
      expect(received.last.error!.code, RpcErrorCode.unavailable);
      expect(received.last.value, isNull);
      expect(worker.closes, 1);
      await subscription.cancel();
    },
  );

  test(
    'real persistent isolate reads Unicode bodies and refreshes committed rows',
    () async {
      final id = writer.importText(
        'First',
        '中文 Straße',
        'text/plain',
        'fixture',
      );
      final reader = SqliteStoreReader.open(
        path,
        profile: 'fixture',
        connection: 'first',
      );
      addTearDown(reader.close);
      final search = await reader.read(StoreReadQueries.sourceSearch('straße'));
      expect(search.current, isTrue);
      expect(search.value, {id});
      expect(() => search.value!.add('other'), throwsUnsupportedError);
      final old = await reader.read(StoreReadQueries.sources());
      expect(old.value!.single.title, 'First');
      writer.importText('After', '更新', 'text/plain', 'fixture', id: id);
      reader.invalidate();
      final fresh = await reader.read(StoreReadQueries.sources());
      expect(fresh.current, isTrue);
      expect(fresh.value!.single.title, 'After');
      expect(fresh.value!.single.revision, 2);
      expect(reader.preference('workspaceEpoch'), writer.workspaceEpoch);
      expect(
        writer.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
    },
  );

  test(
    'service reader tracks writer commits and leaves writer ownership intact',
    () async {
      final reader = SqliteStoreReader.service(
        writer,
        profile: 'service-profile',
        connection: 'service-connection',
      );
      addTearDown(reader.close);
      expect((await reader.read(StoreReadQueries.sources())).value, isEmpty);
      final revision = reader.dataRevision;
      writer.importText('Service commit', 'body', 'text/plain', 'fixture');
      expect(reader.dataRevision, isNot(revision));
      final result = await reader.read(StoreReadQueries.sources());
      expect(result.current, isTrue);
      expect(result.value!.single.title, 'Service commit');
      await reader.close();
      expect(writer.sourceSummaries.single['title'], 'Service commit');
    },
  );

  test('publication guard retires a schema changed after decoding', () async {
    final worker = GatedWorker();
    final reader = gated(worker);
    final received = <ReadResult<String>>[];
    final failed = Completer<void>();
    final started = worker.started.stream.first;
    final subscription = reader
        .watch(
          ReadQuery<String>(
            projection: 'fixture',
            decode: (value) {
              // This models an external writer committing after acceptance sampled
              // its identity but before the retained-value publication guard.
              futureSchema();
              return value as String;
            },
          ),
        )
        .listen((result) {
          received.add(result);
          if (result.freshness == ReadFreshness.failed) failed.complete();
        });
    addTearDown(subscription.cancel);
    await started;
    worker.pending.single.complete(
      ReadWorkerReply(writer.workspaceEpoch, 'old-schema row'),
    );
    await failed.future;
    expect(received, hasLength(1));
    expect(received.single.value, isNull);
    expect(received.single.error!.code, RpcErrorCode.unavailable);
    expect(reader.failure!.message, contains('Update Open Foresight'));
    await reader.close();
  });

  test('real worker detects schema changes after initial reads', () async {
    final worker = SqliteReadWorker(path);
    addTearDown(worker.close);
    final session = SqliteReadSession.open(path);
    addTearDown(session.close);
    final identity = session.identity(
      owner: 'owner',
      profile: 'profile',
      connection: 'connection',
    );
    ReadWorkerRequest request(int sequence) => ReadWorkerRequest(
      projection: 'sources',
      arguments: {},
      identity: identity,
      sequence: sequence,
    );
    await worker.read(request(1));
    futureSchema();
    await expectLater(
      worker.read(request(2)),
      throwsA(isA<IncompatibleReadSchema>()),
    );
    await expectLater(
      worker.read(request(3)),
      throwsA(isA<IncompatibleReadSchema>()),
    );
  });

  test(
    'worker startup preserves the typed future-schema refusal through exit',
    () async {
      final epoch = writer.workspaceEpoch;
      futureSchema();
      for (var attempt = 0; attempt < 10; attempt++) {
        final worker = SqliteReadWorker(path);
        try {
          await expectLater(
            worker.read(
              ReadWorkerRequest(
                projection: 'sources',
                arguments: {},
                sequence: attempt,
                identity: ReadIdentity(
                  owner: 'owner',
                  profile: 'profile',
                  connection: 'connection',
                  epoch: epoch,
                  revision: 'tag',
                ),
              ),
            ),
            throwsA(isA<IncompatibleReadSchema>()),
          );
        } finally {
          await worker.close();
        }
      }
    },
  );

  test(
    'worker uses the already resolved environment instead of consuming a handoff again',
    () async {
      final runner = File('$path.runner')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('/bin/chmod', ['700', runner.path]);
      writer.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend,model_type) VALUES(?,?,?,?,?,?)',
        [
          'generation',
          '/model.litertlm',
          'digest',
          '/old/runner',
          'litert_lm',
          1,
        ],
      );
      writer.setPreference(
        'modelRuntimeResource.generation',
        jsonEncode({
          'resource': 'FORESIGHT_LITERT_RUNNER',
          'runtime': '/old/runner',
          'digest': 'digest',
          'backend': 'litert_lm',
        }),
      );
      final worker = SqliteReadWorker(
        path,
        environment: {
          ...runtimeConfiguration.environment,
          'FORESIGHT_STARTUP_ENV': '/already-consumed/startup.json',
          'FORESIGHT_INSTALL_ROOT': runner.parent.path,
          'FORESIGHT_LITERT_RUNNER': runner.path,
        },
      );
      try {
        final reply = await worker.read(
          ReadWorkerRequest(
            projection: 'model',
            arguments: {'kind': 'generation'},
            sequence: 1,
            identity: ReadIdentity(
              owner: 'owner',
              profile: 'profile',
              connection: 'connection',
              epoch: writer.workspaceEpoch,
              revision: 'tag',
            ),
          ),
        );
        expect(
          (reply.value as ModelRegistration).runtime,
          runner.resolveSymbolicLinksSync(),
        );
        expect(reply.epoch, writer.workspaceEpoch);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'real worker returns typed stats, meeting/export and scope-filtered history',
    () async {
      writer.importText('Source', 'body', 'text/plain', 'fixture');
      writer.db.execute(
        "INSERT INTO meetings(id,title,state,revision) VALUES(7,'Planning','done',1)",
      );
      writer.db.execute(
        "INSERT INTO meeting_details(meeting_id,created,reminder) VALUES(7,10,0)",
      );
      writer.db.execute(
        "INSERT INTO meeting_notes(meeting_id,body,revision,timestamp) VALUES(7,'two words',1,10)",
      );
      writer.db.execute(
        "INSERT INTO answers(id,question,body,citations,model,status,created,conversation) VALUES(1,'Q','Answer','[]','fixture','completed',10,'desktop')",
      );
      writer.setPreference('answerScope.v1.1', 'selected-empty');
      final reader = SqliteStoreReader.open(
        path,
        profile: 'fixture',
        connection: 'first',
      );
      addTearDown(reader.close);
      expect(
        (await reader.read(StoreReadQueries.meetings())).value!.single.title,
        'Planning',
      );
      expect(
        (await reader.read(StoreReadQueries.meetingNote(7))).value!.body,
        'two words',
      );
      expect(
        (await reader.read(StoreReadQueries.exportNotes())).value!.single.body,
        'two words',
      );
      final stats = (await reader.read(
        StoreReadQueries.outputStats(now: DateTime(2026, 10, 21)),
      )).value!;
      expect(stats.sources, 1);
      expect(stats.completedAnswers, 1);
      final empty = await reader.read(
        StoreReadQueries.answers(
          null,
          scope: 'different-selection',
          privateScope: true,
        ),
      );
      expect(empty.value, isEmpty);
      final selected = await reader.read(
        StoreReadQueries.answers(
          null,
          scope: 'selected-empty',
          privateScope: true,
        ),
      );
      expect(selected.value!.single.id, 1);
    },
  );

  test(
    'invalid projection returns a structured error and worker remains usable',
    () async {
      final reader = SqliteStoreReader.open(
        path,
        profile: 'fixture',
        connection: 'first',
      );
      addTearDown(reader.close);
      final invalid = await reader.read(fixture('raw SQL is not a projection'));
      expect(invalid.error!.code, RpcErrorCode.invalidArgument);
      expect((await reader.read(StoreReadQueries.sources())).current, isTrue);
    },
  );

  test('immutable DTO copies nested rows and preserves binary type', () {
    final bytes = Uint8List.fromList([1, 2]);
    final nested = <String, Object?>{
      'list': <String>['old'],
      'bytes': bytes,
    };
    final source = SourceDocument.fromRow({
      'id': 'source',
      'content': 'body',
      'extra': nested,
    });
    bytes[0] = 9;
    (nested['list'] as List<String>).add('new');
    final extra = source.toRow()['extra'] as Map<String, Object?>;
    expect(extra['list'], ['old']);
    expect(extra['bytes'], isA<Uint8List>());
    expect(extra['bytes'], [1, 2]);
    expect(() => (extra['bytes'] as Uint8List)[0] = 3, throwsUnsupportedError);
    expect(() => (extra['list'] as List).add('new'), throwsUnsupportedError);
    expect(() => extra['replacement'] = 1, throwsUnsupportedError);
  });
}
