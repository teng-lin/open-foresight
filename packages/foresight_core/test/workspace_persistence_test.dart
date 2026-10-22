import 'dart:io';

import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Store store;
  late WorkspacePersistence persistence;

  setUp(() {
    directory = createTestTempDirectorySync('workspace-persistence-');
    store = Store('${directory.path}/app.db');
    persistence = WorkspacePersistence(store);
    addTearDown(() {
      store.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
  });

  test(
    'clear commits content, scoped privacy state and helper purge debt together',
    () {
      final source = store.importText(
        'Private source',
        'Private body',
        'text/plain',
        'fixture',
      );
      final meeting = store.meeting('Private meeting');
      store.saveMeetingNotes(meeting, 'Private notes');
      store.artifact(meeting, 'summary', 'Private summary', 'fixture');
      store.db.execute('INSERT INTO request_keys VALUES(?,?,?,?,?)', [
        'saved-key',
        'meetings.create',
        'fingerprint',
        '{"id":1}',
        1,
      ]);
      for (final key in [
        'webAnswer.v1.1',
        'answerScope.v1.1',
        'answerSources.meeting:1',
        'answerSourcesSelection.meeting:1',
        'proactiveScope.1',
        'preparationSources.1',
      ]) {
        store.setPreference(key, 'private');
      }
      store.setPreference('liveEnhance', 'false');
      final epoch = store.workspaceEpoch;
      final result = persistence.clearLocalData(persistence.sourceIds);

      expect(result.sourceIds, [source]);
      expect(result.epoch, isNot(epoch));
      expect(store.workspaceEpoch, result.epoch);
      for (final table in workspaceContentTables) {
        expect(
          store.rows('SELECT count(*) AS n FROM $table').single['n'],
          0,
          reason: table,
        );
      }
      expect(
        store
            .rows('SELECT document_id FROM pending_helper_deletes')
            .single['document_id'],
        source,
      );
      expect(store.preference('liveEnhance'), 'false');
      expect(
        store.rows("SELECT value FROM preferences WHERE value='private'"),
        isEmpty,
      );
      expect(store.preference('internal.privacyMaintenancePending'), '1');
      expect(() => result.sourceIds.clear(), throwsUnsupportedError);
      // A restart between commit and compaction must retain the cleanup intent.
      store.close();
      store = Store('${directory.path}/app.db');
      expect(store.privacyMaintenancePending, isTrue);
      expect(store.rows('SELECT * FROM pending_helper_deletes'), hasLength(1));
    },
  );

  test('a late delete failure rolls back content, epoch and purge debt', () {
    final source = store.importText(
      'Keep source',
      'Keep body',
      'text/plain',
      'fixture',
    );
    store.db.execute('INSERT INTO request_keys VALUES(?,?,?,?,?)', [
      'saved-key',
      'meetings.create',
      'fingerprint',
      '{"id":1}',
      1,
    ]);
    store.setPreference('answerScope.v1.1', 'selected-empty');
    final epoch = store.workspaceEpoch;
    store.db.execute(
      "CREATE TRIGGER fail_last_clear BEFORE DELETE ON request_keys BEGIN SELECT RAISE(ABORT,'blocked privacy transaction'); END",
    );

    expect(
      () => persistence.clearLocalData(persistence.sourceIds),
      throwsA(anything),
    );
    expect(store.sources.single['id'], source);
    expect(store.sources.single['content'], 'Keep body');
    expect(store.workspaceEpoch, epoch);
    expect(store.rows('SELECT * FROM pending_helper_deletes'), isEmpty);
    expect(store.preference('answerScope.v1.1'), 'selected-empty');
    expect(store.rows('SELECT * FROM request_keys'), hasLength(1));
    expect(store.privacyMaintenancePending, isFalse);

    store.db.execute('DROP TRIGGER fail_last_clear');
    expect(
      persistence.clearLocalData(persistence.sourceIds).epoch,
      isNot(epoch),
    );
    expect(store.sources, isEmpty);
  });

  test('commit failure rolls back the durable privacy marker and epoch', () {
    final source = store.importText(
      'Keep',
      'Keep body',
      'text/plain',
      'fixture',
    );
    store.db.execute('INSERT INTO request_keys VALUES(?,?,?,?,?)', [
      'saved-key',
      'meetings.create',
      'fingerprint',
      '{"id":1}',
      1,
    ]);
    store.db.execute(
      'CREATE TABLE external_key_reference(key TEXT REFERENCES request_keys(key) DEFERRABLE INITIALLY DEFERRED)',
    );
    store.db.execute("INSERT INTO external_key_reference VALUES('saved-key')");
    final epoch = store.workspaceEpoch;
    expect(
      () => persistence.clearLocalData(persistence.sourceIds),
      throwsA(anything),
    );
    expect(store.db.autocommit, isTrue);
    expect(store.workspaceEpoch, epoch);
    expect(store.sources.single['id'], source);
    expect(store.rows('SELECT * FROM pending_helper_deletes'), isEmpty);
    expect(store.preference('internal.privacyMaintenancePending'), isEmpty);
    expect(store.rows('SELECT * FROM request_keys'), hasLength(1));
  });
}
