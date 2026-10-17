import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Store store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('note-enhancement-draft-');
    store = Store('${directory.path}/app.db');
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'drafts and explicit empty content preserve raw notes, dates, and history',
    () {
      final id = store.meeting('Meeting');
      store.saveMeetingNotes(id, 'Raw notes', lastManualEdit: 200);
      store.artifact(id, 'enhanced_notes', 'Historical enhancement', 'fixture');
      store.db.execute(
        'UPDATE meeting_notes SET last_enhanced=100,timestamp=50,enhanced_body=NULL',
      );
      expect(store.meetingEnhancedNotes(id), 'Historical enhancement');
      store.saveMeetingEnhancedDraft(id, 'Streamed partial');
      var note = store.rows('SELECT * FROM meeting_notes').single;
      expect(note['body'], 'Raw notes');
      expect(note['revision'], 1);
      expect(note['last_manual_edit'], 200);
      expect(note['last_enhanced'], 100);
      expect(note['timestamp'], greaterThan(50));
      expect(store.meetingEnhancedNotes(id), 'Streamed partial');
      store.saveMeetingEnhancedDraft(id, '');
      expect(store.meetingEnhancedNotes(id), '');
      expect(store.rows('SELECT generated,edited FROM artifacts'), [
        {'generated': 'Historical enhancement', 'edited': null},
      ]);
      store.close();
      store = Store('${directory.path}/app.db');
      expect(store.meetingEnhancedNotes(id), '');
    },
  );

  test(
    'completion and current manual edits synchronize canonical content atomically',
    () {
      final id = store.meeting('Meeting');
      store.artifact(id, 'enhanced_notes', 'Old enhancement', 'fixture');
      final old = store.db.lastInsertRowId;
      store.saveMeetingEnhancedDraft(id, 'Partial');
      store.db.execute(
        "CREATE TRIGGER reject_artifact BEFORE INSERT ON artifacts BEGIN SELECT RAISE(ABORT,'rejected'); END",
      );
      final before = store.rows('SELECT * FROM meeting_notes');
      expect(
        () => store.artifact(id, 'enhanced_notes', 'Rejected', 'fixture'),
        throwsA(anything),
      );
      expect(store.rows('SELECT * FROM meeting_notes'), before);
      store.db.execute('DROP TRIGGER reject_artifact');
      store.artifact(id, 'enhanced_notes', 'Completed', 'fixture');
      final current = store.db.lastInsertRowId;
      expect(store.meetingEnhancedNotes(id), 'Completed');
      store.editArtifact(old, 'Historical manual edit', lastManualEdit: 999);
      expect(store.meetingEnhancedNotes(id), 'Completed');
      store.editArtifact(current, 'Current manual edit', lastManualEdit: 1234);
      expect(store.meetingEnhancedNotes(id), 'Current manual edit');
      expect(
        store
            .rows('SELECT last_manual_edit FROM meeting_notes')
            .single['last_manual_edit'],
        1234,
      );
    },
  );

  test(
    'first programmatic draft captures an association without completion dates',
    () {
      final id = store.meeting('Meeting');
      store.db.execute(
        'CREATE TABLE calendar_events(event_key TEXT,meeting_id INTEGER,metadata TEXT)',
      );
      store.db.execute('INSERT INTO calendar_events VALUES(?,?,?)', [
        'event',
        id,
        '{"summary":"Captured"}',
      ]);
      store.saveMeetingEnhancedDraft(id, 'Initial programmatic text');
      final note = store.rows('SELECT * FROM meeting_notes').single;
      expect(note['body'], '');
      expect(note['revision'], 0);
      expect(note['last_enhanced'], isNull);
      expect(note['last_manual_edit'], isNull);
      expect(
        store.rows('SELECT title FROM meeting_note_events').single['title'],
        'Captured',
      );
      expect(store.rows('SELECT * FROM artifacts'), isEmpty);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );
}
