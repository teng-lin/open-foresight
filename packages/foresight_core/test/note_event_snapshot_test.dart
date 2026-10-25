import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/persistence_fixtures.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late Store store;
  setUp(() {
    directory = createTestTempDirectorySync('note-event-snapshot-');
    store = Store('${directory.path}/notes.db');
  });
  setUp(() {
    addTearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });
  });
  void event(int meeting, String title) => store.db.execute(
    "INSERT INTO calendar_events(event_key,meeting_id,metadata,account,calendar_id,google_id,source_id,starts,ends,status,synced) VALUES(?,?,?,'fixture','fixture','fixture','fixture',0,0,'confirmed',0)",
    ['event', meeting, '{"summary":"$title"}'],
  );

  test('first raw save captures event title and later saves preserve it', () {
    final id = store.meeting('');
    event(id, 'Original event');
    store.saveMeetingNotes(id, 'First note');
    expect(store.db.lastInsertRowId, id);
    store.db.execute('UPDATE calendar_events SET metadata=?', [
      '{"summary":"Renamed event"}',
    ]);
    store.saveMeetingNotes(id, 'Edited note');
    expect(
      store.rows('SELECT title FROM meeting_note_events').single['title'],
      'Original event',
    );
    store.db.execute('DELETE FROM meeting_notes WHERE meeting_id=?', [id]);
    expect(store.rows('SELECT * FROM meeting_note_events'), isEmpty);
  });

  test(
    'enhanced-only first save captures name atomically and returns artifact row ID',
    () {
      store.meeting('Unrelated meeting');
      final id = store.meeting('');
      event(id, 'Captured enhancement event');
      store.db.execute(
        "CREATE TRIGGER reject_artifact BEFORE INSERT ON artifacts BEGIN SELECT RAISE(ABORT,'rejected'); END",
      );
      expect(
        () => store.artifact(id, 'enhanced_notes', 'Rejected', 'fixture'),
        throwsA(anything),
      );
      expect(store.rows('SELECT * FROM meeting_note_events'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_notes'), isEmpty);
      store.db.execute('DROP TRIGGER reject_artifact');
      store.artifact(id, 'enhanced_notes', 'Accepted', 'fixture');
      expect(store.db.lastInsertRowId, 1);
      expect(
        store.rows('SELECT title FROM meeting_note_events').single['title'],
        'Captured enhancement event',
      );
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test('migration does not invent historical association titles', () {
    final id = store.meeting('');
    store.saveMeetingNotes(id, 'Existing note');
    event(id, 'Only current title is known');
    store.db.execute('DROP TABLE meeting_note_events');
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=1');
    store.close();
    store = Store('${directory.path}/notes.db');
    expect(store.rows('SELECT * FROM meeting_note_events'), isEmpty);
    store.saveMeetingNotes(id, 'Existing note edited');
    expect(store.rows('SELECT * FROM meeting_note_events'), isEmpty);
  });
}
