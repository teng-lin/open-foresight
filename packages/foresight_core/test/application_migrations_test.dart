import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String path;
  setUp(() {
    root = createTestTempDirectorySync('application-migrations-');
    path = '${root.path}/application.db';
    addTearDown(() => root.deleteSync(recursive: true));
  });
  Database schema15() {
    final db = sqlite3.open(path);
    db.execute(
      File(
        'test/fixtures/persistence-c28a1561/schema15.sql',
      ).readAsStringSync(),
    );
    db.execute(
      "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES('source','Title','body','text/plain',7,'ready','drive')",
    );
    db.execute(
      "INSERT INTO source_details(source_id,imported,changed,source_uri) VALUES('source',11,22,'https://example.test')",
    );
    db.execute(
      "INSERT INTO google_sources VALUES('source','account','file','2020-01-02T03:04:05Z','text/plain')",
    );
    return db;
  }

  test(
    'Google repair is a one-time schema transition without constructor writes',
    () {
      schema15().dispose();
      final first = Store(path);
      final expected = DateTime.parse(
        '2020-01-02T03:04:05Z',
      ).millisecondsSinceEpoch;
      expect(
        first.rows('SELECT changed FROM source_details').single['changed'],
        expected,
      );
      expect(first.rows('SELECT revision,content FROM sources').single, {
        'revision': 7,
        'content': 'body',
      });
      first.db.execute('UPDATE source_details SET changed=99');
      first.close();
      final reopened = Store(path);
      expect(
        reopened.rows('SELECT changed FROM source_details').single['changed'],
        99,
      );
      reopened.close();
    },
  );
  test('Google repair rollback retains version and allows a later retry', () {
    final db = schema15();
    db.execute(
      "CREATE TRIGGER fail_repair BEFORE UPDATE ON source_details BEGIN SELECT RAISE(ABORT,'fixture rollback'); END",
    );
    db.dispose();
    expect(() => Store(path), throwsA(isA<SqliteException>()));
    final failed = sqlite3.open(path);
    expect(failed.select('PRAGMA user_version').single.values.single, 15);
    expect(
      failed.select('SELECT changed FROM source_details').single['changed'],
      22,
    );
    failed.execute('DROP TRIGGER fail_repair');
    failed.dispose();
    final retried = Store(path);
    expect(
      retried.db.select('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    retried.close();
  });

  Database schema21() {
    final db = schema15();
    db.execute(
      "INSERT INTO meetings(id,title,state,revision) VALUES(42,'Legacy capture','completed',1)",
    );
    db.execute(
      "INSERT INTO transcript(meeting_id,text,final,start_ms,end_ms,source) VALUES(42,'retained speech',1,10,20,'playback')",
    );
    db.execute(
      "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES('meeting-42','Transcript','[Remote 10–20 ms] retained speech','text/plain',3,'indexed','meeting:42')",
    );
    final migrations = ApplicationMigrations(db);
    for (var version = 16; version <= 21; version++) {
      migrations.run(version);
    }
    db.execute('PRAGMA user_version=21');
    return db;
  }

  test(
    'v22 preserves legacy transcript bodies and adds projection without rewriting history',
    () {
      schema21().dispose();
      final store = Store(path);
      try {
        expect(
          store.sourceQueries.source('meeting-42')!.content,
          '[Remote 10–20 ms] retained speech',
        );
        expect(store.rows('SELECT * FROM meeting_transcript_sources').single, {
          'source_id': 'meeting-42',
          'meeting_id': 42,
        });
        expect(store.rows('SELECT * FROM meeting_index_segments'), isEmpty);
        expect(
          store.contentHistory.revisions('sources', 'meeting-42'),
          isEmpty,
        );
        expect(store.rows('PRAGMA user_version').single.values.single, 22);
        expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        store.close();
      }
    },
  );

  test(
    'v22 failure rolls back its complete DDL and retries from untouched v21',
    () {
      final db = schema21();
      // Fail after earlier v22 CREATE statements, rather than before migration.
      db.execute('CREATE TABLE meeting_index_segments(collision INTEGER)');
      db.dispose();
      expect(() => Store(path), throwsA(isA<SqliteException>()));
      final failed = sqlite3.open(path);
      expect(failed.select('PRAGMA user_version').single.values.single, 21);
      expect(
        failed.select(
          "SELECT name FROM sqlite_master WHERE name IN ('meeting_index_progress','meeting_transcript_sources','source_contents')",
        ),
        isEmpty,
      );
      expect(
        failed
            .select("SELECT content FROM sources WHERE id='meeting-42'")
            .single['content'],
        '[Remote 10–20 ms] retained speech',
      );
      failed.execute('DROP TABLE meeting_index_segments');
      failed.dispose();
      final retried = Store(path);
      try {
        expect(retried.rows('PRAGMA user_version').single.values.single, 22);
        expect(
          retried.sourceQueries.source('meeting-42')!.content,
          '[Remote 10–20 ms] retained speech',
        );
      } finally {
        retried.close();
      }
    },
  );
}
