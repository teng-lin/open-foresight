import 'dart:io';

import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/meeting_workflow_store.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Store store;
  late String path;
  setUp(() {
    path = '${createTestTempDirectorySync('history-').path}/application.db';
    store = Store(path);
    addTearDown(() => store.close());
  });

  test('note history survives reopen and can recover the previous text', () {
    final id = store.saveNote(null, 'first', 'trusted');
    store.saveNote(id, 'second', 'replaced');
    store.close();
    store = Store(path);
    final saved =
        store.contentHistory.revisions('notes', id).single['snapshot'] as Map;
    expect(saved['body'], 'trusted');
    store.saveNote(id, saved['title'] as String, saved['body'] as String);
    expect(store.notes().single['body'], 'trusted');
    expect(store.contentHistory.revisions('notes', id), hasLength(2));
  });

  test('schema 17 upgrades without changing existing content', () {
    store.close();
    path =
        '${createTestTempDirectorySync('history-upgrade-').path}/application.db';
    final db = sqlite3.open(path);
    db.execute(
      File(
        'test/fixtures/persistence-c28a1561/schema15.sql',
      ).readAsStringSync(),
    );
    final migrations = ApplicationMigrations(db);
    migrations.run(16);
    migrations.run(17);
    db.execute('PRAGMA user_version=17');
    db.execute(
      "INSERT INTO notes(id,title,body,revision) VALUES(42,'old title','old body',7)",
    );
    db.dispose();
    store = Store(path);
    expect(store.rows('PRAGMA user_version').single.values.single, 18);
    expect(store.notes().single['body'], 'old body');
    expect(store.contentHistory.revisions('notes', 42), isEmpty);
    store.saveNote(42, 'new title', 'new body');
    expect(
      store.contentHistory.revisions('notes', 42).single['snapshot'],
      containsPair('revision', 7),
    );
  });

  test('source history ignores indexing metadata and obeys soft deletion', () {
    final id = store.importText('first', 'trusted', 'text/plain', 'fixture');
    store.importText('second', 'replacement', 'text/plain', 'fixture', id: id);
    expect(
      store.contentHistory.revisions('sources', id).single['snapshot'],
      containsPair('content', 'trusted'),
    );
    store.db.execute("UPDATE sources SET state='ready' WHERE id=?", [id]);
    expect(store.contentHistory.revisions('sources', id), hasLength(1));
    store.db.execute('UPDATE sources SET deleted=1 WHERE id=?', [id]);
    expect(store.contentHistory.revisions('sources', id), isEmpty);
  });

  test('a failed transaction rolls back both replacement and history', () {
    final id = store.saveNote(null, 'first', 'trusted');
    expect(
      () => store.workflowTransaction(() {
        store.saveNote(id, 'second', 'discarded');
        throw StateError('abort fixture');
      }),
      throwsStateError,
    );
    expect(store.notes().single['body'], 'trusted');
    expect(store.contentHistory.revisions('notes', id), isEmpty);
  });

  test(
    'meeting notes, enhanced notes and repeated artifact edits retain previous values',
    () {
      final id = store.meeting('meeting');
      store.saveMeetingNotes(id, 'raw first');
      store.saveMeetingNotes(id, 'raw second');
      store.saveMeetingEnhancedDraft(id, 'enhanced first');
      store.saveMeetingEnhancedDraft(id, 'enhanced second');
      store.artifact(id, 'summary', 'generated', 'fixture');
      final artifact = store.db.lastInsertRowId;
      store.editArtifact(artifact, 'edit first');
      store.editArtifact(artifact, 'edit second');
      final notes = store.contentHistory
          .revisions('meeting_notes', id)
          .map((r) => r['snapshot'] as Map);
      expect(notes.any((r) => r['body'] == 'raw first'), isTrue);
      expect(notes.any((r) => r['enhanced_body'] == 'enhanced first'), isTrue);
      expect(
        store.contentHistory.revisions('artifacts', artifact).first['snapshot'],
        containsPair('edited', 'edit first'),
      );
    },
  );

  test('deletion and workspace clear erase retained history', () {
    final id = store.saveNote(null, 'first', 'trusted');
    store.saveNote(id, 'second', 'replaced');
    store.db.execute('DELETE FROM notes WHERE id=?', [id]);
    expect(store.contentHistory.revisions('notes', id), isEmpty);
    final next = store.saveNote(null, 'next', 'private');
    store.saveNote(next, 'next', 'other');
    WorkspacePersistence(store).clearLocalData([]);
    expect(store.rows('SELECT * FROM content_revisions'), isEmpty);
  });
}
