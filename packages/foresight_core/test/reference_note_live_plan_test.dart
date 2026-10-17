import 'package:foresight_core/src/reference_note_live_plan.dart';
import 'package:test/test.dart';

void main() {
  test('only raw LF growth enters immediate targeting', () {
    for (final text in ['changed', 'changed\nsecond', 'shorter']) {
      expect(
        planNoteLiveEnhancementTargets(
          previousNotes: 'old\nsecond',
          notes: text,
          hasEnhanceableScribbles: true,
          lastSuccessfulShorthand: ['old', 'second'],
          staleIndices: {0},
        ),
        isNull,
      );
    }
  });

  test('enhanceable guard can reject LF growth even with stale indices', () {
    expect(
      planNoteLiveEnhancementTargets(
        previousNotes: 'old',
        notes: 'old\nnew',
        hasEnhanceableScribbles: false,
        lastSuccessfulShorthand: ['old'],
        staleIndices: {0},
      ),
      isNull,
    );
  });

  test(
    'new, changed and stale positions are selected together in encounter order',
    () {
      final stale = {1, 99};
      final baseline = ['same', 'same stale', 'old'];
      expect(
        planNoteLiveEnhancementTargets(
          previousNotes: 'same\nsame stale\nold',
          notes: 'same\nsame stale\nchanged\nnew',
          hasEnhanceableScribbles: true,
          lastSuccessfulShorthand: baseline,
          staleIndices: stale,
        )?.toList(),
        [1, 2, 3],
      );
      expect(stale, {1, 99});
      expect(baseline, ['same', 'same stale', 'old']);
    },
  );

  test(
    'target positions use meaningful extraction while growth uses raw LF count',
    () {
      expect(
        planNoteLiveEnhancementTargets(
          previousNotes: 'same',
          notes: ' \n123\n -- ** • \n same \n new \r',
          hasEnhanceableScribbles: true,
          lastSuccessfulShorthand: ['same'],
        ),
        {1},
      );
    },
  );

  test(
    'LF growth with no changed meaningful lines consumes branch with empty targets',
    () {
      expect(
        planNoteLiveEnhancementTargets(
          previousNotes: 'same',
          notes: 'same\n\n',
          hasEnhanceableScribbles: true,
          lastSuccessfulShorthand: ['same'],
        ),
        isEmpty,
      );
    },
  );

  test(
    'comparisons remain exact and do not normalize spelling or marker changes',
    () {
      expect(
        planNoteLiveEnhancementTargets(
          previousNotes: 'owner',
          notes: '1. OWNER\n* **Enhanced**: changed',
          hasEnhanceableScribbles: true,
          lastSuccessfulShorthand: ['owner', '* **Enhanced**: original'],
        ),
        {0, 1},
      );
    },
  );
}
