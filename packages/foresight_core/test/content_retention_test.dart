import 'dart:io';

import 'package:foresight_core/src/persistence/content_history.dart';
import 'package:foresight_core/src/meeting_actions.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Store store;
  setUp(() {
    store = Store(
      '${createTestTempDirectorySync('retention-').path}/application.db',
    );
    addTearDown(() => store.close());
  });

  test('all authoritative entities have atomic count byte and age retention', () {
    final entities = store
        .rows(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE '%_retain_revision'",
        )
        .map((r) => (r['name'] as String).replaceFirst('_retain_revision', ''))
        .toSet();
    expect(entities, ContentHistory.entities);
    final meeting = store.meeting('History');
    store.saveMeetingNotes(meeting, 'manual 0');
    store.artifact(meeting, 'summary', 'generated', 'fixture');
    final artifact = store.db.lastInsertRowId;
    store.db.execute(
      "INSERT INTO meeting_tasks(id,meeting_id,task_key,task,status,evidence,input_revision) VALUES(1,?,'task','first','open','[]',1)",
      [meeting],
    );
    final note = store.saveNote(null, 'manual', 'first');
    final source = store.importText(
      'Imported',
      'first',
      'text/plain',
      'fixture',
    );
    final watch = Stopwatch()..start();
    for (var i = 0; i < 45; i++) {
      store.saveNote(note, 'manual', 'note $i');
      store.saveMeetingNotes(meeting, 'meeting $i');
      store.editArtifact(artifact, 'artifact $i');
      store.meetingStore.editMeetingTask(
        1,
        status: i.isEven ? 'completed' : 'open',
      );
      store.importText(
        'Imported',
        'source $i',
        'text/plain',
        'fixture',
        id: source,
      );
    }
    for (final entity in ContentHistory.entities) {
      final id = switch (entity) {
        'notes' => note,
        'meeting_notes' => meeting,
        'artifacts' => artifact,
        'meeting_tasks' => 1,
        _ => source,
      };
      expect(
        store.contentHistory.revisions(entity, id),
        hasLength(20),
        reason: entity,
      );
      store.db.execute(
        "UPDATE content_revisions SET created=0 WHERE entity=?",
        [entity],
      );
      expect(
        store.contentHistory.revisions(entity, id),
        isEmpty,
        reason: entity,
      );
    }
    // Retention predicates are backed by indexed entity/timestamp access.
    expect(
      store
          .rows(
            'EXPLAIN QUERY PLAN SELECT id FROM content_revisions WHERE created<0 ORDER BY created LIMIT 256',
          )
          .any((r) => '${r['detail']}'.contains('content_revisions_created')),
      isTrue,
    );
    expect(store.noteBody(note), 'note 44');
    expect(store.sources.single['content'], 'source 44');
    print(
      'retention_fixture replacements=225 history_rows=${store.rows("SELECT count(*) AS n FROM content_revisions").single['n']} elapsed_us=${watch.elapsedMicroseconds}',
    );
    for (final entity in ContentHistory.entities) {
      if (entity == 'sources') {
        store.db.execute('UPDATE sources SET deleted=1 WHERE id=?', [source]);
      } else {
        store.db.execute('DELETE FROM $entity');
      }
      expect(
        store.rows('SELECT id FROM content_revisions WHERE entity=?', [entity]),
        isEmpty,
        reason: entity,
      );
    }
  });

  test(
    'oversized old revision is absent while current content remains restorable',
    () {
      final note = store.saveNote(
        null,
        'Large',
        'x' * (ContentHistory.maximumBytes + 1),
      );
      store.saveNote(note, 'Current', 'small current');
      expect(store.contentHistory.revisions('notes', note), isEmpty);
      expect(store.noteBody(note), 'small current');
      store.saveNote(note, 'Next', 'new current');
      final saved =
          store.contentHistory.revisions('notes', note).single['snapshot']
              as Map;
      expect(saved['body'], 'small current');
      store.saveNote(note, saved['title'] as String, saved['body'] as String);
      expect(store.noteBody(note), 'small current');
    },
  );

  test(
    'aggregate byte bound applies to UTF8 bytes rather than character counts',
    () {
      final note = store.saveNote(null, 'Multibyte', '漢' * (4 * 1024 * 1024));
      for (var i = 0; i < 4; i++) {
        store.saveNote(note, '$i', '漢' * (4 * 1024 * 1024));
      }
      expect(store.contentHistory.revisions('notes', note), hasLength(2));
      final bytes =
          store
                  .rows(
                    "SELECT SUM(length(CAST(snapshot AS BLOB))) AS bytes FROM content_revisions WHERE entity='notes'",
                  )
                  .single['bytes']
              as int;
      expect(bytes, lessThanOrEqualTo(ContentHistory.maximumBytes));
    },
  );

  test(
    'long generated transcripts and live drafts retain no repeated payload',
    () {
      final meeting = store.meeting('Generated');
      for (var i = 0; i < 100; i++) {
        store.importText(
          'Transcript',
          'segment ' * (i + 1),
          'text/plain',
          'meeting:$meeting',
          id: 'meeting-$meeting',
          generated: true,
        );
        store.saveMeetingEnhancedDraft(meeting, 'live draft ' * (i + 1));
      }
      expect(
        store.contentHistory.revisions('sources', 'meeting-$meeting'),
        isEmpty,
      );
      expect(store.contentHistory.revisions('meeting_notes', meeting), isEmpty);
      expect(store.sources.single['content'], 'segment ' * 100);
      expect(store.meetingEnhancedNotes(meeting), 'live draft ' * 100);
      // Manual ownership wins even when a producer mistakenly sets generated.
      store.importText(
        'Edited',
        'manual first',
        'text/plain',
        'meeting:$meeting',
        id: 'meeting-$meeting',
        generated: true,
        locallyEdited: true,
      );
      store.importText(
        'Edited',
        'manual second',
        'text/plain',
        'meeting:$meeting',
        id: 'meeting-$meeting',
        locallyEdited: true,
      );
      expect(
        store.contentHistory
            .revisions('sources', 'meeting-$meeting')
            .single['snapshot'],
        containsPair('content', 'manual first'),
      );
      store.restoreMeetingEnhancedDraft(meeting, 'manual enhanced');
      store.saveMeetingEnhancedDraft(meeting, 'next generated');
      expect(
        store.contentHistory
            .revisions('meeting_notes', meeting)
            .single['snapshot'],
        containsPair('enhanced_body', 'manual enhanced'),
      );
    },
  );

  test(
    'unclassified updates preserve generated ownership until an explicit manual edit',
    () {
      final meeting = store.meeting('Sticky generated source');
      final id = 'meeting-$meeting';
      store.importText(
        'Transcript',
        'first',
        'text/plain',
        'meeting:$meeting',
        id: id,
        generated: true,
      );
      store.importText(
        'Transcript',
        'unclassified update',
        'text/plain',
        'meeting:$meeting',
        id: id,
      );
      store.importText(
        'Transcript',
        'another update',
        'text/plain',
        'meeting:$meeting',
        id: id,
      );
      expect(
        store.rows('SELECT generated FROM sources WHERE id=?', [
          id,
        ]).single['generated'],
        1,
      );
      expect(store.contentHistory.revisions('sources', id), isEmpty);
      store.importText(
        'Edited',
        'manual first',
        'text/plain',
        'meeting:$meeting',
        id: id,
        locallyEdited: true,
      );
      store.importText(
        'Edited',
        'manual second',
        'text/plain',
        'meeting:$meeting',
        id: id,
        locallyEdited: true,
      );
      expect(
        store.rows('SELECT generated FROM sources WHERE id=?', [
          id,
        ]).single['generated'],
        0,
      );
      expect(
        store.contentHistory.revisions('sources', id).single['snapshot'],
        containsPair('content', 'manual first'),
      );
    },
  );

  test(
    'v19 upgrade prunes generated snapshots while retaining manual history and current content',
    () {
      store.close();
      final path =
          '${createTestTempDirectorySync('retention-upgrade-').path}/application.db';
      final db = openApplicationDatabase(path);
      db.execute(
        File(
          'test/fixtures/persistence-c28a1561/schema15.sql',
        ).readAsStringSync(),
      );
      for (var version = 16; version <= 19; version++) {
        ApplicationMigrations(db).run(version);
      }
      db.execute('PRAGMA user_version=19');
      db.execute(
        "INSERT INTO meetings(id,title,state) VALUES(1,'Meeting','idle')",
      );
      db.execute(
        "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES('meeting-1','Transcript','initial','text/plain',1,'ready','meeting:1')",
      );
      db.execute(
        "INSERT INTO sources(id,title,content,mime,revision,state,provenance,locally_edited) VALUES('manual','Imported','initial','text/plain',1,'ready','fixture',1)",
      );
      for (var i = 0; i < 40; i++) {
        db.execute('UPDATE sources SET content=?', ['replacement $i']);
      }
      db.dispose();
      store = Store(path);
      expect(
        store
            .rows("SELECT generated FROM sources WHERE id='meeting-1'")
            .single['generated'],
        1,
      );
      expect(store.contentHistory.revisions('sources', 'meeting-1'), isEmpty);
      expect(
        store.contentHistory.revisions('sources', 'manual'),
        hasLength(20),
      );
      expect(store.sourceById('meeting-1').single['content'], 'replacement 39');
      expect(store.sourceById('manual').single['content'], 'replacement 39');
      expect(store.rows('PRAGMA integrity_check').single.values.single, 'ok');
    },
  );

  test(
    'repeated task replacement preserves manual status and bounded recoverable edits',
    () {
      final meeting = store.meeting('Tasks');
      for (var i = 0; i < 40; i++) {
        store.meetingStore.saveMeetingTasks(
          meeting,
          [
            MeetingAction(
              task: 'Ship fix',
              evidence: [
                {'id': 'fixture', 'quote': 'version $i'},
              ],
            ),
          ],
          'fixture',
          i,
          {},
        );
        final task = store.meetingStore.meetingTasks(meeting).single;
        store.meetingStore.editMeetingTask(
          task['id'] as int,
          status: i.isEven ? 'completed' : 'cancelled',
        );
      }
      final task = store.meetingStore.meetingTasks(meeting).single;
      final history = store.contentHistory.revisions(
        'meeting_tasks',
        task['id'] as int,
      );
      expect(history, hasLength(20));
      expect(task['manual'], 1);
      expect(task['status'], 'cancelled');
      final previous = history.first['snapshot'] as Map;
      store.meetingStore.editMeetingTask(
        task['id'] as int,
        status: previous['status'] as String,
      );
      expect(
        store.meetingStore.meetingTasks(meeting).single['status'],
        previous['status'],
      );
      expect(
        store.contentHistory.revisions('meeting_tasks', task['id'] as int),
        hasLength(20),
      );
    },
  );

  test(
    'source details failure rolls back content and its retained revision atomically',
    () {
      final id = store.importText(
        'Before',
        'original',
        'text/plain',
        'fixture',
      );
      store.db.execute(
        "CREATE TRIGGER reject_details BEFORE INSERT ON source_details BEGIN SELECT RAISE(ABORT,'detail fault'); END",
      );
      expect(
        () => store.importText(
          'After',
          'replacement',
          'text/plain',
          'fixture',
          id: id,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(store.sourceById(id).single['content'], 'original');
      expect(store.sourceById(id).single['revision'], 1);
      expect(store.contentHistory.revisions('sources', id), isEmpty);
    },
  );

  test('writer and reader connections use finite busy timeout', () {
    final reader = Store.readOnly(store.path);
    addTearDown(reader.close);
    for (final connection in [store.db, reader.db]) {
      expect(
        connection.select('PRAGMA busy_timeout').single.values.single,
        applicationSqliteBusyTimeout.inMilliseconds,
      );
    }
  });
}
