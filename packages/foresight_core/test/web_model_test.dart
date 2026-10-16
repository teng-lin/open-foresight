import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  test(
    'real model searches and persists a cited controlled answer',
    () async {
      final directory = Directory.systemTemp.createTempSync('web-model-');
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/unused.sock',
        '${directory.path}/helper',
        manageProcess: false,
      );
      final runtime = NativeRuntime(env['FORESIGHT_NATIVE']!);
      final queries = <String>[];
      final domain = Domain(
        store,
        helper,
        webSearch: SearchCallbacks(
          search: (query) async {
            queries.add(query);
            return [
              const WebSearchItem(
                title: 'Controlled parity fixture',
                link: 'https://example.invalid/controlled-parity-fixture',
                snippet:
                    'The current release code for the Open Foresight controlled parity fixture is CEDAR-8492.',
              ),
            ];
          },
          summarize: (_, _) async => '',
        ),
      )..generator = runtime;
      try {
        await runtime.load(
          env['FORESIGHT_GENERATION_RUNNER']!,
          env['FORESIGHT_GENERATION_MODEL']!,
          backend: 'litert_lm',
        );
        final deltas = await domain
            .askWithWebInConversation(
              'Using Google search, what is the current release code of the Open Foresight controlled parity fixture? Cite the result.',
              'controlled-model-fixture',
            )
            .toList();
        final rows = store.rows('SELECT body,status,citations FROM answers');
        final report = {
          'queries': queries,
          'deltas': deltas,
          'answers': rows,
          'runtime': runtime.effectiveState,
        };
        final reportPath = env['FORESIGHT_WEB_MODEL_REPORT'];
        if (reportPath != null)
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        expect(queries, isNotEmpty, reason: '$report');
        expect(rows, hasLength(1));
        expect(rows.single['status'], 'completed', reason: '$report');
        expect(rows.single['body'], contains('CEDAR-8492'), reason: '$report');
        expect(rows.single['body'], contains('[Source:1]'), reason: '$report');
        final citations =
            jsonDecode(rows.single['citations'] as String) as List;
        expect(
          citations.single['url'],
          'https://example.invalid/controlled-parity-fixture',
        );
      } finally {
        domain.close();
        runtime.close();
        await helper.close();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    skip: env['FORESIGHT_WEB_MODEL_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
