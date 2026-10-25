import 'sql_support_test_bootstrap.dart';
import 'dart:io';

import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/persistence/domain_queries.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

final class _RestoredRuntime extends NativeRuntime {
  _RestoredRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  String? restoredBackend;
  @override
  Future<void> load(
    String runtime,
    String model, {
    String backend = 'llama_cpp',
  }) async {
    restoredBackend = backend;
  }

  @override
  void close() {}
}

final class _RestoredDomain extends Domain {
  _RestoredDomain(super.store, super.helper, this.runtime);
  final _RestoredRuntime runtime;
  @override
  NativeRuntime createNoteEnhancementRuntime() => runtime;
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory scratch;
  late Store store;
  late DomainQueries queries;
  setUp(() {
    scratch = createTestTempDirectorySync('domain-queries-');
    store = Store('${scratch.path}/application.db');
    queries = DomainQueries(store);
    addTearDown(store.close);
  });

  String source(String id, {String? title}) => store.importText(
    title ?? id,
    'Content $id',
    'text/plain',
    'fixture',
    id: id,
  );

  test('helper delete acknowledgements preserve unacknowledged intent', () {
    store.db.execute(
      "INSERT INTO pending_helper_deletes(document_id,queued_at) VALUES('one',0),('two',0)",
    );
    expect(queries.pendingHelperDeletes(), ['one', 'two']);
    expect(queries.helperDeletePending('one'), isTrue);
    queries.acknowledgeHelperDelete('one');
    expect(queries.helperDeletePending('one'), isFalse);
    expect(queries.pendingHelperDeletes(), ['two']);
    expect(store.db.autocommit, isTrue);
  });

  test(
    'index results never overwrite a newer revision or resurrect a tombstone',
    () {
      source('one');
      final original = queries.activeSource('one')!;
      expect(original.content, 'Content one');
      expect(original.mime, 'text/plain');
      source('one', title: 'New revision');
      queries.sourceRevisionState('one', original.revision, 'indexed');
      expect(queries.activeSource('one')!.state, 'pending');
      final current = queries.activeSource('one')!;
      queries.sourceRevisionState(
        'one',
        current.revision,
        'failed',
        'real failure',
      );
      expect(queries.activeSource('one')!.error, 'real failure');
      store.tombstone('one');
      queries.sourceRevisionState('one', current.revision, 'indexed');
      expect(queries.activeSource('one'), isNull);
      expect(queries.unreconciledDeletes(), ['one']);
      queries.sourceState('one', 'deleted');
      expect(queries.unreconciledDeletes(), isEmpty);
    },
  );

  test(
    'setup retry changes only the historical pipeline failure and queues IDs by title',
    () {
      source('z', title: 'Zulu');
      source('a', title: 'Alpha');
      source('other', title: 'Other');
      source('deleted', title: 'Deleted');
      queries.sourceState('z', 'indexing');
      queries.sourceState(
        'a',
        'failed',
        'gRPC Error(code: 9, message: Pipeline not initialized)',
      );
      queries.sourceState('other', 'failed', 'unrelated failure');
      queries.sourceState(
        'deleted',
        'failed',
        'gRPC Error: Pipeline not initialized',
      );
      store.tombstone('deleted');
      queries.retryUnconfiguredSources();
      expect(queries.pendingSources(), ['a', 'z']);
      expect(queries.activeSource('a')!.error, isEmpty);
      expect(queries.activeSource('other')!.error, 'unrelated failure');
    },
  );

  test(
    'graph lookup and citations retain missing, tombstone and raw revision semantics',
    () {
      source('one');
      expect(queries.graphSourceContent('one'), 'Content one');
      expect(queries.citationCurrent('one', 1), isTrue);
      expect(queries.citationCurrent('one', 1.0), isTrue);
      expect(queries.citationCurrent('one', '1'), isFalse);
      expect(queries.citationCurrent('absent', 1), isFalse);
      expect(() => queries.graphSourceContent('absent'), throwsStateError);
      store.tombstone('one');
      expect(queries.citationCurrent('one', 1), isFalse);
      expect(() => queries.graphSourceContent('one'), throwsStateError);
    },
  );

