import 'sql_support_test_bootstrap.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/foresight_core.dart' show Store, Domain, Helper;
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/meeting_actions.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Map<String, Object?> detail({
  Map<String, Object?> meeting = const {'id': 1},
  List<Object?> notes = const [],
  List<Object?> transcript = const [],
  List<Object?> artifacts = const [],
  List<Object?> questions = const [],
}) => {
  'meeting': meeting,
  'notes': notes,
  'transcript': transcript,
  'artifacts': artifacts,
  'questions': questions,
};

final invalidResponse = isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.internal)
    .having((error) => error.reason, 'reason', RpcErrorReason.outcomeUnknown)
    .having(
      (error) => error.message,
      'safe message',
      isNot(contains('private-canary')),
    );

void main() {
  bootstrapSqlSupportFixture();
  test(
    'actual service projection replies retain their nullable SQL fields',
    () async {
      final root = createTestTempDirectorySync('projection-replies-');
      final store = Store('${root.path}/profile.db');
      final helper = Helper(
        '${root.path}/unused.sock',
        '${root.path}/helper',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      final app = Application(domain);
      addTearDown(() async {
        await app.close();
        domain.close();
        await domain.drain();
        await helper.close();
        store.close();
      });
      final sourceId = store.importText(
        'Document',
        'Body',
        'text/plain',
        'local',
      );
      store.saveNote(null, 'Note', 'Draft');
      final meetingId = store.meeting('Meeting');
      store.saveMeetingNotes(meetingId, 'Notes');
      store.transcript(meetingId, 'Commitment', true, 0, 10, 'microphone');
      store.artifact(
        meetingId,
        'summary',
        'Summary',
        'fixture',
        manifest: {'degraded': false},
      );
      store.meetingStore.saveMeetingTasks(
        meetingId,
        [
          const MeetingAction(
            task: 'Follow up',
            evidence: [
              {'id': 'quote', 'quote': 'Commitment'},
            ],
          ),
        ],
        'fixture',
        1,
        {},
      );
      store.db.execute(
        'INSERT INTO meeting_questions(meeting_id,question,normalized,created) VALUES(?,?,?,?)',
        [meetingId, 'Question?', 'question', 1],
      );
      final source = sourcesGetDescriptor.decodeResponse(
        await app.call('sources.get', {'id': sourceId}),
      );
      expect(source.id, sourceId);
      expect(source.labels, isEmpty);
      expect(
        sourcesListDescriptor.decodeResponse(
          await app.call('sources.list', {}),
        ),
        isNotEmpty,
      );
      expect(
        notesListDescriptor
            .decodeResponse(await app.call('notes.list', {}))
            .single
            .body,
        'Draft',
      );
      expect(
        meetingsListDescriptor
            .decodeResponse(await app.call('meetings.list', {}))
            .single
            .id,
        meetingId,
      );
      final meeting = meetingsGetDescriptor.decodeResponse(
        await app.call('meetings.get', {'id': meetingId}),
      );
      expect(meeting.notes.single.body, 'Notes');
      expect(meeting.transcript.single.finalSegment, true);
      expect(meeting.artifacts.first.manifest, isA<Map<String, Object?>>());
      expect(meeting.questions.single.answerId, isNull);
      expect(
        meetingsTasksDescriptor
            .decodeResponse(await app.call('meetings.tasks', {'id': meetingId}))
            .single
            .evidence
            .single
            .quote,
        'Commitment',
      );
    },
  );

  test('projection identity fields fail inside the response boundary', () {
    for (final malformed in <Object?>[null, 'private-canary', [], {}]) {
      expect(
        () => sourcesGetDescriptor.decodeResponse(malformed),
        throwsA(invalidResponse),
      );
    }
    for (final id in <Object?>[null, 7, [], {}]) {
      expect(
        () => sourcesGetDescriptor.decodeResponse({'id': id}),
        throwsA(invalidResponse),
      );
    }
    for (final row in <Map<String, Object?>>[
      {},
      {'id': 'private-canary'},
    ]) {
      for (final decode in <Object? Function(Object?)>[
        notesListDescriptor.decodeResponse,
        meetingsListDescriptor.decodeResponse,
        meetingsTasksDescriptor.decodeResponse,
      ]) {
        expect(() => decode([row]), throwsA(invalidResponse));
      }
      expect(
        () => meetingsGetDescriptor.decodeResponse(detail(meeting: row)),
        throwsA(invalidResponse),
      );
    }
    expect(
      () => sourcesListDescriptor.decodeResponse([{}]),
      throwsA(invalidResponse),
    );
    for (final row in <Map<String, Object?>>[
      {},
      {'id': 2},
    ]) {
      expect(
        () => meetingsGetDescriptor.decodeResponse(detail(notes: [row])),
        throwsA(invalidResponse),
      );
      expect(
        () => meetingsGetDescriptor.decodeResponse(detail(transcript: [row])),
        throwsA(invalidResponse),
      );
      expect(
        () => meetingsGetDescriptor.decodeResponse(detail(artifacts: [row])),
        throwsA(invalidResponse),
      );
      expect(
        () => meetingsGetDescriptor.decodeResponse(detail(questions: [row])),
        throwsA(invalidResponse),
      );
    }
  });

  test(
    'lazy projection fields and nested lists are validated before success',
    () {
      for (final fields in <Map<String, Object?>>[
        {'title': 1},
        {'revision': 'private-canary'},
        {'source_uri': false},
        {'deleted': 'private-canary'},
        {'locally_edited': 2},
        {'labels': '[1]'},
        {'labels': '{}'},
        {'labels': 'private-canary'},
      ]) {
        expect(
          () =>
              sourcesGetDescriptor.decodeResponse({'id': 'source', ...fields}),
          throwsA(invalidResponse),
        );
      }
      expect(
        () => notesListDescriptor.decodeResponse([
          {'id': 1, 'body': []},
        ]),
        throwsA(invalidResponse),
      );
      expect(
        () => meetingsListDescriptor.decodeResponse([
          {'id': 1, 'calendar_ends': 'private-canary'},
        ]),
        throwsA(invalidResponse),
      );
      for (final fields in <Map<String, Object?>>[
        {'owner': 1},
        {'manual': []},
        {'evidence': '[{"quote":7}]'},
        {'evidence': '[null]'},
        {'evidence': '{}'},
      ]) {
        expect(
          () => meetingsTasksDescriptor.decodeResponse([
            {'id': 1, 'meeting_id': 2, ...fields},
          ]),
          throwsA(invalidResponse),
        );
      }
      final malformedDetails = [
        detail(
          notes: [
            {'meeting_id': 1, 'last_manual_edit': false},
          ],
        ),
        detail(
          transcript: [
            {'id': 1, 'meeting_id': 1, 'final': 2},
          ],
        ),
        detail(
          artifacts: [
            {'id': 1, 'meeting_id': 1, 'manifest': '[]'},
          ],
        ),
        detail(
          questions: [
            {
              'id': 1,
              'meeting_id': 1,
              'citations': '[{"revision":"private-canary"}]',
            },
          ],
        ),
      ];
      for (final reply in malformedDetails) {
        expect(
          () => meetingsGetDescriptor.decodeResponse(reply),
          throwsA(invalidResponse),
        );
      }
    },
  );

  test('nullable fields and absent defaults preserve the original rows', () {
    final row = <String, Object?>{
      'id': 'source',
      'title': null,
      'source_uri': null,
      'labels': null,
      'deleted': 0,
      'locally_edited': true,
      'unknown_metadata': {'version': 1},
    };
    final source = sourcesGetDescriptor.decodeResponse(row);
    expect(source.toRow(), row);
    expect(source.title, '');
    expect(source.sourceUri, isNull);
    expect(source.labels, isEmpty);
    expect(source.deleted, false);
    expect(source.locallyEdited, true);
    final task = meetingsTasksDescriptor.decodeResponse([
      {
        'id': 3,
        'meeting_id': 1,
        'owner': null,
        'evidence': '[{"id":"a","quote":"b"}]',
      },
    ]).single;
    expect(task.owner, isNull);
    expect(task.evidence.single.quote, 'b');
    final result = meetingsGetDescriptor.decodeResponse(
      detail(
        artifacts: [
          {'id': 2, 'meeting_id': 1, 'manifest': '{"degraded":true}'},
        ],
        questions: [
          {'id': 3, 'meeting_id': 1, 'citations': null},
        ],
      ),
    );
    expect(result.artifacts.single.manifest['degraded'], true);
    expect(result.questions.single.citations, isEmpty);
  });
}
