import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late Store store;
  setUp(() {
    directory = createTestTempDirectorySync('note-edit-dates-');
    store = Store('${directory.path}/app.db');
  });
  setUp(() {
    addTearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'raw saves preserve supplied keypress date and do not restamp identical bodies',
    () {
      final id = store.meeting('Meeting');
      store.saveMeetingNotes(id, 'First', lastManualEdit: 1234);
      store.db.execute('UPDATE meeting_notes SET last_enhanced=17');
      store.saveMeetingNotes(id, 'First');
      var note = store.rows('SELECT * FROM meeting_notes').single;
      expect(note['last_manual_edit'], 1234);
      expect(note['last_enhanced'], 17);
      final before = DateTime.now().millisecondsSinceEpoch;
      store.saveMeetingNotes(id, 'Genuine change');
      note = store.rows('SELECT * FROM meeting_notes').single;
      expect(
        note['last_manual_edit'],
        inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
      );
      expect(note['last_enhanced'], 17);
      store.saveMeetingNotes(id, 'First', lastManualEdit: 2345);
      store.close();
      store = Store('${directory.path}/app.db');
      expect(
        store
            .rows('SELECT last_manual_edit FROM meeting_notes')
            .single['last_manual_edit'],
        2345,
      );
    },
  );

  test(
    'generation and current manual enhancement edits keep distinct timestamps',
    () {
      final id = store.meeting('Meeting');
      store.saveMeetingNotes(id, 'Raw', lastManualEdit: 1234);
      final before = DateTime.now().millisecondsSinceEpoch;
      store.artifact(id, 'enhanced_notes', 'First enhanced', 'fixture');
      final historical = store.db.lastInsertRowId;
      var note = store.rows('SELECT * FROM meeting_notes').single;
      expect(
        note['last_enhanced'],
        inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
      );
      expect(note['last_manual_edit'], 1234);
      store.artifact(id, 'enhanced_notes', 'Current enhanced', 'fixture');
      final current = store.db.lastInsertRowId;
      final enhancedDate = store
          .rows('SELECT last_enhanced FROM meeting_notes')
          .single['last_enhanced'];
      store.editArtifact(current, 'Manual enhanced', lastManualEdit: 4567);
      store.editArtifact(current, 'Manual enhanced');
      store.editArtifact(historical, 'Historical edit', lastManualEdit: 9999);
      store.artifact(id, 'summary', 'Summary', 'fixture');
      store.editArtifact(
        store.db.lastInsertRowId,
        'Summary edit',
        lastManualEdit: 9999,
      );
      note = store.rows('SELECT * FROM meeting_notes').single;
      expect(note['last_manual_edit'], 4567);
      expect(note['last_enhanced'], enhancedDate);
      expect(note['body'], 'Raw');
      expect(note['revision'], 1);
    },
  );
}
