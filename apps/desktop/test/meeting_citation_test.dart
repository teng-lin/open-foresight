import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'saved meeting factual answer includes a valid source citation',
    () async {
      final env = Platform.environment;
      final temporary = createTestTempDirectorySync('meeting-citation-');
      addTearDown(() {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
      Process.runSync('chmod', ['700', temporary.path]);
      final store = Store('${temporary.path}/app.db');
      final helper = Helper(
        '${temporary.path}/helper.sock',
        '${temporary.path}/helper',
      );
      final domain = Domain(store, helper);
      final app = Application(domain);
      try {
        await store.register('embedding', env['FORESIGHT_EMBEDDING']!, '');
        await store.register(
          'generation',
          env['FORESIGHT_GENERATION_MODEL']!,
          env['FORESIGHT_GENERATION_RUNNER']!,
          backend: env['FORESIGHT_GENERATION_BACKEND'] ?? 'litert_lm',
        );
        helper.onReady = domain.resume;
        await helper.start();
        expect(helper.state, contains('live'), reason: helper.state);
        expect(domain.generator, isNotNull);
        final id = store.importText(
          'Meeting transcript',
          '[playback; captured-sample timeline (gaps excluded) 0–11640 ms] And so my fellow Americans ask not what your country can do for you. Ask what you can do for your country.',
          'text/plain',
          'real speech evaluation fixture',
        );
        await domain.index(id);
        await app
            .ask('What does the speaker ask Americans to do? Cite [S1].')
            .drain<void>();
        final answer = store.rows('SELECT * FROM answers').single;
        final report = env['FORESIGHT_CITATION_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(answer),
          );
        expect(answer['status'], 'completed', reason: answer['body'] as String);
        expect((answer['body'] as String).toLowerCase(), contains('country'));
        expect(answer['body'], contains('[S1]'));
        expect(
          (answer['body'] as String).toLowerCase(),
          isNot(contains('king')),
        );
        expect(
          (answer['body'] as String).toLowerCase(),
          isNot(contains('dream')),
        );
      } finally {
        domain.generator?.close();
        await helper.close();
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['FORESIGHT_INTEGRATION'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
