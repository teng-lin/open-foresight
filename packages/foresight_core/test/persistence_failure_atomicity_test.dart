import 'dart:io';

import 'package:foresight_core/src/conversation_answer.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Store store;
  setUp(() {
    root = createTestTempDirectorySync('atomic-');
    store = Store('${root.path}/app.db');
    addTearDown(() => store.close());
  });
  void reject(String table, {String operation = 'INSERT'}) => store.db.execute(
    "CREATE TEMP TRIGGER reject_write BEFORE $operation ON $table "
    "BEGIN SELECT RAISE(ABORT,'injected persistence failure'); END",
  );
  void retry() => store.db.execute('DROP TRIGGER reject_write');

  test(
    'meeting notes failure rolls back and a subsequent save survives reopen',
    () {
      final meeting = store.meeting('Planning');
      store.saveMeetingNotes(meeting, 'Original notes');
      reject('meeting_notes');
      expect(
        () => store.saveMeetingNotes(meeting, 'Lost edit'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.db.autocommit, isTrue);
      expect(store.rows('SELECT body,revision FROM meeting_notes'), [
        {'body': 'Original notes', 'revision': 1},
      ]);
      retry();
      store.saveMeetingNotes(meeting, 'Retried edit');
      final view = Store.readOnly(store.path);
      try {
        expect(view.rows('SELECT body,revision FROM meeting_notes'), [
          {'body': 'Retried edit', 'revision': 2},
        ]);
      } finally {
        view.close();
      }
    },
  );

  test(
    'model registration failure preserves previous identity and diagnostic',
    () async {
      final model = File('${root.path}/old-model')
        ..writeAsStringSync('old bytes');
      await store.register('generation', model.path, '/old-runtime');
      final previous = store.model('generation');
      store.setPreference('modelIntegrityError.generation', 'Repair needed');
      reject('preferences', operation: 'DELETE');
      final replacement = File('${root.path}/new-model')
        ..writeAsStringSync('new bytes');
      await expectLater(
        store.register('generation', replacement.path, '/new-runtime'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.model('generation'), previous);
      expect(
        store.preference('modelIntegrityError.generation'),
        'Repair needed',
      );
      expect(store.db.autocommit, isTrue);
      retry();
      await store.register('generation', replacement.path, '/new-runtime');
      expect(store.model('generation')!['path'], replacement.path);
      expect(store.preference('modelIntegrityError.generation'), isEmpty);
      for (final type in [-1, 18]) {
        await expectLater(
          store.register('generation', model.path, '', modelType: type),
          throwsArgumentError,
        );
      }
    },
  );

  for (final emptyDirectory in [false, true]) {
    test(
      'integrity rejection is atomic when its diagnostic cannot persist (directory=$emptyDirectory)',
      () async {
        final model = File('${root.path}/model')..writeAsStringSync('trusted');
        await store.register('generation', model.path, '');
        model.deleteSync();
        if (emptyDirectory) Directory(model.path).createSync();
        reject('preferences');
        await expectLater(
          store.verifyRegisteredModels(rejectInvalidRegistrations: true),
          throwsA(isA<SqliteException>()),
        );
        expect(store.model('generation'), isNotNull);
        expect(store.db.autocommit, isTrue);
        retry();
        expect(
          await store.verifyRegisteredModels(rejectInvalidRegistrations: true),
          ['generation'],
        );
        expect(store.model('generation'), isNull);
        expect(
          store.preference('modelIntegrityError.generation'),
          contains('missing'),
        );
      },
    );
  }

  for (final operation in ['labels', 'deleteOrganizationLabel']) {
    test('$operation rolls back all tables and can be retried', () {
      final source = store.importText(
        'Atlas',
        'Evidence',
        'text/plain',
        'fixture',
      );
      store.labels(source, ['Planning']);
      store.saveLabelCluster('Planning');
      final before = store.documentLabels.map((label) => label.name).toList();
      reject('source_details', operation: 'UPDATE');
      expect(
        () => operation == 'labels'
            ? store.labels(source, ['Changed'])
            : store.deleteOrganizationLabel('Planning'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.db.autocommit, isTrue);
      expect(store.documentLabels.map((label) => label.name), before);
      expect(
        store.rows('SELECT label FROM document_clusters').single['label'],
        'Planning',
      );
      retry();
      store.deleteOrganizationLabel('Planning');
      expect(store.documentLabels, isEmpty);
      expect(store.rows('SELECT * FROM document_clusters'), isEmpty);
    });
  }

  test(
    'answer, web checkpoint and meeting link commit as one transaction',
    () async {
      final helper = Helper(
        '${root.path}/unused.sock',
        root.path,
        manageProcess: false,
      );
      addTearDown(helper.close);
      final domain = Domain(store, helper);
      addTearDown(domain.close);
      final meeting = store.meeting('Planning');
      final answer = ConversationAnswer(
        domain,
        'Question',
        'conversation',
        meetingId: meeting,
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'Question'},
        {'role': 'assistant', 'content': 'Answer'},
      ];
      void save() => answer.saveAnswer(
        'Question',
        'Answer',
        'completed',
        [],
        'fixture',
        conversation: 'conversation',
        memoryMessages: messages,
        memoryTokenCounts: [1, 1],
        historyThroughAnswerId: 0,
      );
      reject('meeting_answers');
      expect(save, throwsA(isA<SqliteException>()));
      for (final table in [
        'answers',
        'conversation_memory',
        'meeting_answers',
      ]) {
        expect(store.rows('SELECT * FROM $table'), isEmpty);
      }
      expect(
        store.rows("SELECT * FROM preferences WHERE key LIKE 'webAnswer.%'"),
        isEmpty,
      );
      retry();
      save();
      final view = Store.readOnly(store.path);
      try {
        for (final table in [
          'answers',
          'conversation_memory',
          'meeting_answers',
        ]) {
          expect(view.rows('SELECT * FROM $table'), hasLength(1));
        }
      } finally {
        view.close();
      }
    },
  );

  test(
    'read-only desktop queries retain source visibility and export saved notes',
    () async {
      final source = store.importText(
        'Atlas',
        'Original evidence',
        'text/plain',
        'fixture',
      );
      store.saveNote(null, 'Standalone', 'User prose');
      final note = store.notes().single['id'] as int;
      final meeting = store.meeting('Planning');
      store.saveMeetingNotes(meeting, 'Meeting prose');
      final model = File('${root.path}/embedding.litertlm')
        ..writeAsStringSync('embedding fixture');
      await store.register('embedding', model.path, '');
      final speech = File('${root.path}/speech.bin')
        ..writeAsStringSync('speech fixture');
      await store.register('speech', speech.path, '');
      store.tombstone(source);
      final view = Store.readOnly(store.path);
      try {
        expect(view.sourceById(source), isEmpty);
        expect(
          view.sourceById(source, includeDeleted: true).single['content'],
          'Original evidence',
        );
        expect(view.noteSummaries().single, {
          'id': note,
          'title': 'Standalone',
          'revision': 1,
        });
        expect(view.noteBody(note), 'User prose');
        expect(view.exportNotes().map((row) => row['body']).toSet(), {
          'User prose',
          'Meeting prose',
        });
        expect(view.registeredEmbedding().single['path'], model.path);
        expect(view.registeredSpeech(), hasLength(1));
        expect(view.googleSourceMimes(), isEmpty);
      } finally {
        view.close();
      }
    },
  );
}
