import 'package:foresight_core/src/question_similarity.dart';
import 'package:test/test.dart';

void main() {
  test(
    'edit ratio uses unit costs and maximum length rather than total length',
    () {
      expect(QuestionSimilarity.editDistance('kitten', 'sitting'), 3);
      expect(
        QuestionSimilarity.editRatio('kitten', 'sitting'),
        closeTo(4 / 7, 1e-12),
      );
      expect(QuestionSimilarity.editDistance('ab', 'ba'), 2);
      expect(QuestionSimilarity.editRatio('ab', 'ba'), 0);
      expect(QuestionSimilarity.editDistance('', 'abc'), 3);
      expect(QuestionSimilarity.editRatio('', 'abc'), 0);
      expect(QuestionSimilarity.editRatio('', ''), 1);
      expect(QuestionSimilarity.editRatio('same', 'same'), 1);
    },
  );

  test(
    'edit calculations preserve reference UTF-16 and normalization semantics',
    () {
      expect(QuestionSimilarity.editDistance('😀', '😃'), 1);
      expect(QuestionSimilarity.editRatio('😀', '😃'), .5);
      expect(QuestionSimilarity.editRatio('谁负责', '谁负责'), 1);
      expect(QuestionSimilarity.editDistance('谁负责', '谁安排'), 2);
      expect(QuestionSimilarity.editRatio('A', 'a'), 0);
      expect(QuestionSimilarity.editRatio('é', 'e\u0301'), 0);
    },
  );

  test(
    'partial ratio scans all offsets including the last one in either direction',
    () {
      expect(QuestionSimilarity.partialRatio('ship', 'will ship'), 1);
      expect(QuestionSimilarity.partialRatio('will ship', 'ship'), 1);
      expect(QuestionSimilarity.partialRatio('abc', 'xxabcyy'), 1);
      expect(
        QuestionSimilarity.partialRatio('abc', 'xxabd'),
        closeTo(2 / 3, 1e-12),
      );
      expect(
        QuestionSimilarity.partialRatio('abc', 'abd'),
        closeTo(2 / 3, 1e-12),
      );
      expect(QuestionSimilarity.partialRatio('😀', 'x😃'), .5);
      expect(QuestionSimilarity.partialRatio('', ''), 0);
      expect(QuestionSimilarity.partialRatio('abc', ''), 0);
    },
  );

  test(
    'token-set ratio sorts full sets and takes the larger shared-set score',
    () {
      expect(QuestionSimilarity.tokenSetRatio({'b', 'a'}, {'a', 'b'}), 1);
      expect(QuestionSimilarity.tokenSetRatio({'a'}, {'b', 'a'}), 1);
      expect(
        QuestionSimilarity.tokenSetRatio({'a', 'b'}, {'a', 'c'}),
        closeTo(1 / 3, 1e-12),
      );
      expect(QuestionSimilarity.tokenSetRatio({'a'}, {'b'}), 0);
      expect(QuestionSimilarity.tokenSetRatio({}, {}), 0);
      expect(
        QuestionSimilarity.tokenSetRatio({'谁', '负责'}, {'负责', '谁', '草稿'}),
        1,
      );
    },
  );

  test('Jaccard uses token sets and intersection over union', () {
    expect(QuestionSimilarity.jaccard({}, {}), 1);
    expect(QuestionSimilarity.jaccard({'a'}, {}), 0);
    expect(
      QuestionSimilarity.jaccard(
        {'who', 'owns', 'draft'},
        {'who', 'owns', 'notes'},
      ),
      .5,
    );
    expect(QuestionSimilarity.jaccard({'谁', '负责'}, {'谁', '负责'}), 1);
    expect(QuestionSimilarity.jaccard({'a'}, {'b'}), 0);
  });
}
