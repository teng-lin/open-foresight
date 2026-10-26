import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';

void main() {
  bootstrapSqlSupportFixture();
  final env = Platform.environment;
  test(
    'dedicated detector queues English and Chinese questions without a chat model',
    () async {
      final directory = createTestTempDirectorySync('proactive-model-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/unused.sock',
        '${directory.path}/unused',
      );
      final domain = Domain(store, helper);
      final app = Application(domain);
      try {
        await configureDedicatedQuery(store, env['FORESIGHT_QUERY_MODEL']!);
        final id = store.meeting('Controlled bilingual fixture');
        app.proactive.begin(id);
        store.transcript(
          id,
          'Mira will send the draft on Tuesday. What is the release date? 谁负责测试？ We agreed to review the draft tomorrow.',
          true,
          0,
          10000,
          'controlled fixture',
        );
        app.proactive.notify(id);
        // Detection only: this test never invokes retrieval, audio capture or web search.
        await app.proactive.process();
        final questions = store.rows(
          'SELECT question,state FROM meeting_questions ORDER BY id',
        );
        final report = {
          'questions': questions,
          'errors': app.proactive.errors.map(
            (key, value) => MapEntry('$key', value),
          ),
          'backend': store.model('query-detection')?['backend'],
          'chat_model_registered': store.model('generation') != null,
        };
        final reportPath = env['FORESIGHT_PROACTIVE_REPORT'];
        if (reportPath != null) {
          final file = File(reportPath);
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
        expect(app.proactive.errors, isEmpty, reason: '$report');
        expect(
          questions.map((row) => row['question']),
          unorderedEquals(['What is the release date?', '谁负责测试？']),
        );
        expect(store.rows('SELECT * FROM answers'), isEmpty);
        expect(domain.generator, isNull);
        expect(store.model('generation'), isNull);
        await app.proactive.reset();
        final quiet = store.meeting('Statement-only fixture');
        app.proactive.begin(quiet);
        store.transcript(
          quiet,
          'Good morning, everyone. Thank you, Mira. The release is on Tuesday and the draft is ready.',
          true,
          0,
          10000,
          'controlled fixture',
        );
        app.proactive.notify(quiet);
        await app.proactive.process();
        expect(app.proactive.errors, isEmpty);
        expect(
          store.rows('SELECT * FROM meeting_questions WHERE meeting_id=?', [
            quiet,
          ]),
          isEmpty,
        );
      } finally {
        await app.close();
        domain.close();
        await helper.close();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    skip: env['FORESIGHT_PROACTIVE_MODEL_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
