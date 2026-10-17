import 'package:foresight_core/src/reference_note_enhancement_merge.dart';
import 'package:test/test.dart';

const heading = '### 💡 Potential Important Topics Not In Notes';

void main() {
  NoteEnhancementMerge twoNotes({
    bool isLive = false,
    Map<int, String> previous = const {},
  }) => NoteEnhancementMerge(
    originalNotes: ['raw one', 'raw two'],
    pendingNotes: [
      (originalIndex: 0, text: 'one'),
      (originalIndex: 1, text: 'two'),
    ],
    previousEnhanced: previous,
    isLive: isLive,
  );

  test(
    'each preview starts fresh and shorter parses restore accepted prior text',
    () {
      final merge = twoNotes(previous: {1: '- Previous two'});
      expect(
        merge.previewCleaned('- New one\n- New two', [0, 1]).body,
        '- New one\n\n- New two',
      );
      expect(
        merge.previewCleaned('- Revised one', [0, 1]).body,
        '- Revised one\n\n- Previous two',
      );
      expect(merge.accepted, {1: '- Previous two'});
      expect(merge.finalBody, 'raw one\n\n- Previous two');
    },
  );

  test(
    'batch order maps through pending original indices before display ordering',
    () {
      final merge = NoteEnhancementMerge(
        originalNotes: ['raw A', 'raw B', 'raw C'],
        pendingNotes: [
          (originalIndex: 0, text: 'A'),
          (originalIndex: 2, text: 'C'),
        ],
      );
      final preview = merge.previewCleaned('- C\n- A', [1, 0]);
      expect(preview.body, '- A\n\nraw B\n\n- C');
      expect(preview.activeIndex, 0);
    },
  );

  test('live mode suppresses streamed and final topics', () {
    final merge = twoNotes(isLive: true);
    final text = '- Primary\n$heading\n- Topic';
    final preview = merge.previewCleaned(text, [0]);
    expect(preview.body, '- Primary\n\nraw two');
    expect(preview.activeIndex, 0);
    merge.acceptCleaned(text, [0]);
    expect(merge.savedTopics, isEmpty);
    expect(merge.finalBody, '- Primary\n\nraw two');
  });

  test(
    'preview independently rescans topic bullets and deduplicates exact strings',
    () {
      final merge = twoNotes();
      final preview = merge.previewCleaned(
        '- Primary\n$heading\nprose omitted\n- Topic\n- Topic\n* Topic',
        [0],
      );
      expect(
        preview.body,
        '- Primary\n\nraw two\n\n$heading\n\n- Topic\n\n* Topic',
      );
      expect(preview.activeIndex, 4);
      expect(merge.savedTopics, isEmpty);
    },
  );

  test(
    'final omissions preserve accepted notes and normalize only missing shorthand',
    () {
      final merge = twoNotes(previous: {0: '- Accepted'});
      merge.acceptCleaned('unusable prose', [0, 1]);
      expect(merge.accepted, {0: '- Accepted', 1: '* two'});
      expect(merge.finalBody, '- Accepted\n\n* two');
    },
  );

  test(
    'final parse commits terminal content rather than the last interim map',
    () {
      final merge = twoNotes();
      merge.previewCleaned('- Interim one\n- Interim two', [0, 1]);
      merge.acceptCleaned('- Terminal', [0, 1]);
      expect(merge.finalBody, '- Terminal\n\n* two');
      expect(merge.accepted, {0: '- Terminal', 1: '* two'});
    },
  );

  test(
    'saved topics establish preview section state for subsequent batches',
    () {
      final merge = twoNotes();
      merge.acceptCleaned('- First\n$heading\n- Topic', [0]);
      final preview = merge.previewCleaned('- Second\n- Topic\n- More', [1]);
      expect(
        preview.body,
        '- First\n\n- Second\n\n$heading\n\n- Topic\n\n- More',
      );
      expect(preview.activeIndex, 4);
    },
  );

  test(
    'final topic parsing retains prose and deduplicates against saved topics only',
    () {
      final merge = twoNotes();
      merge.acceptCleaned('- First\n$heading\nprose\n- First', [0]);
      merge.acceptCleaned('- Second\n$heading\nprose\n- First', [1]);
      expect(merge.savedTopics, [heading, 'prose', '- First']);
      expect(
        merge.finalBody,
        '- First\n\n- Second\n\n$heading\n\nprose\n\n- First',
      );
    },
  );
}
