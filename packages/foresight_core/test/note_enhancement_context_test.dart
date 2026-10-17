import 'package:foresight_core/src/reference_note_enhancement_context.dart';
import 'package:test/test.dart';

void main() {
  test('deduplicates trimmed excerpt text in batch encounter order', () {
    final context = buildNoteEnhancementBatchContext(
      chunks: [' First ', 'Second', '\tFirst\n', '   '],
      pendingNotes: [
        (originalIndex: 8, text: 'one'),
        (originalIndex: 3, text: 'two'),
      ],
      selectedRefs: [
        [0, 2, 3],
        [1, 0, 99],
      ],
      batch: [1, 0],
      previousEnhanced: {3: '**Previous**', 0: 'Wrong index'},
      isLastBatch: false,
    );
    expect(
      context.relevantExcerpts,
      '<excerpt id="E0">\nSecond\n</excerpt>\n'
      '<excerpt id="E1">\nFirst\n</excerpt>\n',
    );
    expect(
      context.shorthandNotes,
      '<item id="1">\n  <scribble>two</scribble>\n  <previous_enhanced>**Previous**</previous_enhanced>\n  <excerpt_refs>E0, E1</excerpt_refs>\n</item>\n'
      '<item id="2">\n  <scribble>one</scribble>\n  \n  <excerpt_refs>E1, E1</excerpt_refs>\n</item>\n',
    );
    expect(context.uncoveredExcerpts, '');
    expect(context.includeMissedTopics, isFalse);
  });

  test(
    'keeps raw scribble, previous enhancement and excerpt markup unchanged',
    () {
      final context = buildNoteEnhancementBatchContext(
        chunks: [' <tag>& value</tag> '],
        pendingNotes: [(originalIndex: 10, text: '<raw>&')],
        selectedRefs: [
          [0],
        ],
        batch: [0],
        previousEnhanced: {10: ' '},
        isLastBatch: true,
      );
      expect(context.relevantExcerpts, contains('<tag>& value</tag>'));
      expect(context.shorthandNotes, contains('<scribble><raw>&</scribble>'));
      expect(
        context.shorthandNotes,
        contains('<previous_enhanced> </previous_enhanced>'),
      );
    },
  );

  test('missing and empty excerpts leave an empty reference element', () {
    final context = buildNoteEnhancementBatchContext(
      chunks: [' '],
      pendingNotes: [(originalIndex: 0, text: 'note')],
      selectedRefs: [
        [0, 100],
      ],
      batch: [0],
      isLastBatch: true,
    );
    expect(context.relevantExcerpts, '');
    expect(context.shorthandNotes, contains('<excerpt_refs></excerpt_refs>'));
  });

  for (final isLive in [true, false]) {
    for (final isLastBatch in [true, false]) {
      test('uncovered gating live=$isLive last=$isLastBatch', () {
        final context = buildNoteEnhancementBatchContext(
          chunks: [],
          pendingNotes: [],
          selectedRefs: [],
          batch: [],
          uncoveredChunks: [' decision ', 'risk'],
          isLive: isLive,
          isLastBatch: isLastBatch,
        );
        expect(context.includeMissedTopics, !isLive && isLastBatch);
        expect(
          context.uncoveredExcerpts,
          !isLive && isLastBatch
              ? '<uncovered_meeting_excerpts>\n'
                    '<uncovered_excerpt id="U0">\n decision \n</uncovered_excerpt>\n'
                    '<uncovered_excerpt id="U1">\nrisk\n</uncovered_excerpt>\n'
                    '</uncovered_meeting_excerpts>\n'
              : '',
        );
      });
    }
  }

  test(
    'uncovered selection skips used indices and caps matches in original order',
    () {
      expect(
        selectUncoveredNoteEnhancementExcerpts(
          [
            'Decision already referenced',
            'unrelated prose',
            ' NEXT STEP tomorrow ',
            'risk assessment',
            'budget review',
          ],
          [
            [0, 0],
          ],
        ),
        [' NEXT STEP tomorrow ', 'risk assessment'],
      );
    },
  );

  test(
    'uncovered keywords are case insensitive, word bounded, and use exact spaces',
    () {
      expect(
        selectUncoveredNoteEnhancementExcerpts([
          'undecided',
          'riskier',
          'action  item',
          'FOLLOW UP',
          'launching',
          'approved!',
        ], []),
        ['FOLLOW UP', 'approved!'],
      );
    },
  );

  test('uncovered usage is per chunk index rather than deduplicated text', () {
    expect(
      selectUncoveredNoteEnhancementExcerpts(
        ['decision', 'decision'],
        [
          [0],
        ],
      ),
      ['decision'],
    );
    expect(selectUncoveredNoteEnhancementExcerpts([], []), isEmpty);
  });
}
