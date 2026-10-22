import 'dart:typed_data';

import 'package:foresight_core/desktop.dart';
import 'package:test/test.dart';

void main() {
  test(
    'projection snapshots copy nested mutable values and reject unsupported objects',
    () {
      final bytes = Uint8List.fromList([1, 2]);
      final nested = <String, Object?>{
        'bytes': bytes,
        'values': <Object?>[null, true, 2.5],
      };
      final source = SourceDocument.fromRow({
        'id': 'source-a',
        'content': 'Original',
        'metadata': nested,
      });
      bytes[0] = 9;
      (nested['values'] as List).add('late');
      nested['new'] = 'late';
      final retained = source.toRow()['metadata'] as Map<String, Object?>;
      expect(retained.keys.toSet(), {'bytes', 'values'});
      expect(retained['bytes'], [1, 2]);
      expect(retained['values'], [null, true, 2.5]);
      expect(
        () => (retained['bytes'] as Uint8List)[0] = 8,
        throwsUnsupportedError,
      );
      expect(
        () => (retained['values'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => source.toRow()['content'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => SourceDocument.fromRow({'callback': () {}}),
        throwsArgumentError,
      );
      expect(
        () => SourceDocument.fromRow({
          'metadata': {1: 'invalid key'},
        }),
        throwsA(isA<TypeError>()),
      );
    },
  );

  test(
    'calendar preview fallback distinguishes absent times from explicit zero times',
    () {
      final preview = MeetingDetails.fromRow({
        'calendar_starts': 100,
        'calendar_ends': 200,
      });
      expect(
        [preview.starts, preview.ends, preview.created, preview.durationMs],
        [100, 200, null, null],
      );
      final workspace = MeetingDetails.fromRow({
        'starts': 0,
        'ends': 10,
        'calendar_starts': 100,
        'calendar_ends': 200,
      });
      expect([workspace.starts, workspace.ends], [0, 10]);
      final absent = MeetingCollectionEntry.fromRow({});
      expect(absent.reminder || absent.hasTranscript, isFalse);
      expect(absent.calendarStatus, isNull);
      expect(SourceSummary.fromRow({}).labels, isEmpty);
      expect(DocumentCluster.fromRow({}).radius, 100);
      expect(
        MeetingArtifact.fromRow({'generated': 'Generated fallback'}).body,
        'Generated fallback',
      );
    },
  );

  test(
    'artifact and export JSON remains immutable after callers retain nested associations',
    () {
      final artifact = MeetingArtifact.fromRow({
        'manifest':
            '{"documents":[{"id":"source-a","selected":true}],"count":1}',
      });
      final manifest = artifact.manifest;
      expect((manifest['documents'] as List).single, {
        'id': 'source-a',
        'selected': true,
      });
      expect(
        () => ((manifest['documents'] as List).single as Map)['id'] = 'other',
        throwsUnsupportedError,
      );
      final note = ExportNote.fromRow({
        'export_metadata': '{"attachments":[{"fileId":"drive-a"}]}',
      });
      expect(
        ((note.metadata['attachments'] as List).single as Map)['fileId'],
        'drive-a',
      );
      expect(
        () => (note.metadata['attachments'] as List).add({}),
        throwsUnsupportedError,
      );
      expect(ExportNote.fromRow({}).metadata, isEmpty);
      expect(MeetingArtifact.fromRow({}).manifest, isEmpty);
    },
  );

  test(
    'task and answer evidence keeps typed associations and refuses malformed JSON',
    () {
      final task = MeetingTask.fromRow({
        'evidence': '[{"id":"transcript:7","quote":"Keep this decision"}]',
        'manual': true,
        'stale': 1,
      });
      expect(task.manual && task.stale, isTrue);
      expect(task.evidence.single.quote, 'Keep this decision');
      expect(() => task.evidence.clear(), throwsUnsupportedError);
      final unanswered = MeetingQuestion.fromRow({});
      expect(unanswered.citations, isEmpty);
      expect(unanswered.transcriptId, isNull);
      expect(unanswered.answerId, isNull);
      expect(unanswered.body, isNull);
      final answer = SavedAnswer.fromRow({});
      expect(answer.conversation, 'desktop');
      expect(answer.citations, isEmpty);
      for (final malformed in ['{', '[1]', '[{"id":3}]']) {
        final broken = MeetingTask.fromRow({'evidence': malformed});
        expect(
          () => broken.evidence.single.id,
          throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
        );
      }
      expect(
        () => SourceSummary.fromRow({'labels': '[1]'}).labels,
        throwsA(isA<TypeError>()),
      );
      expect(
        () => MeetingArtifact.fromRow({'manifest': '[]'}).manifest,
        throwsA(isA<TypeError>()),
      );
      expect(
        () => SavedAnswer.fromRow({'citations': '{}'}).citations,
        throwsA(isA<TypeError>()),
      );
    },
  );
}
