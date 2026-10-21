import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
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
}
