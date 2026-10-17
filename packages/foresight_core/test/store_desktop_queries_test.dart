import 'dart:io';

import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Store store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('desktop-queries-');
    store = Store('${root.path}/app.db');
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'output words filter completion, bucket history, and refresh snapshots',
    () {
      final now = DateTime.utc(2026, 1, 15, 12);
      void answer(String body, int days, {String status = 'completed'}) {
        store.answer('Question', body, status, [], 'fixture');
        store.db.execute('UPDATE answers SET created=? WHERE id=?', [
          now.subtract(Duration(days: days)).millisecondsSinceEpoch,
          store.db.lastInsertRowId,
        ]);
      }

      answer('two\twords', 0);
      answer('three small\nwords', 7);
      answer('oldest included', 34);
      answer('too old', 35);
      answer('future response', -1);
      answer('', 0);
      answer('ignore this incomplete output', 0, status: 'cancelled');
      final meeting = store.meeting('Planning');
      store.artifact(meeting, 'summary', 'artifact has three', 'fixture');

      expect(store.localOutputWords, 14);
      expect(store.localOutputWords, 14);
      expect(store.weeklyAnswerWords(now), [2, 0, 0, 3, 2]);
      expect(store.completedAnswerCountRows().single['n'], 6);
      expect(store.completedAnswerBodies().length, 6);

      final peer = Store(store.path);
      try {
        peer.answer(
          'External write',
          'external entry',
          'completed',
          [],
          'fixture',
        );
        expect(store.localOutputWords, 16);
      } finally {
        peer.close();
      }
      store.answer('Local write', 'own', 'completed', [], 'fixture');
      expect(store.localOutputWords, 17);
      store.db.execute('BEGIN');
      try {
        store.answer('Uncommitted', 'rolled back', 'completed', [], 'fixture');
        expect(store.localOutputWords, 19);
      } finally {
        store.db.execute('ROLLBACK');
      }
      expect(store.localOutputWords, 17);
    },
  );

  test(
    'meeting projections preserve scope, final duration, and newest artifacts',
    () {
      final helper = Helper('${root.path}/socket', '${root.path}/helper');
      final domain = Domain(store, helper);
      final app = Application(domain);
      addTearDown(() async {
        await app.close();
        domain.close();
        await helper.close();
      });
      app.google; // Initialize the optional calendar projection schema.
      final first = store.meeting('Recorded');
      final second = store.meeting('No recording');
      for (final (id, created) in [(first, 2000), (second, 1000)]) {
        store.db.execute(
          'UPDATE meeting_details SET created=? WHERE meeting_id=?',
          [created, id],
        );
      }
      store.transcript(first, 'Final evidence', true, 0, 5000, 'microphone');
      store.transcript(
        first,
        'Partial evidence',
        false,
        5000,
        9000,
        'microphone',
      );
      store.saveMeetingNotes(first, 'Draft notes');
      store.saveNote(null, 'Standalone', 'Standalone body');
      store.answer(
        'Desktop question',
        'Desktop answer',
        'completed',
        [],
        'fixture',
      );
      store.answer(
        'Meeting question',
        'Meeting answer',
        'completed',
        [],
        'fixture',
        conversation: 'meeting:$first',
      );
      store.db.execute(
        'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
        [first, store.db.lastInsertRowId],
      );
      store.artifact(first, 'enhanced_notes', 'Old enhancement', 'fixture');
      store.artifact(first, 'enhanced_notes', 'New enhancement', 'fixture');
      store.artifact(first, 'summary', 'Separate summary', 'fixture');

      final meetings = store.meetingCollection();
      expect(meetings.map((row) => row['id']), [second, first]);
      expect(meetings.first['has_transcript'], 0);
      expect(meetings.first['duration_ms'], isNull);
      expect(meetings.last['has_transcript'], 1);
      expect(meetings.last['duration_ms'], 5000);
      expect(store.recordedMeetingCountRows().single['n'], 1);
      expect(store.meetingPreviewRows(first).single['duration_ms'], 5000);
      expect(
        store.meetingWorkspaceRows(second).single['title'],
        'No recording',
      );
      expect(store.meetingNoteRows(first).single['body'], 'Draft notes');
      expect(store.meetingNoteRows(second), isEmpty);
      expect(store.notes().single['body'], 'Standalone body');
      expect(store.finalTranscript(first).single['text'], 'Final evidence');
      expect(store.meetingTranscript(first).length, 2);
      expect(store.meetingTranscript(second), isEmpty);
      expect(store.conversationAnswers(null).single['body'], 'Desktop answer');
      expect(store.conversationAnswers(first).single['body'], 'Meeting answer');
      expect(store.conversationAnswers(second), isEmpty);
      expect(
        store.enhancedNoteArtifacts(first).single['generated'],
        'New enhancement',
      );
      expect(
        store
            .meetingArtifacts(first, 'enhanced_notes')
            .map((row) => row['generated']),
        ['New enhancement', 'Old enhancement'],
      );
      expect(
        store.meetingArtifacts(first, 'summary').single['generated'],
        'Separate summary',
      );
      expect(store.meetingQuestions(first), isEmpty);
    },
  );
}
