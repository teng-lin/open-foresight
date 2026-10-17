import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  test(
    'real model searches and persists a cited controlled answer',
    () async {
      final directory = Directory.systemTemp.createTempSync('web-model-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        env['FORESIGHT_WEB_TOKENIZER_SOCKET'] ??
            '${directory.path}/unused.sock',
        '${directory.path}/helper',
        manageProcess: false,
      );
      if (env['FORESIGHT_WEB_TOKENIZER_SOCKET'] != null) {
        helper.snapshot = control.State(tokenizerReady: true);
      }
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
        final reason = reportPath ?? 'Controlled web-model fixture';
        if (reportPath != null)
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        expect(queries, isNotEmpty, reason: reason);
        expect(rows, hasLength(1));
        expect(rows.single['status'], 'completed', reason: reason);
        expect(rows.single['body'], contains('CEDAR-8492'), reason: reason);
        expect(rows.single['body'], contains('[Source:1]'), reason: reason);
        final citations =
            jsonDecode(rows.single['citations'] as String) as List;
        expect(
          citations.single['url'],
          'https://example.invalid/controlled-parity-fixture',
        );
        final searchCount = queries.length;
        final followup = await domain
            .askWithWebInConversation(
              'What was that code? Reply with just the code.',
              'controlled-model-fixture',
            )
            .toList();
        report['followup'] = followup;
        report['queries_after_followup'] = List<String>.of(queries);
        if (reportPath != null) {
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
        expect(followup.last, contains('CEDAR-8492'), reason: reason);
        expect(queries.length, searchCount, reason: reason);
        expect(store.rows('SELECT id FROM answers'), hasLength(2));
        for (var i = 0; i < 6; i++) {
          final body = i < 3
              ? '${i == 0 ? 'The user chose violet as the project theme color. ' : ''}'
                    '${'Planning context remains consistent across the project. ' * 90}'
              : 'The current work is on schedule. ' * 16;
          store.answer(
            'Planning note $i',
            body,
            'completed',
            [],
            'controlled fixture',
            conversation: 'controlled-compression-fixture',
          );
        }
        final compressedAnswer = await domain
            .askWithWebInConversation(
              'What project theme color did I choose? Reply with just the color.',
              'controlled-compression-fixture',
            )
            .toList();
        report['compression_attempt'] = {
          'answer': compressedAnswer,
          'saved_answers': store.rows(
            "SELECT question,status FROM answers WHERE conversation='controlled-compression-fixture'",
          ),
        };
        if (reportPath != null)
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        final checkpoint = store
            .rows(
              "SELECT * FROM conversation_memory WHERE conversation='controlled-compression-fixture'",
            )
            .single;
        final memory = List<Map<String, dynamic>>.from(
          jsonDecode(checkpoint['messages'] as String) as List,
        );
        report['compression'] = {
          'answer': compressedAnswer,
          'messages': memory,
        };
        if (reportPath != null) {
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
        expect(
          referenceHistoryText(memory.first),
          startsWith(referenceMemoryPrefix),
          reason: reason,
        );
        expect(
          referenceHistoryText(memory.first).toLowerCase(),
          contains('violet'),
          reason: reason,
        );
        expect(
          compressedAnswer.last.toLowerCase(),
          contains('violet'),
          reason: reason,
        );
        expect(queries.length, searchCount, reason: reason);
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
