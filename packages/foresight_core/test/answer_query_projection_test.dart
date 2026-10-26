import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/conversation_answer.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/persistence/conversation_queries.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/summary_generator.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late Store store;
  late ConversationQueries queries;
  setUp(() {
    directory = createTestTempDirectorySync('answer-projection-');
    store = Store('${directory.path}/app.db');
    queries = ConversationQueries(store);
    addTearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });
  });
  test(
    'typed source summaries preserve selected fields and immutable snapshots',
    () {
      final id = store.importText(
        'Atlas',
        'Private body',
        'text/plain',
        'fixture',
      );
      store.state(id, 'indexed');
      final selected = queries.sourceSummaries.single;
      final original = jsonEncode(store.sourceSummaries.single);
      expect(jsonEncode(selected.toRow()), original);
      expect(selected.toRow().containsKey('content'), isFalse);
      expect(selected.id, id);
      expect(selected.state, 'indexed');
      expect(
        () => selected.toRow()['title'] = 'mutation',
        throwsUnsupportedError,
      );
      store.importText(
        'New title',
        'New body',
        'text/plain',
        'changed',
        id: id,
      );
      expect(selected.title, 'Atlas');
      expect(queries.sourceSummaries.single.title, 'New title');
    },
  );
  test(
    'typed history retains scoped membership, selected fields and checkpoint null counts',
    () {
      final ids = <int>[];
      for (var i = 0; i < 3; i++) {
        store.answer(
          'Q$i',
          'A$i',
          'completed',
          [],
          'fixture',
          conversation: 'room',
        );
        final id = store.db.lastInsertRowId;
        ids.add(id);
        store.setPreference('answerScope.v1.$id', i == 1 ? 'B' : 'A');
        store.setPreference('webAnswer.v1.$id', 'true');
      }
      final local = queries.history(
        'room',
        web: false,
        through: 0,
        privateScope: false,
        scopeIdentity: '',
      );
      expect(local.map((a) => a.question), ['Q0', 'Q1', 'Q2']);
      expect(local.first.toRow().keys, ['question', 'body', 'model_response']);
      expect(local.first.modelResponse, isNull);
      final web = queries.history(
        'room',
        web: true,
        through: ids.first,
        privateScope: true,
        scopeIdentity: 'A',
      );
      expect(web.map((a) => a.id), [ids.last]);
      expect(web.single.toRow().keys, [
        'id',
        'question',
        'body',
        'model_response',
      ]);
      expect(
        () => web.single.toRow()['body'] = 'mutation',
        throwsUnsupportedError,
      );
      store.db.execute(
        'INSERT INTO conversation_memory(conversation,through_answer_id,messages,token_counts) VALUES(?,?,?,?)',
        ['memory', ids.last, '[]', null],
      );
      final checkpoint = queries.checkpoint('memory', 'room').single;
      expect(checkpoint.throughAnswerId, ids.last);
      expect(checkpoint.messages, '[]');
      expect(checkpoint.tokenCounts, isNull);
      expect(queries.checkpoint('memory', 'another-room'), isEmpty);
    },
  );
  test(
    'typed model preserves full registration ordering in web memory identity',
    () async {
      final helper = Helper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      addTearDown(() async {
        domain.close();
        await helper.close();
      });
      final answer = ConversationAnswer(domain, 'Question?', 'desktop');
      String expected(String model) =>
          'web-memory-v2:${summaryDigest('[$model,null,"utf8-byte-history-v1",${jsonEncode(answer.scopeIdentity)}]')}:desktop';
      expect(queries.model('generation'), isNull);
      expect(answer.memoryKey, expected('null'));
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend,model_type) VALUES(?,?,?,?,?,?)',
        [
          'generation',
          '/fixture/model',
          'digest',
          '/fixture/runner',
          'litert_lm',
          7,
        ],
      );
      const model =
          '{"kind":"generation","path":"/fixture/model","digest":"digest","runtime":"/fixture/runner","backend":"litert_lm","model_type":7}';
      expect(jsonEncode(queries.model('generation')!.toRow()), model);
      expect(answer.memoryKey, expected(model));
      store.db.execute("UPDATE models SET runtime='/replacement/runner'");
      expect(answer.memoryKey, isNot(expected(model)));
    },
  );
}
