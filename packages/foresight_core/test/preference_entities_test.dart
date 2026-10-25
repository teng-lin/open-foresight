import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

import 'package:foresight_core/src/persistence/preference_entities.dart';
import 'package:foresight_core/src/persistence/migration_backups.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/persistence_fixtures.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'sql_support_test_bootstrap.dart';

Database historical([String? path]) {
  final db = path == null
      ? sqlite3.openInMemory()
      : openApplicationDatabase(path);
  db.execute('PRAGMA foreign_keys=ON');
  db.execute(
    File('test/fixtures/persistence-c28a1561/schema15.sql').readAsStringSync(),
  );
  for (var version = 16; version <= 22; version++) {
    ApplicationMigrations(db).run(version);
  }
  db.execute("INSERT INTO meetings(id,title,state) VALUES(7,'Meeting','idle')");
  db.execute(
    "INSERT INTO answers(id,question,body,status,citations,model,created) VALUES(9,'Question','Answer','completed','[]','model',0)",
  );
  for (final id in ['a', 'b']) {
    db.execute(
      "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES(?,?,'','text/plain',1,'indexed','test')",
      [id, id],
    );
  }
  return db;
}

void preference(Database db, String key, Object value) =>
    db.execute('INSERT INTO preferences(key,value) VALUES(?,?)', [key, value]);

