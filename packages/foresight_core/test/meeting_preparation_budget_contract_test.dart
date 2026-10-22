import 'dart:async';
import 'dart:convert';

import 'package:foresight_core/src/meeting_preparation.dart';
import 'package:foresight_core/src/summary_generator.dart';
import 'package:test/test.dart';

void main() {
  test(
    'clipping budgets every source and preserves Unicode scalar boundaries',
    () {
      final parts = [
        'Source A ${'😀' * 300}',
        'Source B ${'界😀' * 300}',
        'Source C retained',
      ];
      for (final context in [350, 351, 352, 353, 512]) {
        final joined = fitWorkflowPartials(
          parts,
          system: 'source policy',
          prefix: 'reduce:',
          context: context,
          output: 64,
        );
        expect(joined.clipped, isTrue);
        final retained = joined.text.split('\n\n---\n\n');
        expect(retained, hasLength(parts.length));
        for (var i = 0; i < parts.length; i++) {
          final prefix = retained[i].endsWith('...')
              ? retained[i].substring(0, retained[i].length - 3)
              : retained[i];
          expect(parts[i], startsWith(prefix));
          expect(prefix, startsWith('Source ${String.fromCharCode(65 + i)}'));
          expect(utf8.decode(utf8.encode(prefix)), prefix);
        }
        expect(retained.last, parts.last);
        expect(
          utf8.encode('source policy\n\nreduce:${joined.text}').length +
              64 +
              128,
          lessThanOrEqualTo(context),
        );
      }
    },
  );

  test(
    'impossible document and combined-source budgets refuse before inference',
    () async {
      expect(() => workflowTextWindows('owned input', 127), throwsStateError);
      expect(
        () => fitWorkflowPartials(
          ['Source A ${'a' * 200}', 'Source B ${'b' * 200}'],
          system: 'policy',
          prefix: 'reduce',
          context: 150,
          output: 64,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('fewer documents'),
          ),
        ),
      );
      var calls = 0;
      await expectLater(
        summarizePreparationDocument(
          'source ' * 100,
          context: 512,
          output: 400,
          checkCurrent: () {},
          onProgress: (_) {},
          complete: (_, __, ___) async {
            calls++;
            return 'must not be used';
          },
        ),
        throwsStateError,
      );
      expect(calls, 0);
    },
  );

  test('empty MAP output cannot produce a preparation document', () async {
    final progress = <SummaryProgress>[];
    var calls = 0;
    await expectLater(
      summarizePreparationDocument(
        'owned document fact ' * 100,
        checkCurrent: () {},
        onProgress: progress.add,
        complete: (prompt, system, _) async {
          calls++;
          expect(prompt, startsWith(documentMapPrefix));
          expect(system, documentSummaryInstructions);
          return ' \n ';
        },
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          'Document model returned empty output',
        ),
      ),
    );
    expect(calls, 1);
    expect(progress.single.phase, 'documents');
    expect(progress.single.completed, 0);
  });

  test(
    'real multi-window MAP preserves every summary before empty REDUCE refusal',
    () async {
      final text = List.generate(150, (i) => 'Document fact $i: 中文😀. ').join();
      final maps = <String>[], progress = <SummaryProgress>[];
      String? reduction;
      await expectLater(
        summarizePreparationDocument(
          text,
          context: 1800,
          output: 128,
          checkCurrent: () {},
          onProgress: progress.add,
          complete: (prompt, system, _) async {
            expect(system, documentSummaryInstructions);
            expect(
              utf8.encode('$system\n\n$prompt').length + 128 + 128,
              lessThanOrEqualTo(1800),
            );
            if (prompt.startsWith(documentMapPrefix)) {
              final result = 'MAP_${maps.length} ${'界😀' * 80}';
              maps.add(result);
              return result;
            }
            expect(prompt, startsWith(documentReducePrefix));
            reduction = prompt;
            return '  ';
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'Document reduction returned empty output',
          ),
        ),
      );
      expect(maps.length, greaterThan(1));
      for (var i = 0; i < maps.length; i++) {
        expect(reduction, contains('MAP_$i '));
      }
      expect(progress.last.phase, 'reducing');
      expect(progress.last.completed, maps.length);
      expect(progress.last.total, maps.length);
    },
  );

  test(
    'cancellation rejects a held completion without reduction or further progress',
    () async {
      final entered = Completer<void>(), release = Completer<String>();
      var current = true, calls = 0;
      final progress = <SummaryProgress>[];
      final pending = summarizePreparationDocument(
        'owned fact ' * 500,
        checkCurrent: () {
          if (!current) throw StateError('owned preparation cancelled');
        },
        onProgress: progress.add,
        complete: (_, __, ___) {
          calls++;
          entered.complete();
          return release.future;
        },
      );
      // Attach the rejection handler before releasing work that can fail.
      final rejected = expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'owned preparation cancelled',
          ),
        ),
      );
      addTearDown(() async {
        current = false;
        if (!release.isCompleted) release.complete('late fact');
        await rejected;
      });
      await entered.future;
      current = false;
      release.complete('late fact');
      await rejected;
      expect(calls, 1);
      expect(progress.map((p) => p.phase), ['documents']);
    },
  );
}
