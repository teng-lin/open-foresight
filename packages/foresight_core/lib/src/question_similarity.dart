import 'dart:math' as math;

/// Calculations recovered from the reference's question similarity strategies.
/// Inputs are already normalized/tokenized by the caller. Thresholds and the
/// exact reference normalization are deliberately not supplied here.
abstract final class QuestionSimilarity {
  /// Reference _LevenshteinUtils.distance uses UTF-16 string indices and unit
  /// insertion, deletion and substitution costs (not transposition distance).
  static int editDistance(String left, String right) {
    if (left == right) return 0;
    if (left.isEmpty) return right.length;
    if (right.isEmpty) return left.length;
    var previous = List<int>.generate(right.length + 1, (i) => i);
    var current = List<int>.filled(right.length + 1, 0);
    for (var i = 0; i < left.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < right.length; j++) {
        final cost = left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = math.min(
          math.min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + cost,
        );
      }
      final scratch = previous;
      previous = current;
      current = scratch;
    }
    return previous[right.length];
  }

  /// Reference normalization is (max length - distance) / max length.
  static double editRatio(String left, String right) {
    final length = math.max(left.length, right.length);
    return length == 0 ? 1 : (length - editDistance(left, right)) / length;
  }

  /// Reference PartialRatioStrategy scans every equal-length substring,
  /// including the final possible offset, stopping early on a perfect match.
  /// Empty input is ineligible even though editRatio('', '') is one.
  static double partialRatio(String left, String right) {
    if (left.isEmpty || right.isEmpty) return 0;
    if (left.length == right.length) return editRatio(left, right);
    final shorter = left.length < right.length ? left : right;
    final longer = left.length < right.length ? right : left;
    var best = 0.0;
    for (var start = 0; start <= longer.length - shorter.length; start++) {
      final score = editRatio(
        shorter,
        longer.substring(start, start + shorter.length),
      );
      if (score > best) best = score;
      if (best == 1) break;
    }
    return best;
  }

  /// Reference TokenSetRatioStrategy compares the sorted intersection with
  /// each sorted full set and takes the larger edit ratio.
  static double tokenSetRatio(Set<String> left, Set<String> right) {
    if (left.isEmpty || right.isEmpty) return 0;
    final common = left.intersection(right);
    if (common.isEmpty) return 0;
    String joined(Set<String> tokens) => (tokens.toList()..sort()).join(' ');
    final shared = joined(common);
    return math.max(
      editRatio(shared, joined(left)),
      editRatio(shared, joined(right)),
    );
  }

  /// Reference JaccardIndexStrategy treats two empty sets as identical and
  /// one empty set as dissimilar; otherwise intersection / union.
  static double jaccard(Set<String> left, Set<String> right) {
    if (left.isEmpty && right.isEmpty) return 1;
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    return intersection / (left.length + right.length - intersection);
  }
}