void main() {
  bootstrapSqlSupportFixture();
  late Database db;
  setUp(() {
    db = historical();
  });
  tearDown(() => db.dispose());

  test(
    'v23 preserves scopes, flags, ordered duplicates and explicit empty selection',
    () {
      final values = <String, String>{
        'answerScope.v1.9': 'private-scope',
        'webAnswer.v1.9': 'true',
        'answerScope.meeting:7': 'selected',
        'proactiveScope.7': 'workspace',
        'answerSources.meeting:7': '["b","a","b"]',
        'answerSourcesSelection.7': '[]',
        'preparationSources.7': '["a"]',
      };
      values.forEach((key, value) => preference(db, key, value));
      preference(db, 'updateNoticeEnabled', 'false');
      preference(db, 'workspaceEpoch', 'retained');
      ApplicationMigrations(db).run(23);
      final entities = PreferenceEntities(db);
      values.forEach((key, value) => expect(entities.read(key), value));
      expect(
        db.select('SELECT key FROM preferences').map((r) => r['key']),
        containsAll(['updateNoticeEnabled', 'workspaceEpoch']),
      );
      expect(
        db.select('SELECT key FROM preferences WHERE key LIKE ?', ['answer%']),
        isEmpty,
      );
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'invalid and orphan legacy values survive migration then expire with erasure debt',
    () {
      preference(db, 'preparationSources.7', 'not-json');
      preference(db, 'answerScope.v1.999', 'orphan-private');
      preference(db, 'answerSources.chat', '["missing"]');
      ApplicationMigrations(db).run(23);
      final entities = PreferenceEntities(db);
      expect(entities.read('preparationSources.7'), 'not-json');
      expect(entities.read('answerScope.v1.999'), 'orphan-private');
      expect(
        db
            .select('SELECT reason FROM legacy_preference_entities')
            .map((r) => r['reason']),
        containsAll([
          'invalid_source_selection',
          'orphan_answer',
          'missing_selected_source',
        ]),
      );
      db.execute('DELETE FROM meetings WHERE id=7');
      expect(entities.read('preparationSources.7'), isNull);
      expect(entities.read('answerScope.v1.999'), 'orphan-private');
      db.execute('UPDATE legacy_preference_entities SET created=0');
      expect(entities.read('answerScope.v1.999'), isNull);
      expect(entities.pruneLegacy(), isFalse);
      expect(db.select('SELECT * FROM legacy_preference_entities'), isEmpty);
      expect(
        db
            .select(
              "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
            )
            .single['value'],
        '1',
      );
    },
  );

  test(
    'live answer and meeting deletion cascade typed and malformed owned rows',
    () {
      preference(db, 'webAnswer.v1.9', 'invalid');
      preference(db, 'answerScope.v1.9', 'scope');
      preference(db, 'answerSourcesSelection.7', 'invalid');
      preference(db, 'answerSources.meeting:7', '["a","b"]');
      ApplicationMigrations(db).run(23);
      db.execute('DELETE FROM answers WHERE id=9');
      db.execute('DELETE FROM meetings WHERE id=7');
      for (final table in [
        'answer_metadata',
        'legacy_preference_entities',
        'source_selections',
        'source_selection_items',
      ]) {
        expect(db.select('SELECT * FROM $table'), isEmpty, reason: table);
      }
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'quarantine replacement stays atomic on storage failure and outer rollback',
    () {
      ApplicationMigrations(db).run(23);
      final entities = PreferenceEntities(db);
      expect(
        entities.write('answerSources.chat', jsonEncode(['b', 'a'])),
        isTrue,
      );
      db.execute(
        "CREATE TRIGGER reject_quarantine BEFORE INSERT ON legacy_preference_entities BEGIN SELECT RAISE(ABORT,'storage failure'); END",
      );
      expect(
        () => entities.write('answerSources.chat', '["a","missing"]'),
        throwsA(isA<SqliteException>()),
      );
      db.execute('DROP TRIGGER reject_quarantine');
      expect(entities.read('answerSources.chat'), '["b","a"]');
      db.execute('BEGIN');
      entities.write('answerSources.chat', '["a","missing"]');
      expect(entities.read('answerSources.chat'), '["a","missing"]');
      expect(db.select('SELECT * FROM source_selection_items'), isEmpty);
      expect(
        db
            .select('SELECT reason FROM legacy_preference_entities')
            .single['reason'],
        'missing_selected_source',
      );
      db.execute('ROLLBACK');
      expect(entities.read('answerSources.chat'), '["b","a"]');
      db.execute("DELETE FROM sources WHERE id='b'");
      expect(entities.read('answerSources.chat'), '["a"]');
      expect(entities.write('updateNoticeEnabled', 'true'), isFalse);
      expect(entities.read('updateNoticeEnabled'), isNull);
    },
  );

  test(
    'migration interruption rolls back moved rows and DDL with caller transaction',
    () {
      preference(db, 'answerScope.v1.9', 'scope');
      db.execute(
        "CREATE TRIGGER interrupt_entity_migration BEFORE DELETE ON preferences BEGIN SELECT RAISE(ABORT,'interrupted'); END",
      );
      db.execute('BEGIN IMMEDIATE');
      expect(
        () => ApplicationMigrations(db).run(23),
        throwsA(isA<SqliteException>()),
      );
      db.execute('ROLLBACK');
      expect(
        db
            .select(
              "SELECT value FROM preferences WHERE key='answerScope.v1.9'",
            )
            .single['value'],
        'scope',
      );
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE name='answer_metadata'",
        ),
        isEmpty,
      );
    },
  );
  test(
    'bounded quarantine pruning preserves recent rows and empties expired backlog',
    () {
      ApplicationMigrations(db).run(23);
      for (var id = 0; id < 260; id++) {
        db.execute(
          "INSERT INTO legacy_preference_entities(key,value,reason,created) VALUES(?,'private','orphan_answer',0)",
          ['webAnswer.v1.${1000 + id}'],
        );
      }
      db.execute(
        "INSERT INTO legacy_preference_entities(key,value,reason,created) VALUES('webAnswer.v1.999','recent','orphan_answer',?)",
        [DateTime.now().millisecondsSinceEpoch],
      );
      final entities = PreferenceEntities(db);
      expect(entities.pruneLegacy(), isTrue);
      expect(
        db
            .select('SELECT COUNT(*) AS n FROM legacy_preference_entities')
            .single['n'],
        5,
      );
      expect(entities.pruneLegacy(), isFalse);
      expect(
        db
            .select('SELECT COUNT(*) AS n FROM legacy_preference_entities')
            .single['n'],
        1,
      );
      expect(entities.read('webAnswer.v1.999'), 'recent');
    },
  );

  test(
    'verified v22 backup restores legacy values and remigrates ordered entities',
    () {
      final directory = createTestTempDirectorySync('entity-restore-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/application.db';
      final source = historical(path);
      preference(source, 'answerSources.meeting:7', '["b","a"]');
      preference(source, 'preparationSources.7', 'malformed-private');
      preference(source, 'updateNoticeEnabled', 'false');
      source.execute('PRAGMA user_version=22');
      final backups = MigrationBackups(path);
      final snapshot = backups.create(source, 22);
      source.execute('BEGIN IMMEDIATE');
      ApplicationMigrations(source).run(23);
      source.execute('PRAGMA user_version=23');
      source.execute('COMMIT');
      source.dispose();
      final restored = backups.restoreCopy(
        snapshot.name,
        supportedVersion: 23,
        confirmDataLoss: true,
      );
      final restoredDb = openApplicationDatabase(restored);
      try {
        restoredDb.execute('PRAGMA foreign_keys=ON');
        expect(
          restoredDb.select('PRAGMA user_version').single.values.single,
          22,
        );
        expect(
          restoredDb
              .select(
                "SELECT value FROM preferences WHERE key='preparationSources.7'",
              )
              .single['value'],
          'malformed-private',
        );
        restoredDb.execute('BEGIN IMMEDIATE');
        ApplicationMigrations(restoredDb).run(23);
        restoredDb.execute('PRAGMA user_version=23');
        restoredDb.execute('COMMIT');
        expect(
          PreferenceEntities(restoredDb).read('answerSources.meeting:7'),
          '["b","a"]',
        );
        expect(
          PreferenceEntities(restoredDb).read('preparationSources.7'),
          'malformed-private',
        );
        expect(
          restoredDb
              .select(
                "SELECT value FROM preferences WHERE key='updateNoticeEnabled'",
              )
              .single['value'],
          'false',
        );
        restoredDb.execute('DELETE FROM meetings WHERE id=7');
        expect(
          PreferenceEntities(restoredDb).read('preparationSources.7'),
          isNull,
        );
        expect(
          restoredDb
              .select(
                "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
              )
              .single['value'],
          '1',
        );
        backups.erase();
        expect(backups.snapshots(supportedVersion: 23), isEmpty);
        expect(File(restored).existsSync(), isFalse);
      } finally {
        restoredDb.dispose();
      }
    },
  );
  test(
    'historical fixture reconstructs legacy shape without dropping entity values',
    () {
      preference(db, 'preparationSources.7', 'invalid-private');
      ApplicationMigrations(db).run(23);
      final entities = PreferenceEntities(db);
      entities.write('answerScope.v1.9', 'private-scope');
      entities.write('webAnswer.v1.9', 'false');
      entities.write('answerSources.meeting:7', '["b","a","b"]');
      entities.write('answerSourcesSelection.7', '[]');
      prePreferenceEntitiesFixture(db);
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE name='answer_metadata'",
        ),
        isEmpty,
      );
      expect(
        db
            .select(
              "SELECT value FROM preferences WHERE key='answerSources.meeting:7'",
            )
            .single['value'],
        '["b","a","b"]',
      );
      expect(
        db
            .select("SELECT value FROM preferences WHERE key='webAnswer.v1.9'")
            .single['value'],
        'false',
      );
      ApplicationMigrations(db).run(23);
      expect(entities.read('answerScope.v1.9'), 'private-scope');
      expect(entities.read('answerSources.meeting:7'), '["b","a","b"]');
      expect(entities.read('answerSourcesSelection.7'), '[]');
      expect(entities.read('preparationSources.7'), 'invalid-private');
    },
  );
  test('reused parent IDs cannot inherit or re-expose orphan quarantine', () {
    preference(db, 'proactiveScope.8', 'selected');
    preference(db, 'preparationSources.8', '["a"]');
    preference(db, 'webAnswer.v1.999', 'true');
    ApplicationMigrations(db).run(23);
    final entities = PreferenceEntities(db);
    expect(entities.read('proactiveScope.8'), 'selected');
    expect(entities.read('webAnswer.v1.999'), 'true');
    db.execute(
      "INSERT INTO meetings(id,title,state) VALUES(8,'New owner','idle')",
    );
    db.execute(
      "INSERT INTO answers(id,question,body,status,citations,model,created) VALUES(999,'New question','New answer','completed','[]','model',0)",
    );
    expect(entities.read('proactiveScope.8'), isNull);
    expect(entities.read('preparationSources.8'), isNull);
    expect(entities.read('webAnswer.v1.999'), isNull);
    expect(db.select('SELECT * FROM legacy_preference_entities'), isEmpty);
    expect(
      db
          .select(
            "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
          )
          .single['value'],
      '1',
    );
    expect(entities.write('proactiveScope.8', 'workspace'), isTrue);
    expect(entities.write('webAnswer.v1.999', 'false'), isTrue);
    db.execute('DELETE FROM meetings WHERE id=8');
    db.execute('DELETE FROM answers WHERE id=999');
    expect(entities.read('proactiveScope.8'), isNull);
    expect(entities.read('webAnswer.v1.999'), isNull);
  });

  test(
    'compatibility quarantine keeps invalid inputs outside strict relations and owner reuse erases them',
    () {
      ApplicationMigrations(db).run(23);
      final entities = PreferenceEntities(db);
      expect(entities.write('answerScope.v1.999', 'private'), isTrue);
      expect(entities.write('proactiveScope.999', 'selected'), isTrue);
      expect(entities.read('answerScope.v1.999'), 'private');
      expect(entities.read('proactiveScope.999'), 'selected');
      entities.write('webAnswer.v1.9', 'true');
      entities.write('webAnswer.v1.9', 'invalid');
      expect(entities.read('webAnswer.v1.9'), 'invalid');
      expect(db.select('SELECT * FROM answer_metadata'), isEmpty);
      expect(db.select('SELECT * FROM proactive_scopes'), isEmpty);
      db.execute('DELETE FROM answers WHERE id=9');
      expect(entities.read('webAnswer.v1.9'), isNull);
      db.execute(
        "INSERT INTO answers(id,question,body,status,citations,model,created) VALUES(999,'New','New','completed','[]','model',0)",
      );
      db.execute(
        "INSERT INTO meetings(id,title,state) VALUES(999,'New','idle')",
      );
      expect(db.select('SELECT * FROM legacy_preference_entities'), isEmpty);
      expect(entities.read('answerScope.v1.999'), isNull);
      expect(entities.read('proactiveScope.999'), isNull);
      expect(
        db
            .select(
              "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
            )
            .single['value'],
        '1',
      );
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );
}
