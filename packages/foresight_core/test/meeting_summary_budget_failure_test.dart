import 'dart:convert';

import 'package:foresight_core/src/summary_generator.dart';
import 'package:foresight_core/src/summary_prompt.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a single oversized word refuses mapping without invoking completion',
    () async {
      var calls = 0;
      final generator = SummaryGenerator(
        countTokens: (text) async => utf8.encode(text).length,
        complete: (_, __, ___) async {
          calls++;
          return 'must not be used';
        },
        checkCurrent: () {},
        onProgress: (_) {},
      );
      await expectLater(
        generator.generate('界' * 2000, identity: 'owned-model'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('transcript word'),
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  for (final allowance in [0, 1]) {
    test(
      'reduction framing with $allowance byte allowance rejects irreducible summaries',
      () async {
        const output = 128;
        final context =
            utf8
                .encode(
                  '$summarySourcePolicy$summaryFullInstructions\n\n${summaryReducePrompt('')}',
                )
                .length +
            output +
            128 +
            allowance;
        var maps = 0, reduces = 0;
        final generator = SummaryGenerator(
          contextTokens: context,
          outputTokens: output,
          countTokens: (text) async => utf8.encode(text).length,
          checkCurrent: () {},
          onProgress: (_) {},
          complete: (prompt, _, __) async {
            if (prompt.startsWith(summaryChunkStart)) {
              maps++;
            } else {
              reduces++;
            }
            return 'Z';
          },
        );
        await expectLater(
          generator.generate('owned word ' * 1000, identity: 'owned-model'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('Summary reduction exceeds'),
            ),
          ),
        );
        expect(maps, greaterThan(1));
        expect(reduces, allowance == 0 ? 0 : greaterThan(0));
      },
    );
  }
}
