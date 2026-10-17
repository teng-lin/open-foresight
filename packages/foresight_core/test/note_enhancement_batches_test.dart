import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:test/test.dart';

void main() {
  test('empty notes produce no batches', () {
    expect(clusterNoteEnhancementBatches([], 0), isEmpty);
  });

  test('overlap scan expands its union without revisiting earlier misses', () {
    final refs = [
      [0],
      [1],
      [0, 1],
      [1],
    ];
    expect(clusterNoteEnhancementBatches(refs, 4), [
      [0, 2, 3],
      [1],
    ]);
    expect(refs, [
      [0],
      [1],
      [0, 1],
      [1],
    ]);
  });

  test('multi-note overlap batches do not fill with unrelated notes', () {
    expect(
      clusterNoteEnhancementBatches([
        [0],
        [0],
        [1],
        [2],
      ], 4),
      [
        [0, 1],
        [2, 3],
      ],
    );
  });

  test('singleton fallback packs unrelated notes up to the four-note cap', () {
    expect(
      clusterNoteEnhancementBatches([
        [0],
        [1],
        [2],
        [3],
        [4],
      ], 5),
      [
        [0, 1, 2, 3],
        [4],
      ],
    );
  });

  test('overlap scan enforces the same four-note cap', () {
    expect(clusterNoteEnhancementBatches(List.generate(6, (_) => [0]), 6), [
      [0, 1, 2, 3],
      [4, 5],
    ]);
  });

  test(
    'union budget deduplicates references and skips an expensive candidate',
    () {
      expect(
        clusterNoteEnhancementBatches([
          [0, 1, 1, 2, 3],
          [0, 4],
          [0, 1],
        ], 3),
        [
          [0, 2],
          [1],
        ],
      );
    },
  );

  test(
    'singleton fallback also skips candidates that exceed the union budget',
    () {
      expect(
        clusterNoteEnhancementBatches([
          [0, 1, 2],
          [3, 4],
          [3],
        ], 3),
        [
          [0, 2],
          [1],
        ],
      );
    },
  );

  test('over-budget seed remains a batch rather than being dropped', () {
    expect(
      clusterNoteEnhancementBatches([
        List.generate(8, (i) => i),
        [0],
      ], 2),
      [
        [0],
        [1],
      ],
    );
  });
}
