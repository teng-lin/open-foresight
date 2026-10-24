import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Store store;
  setUp(() {
    directory = createTestTempDirectorySync('foresight-note-time-');
    store = Store('${directory.path}/app.db');
  });
  setUp(() {
    addTearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  int meetingTimestamp(int id) =>
      store.rows('SELECT timestamp FROM meeting_notes WHERE meeting_id=?', [
            id,
          ]).single['timestamp']
          as int;

  test(
    'legacy migration preserves unknown times and fills them on accepted saves',
    () {
      store.close();
      final path = '${directory.path}/legacy.db';
      final legacy = sqlite3.open(path);
      legacy.execute('''
      PRAGMA user_version=1;
      CREATE TABLE notes(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1);
      CREATE TABLE meetings(id INTEGER PRIMARY KEY,title TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL);
      CREATE TABLE meeting_details(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id),created INTEGER NOT NULL,reminder INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE meeting_notes(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,body TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 0);
      INSERT INTO notes VALUES(7,'Legacy standalone','Keep original body',4);
      INSERT INTO meetings VALUES(9,'Legacy meeting',2,'idle');
      INSERT INTO meeting_details VALUES(9,17,0);
      INSERT INTO meeting_notes VALUES(9,'Keep shorthand',3);
    ''');
      legacy.dispose();
      store = Store(path);
      expect(store.rows('SELECT * FROM notes').single, {
        'id': 7,
        'title': 'Legacy standalone',
        'body': 'Keep original body',
        'revision': 4,
        'timestamp': null,
      });
      expect(store.rows('SELECT * FROM meeting_notes').single, {
        'meeting_id': 9,
        'body': 'Keep shorthand',
        'revision': 3,
        'timestamp': null,
        'last_enhanced': null,
        'last_manual_edit': null,
        'enhanced_body': null,
        'enhanced_generated': 1,
      });
      store.close();
      store = Store(path);
      expect(
        store.rows('SELECT timestamp FROM notes').single['timestamp'],
        isNull,
      );
      expect(
        store.rows('SELECT timestamp FROM meeting_notes').single['timestamp'],
        isNull,
      );
      final before = DateTime.now().millisecondsSinceEpoch;
      store.saveNote(7, 'Legacy standalone', 'Edited body');
      store.saveMeetingNotes(9, 'Edited shorthand');
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(
        store.rows('SELECT timestamp FROM notes').single['timestamp'],
        inInclusiveRange(before, after),
      );
      expect(meetingTimestamp(9), inInclusiveRange(before, after));
      expect(
        store.rows('SELECT created FROM meeting_details').single['created'],
        17,
      );
    },
  );

  test(
    'accepted standalone and meeting saves refresh time independently of creation',
    () {
      final before = DateTime.now().millisecondsSinceEpoch;
      store.saveNote(null, 'Standalone', 'Original');
      final note = store.rows('SELECT * FROM notes').single;
      final id = store.meeting('Meeting');
      store.db.execute(
        'UPDATE meeting_details SET created=17 WHERE meeting_id=?',
        [id],
      );
      store.saveMeetingNotes(id, 'Original shorthand');
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(note['timestamp'], inInclusiveRange(before, after));
      expect(meetingTimestamp(id), inInclusiveRange(before, after));

      store.db.execute('UPDATE notes SET timestamp=1');
      store.db.execute('UPDATE meeting_notes SET timestamp=1');
      final nextBefore = DateTime.now().millisecondsSinceEpoch;
      // These are accepted writes; UI flush/staleness guards are a separate layer.
      store.saveNote(note['id'] as int, 'Standalone', 'Original');
      store.saveMeetingNotes(id, 'Revised shorthand');
      final nextAfter = DateTime.now().millisecondsSinceEpoch;
      expect(
        store.rows('SELECT timestamp FROM notes').single['timestamp'],
        inInclusiveRange(nextBefore, nextAfter),
      );
      expect(meetingTimestamp(id), inInclusiveRange(nextBefore, nextAfter));
      expect(store.rows('SELECT revision FROM notes').single['revision'], 2);
      expect(
        store.rows('SELECT revision FROM meeting_notes').single['revision'],
        2,
      );
      expect(
        store.rows('SELECT created FROM meeting_details').single['created'],
        17,
      );
      final saved = meetingTimestamp(id);
      store.close();
      store = Store('${directory.path}/app.db');
      expect(meetingTimestamp(id), saved);
    },
  );

  test(
    'current enhancement saves refresh time without promoting historical edits or summaries',
    () {
      final id = store.meeting('Meeting');
      store.saveMeetingNotes(id, 'Raw shorthand');
      store.db.execute('UPDATE meeting_notes SET timestamp=1');
      store.artifact(id, 'summary', 'Summary', 'fixture');
      final summary = store.db.lastInsertRowId;
      expect(meetingTimestamp(id), 1);
      final before = DateTime.now().millisecondsSinceEpoch;
      store.artifact(id, 'enhanced_notes', 'First enhancement', 'fixture');
      final first = store.db.lastInsertRowId;
      expect(
        meetingTimestamp(id),
        inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
      );
      store.artifact(id, 'enhanced_notes', 'Current enhancement', 'fixture');
      final current = store.db.lastInsertRowId;
      store.db.execute('UPDATE meeting_notes SET timestamp=2');
      store.editArtifact(first, 'Historical edit');
      store.editArtifact(summary, 'Summary edit');
      expect(meetingTimestamp(id), 2);
      final editedBefore = DateTime.now().millisecondsSinceEpoch;
      store.editArtifact(current, 'Current edit');
      expect(
        meetingTimestamp(id),
        inInclusiveRange(editedBefore, DateTime.now().millisecondsSinceEpoch),
      );
      expect(store.rows('SELECT body,revision FROM meeting_notes').single, {
        'body': 'Raw shorthand',
        'revision': 1,
      });
    },
  );

  test('enhanced-only saves allocate a note with a known timestamp', () {
    store.meeting('Other');
    final id = store.meeting('Enhanced only');
    final before = DateTime.now().millisecondsSinceEpoch;
    store.artifact(
      id,
      'enhanced_notes',
      'Enhanced without shorthand',
      'fixture',
    );
    expect(
      store.db.lastInsertRowId,
      store.rows('SELECT id FROM artifacts').single['id'],
    );
    expect(
      meetingTimestamp(id),
      inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
    );
    expect(store.rows('SELECT body,revision FROM meeting_notes').single, {
      'body': '',
      'revision': 0,
    });
  });

  test('failed enhancement writes roll back timestamp and content together', () {
    final id = store.meeting('Meeting');
    store.saveMeetingNotes(id, 'Raw notes');
    store.artifact(id, 'enhanced_notes', 'Current enhancement', 'fixture');
    final current = store.db.lastInsertRowId;
    store.db.execute('UPDATE meeting_notes SET timestamp=42');
    final notesBefore = store.rows('SELECT * FROM meeting_notes');
    final artifactsBefore = store.rows('SELECT * FROM artifacts');
    store.db.execute(
      "CREATE TRIGGER reject_enhancement BEFORE INSERT ON artifacts WHEN NEW.kind='enhanced_notes' BEGIN SELECT RAISE(ABORT,'injected artifact failure'); END",
    );
    expect(
      () => store.artifact(id, 'enhanced_notes', 'Rejected', 'fixture'),
      throwsA(isA<SqliteException>()),
    );
    expect(store.rows('SELECT * FROM meeting_notes'), notesBefore);
    expect(store.rows('SELECT * FROM artifacts'), artifactsBefore);
    store.db.execute('DROP TRIGGER reject_enhancement');
    store.db.execute(
      "CREATE TRIGGER reject_enhancement_edit BEFORE UPDATE OF edited ON artifacts BEGIN SELECT RAISE(ABORT,'injected edit failure'); END",
    );
    expect(
      () => store.editArtifact(current, 'Rejected edit'),
      throwsA(isA<SqliteException>()),
    );
    expect(store.rows('SELECT * FROM meeting_notes'), notesBefore);
    expect(store.rows('SELECT * FROM artifacts'), artifactsBefore);
    store.db.execute('DROP TRIGGER reject_enhancement_edit');
    store.editArtifact(current, 'Accepted edit');
    expect(meetingTimestamp(id), isNot(42));
    expect(
      store.rows('SELECT edited FROM artifacts').single['edited'],
      'Accepted edit',
    );
  });
}