  for (final fixture in [
    (backend: null, type: null, expectedType: 14, expectedBackend: 'llama_cpp'),
    (backend: null, type: 0, expectedType: 0, expectedBackend: 'llama_cpp'),
    (
      backend: 'litert_lm',
      type: 0,
      expectedType: 14,
      expectedBackend: 'litert_lm',
    ),
    (
      backend: 'litert_lm',
      type: 2,
      expectedType: 2,
      expectedBackend: 'litert_lm',
    ),
  ]) {
    test(
      'restore keeps nullable registration/fallback ${fixture.backend}/${fixture.type}',
      () async {
        // A narrowly scoped legacy-row fixture permits SQL nulls that modern DDL
        // defaults exclude. The adapter must not replace them with DTO defaults.
        store.db.execute('DROP TABLE models');
        store.db.execute(
          'CREATE TABLE models(kind TEXT PRIMARY KEY,path TEXT,digest TEXT,runtime TEXT,backend TEXT,model_type INTEGER)',
        );
        store.db.execute('INSERT INTO models VALUES(?,?,?,?,?,?)', [
          'generation',
          '/fixture/model',
          '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
          '/fixture/runner',
          fixture.backend,
          fixture.type,
        ]);
        final registration = queries.generationRegistration()!;
        expect(registration.backend, fixture.backend);
        if (fixture.type == null) expect(registration.modelType, isNull);
        expect(queries.hasModel('generation'), isTrue);
        expect(queries.hasModel('embedding'), isFalse);
        final helper = Helper(
          '${scratch.path}/helper.sock',
          '${scratch.path}/helper',
          manageProcess: false,
        );
        final runtime = _RestoredRuntime();
        final domain = _RestoredDomain(store, helper, runtime);
        try {
          expect(await domain.noteEnhancementService(), same(runtime));
          expect(runtime.modelType, fixture.expectedType);
          expect(runtime.restoredBackend, fixture.expectedBackend);
        } finally {
          domain.close();
          await helper.close();
        }
      },
    );
  }

  test(
    'startup captures only active states without changing meeting revisions',
    () {
      final ids = <String, int>{};
      for (final state in [
        'recording',
        'transcribing',
        'paused',
        'idle',
        'completed',
        'interrupted',
      ]) {
        final id = store.meeting(state);
        ids[state] = id;
        store.db.execute('UPDATE meetings SET state=? WHERE id=?', [state, id]);
      }
      expect(store.meetingStore.interruptActiveCaptures(), [
        ids['recording'],
        ids['transcribing'],
        ids['paused'],
      ]);
      expect(store.meetingStore.interruptActiveCaptures(), isEmpty);
      final rows = store.rows(
        'SELECT title,state,revision FROM meetings ORDER BY id',
      );
      expect(rows.map((row) => row['state']), [
        'interrupted',
        'interrupted',
        'interrupted',
        'idle',
        'completed',
        'interrupted',
      ]);
      expect(rows.map((row) => row['revision']).toSet(), {0});
    },
  );

  test(
    'future schema retires every domain read/write before changed-table SQL',
    () {
      source('one');
      store.db.execute(
        "INSERT INTO pending_helper_deletes(document_id,queued_at) VALUES('one',0)",
      );
      store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
      store.db.execute('ALTER TABLE sources RENAME TO future_sources');
      store.db.execute('ALTER TABLE models RENAME TO future_models');
      store.db.execute('ALTER TABLE meetings RENAME TO future_meetings');
      for (final operation in <Object? Function()>[
        queries.pendingHelperDeletes,
        () => queries.helperDeletePending('one'),
        () => queries.acknowledgeHelperDelete('one'),
        () => queries.graphSourceContent('one'),
        () => queries.activeSource('one'),
        () => queries.sourceState('one', 'indexed'),
        () => queries.sourceRevisionState('one', 1, 'indexed'),
        queries.unreconciledDeletes,
        queries.retryUnconfiguredSources,
        queries.pendingSources,
        () => queries.hasModel('generation'),
        queries.generationRegistration,
        queries.embeddingRegistration,
        () => queries.citationCurrent('one', 1),
        store.meetingStore.interruptActiveCaptures,
      ]) {
        expect(operation, throwsA(isA<IncompatibleReadSchema>()));
        expect(store.db.autocommit, isTrue);
      }
      expect(
        store.db
            .select('SELECT document_id FROM pending_helper_deletes')
            .single['document_id'],
        'one',
      );
      expect(
        store.db.select('SELECT state FROM future_sources').single['state'],
        'pending',
      );
    },
  );
}
