import 'package:foresight_core/src/reference_note_enhancement_ranking.dart';
import 'package:test/test.dart';

void main() {
  test('cosine preserves sign and normalizes vector magnitude', () {
    expect(noteEnhancementCosineSimilarity([3, 0], [7, 0]), 1);
    expect(noteEnhancementCosineSimilarity([3, 0], [-7, 0]), -1);
    expect(noteEnhancementCosineSimilarity([3, 0], [0, 7]), 0);
    expect(noteEnhancementCosineSimilarity([3, 4], [1, 0]), closeTo(.6, 1e-15));
  });

  test('empty, unequal-length and zero-norm vectors score zero', () {
    expect(noteEnhancementCosineSimilarity([], [1]), 0);
    expect(noteEnhancementCosineSimilarity([1], []), 0);
    expect(noteEnhancementCosineSimilarity([1, 2], [1]), 0);
    expect(noteEnhancementCosineSimilarity([0, 0], [1, 2]), 0);
  });

  test('nonfinite arithmetic is retained without an invented repair', () {
    expect(noteEnhancementCosineSimilarity([double.nan], [1]), isNaN);
    expect(noteEnhancementCosineSimilarity([double.infinity], [1]), isNaN);
  });

  test(
    'five pending notes select two highest cosine scores in descending order',
    () {
      expect(
        selectNoteEnhancementExcerptRefs(
          noteEmbeddings: List.generate(5, (_) => [1, 0]),
          chunkEmbeddings: [
            [-100, 0],
            [0, 20],
            [3, 4],
            [1, 0],
          ],
        ),
        List.generate(5, (_) => [3, 2]),
      );
    },
  );

  test('six pending notes select only the highest score', () {
    expect(
      selectNoteEnhancementExcerptRefs(
        noteEmbeddings: List.generate(6, (_) => [1, 0]),
        chunkEmbeddings: [
          [0, 1],
          [1, 0],
        ],
      ),
      List.generate(6, (_) => [1]),
    );
  });

  test('an empty chunk vector makes every note use the first chunks', () {
    expect(
      selectNoteEnhancementExcerptRefs(
        noteEmbeddings: [
          [1, 0],
          [0, 1],
        ],
        chunkEmbeddings: [
          [-1, 0],
          [],
          [1, 0],
        ],
      ),
      [
        [0, 1],
        [0, 1],
      ],
    );
  });

  test('an empty note vector only changes that note to prefix fallback', () {
    expect(
      selectNoteEnhancementExcerptRefs(
        noteEmbeddings: [
          [],
          [1, 0],
        ],
        chunkEmbeddings: [
          [-1, 0],
          [0, 1],
          [1, 0],
        ],
      ),
      [
        [0, 1],
        [2, 1],
      ],
    );
  });

  test(
    'missing chunks and no pending notes preserve their output cardinality',
    () {
      expect(
        selectNoteEnhancementExcerptRefs(
          noteEmbeddings: [
            [1],
            [],
          ],
          chunkEmbeddings: [],
        ),
        [[], []],
      );
      expect(
        selectNoteEnhancementExcerptRefs(
          noteEmbeddings: [],
          chunkEmbeddings: [
            [1],
          ],
        ),
        isEmpty,
      );
    },
  );
}
