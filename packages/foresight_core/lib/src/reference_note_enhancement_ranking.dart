import 'dart:math' as math;

/// RagOrchestrator.computeCosineSimilarity (0x1006b4bb4). Empty, mismatched
/// or zero-norm vectors score zero. There is no epsilon or finite-value repair.
double noteEnhancementCosineSimilarity(List<double> left, List<double> right) {
  if (left.isEmpty || right.isEmpty || left.length != right.length) return 0;
  var dot = 0.0, leftNorm = 0.0, rightNorm = 0.0;
  for (var index = 0; index < left.length; index++) {
    dot += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }
  if (leftNorm == 0 || rightNorm == 0) return 0;
  return dot / (math.sqrt(leftNorm) * math.sqrt(rightNorm));
}

/// enhanceStream selection at 0x100a2cf28 and 0x100a2d53c–0x100a2d8a8.
/// Each vector corresponds to one pending shorthand note.
List<List<int>> selectNoteEnhancementExcerptRefs({
  required List<List<double>> noteEmbeddings,
  required List<List<double>> chunkEmbeddings,
}) {
  final count = noteEmbeddings.length > 5 ? 1 : 2;
  final missingChunkEmbedding = chunkEmbeddings.any((vector) => vector.isEmpty);
  return [
    for (final note in noteEmbeddings)
      if (note.isEmpty || missingChunkEmbedding)
        List.generate(math.min(count, chunkEmbeddings.length), (index) => index)
      else
        ([
              for (var index = 0; index < chunkEmbeddings.length; index++)
                (
                  chunkIndex: index,
                  score: noteEnhancementCosineSimilarity(
                    note,
                    chunkEmbeddings[index],
                  ),
                ),
            ]..sort((left, right) => right.score.compareTo(left.score)))
            .take(count)
            .map((entry) => entry.chunkIndex)
            .toList(),
  ];
}
