import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/domain.dart';
import 'package:foresight_linux/helper.dart';
import 'package:foresight_linux/native.dart';
import 'package:foresight_linux/store.dart';

void main() {
  test(
    'saved question receives a grounded answer on a private database copy',
    () async {
      final env = Platform.environment;
      final store = Store(env['FORESIGHT_ANSWER_DATABASE']!);
      final helper = Helper(
        env['FORESIGHT_ANSWER_SOCKET']!,
        '${Directory.systemTemp.path}/unused-answer-helper',
      );
      final domain = Domain(store, helper);
      final generator = NativeRuntime(env['FORESIGHT_NATIVE']!);
      domain.generator = generator;
      try {
        final model = store
            .rows("SELECT * FROM models WHERE kind='generation'")
            .single;
        await generator.load(
          env['FORESIGHT_LITERT_RUNNER']!,
          model['path'] as String,
          backend: model['backend'] as String,
        );
        final timer = Stopwatch()..start();
        final result = await domain
            .ask(env['FORESIGHT_ANSWER_QUESTION']!)
            .toList();
        final answer = store
            .rows('SELECT * FROM answers ORDER BY id DESC LIMIT 1')
            .single;
        final citations = jsonDecode(answer['citations'] as String) as List;
        expect(answer['status'], 'completed', reason: result.last);
        expect(citations, isNotEmpty);
        if (env['FORESIGHT_ANSWER_EXPECT_SYNTHESIS'] == '1') {
          expect(
            answer['model'],
            isNot(isIn(['source-fallback', 'source-guide', 'source-examples'])),
          );
        }
        if (env['FORESIGHT_ANSWER_EXPECT_TEXT_JSON']
            case final String expected) {
          for (final term in (jsonDecode(expected) as List).cast<String>()) {
            expect(result.last.toLowerCase(), contains(term.toLowerCase()));
          }
        }
        expect(result.last, contains(RegExp(r'\[S\d+\]')));
        final term = env['FORESIGHT_ANSWER_EXPECT_TERM']!.toLowerCase();
        expect(
          citations.any(
            (c) => (c['excerpt'] as String).toLowerCase().contains(term),
          ),
          true,
        );
        if (env['FORESIGHT_ANSWER_EXPECT_PROCEDURE'] == '1') {
          expect(citations.length, 1);
          final excerpt = (citations.single as Map)['excerpt'] as String;
          expect(
            RegExp(
              r'^#{1,6}\s+Step\s+\d+',
              multiLine: true,
            ).allMatches(excerpt).length,
            10,
          );
          final text = result.last.toLowerCase();
          final steps = RegExp(
            r'(?:^|\n)\s*(?:#{1,6}\s*)?(?:\*\*)?(?:step\s+)?(10|[1-9])[.)\s—:-]',
          ).allMatches(text).map((m) => int.parse(m[1]!)).toSet();
          expect(steps, containsAll(List.generate(10, (i) => i + 1)));
          for (final term in [
            'claim',
            'minimum',
            'preferred',
            'evidence',
            'decision',
            'version',
          ]) {
            expect(text, contains(term));
          }
          for (final unrelated in [
            'comparable deal analysis',
            'preferred economics',
            '124 months',
          ]) {
            expect(text, isNot(contains(unrelated)));
          }
        }
        if (env['FORESIGHT_ANSWER_EXPECT_EXAMPLES'] == '1') {
          expect(answer['model'], 'source-examples');
          expect(citations.length, 2);
          expect(result.last, startsWith('From your source examples'));
          for (final citation in citations) {
            // Every selected section reaches the UI intact, including tables,
            // numeric targets and the source author's evidence boundaries.
            expect(result.last, contains(citation['excerpt'] as String));
          }
          for (final term in [
            'LIBREXIA-AF',
            '100 mg',
            '1.37',
            'Malaria treatment',
            '42–63',
            '2017 targets',
          ]) {
            expect(result.last, contains(term));
          }
          expect(result.last, isNot(contains('Sept 207')));
        }
        if (env['FORESIGHT_ANSWER_OUTPUT'] case final String path) {
          File(path).writeAsStringSync(result.last);
        }
        File(env['FORESIGHT_ANSWER_REPORT']!).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({
            'passed': true,
            'question': env['FORESIGHT_ANSWER_QUESTION'],
            'answer_status': answer['status'],
            'citation_count': citations.length,
            'selected_evidence_contains_expected_term': true,
            'answer_method': answer['model'],
            'generation_used_for_answer': !{'source-guide', 'source-examples'}.contains(answer['model']),
            'generation_backend': generator.effectiveState['backend'],
            'elapsed_seconds': timer.elapsedMilliseconds / 1000,
            'source_profile_modified': false,
            'method': {'source-guide', 'source-examples'}.contains(answer['model']) ? 'Actual helper retrieval and application authored-source rendering; only a private backup database receives the saved answer' : 'Actual helper retrieval and GPU Gemma generation; only a private backup database receives the saved answer',
            'private_source_text_and_answer_retained_in_report': false,
          })}\n',
        );
      } finally {
        domain.close();
        generator.close();
        await helper.close();
        store.close();
      }
    },
    skip: Platform.environment['FORESIGHT_ANSWER_DATABASE'] == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
