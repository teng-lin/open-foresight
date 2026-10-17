import 'dart:io';

import 'package:foresight_core/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('foresight-migration-');
    path = '${directory.path}/application.db';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('Store owns Google tables before a connection exists', () {
    final store = Store(path);
    addTearDown(store.close);
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    for (final table in [
      'google_sources',
      'calendar_events',
      'google_folders',
    ]) {
      expect(
        store.rows('SELECT name FROM sqlite_master WHERE name=?', [table]),
        hasLength(1),
      );
    }
    expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
  });

  test('newer schemas are refused without modifying the database', () {
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE future(value TEXT)');
    db.execute('INSERT INTO future VALUES(?)', ['future data']);
    db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    db.dispose();
    final bytes = File(path).readAsBytesSync();
    expect(() => Store(path), throwsStateError);
    expect(() => Store.readOnly(path), throwsStateError);
    expect(File(path).readAsBytesSync(), bytes);
    expect(File('$path-wal').existsSync(), isFalse);
    expect(File('$path-shm').existsSync(), isFalse);
  });

  test('legacy version one migrates in order and preserves stored data', () {
    // A genuine old baseline, before source-details and Google tables existed.
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE sources(id TEXT PRIMARY KEY,title TEXT NOT NULL,
        content TEXT NOT NULL,mime TEXT NOT NULL,revision INTEGER NOT NULL,
        state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',
        deleted INTEGER NOT NULL DEFAULT 0,provenance TEXT NOT NULL);
      INSERT INTO sources VALUES('legacy','Title','Body','text/plain',1,
        'imported','',0,'url:https://example.com/original');
      PRAGMA user_version=1;
    ''');
    db.dispose();
    var store = Store(path);
    expect(store.sources.single['content'], 'Body');
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    store.close();
    store = Store(path);
    addTearDown(store.close);
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(store.rows('SELECT total_changes() AS n').single['n'], 0);
  });

  test('failure after migration DDL rolls back schema, data and version', () {
    var store = Store(path);
    final id = store.importText(
      'Title',
      'Body',
      'text/plain',
      'url:https://example.com/original',
    );
    store.db.execute('ALTER TABLE source_details DROP COLUMN source_uri');
    store.db.execute('PRAGMA user_version=4');
    // Simulate interruption after ADD COLUMN but during its data backfill.
    store.db.execute('''CREATE TRIGGER interrupt_migration
      BEFORE UPDATE ON source_details BEGIN
        SELECT RAISE(ABORT, 'interrupted migration');
      END''');
    store.close();
    expect(() => Store(path), throwsA(isA<SqliteException>()));
    final db = sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 4);
    expect(
      db.select('PRAGMA table_info(source_details)').map((row) => row['name']),
      isNot(contains('source_uri')),
    );
    expect(
      db.select('SELECT content FROM sources WHERE id=?', [
        id,
      ]).single['content'],
      'Body',
    );
    db.execute('DROP TRIGGER interrupt_migration');
    db.dispose();
    store = Store(path);
    addTearDown(store.close);
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
  });

  test('legacy malformed labels repair once without repeating writes', () {
    var store = Store(path);
    final id = store.importText('Title', 'Body', 'text/plain', 'fixture');
    store.db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
      'invalid JSON',
      id,
    ]);
    store.db.execute('PRAGMA user_version=8');
    store.close();
    store = Store(path);
    expect(store.sources.single['labels'], '[]');
    store.close();
    store = Store(path);
    addTearDown(store.close);
    expect(store.rows('SELECT total_changes() AS n').single['n'], 0);
  });
}
