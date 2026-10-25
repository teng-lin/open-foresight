import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'existing answer database migrates without changing old text or citations',
    () {
      final directory = createTestTempDirectorySync('history-migration-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final path = '${directory.path}/app.db';
      final legacy = sqlite3.open(path);
      legacy.execute(
        '''CREATE TABLE answers(id INTEGER PRIMARY KEY,question TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL,citations TEXT NOT NULL,model TEXT NOT NULL,created INTEGER NOT NULL);
      INSERT INTO answers VALUES(7,'Old question','Old answer [S1]','completed','[{"citation":"S1"}]','legacy',42);
      CREATE TABLE conversation_memory(conversation TEXT PRIMARY KEY,through_answer_id INTEGER NOT NULL,messages TEXT NOT NULL);
      INSERT INTO conversation_memory VALUES('desktop',7,'[]');
      PRAGMA user_version=1;''',
      );
      legacy.dispose();
      final store = Store(path);
      try {
        final row = store.rows('SELECT * FROM answers').single;
        expect(row['id'], 7);
        expect(row['created'], 42);
        expect(row['citations'], '[{"citation":"S1"}]');
        expect(row['model_response'], isNull);
        final checkpoint = store
            .rows('SELECT * FROM conversation_memory')
            .single;
        expect(checkpoint['through_answer_id'], 7);
        expect(checkpoint['messages'], '[]');
        expect(checkpoint['token_counts'], isNull);
        expect(referenceChatHistory([row]), [
          referenceTextMessage('user', 'Old question'),
          referenceTextMessage('assistant', 'Old answer [S1]'),
        ]);
        final response = referenceTextMessage(
          'assistant',
          'New answer [Source:8]',
        );
        store.answer(
          'New question',
          'New answer [Source:1]',
          'completed',
          [],
          'fixture',
          modelResponse: response,
        );
        final saved = store.rows('SELECT * FROM answers ORDER BY id').last;
        expect(jsonDecode(saved['model_response'] as String), response);
        expect(referenceChatHistory([saved]).last, response);
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
