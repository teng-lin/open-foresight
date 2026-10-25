import 'sql_support_test_bootstrap.dart';
import 'package:foresight_core/src/answer_retrieval.dart'
    show retrieveAnswerPassages;
import 'package:foresight_core/src/answer_phase_values.dart';
import 'package:foresight_core/src/answer_source_scope.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/store_read_queries.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'phase requests pin source membership before caller-owned sets change',
    () {
      final ids = {'meeting-1'};
      final request = AnswerPhaseRequest(
        question: 'Who leads Atlas?',
        conversation: 'meeting:1',
        scopeIdentity: 'scope-at-admission',
        privateScope: true,
        useWeb: false,
        sourceScope: AnswerSourceScope('selected', ids),
      );
      ids.add('private-source');
      expect(request.sourceIds, {'meeting-1'});
      expect(
        () => request.sourceIds!.add('private-source'),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'evidence and structured history cannot change across phase boundaries',
    () {
      final provenance = {
        'parts': <Object?>['original'],
      };
      final citation = <String, Object?>{
        'citation': 'S1',
        'provenance': provenance,
      };
      final sources = [('Atlas', 'source:atlas')];
      final retrieval = AnswerRetrievalSnapshot(
        terminal: false,
        previousQuestion: null,
        followUp: false,
        localGrounding: false,
        citations: [citation],
        chatSources: sources,
        chatMetadata: {sources.single: citation},
        context: 'Pinned evidence',
      );
      (provenance['parts'] as List).add('changed');
      citation['citation'] = 'S2';
      sources.clear();
      expect(retrieval.citations.single['citation'], 'S1');
      expect((retrieval.citations.single['provenance'] as Map)['parts'], [
        'original',
      ]);
      expect(retrieval.chatSources, [('Atlas', 'source:atlas')]);
      expect(
        () => retrieval.chatMetadata.values.single['citation'] = 'S9',
        throwsUnsupportedError,
      );
      final content = <Object?>[
        {'type': 'text', 'text': 'Original structured response'},
      ];
      final messages = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': content},
      ];
      final counts = [7];
      final memory = AnswerMemorySnapshot(messages, counts);
      (content.single as Map)['text'] = 'later mutation';
      counts[0] = 999;
      expect(
        ((memory.messages.single['content'] as List).single as Map)['text'],
        'Original structured response',
      );
      expect(memory.tokenCounts, [7]);
      expect(
        () => (memory.messages.single['content'] as List).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'service answer projection uses pinned revisions on its real read worker',
    () async {
      final root = createTestTempDirectorySync('answer-read-');
      final writer = Store('${root.path}/application.db');
      final id = writer.importText(
        'Atlas ownership',
        'Mira leads the Atlas project. Mira owns the delivery schedule.',
        'text/plain',
        'fixture',
      );
      writer.state(id, 'indexed');
      final revision = writer.sources.single['revision'];
      final reader = SqliteStoreReader.service(
        writer,
        profile: 'fixture-profile',
        connection: 'fixture-service',
      );
      addTearDown(() async {
        await reader.close();
        writer.close();
      });
      final query = StoreReadQueries.answerPassages(
        'Who leads Atlas?',
        {id: revision},
        [
          {
            'document_id': id,
            'text': 'Mira leads the Atlas project.',
            'score': 0.9,
          },
        ],
        scope: 'workspace',
      );
      final first = await reader.read(query);
      expect(first.error, isNull);
      expect(first.current, isTrue);
      expect(
        await retrieveAnswerPassages(
          writer.path,
          'Who leads Atlas?',
          {id: revision},
          [
            {
              'document_id': id,
              'text': 'Mira leads the Atlas project.',
              'score': 0.9,
            },
          ],
        ),
        first.value,
      );
      expect(first.value, isNotEmpty);
      expect(first.value!.every((row) => row['document_id'] == id), isTrue);
      expect(
        () => first.value!.single['excerpt'] = 'mutated',
        throwsUnsupportedError,
      );
      writer.importText(
        'Atlas ownership',
        'A new owner replaced Mira.',
        'text/plain',
        'fixture',
        id: id,
      );
      writer.state(id, 'indexed');
      reader.invalidate();
      final after = await reader.read(query);
      expect(after.error, isNull);
      expect(
        after.value,
        isEmpty,
        reason: 'Old semantic chunks cannot attach to the new source revision',
      );
    },
  );
}
