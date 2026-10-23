import 'dart:convert';
import 'support/current_read.dart';

import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/graph_persistence.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _Workspace {
  final root = createTestTempDirectorySync('typed-reader-contract-');
  late final path = '${root.path}/application.db';
  late final writer = Store(path);
  late final String source;
  late final int note;

  _Workspace() {
    addTearDown(() {
      writer.close();
      root.deleteSync(recursive: true);
    });
    source = writer.importText(
      'Launch plan',
      'Launch the satellite on Tuesday.',
      'text/markdown',
      'google_drive',
      modifiedAtMs: 500,
      sourceUri: 'drive:launch',
      locallyEdited: true,
    );
    writer.state(source, 'indexed', 'retained diagnostic');
    writer.db.execute(
      'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale) VALUES(?,?,?,?,?)',
      [source, 'Space', 'manual', '#123456', 'Launch planning'],
    );
    writer.db.execute('INSERT INTO google_sources VALUES(?,?,?,?,?)', [
      source,
      'fixture-account',
      'drive-launch',
      'v1',
      'application/google-doc',
    ]);
    writer.db.execute(
      'INSERT INTO models(kind,path,digest,runtime,backend,model_type) VALUES(?,?,?,?,?,?)',
      [
        'embedding',
        '/fixture/model.litertlm',
        'fixture-digest',
        '/fixture/runner',
        'fixture',
        7,
      ],
    );
    note = writer.saveNote(null, 'Private note', 'Keep the original notes');
    writer.db.execute('UPDATE notes SET timestamp=300 WHERE id=?', [note]);
    writer.db.execute(
      "INSERT INTO document_clusters(cluster_id,label,summary,center_proj_x,center_proj_y,radius) VALUES(4,'Space','Related launch documents',1.25,-2.5,20.5)",
    );
    writer.db.execute(
      "INSERT INTO meetings VALUES(7,'Launch review',3,'done')",
    );
    writer.db.execute('INSERT INTO meeting_details VALUES(7,100,1)');
    writer.db.execute(
      'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [
        'event-launch',
        'fixture-account',
        'calendar',
        'google-event',
        7,
        source,
        1000,
        2000,
        'confirmed',
        jsonEncode({
          'summary': 'Calendar launch',
          'attachments': [
            {
              'fileId': 'drive-launch',
              'fileUrl': 'drive:launch',
              'title': 'Launch plan',
              'mimeType': 'text/markdown',
              'iconLink': 'icon:document',
            },
          ],
        }),
        500,
      ],
    );
    writer.db.execute(
      'INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,last_manual_edit,last_enhanced,enhanced_body) VALUES(7,?,2,800,700,850,?)',
      ['Original meeting notes', 'Edited enhanced notes'],
    );
    writer.db.execute(
      "INSERT INTO meeting_note_events VALUES(1,7,'event-launch','Original calendar title')",
    );
    writer.db.execute(
      "INSERT INTO transcript VALUES(11,7,'partial',0,0,50,'microphone')",
    );
    writer.db.execute(
      "INSERT INTO transcript VALUES(12,7,'Final launch decision',1,50,9000,'microphone')",
    );
    writer.db.execute(
      'INSERT INTO answers(id,question,body,status,citations,model,created,conversation,request_id,model_response) VALUES(21,?,?,?,?,?,?,?,?,?)',
      [
        'When?',
        'Tuesday',
        'completed',
        jsonEncode([
          {
            'kind': 'document',
            'document_id': source,
            'revision': 1,
            'citation': '[S1]',
            'excerpt': 'Launch on Tuesday',
            'url': 'drive:launch',
            'title': 'Launch plan',
          },
        ]),
        'fixture-model',
        600,
        'desktop',
        'request-launch',
        '{"tokens":3}',
      ],
    );
    writer.db.execute(
      "INSERT INTO answers(id,question,body,status,citations,model,created,conversation) VALUES(22,'Private?','Hidden','completed','[]','fixture-model',601,'meeting:7')",
    );
    writer.db.execute('INSERT INTO meeting_answers VALUES(7,21),(7,22)');
    writer.setPreference('answerScope.v1.21', 'launch-selection');
    writer.setPreference('answerScope.v1.22', 'other-selection');
    writer.db.execute(
      "INSERT INTO meeting_questions VALUES(31,7,12,'When?','when','answered',21,'',602)",
    );
    writer.db.execute(
      'INSERT INTO artifacts(id,meeting_id,kind,generated,edited,input_revision,model,prompt_version,created,manifest) VALUES(41,7,?,?,?,?,?,?,?,?)',
      [
        'enhanced_notes',
        'Generated artifact',
        'Edited artifact',
        3,
        'fixture-model',
        'prompt-v2',
        603,
        '{"sources":["launch"],"ready":true}',
      ],
    );
    writer.db
        .execute('INSERT INTO meeting_tasks VALUES(51,7,?,?,?,?,?,?,?,0,1)', [
          'send-plan',
          'Send launch plan',
          'Ada',
          'Tuesday',
          'pending',
          '[{"id":"segment:12","quote":"Final launch decision"}]',
          3,
        ]);
    writer.db.execute(
      "INSERT INTO meeting_tasks VALUES(52,7,'old','Old task',NULL,NULL,'done','[]',1,1,0)",
    );
  }

  SqliteStoreReader reader() {
    final reader = SqliteStoreReader.open(
      path,
      profile: 'launch-profile',
      connection: 'first',
    );
    addTearDown(reader.close);
    return reader;
  }
}

