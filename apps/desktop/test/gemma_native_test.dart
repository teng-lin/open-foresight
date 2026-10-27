import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:foresight_core/foresight_core.dart' show configureGeneration;

void main() {
  test(
    'real Gemma 4 E2B native stream, grounded citation and owned cancellation',
    () async {
      final env = Platform.environment;
      final dir = createTestTempDirectorySync('foresight-gemma-native-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      Process.runSync('chmod', ['700', dir.path]);
      final store = Store('${dir.path}/app.db');
      final helper = Helper('${dir.path}/helper.sock', '${dir.path}/helper');
      final domain = Domain(store, helper);
      final app = Application(domain);
      var passed = false;
      try {
        domain.generator = await configureGeneration(
          store,
          env['FORESIGHT_NATIVE']!,
          env['FORESIGHT_GEMMA_MODEL']!,
          env['FORESIGHT_LITERT_RUNNER']!,
          backend: 'litert_lm',
        );
        expect(
          domain.generator!.effectiveState['backend'],
          'litert-lm-${env['FORESIGHT_LITERT_BACKEND'] ?? 'cpu'}-native',
        );
        expect(
          store
              .rows("SELECT backend FROM models WHERE kind='generation'")
              .single['backend'],
          'litert_lm',
        );
        await store.register(
          'embedding',
          env['FORESIGHT_EMBEDDING']!,
          '',
          backend: env['FORESIGHT_EMBEDDING_GPU'] == '1'
              ? 'litert_lm_embedding_gpu'
              : 'litert_lm_embedding_cpu',
        );
        helper.onReady = domain.resume;
        await helper.start();
        final readiness = Stopwatch()..start();
        while (helper.snapshot?.pipeline != 'ready' &&
            readiness.elapsed < const Duration(seconds: 90)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(helper.snapshot?.pipeline, 'ready', reason: helper.state);
        final id = store.importText(
          'Planning',
          'The planning meeting is on Friday. Mira sends the report on Tuesday.',
          'text/plain',
          'controlled fixture',
        );
        await domain.index(id);
        final answer =
            (await app.ask('When is the planning meeting? Cite [S1].').toList())
                .last;
        expect(answer.toLowerCase(), contains('friday'));
        expect(answer, contains('[S1]'));
        expect(
          store.rows('SELECT status FROM answers').single['status'],
          'completed',
        );
        expect(
          store.rows('SELECT model FROM answers').single['model'],
          isNot('source-fallback'),
          reason: answer,
        );
        final guide = store.importText(
          'Target Product Profile writing guide',
          'To write a Target Product Profile, follow these three steps. '
              'Step 1: Define the intended patient population and unmet need. '
              'Output a precise indication and population statement. '
              'Step 2: Define the comparator and measurable desired benefit. '
              'Output a table with minimum acceptable and preferred targets. '
              'Step 3: Link each target to supporting evidence and identify gaps. '
              'Output an evidence plan with an owner for each missing study. '
              'This guide does not specify numerical clinical thresholds.',
          'text/plain',
          'controlled how-to fixture',
        );
        await domain.index(guide);
        final procedure =
            (await app
                    .ask(
                      'How should I write a Target Product Profile? Explain the steps and outputs.',
                    )
                    .toList())
                .last;
        for (final term in ['population', 'comparator', 'evidence', 'owner']) {
          expect(procedure.toLowerCase(), contains(term));
        }
        expect(procedure.split(RegExp(r'\s+')).length, greaterThan(40));
        expect(
          store
              .rows('SELECT status FROM answers ORDER BY id DESC LIMIT 1')
              .single['status'],
          'completed',
        );
        expect(
          store
              .rows('SELECT model FROM answers ORDER BY id DESC LIMIT 1')
              .single['model'],
          isNot('source-fallback'),
          reason: procedure,
        );
        final numeric = store.importText(
          'Orion development profile',
          'Orion is an investigational oral therapy. The Orion design publication '
              'is dated 2019. Its dose target is 100 mg. Its planning horizon is '
              '12–24 months. These are proposed targets, not demonstrated outcomes.',
          'text/plain',
          'numeric fidelity fixture',
        );
        await domain.index(numeric);
        final numericAnswer =
            (await app
                    .ask(
                      'Describe the Orion development profile, including its publication date, '
                      'dose target, planning horizon and evidence limitations.',
                    )
                    .toList())
                .last;
        for (final value in ['2019', '100 mg']) {
          expect(numericAnswer, contains(value));
        }
        expect(numericAnswer, contains(RegExp(r'12\s*[–-]\s*24\s+months')));
        expect(
          store
              .rows('SELECT model FROM answers ORDER BY id DESC LIMIT 1')
              .single['model'],
          isNot('source-fallback'),
        );
        final missing =
            (await app.ask('Who is Unlisted Person90210?').toList()).last;
        expect(missing, 'Insufficient context');
        expect(
          store
              .rows('SELECT status FROM answers ORDER BY id DESC LIMIT 1')
              .single['status'],
          'insufficient_context',
        );
        final cancelledAnswer = app
            .ask(
              'Describe the Orion development profile and its evidence limitations.',
            )
            .toList();
        final cancelDeadline = Stopwatch()..start();
        while (!domain.generator!.generating &&
            cancelDeadline.elapsed < const Duration(seconds: 15)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(domain.generator!.generating, true);
        domain.generator!.cancel();
        await cancelledAnswer;
        expect(
          store
              .rows('SELECT status FROM answers ORDER BY id DESC LIMIT 1')
              .single['status'],
          'cancelled',
        );
        final reusedAnswer =
            (await app.ask('When is the planning meeting?').toList()).last;
        expect(reusedAnswer.toLowerCase(), contains('friday'));
        var delta = false;
        var cancelled = false;
        await for (final event in domain.generator!.generate(
          'gemma-cancel',
          'Write a long detailed explanation of every planet.',
          maxOutputTokens: 1024,
        )) {
          if (event['type'] == 'delta' && !delta) {
            delta = true;
            domain.generator!.cancel();
          }
          if (event['type'] == 'done')
            cancelled = event['status'] == 'cancelled';
        }
        expect(delta, true);
        expect(cancelled, true);
        expect(domain.generator!.generating, false);
        final next = await domain.generator!
            .generate(
              'gemma-reuse',
              'Reply with just the number: two plus two.',
              maxOutputTokens: 64,
            )
            .toList();
        expect(next.last['status'], 'completed');
        final text = next
            .where((e) => e['type'] == 'delta')
            .map((e) => e['text'])
            .join();
        expect(text.toLowerCase(), anyOf(contains('4'), contains('four')));
        final report = env['FORESIGHT_GEMMA_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert({
              'model': 'Gemma 4 E2B IT public LiteRT artifact',
              'model_digest': store.rows("SELECT digest FROM models WHERE kind='generation'").single['digest'],
              'platform': Platform.operatingSystem,
              'runtime': 'litert-lm 0.18.0 ${env['FORESIGHT_LITERT_BACKEND'] ?? 'cpu'}',
              'native_load_and_backend_registration': 'passed',
              'grounded_answer': answer,
              'how_to_steps_and_outputs': 'passed',
              'verified_synthesis_without_source_fallback': 'passed for factual, three-step how-to and numeric profile questions',
              'numeric_date_dose_range_fidelity': 'passed',
              'native_cancellation_and_reuse': 'passed',
              'grounded_pipeline_cancellation_and_reuse': 'passed before unverified text is streamed',
              'legitimate_insufficient_context_without_parser_failure': 'passed',
              'limitations': ['Public weights are not proven byte-identical to Mac encrypted service assets', 'E4B/12B not tested on this host; chooser exposes memory requirements'],
            })}\n',
          );
        passed = true;
      } finally {
        final report = env['FORESIGHT_GEMMA_REPORT'];
        if (!passed && report != null) {
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'status': 'failed',
              'runtime': domain.generator?.effectiveState,
              'answers': store.rows(
                'SELECT question,body,status,model FROM answers',
              ),
            }),
          );
        }
        await app.close();
        domain.close();
        await domain.drain();
        await helper.close();
        store.close();
        dir.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['FORESIGHT_GEMMA_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