void main() {
  test(
    'typed reader keeps source, model, label and note snapshots independent of later commits',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      final source = (await currentRead(
        reader,
        StoreReadQueries.sources(),
      )).single;
      final model = (await currentRead(
        reader,
        StoreReadQueries.models(),
      )).single;
      final note = (await currentRead(reader, StoreReadQueries.notes())).single;
      expect(source.id, workspace.source);
      expect(
        [
          source.title,
          source.mime,
          source.provenance,
          source.state,
          source.error,
        ],
        [
          'Launch plan',
          'text/markdown',
          'google_drive',
          'indexed',
          'retained diagnostic',
        ],
      );
      expect(source.labels, ['Space']);
      expect(source.locallyEdited, isTrue);
      expect(source.deleted, isFalse);
      expect(source.changed, 500);
      expect(source.imported, greaterThanOrEqualTo(0));
      expect(source.sourceUri, 'drive:launch');
      expect(
        [
          model.kind,
          model.path,
          model.digest,
          model.runtime,
          model.backend,
          model.modelType,
        ],
        [
          'embedding',
          '/fixture/model.litertlm',
          'fixture-digest',
          '/fixture/runner',
          'fixture',
          7,
        ],
      );
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.model('embedding'),
        ))!.digest,
        model.digest,
      );
      expect(
        (await currentRead(reader, StoreReadQueries.model('not-registered'))),
        isNull,
      );
      expect(
        [note.id, note.title, note.revision],
        [workspace.note, 'Private note', 1],
      );
      expect(
        (await currentRead(reader, StoreReadQueries.noteBody(note.id))),
        'Keep the original notes',
      );
      expect((await currentRead(reader, StoreReadQueries.sourceMimes())), {
        source.id: 'application/google-doc',
      });
      final originalMimes = await currentRead(
        reader,
        StoreReadQueries.sourceMimes(),
      );
      expect(() => originalMimes['new'] = 'mime', throwsUnsupportedError);
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.labels(),
        )).single.documentId,
        source.id,
      );
      final cluster = (await currentRead(
        reader,
        StoreReadQueries.clusters(),
      )).single;
      expect(
        [
          cluster.id,
          cluster.label,
          cluster.summary,
          cluster.x,
          cluster.y,
          cluster.radius,
        ],
        [4, 'Space', 'Related launch documents', 1.25, -2.5, 20.5],
      );
      expect((await currentRead(reader, StoreReadQueries.clusterNames())), [
        'Space',
      ]);
      expect(
        (await currentRead(reader, StoreReadQueries.graphLabelSet())),
        contains(source.id),
      );
      final document = (await currentRead(
        reader,
        StoreReadQueries.source(source.id),
      ))!;
      expect(document.content, 'Launch the satellite on Tuesday.');
      expect(
        (await currentRead(reader, StoreReadQueries.source('absent'))),
        isNull,
      );
      final revision = reader.dataRevision;
      workspace.writer.importText(
        'Changed title',
        'Changed body',
        'text/plain',
        'fixture',
        id: source.id,
      );
      workspace.writer.saveNote(note.id, 'Edited note', 'Edited body');
      expect(reader.dataRevision, isNot(revision));
      expect(source.title, 'Launch plan');
      expect(document.content, 'Launch the satellite on Tuesday.');
      expect(note.title, 'Private note');
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.source(source.id),
        ))!.revision,
        2,
      );
      workspace.writer.tombstone(source.id);
      expect(
        (await currentRead(reader, StoreReadQueries.source(source.id))),
        isNull,
      );
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.source(source.id, includeDeleted: true),
        ))!.deleted,
        isTrue,
      );
      expect((await currentRead(reader, StoreReadQueries.sources())), isEmpty);
    },
  );

  test(
    'meeting projections join the selected meeting and preserve calendar and evidence identities',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      final collection = (await currentRead(
        reader,
        StoreReadQueries.meetings(),
      )).single;
      expect(
        [
          collection.id,
          collection.title,
          collection.state,
          collection.revision,
          collection.created,
          collection.starts,
          collection.ends,
          collection.durationMs,
        ],
        [7, 'Launch review', 'done', 3, 100, 1000, 2000, 9000],
      );
      expect(collection.reminder && collection.hasTranscript, isTrue);
      expect(collection.calendarStatus, 'confirmed');
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.meeting(7, preview: true),
        ))!.durationMs,
        9000,
      );
      expect(
        (await currentRead(reader, StoreReadQueries.meeting(7)))!.starts,
        1000,
      );
      expect(
        (await currentRead(reader, StoreReadQueries.meetingRevision(7))),
        3,
      );
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.meeting(404, preview: true),
        )),
        isNull,
      );
      expect(
        (await currentRead(reader, StoreReadQueries.meeting(404))),
        isNull,
      );
      expect(
        (await currentRead(reader, StoreReadQueries.meetingRevision(404))),
        isNull,
      );
      final note = (await currentRead(
        reader,
        StoreReadQueries.meetingNote(7),
      ))!;
      expect(
        [
          note.meetingId,
          note.body,
          note.enhancedBody,
          note.revision,
          note.timestamp,
          note.lastManualEdit,
          note.lastEnhancedAt,
        ],
        [
          7,
          'Original meeting notes',
          'Edited enhanced notes',
          2,
          800,
          700,
          850,
        ],
      );
      expect(
        (await currentRead(reader, StoreReadQueries.meetingNote(404))),
        isNull,
      );
      final transcript = (await currentRead(
        reader,
        StoreReadQueries.transcript(7),
      ));
      expect(transcript.map((segment) => segment.id), [11, 12]);
      expect(transcript.first.finalSegment, isFalse);
      final finalSegment = (await currentRead(
        reader,
        StoreReadQueries.transcript(7, finalOnly: true),
      )).single;
      expect(
        [
          finalSegment.meetingId,
          finalSegment.body,
          finalSegment.text,
          finalSegment.startMs,
          finalSegment.endMs,
          finalSegment.source,
        ],
        [
          7,
          'Final launch decision',
          'Final launch decision',
          50,
          9000,
          'microphone',
        ],
      );
      expect(finalSegment.finalSegment, isTrue);
      final question = (await currentRead(
        reader,
        StoreReadQueries.questions(7),
      )).single;
      expect(
        [
          question.id,
          question.meetingId,
          question.transcriptId,
          question.question,
          question.normalized,
          question.state,
          question.answerId,
          question.error,
          question.created,
          question.body,
        ],
        [31, 7, 12, 'When?', 'when', 'answered', 21, '', 602, 'Tuesday'],
      );
      final citation = question.citations.single;
      expect(
        [
          citation.kind,
          citation.documentId,
          citation.revision,
          citation.label,
          citation.excerpt,
          citation.url,
          citation.title,
        ],
        [
          'document',
          workspace.source,
          1,
          '[S1]',
          'Launch on Tuesday',
          'drive:launch',
          'Launch plan',
        ],
      );
      final artifact = (await currentRead(
        reader,
        StoreReadQueries.artifacts(7, 'enhanced_notes'),
      )).single;
      expect(
        [
          artifact.id,
          artifact.meetingId,
          artifact.kind,
          artifact.generated,
          artifact.edited,
          artifact.body,
          artifact.model,
          artifact.inputRevision,
          artifact.promptVersion,
          artifact.created,
        ],
        [
          41,
          7,
          'enhanced_notes',
          'Generated artifact',
          'Edited artifact',
          'Edited artifact',
          'fixture-model',
          3,
          'prompt-v2',
          603,
        ],
      );
      expect(artifact.manifest, {
        'sources': ['launch'],
        'ready': true,
      });
      expect(
        (await currentRead(reader, StoreReadQueries.enhancedNotes(7))),
        'Edited enhanced notes',
      );
      final tasks = (await currentRead(reader, StoreReadQueries.tasks(7)));
      expect(tasks.map((task) => task.id), [51, 52]);
      final task = tasks.first;
      expect(
        [
          task.meetingId,
          task.key,
          task.task,
          task.owner,
          task.due,
          task.status,
          task.inputRevision,
        ],
        [7, 'send-plan', 'Send launch plan', 'Ada', 'Tuesday', 'pending', 3],
      );
      expect(task.manual && !task.stale, isTrue);
      expect(tasks.last.stale, isTrue);
      expect(
        [task.evidence.single.id, task.evidence.single.quote],
        ['segment:12', 'Final launch decision'],
      );
      expect(() => tasks.clear(), throwsUnsupportedError);
      expect(
        () => task.evidence.add(task.evidence.single),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'public async queries preserve filtered scope and immutable calendar/export payloads',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      final epoch = reader.workspaceEpoch;
      final selected = await reader.read(
        StoreReadQueries.answers(
          7,
          scope: 'launch-selection',
          privateScope: true,
        ),
      );
      expect(selected.current, isTrue);
      expect(selected.requestTag, reader.dataRevision);
      expect(selected.value!.map((answer) => answer.id), [21]);
      final answer = selected.value!.single;
      expect(
        [
          answer.question,
          answer.body,
          answer.status,
          answer.model,
          answer.created,
          answer.conversation,
          answer.requestId,
          answer.modelResponse,
        ],
        [
          'When?',
          'Tuesday',
          'completed',
          'fixture-model',
          600,
          'desktop',
          'request-launch',
          '{"tokens":3}',
        ],
      );
      expect(answer.citations.single.documentId, workspace.source);
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.answers(null, scope: '', privateScope: false),
        )).map((answer) => answer.id),
        [21],
      );
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.answers(7, scope: '', privateScope: false),
        )).map((answer) => answer.id),
        [21, 22],
      );
      expect(
        (await reader.read(
          StoreReadQueries.answers(7, scope: '', privateScope: false),
        )).value,
        hasLength(2),
      );
      final attachments = (await reader.read(
        StoreReadQueries.attachments(7),
      )).value!;
      final attachment = attachments.single;
      expect(
        [
          attachment.fileId,
          attachment.fileUrl,
          attachment.title,
          attachment.mimeType,
          attachment.iconLink,
        ],
        [
          'drive-launch',
          'drive:launch',
          'Launch plan',
          'text/markdown',
          'icon:document',
        ],
      );
      expect(() => attachments.clear(), throwsUnsupportedError);
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.attachments(7),
        )).single.fileId,
        attachment.fileId,
      );
      expect(
        (await reader.read(StoreReadQueries.attachments(404))).value,
        isEmpty,
      );
      final exported = (await reader.read(
        StoreReadQueries.exportNotes(),
      )).value!;
      final meeting = exported.firstWhere(
        (note) => note.title == 'Launch review',
      );
      expect(
        [
          meeting.id,
          meeting.body,
          meeting.enhancedBody,
          meeting.date,
          meeting.end,
          meeting.associationTitle,
        ],
        [
          7,
          'Original meeting notes',
          'Edited enhanced notes',
          1000,
          2000,
          'Original calendar title',
        ],
      );
      expect(meeting.metadata['summary'], 'Calendar launch');
      expect(
        () => (meeting.metadata['attachments'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        (await currentRead(
          reader,
          StoreReadQueries.exportNotes(),
        )).map((note) => note.title),
        ['Launch review', 'Private note'],
      );
      expect(reader.workspaceEpoch, epoch);
      workspace.writer.db.execute(
        "UPDATE calendar_events SET metadata='{}' WHERE meeting_id=7",
      );
      expect(attachment.title, 'Launch plan');
      expect(meeting.metadata['summary'], 'Calendar launch');
      expect(
        (await currentRead(reader, StoreReadQueries.attachments(7))),
        isEmpty,
      );
    },
  );

  test(
    'nine additional typed factories round-trip through the read worker',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      final notes = (await reader.read(StoreReadQueries.notes())).value!;
      expect(notes.single.id, workspace.note);
      expect(notes.single.title, 'Private note');
      expect(() => notes.clear(), throwsUnsupportedError);
      expect(
        (await reader.read(StoreReadQueries.noteBody(workspace.note))).value,
        'Keep the original notes',
      );
      final missingNote = await reader.read(StoreReadQueries.noteBody(404));
      expect(missingNote.freshness, ReadFreshness.failed);
      expect(missingNote.value, isNull);
      final mimes = (await reader.read(StoreReadQueries.sourceMimes())).value!;
      expect(mimes, {workspace.source: 'application/google-doc'});
      expect(() => mimes.clear(), throwsUnsupportedError);
      final labels = (await reader.read(StoreReadQueries.labels())).value!;
      expect(labels.single.documentId, workspace.source);
      expect(labels.single.name, 'Space');
      expect(labels.single.colorHex, '#123456');
      expect(() => labels.clear(), throwsUnsupportedError);
      final clusters = (await reader.read(StoreReadQueries.clusters())).value!;
      expect(clusters.single.id, 4);
      expect(clusters.single.label, 'Space');
      expect(clusters.single.x, 1.25);
      expect(() => clusters.clear(), throwsUnsupportedError);
      final names = (await reader.read(StoreReadQueries.clusterNames())).value!;
      expect(names, ['Space']);
      expect(() => names.clear(), throwsUnsupportedError);
      final labelSet = (await reader.read(
        StoreReadQueries.graphLabelSet(),
      )).value!;
      expect(
        labelSet,
        (await currentRead(reader, StoreReadQueries.graphLabelSet())),
      );
      expect((await reader.read(StoreReadQueries.meetingRevision(7))).value, 3);
      expect(
        (await reader.read(StoreReadQueries.meetingRevision(404))).value,
        isNull,
      );
      expect(
        (await reader.read(StoreReadQueries.enhancedNotes(7))).value,
        'Edited enhanced notes',
      );
      expect(
        (await reader.read(StoreReadQueries.enhancedNotes(404))).value,
        '',
      );
      workspace.writer.saveNote(workspace.note, 'Updated note', 'Updated body');
      expect(
        (await reader.read(StoreReadQueries.noteBody(workspace.note))).value,
        'Updated body',
      );
      expect(notes.single.title, 'Private note');
    },
  );

  test(
    'typed async source/model/meeting queries and close retain the last immutable values',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      expect(
        (await reader.read(StoreReadQueries.model('embedding'))).value!.digest,
        'fixture-digest',
      );
      final models = (await reader.read(StoreReadQueries.models())).value!;
      expect(() => models.clear(), throwsUnsupportedError);
      expect(
        (await reader.read(
          StoreReadQueries.preference('missing', 'fallback'),
        )).value,
        'fallback',
      );
      final source = (await reader.read(
        StoreReadQueries.source(workspace.source),
      )).value!;
      expect(source.content, contains('Tuesday'));
      expect((await reader.read(StoreReadQueries.meeting(7))).value!.id, 7);
      expect(
        (await reader.read(
          StoreReadQueries.meeting(7, preview: true),
        )).value!.durationMs,
        9000,
      );
      expect(
        (await reader.read(
          StoreReadQueries.transcript(7, finalOnly: true),
        )).value!.single.id,
        12,
      );
      expect(
        (await reader.read(
          StoreReadQueries.artifacts(7, 'enhanced_notes'),
        )).value!.single.body,
        'Edited artifact',
      );
      expect(
        (await reader.read(StoreReadQueries.tasks(7))).value!.first.key,
        'send-plan',
      );
      expect(
        (await reader.read(
          StoreReadQueries.questions(7),
        )).value!.single.answerId,
        21,
      );
      await reader.close();
      await reader.close();
      final closed = await reader.read(StoreReadQueries.sources());
      expect(closed.freshness, ReadFreshness.cancelled);
      expect(closed.value, isNull);
      expect(source.content, contains('Tuesday'));
      expect(workspace.writer.sourceById(workspace.source), isNotEmpty);
    },
  );

  test(
    'typed collection and passage queries retain only matching live source revisions',
    () async {
      final workspace = _Workspace();
      final reader = workspace.reader();
      final sources = (await reader.read(StoreReadQueries.sources())).value!;
      expect(sources.single.id, workspace.source);
      expect(() => sources.clear(), throwsUnsupportedError);
      final found = (await reader.read(
        StoreReadQueries.sourceSearch('SATELLITE'),
      )).value!;
      expect(found, {workspace.source});
      expect(() => found.clear(), throwsUnsupportedError);
      expect(
        (await reader.read(StoreReadQueries.meetings())).value!.single.title,
        'Launch review',
      );
      expect(
        (await reader.read(StoreReadQueries.meetingNote(7))).value!.body,
        'Original meeting notes',
      );
      final query = StoreReadQueries.answerPassages(
        'When does the satellite launch?',
        {workspace.source: 1},
        [
          {
            'document_id': workspace.source,
            'text': 'Launch the satellite on Tuesday.',
            'score': .9,
          },
        ],
        scope: 'launch-selection',
      );
      final passages = (await reader.read(query)).value!;
      expect(passages, isNotEmpty);
      expect(passages.first['document_id'], workspace.source);
      expect(passages.first['revision'], 1);
      expect(passages.first['title'], 'Launch plan');
      expect(passages.first['excerpt'], contains('Tuesday'));
      expect(() => passages.clear(), throwsUnsupportedError);
      expect(() => passages.first['title'] = 'Changed', throwsUnsupportedError);
      workspace.writer.importText(
        'Revised launch',
        'Launch the satellite on Wednesday.',
        'text/markdown',
        'fixture',
        id: workspace.source,
      );
      reader.invalidate();
      expect((await reader.read(query)).value, isEmpty);
      expect(passages.first['revision'], 1);
      expect(passages.first['excerpt'], contains('Tuesday'));
    },
  );

  test(
    'graph query selection rechecks current source revisions and freezes vectors',
    () async {
      final workspace = _Workspace();
      final second = workspace.writer.importText(
        'Orbit plan',
        'Orbit the moon.',
        'text/plain',
        'fixture',
      );
      workspace.writer.state(second, 'indexed');
      final reader = workspace.reader();
      final selected = (await currentRead(reader, StoreReadQueries.sources()));
      final identity = jsonEncode([
        graphLayoutAlgorithmVersion,
        'fixture-digest',
        'fixture',
        'model',
        'scene',
        3,
      ]);
      final labels = (await currentRead(
        reader,
        StoreReadQueries.graphLabelSet(),
      ));
      expect(
        workspace.writer.saveGraphLayout(
          identity,
          workspace.writer.sources,
          {
            workspace.source: [1, 0, 0],
            second: [0, 1, 0],
          },
          {
            workspace.source: const GraphPoint(.1, .2, .3),
            second: const GraphPoint(.3, .2, .1),
          },
          labelSet: labels,
        ),
        isTrue,
      );
      reader.invalidate();
      final explicit = (await reader.read(
        StoreReadQueries.graphLayout(
          sources: selected,
          identity: identity,
          dimensions: 3,
          labelSet: labels,
          helperIdentity: 'helper-a',
        ),
      )).value!;
      expect(explicit.complete, isTrue);
      expect(explicit.identity, identity);
      expect(explicit.points.keys.toSet(), {workspace.source, second});
      expect(explicit.vectors[workspace.source], [1, 0, 0]);
      expect(() => explicit.points.clear(), throwsUnsupportedError);
      expect(
        () => explicit.vectors[workspace.source]![0] = 9,
        throwsUnsupportedError,
      );
      final registered = (await reader.read(
        StoreReadQueries.graphLayout(
          sources: selected,
          helperIdentity: 'helper-b',
        ),
      )).value!;
      expect(registered.complete, isTrue);
      workspace.writer.importText(
        'Revised launch',
        'A new plan.',
        'text/plain',
        'fixture',
        id: workspace.source,
      );
      reader.invalidate();
      final revised = (await reader.read(
        StoreReadQueries.graphLayout(
          sources: selected,
          identity: identity,
          dimensions: 3,
          helperIdentity: 'helper-a',
        ),
      )).value!;
      expect(revised.complete, isFalse);
      expect(revised.points.containsKey(workspace.source), isFalse);
      expect(explicit.points.containsKey(workspace.source), isTrue);
    },
  );

  test(
    'session identity refuses caller transactions and closed borrowed sessions leave writer usable',
    () {
      final workspace = _Workspace();
      final session = SqliteReadSession.borrow(workspace.writer);
      workspace.writer.db.execute('BEGIN');
      expect(
        () => session.identity(
          owner: 'owner',
          profile: 'profile',
          connection: 'first',
        ),
        throwsStateError,
      );
      workspace.writer.db.execute('ROLLBACK');
      final first = session.identity(
        owner: 'owner',
        profile: 'profile',
        connection: 'first',
      );
      expect(
        [first.owner, first.profile, first.connection, first.epoch],
        ['owner', 'profile', 'first', workspace.writer.workspaceEpoch],
      );
      session.close();
      session.close();
      expect(
        () => session.query('sources', {}),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(
        () => session.identity(
          owner: 'owner',
          profile: 'profile',
          connection: 'first',
        ),
        throwsA(isA<RpcError>()),
      );
      expect(workspace.writer.sourceSummaries.single['id'], workspace.source);
    },
  );

  test(
    'reader startup and later projections classify future schemas without mutating them',
    () {
      final workspace = _Workspace();
      workspace.writer.db.execute(
        'PRAGMA user_version=${Store.schemaVersion + 1}',
      );
      expect(
        () => SqliteReadSession.open(workspace.path),
        throwsA(isA<IncompatibleReadSchema>()),
      );
      expect(
        workspace.writer.db.select('PRAGMA user_version').single.values.single,
        Store.schemaVersion + 1,
      );
    },
  );
}
