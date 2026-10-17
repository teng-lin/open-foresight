/// Original pending scribble retains its position in the complete note list.
typedef PendingNoteEnhancement = ({int originalIndex, String text});

/// Unreferenced chunks matching the original decision/action expression, capped
/// at two in transcript order (enhanceStream 0x100a2da90–0x100a2db98).
List<String> selectUncoveredNoteEnhancementExcerpts(
  List<String> chunks,
  List<List<int>> selectedRefs,
) {
  final usage = List<int>.filled(chunks.length, 0);
  for (final refs in selectedRefs) {
    for (final ref in refs) {
      usage[ref]++;
    }
  }
  final uncovered = <String>[];
  for (var index = 0; index < chunks.length; index++) {
    if (usage[index] == 0 && _decisionPattern.hasMatch(chunks[index])) {
      uncovered.add(chunks[index]);
      if (uncovered.length >= 2) break;
    }
  }
  return uncovered;
}

/// Assemble the original raw XML fragments. Excerpts deduplicate by trimmed
/// text, IDs follow first encounter, and per-note reference duplicates remain.
({
  String relevantExcerpts,
  String shorthandNotes,
  String uncoveredExcerpts,
  bool includeMissedTopics,
})
buildNoteEnhancementBatchContext({
  required List<String> chunks,
  required List<PendingNoteEnhancement> pendingNotes,
  required List<List<int>> selectedRefs,
  required List<int> batch,
  Map<int, String> previousEnhanced = const {},
  List<String> uncoveredChunks = const [],
  bool isLive = false,
  required bool isLastBatch,
}) {
  final excerptIds = <String, String>{};
  for (final index in batch) {
    for (final ref in selectedRefs[index]) {
      if (ref >= chunks.length) continue;
      final text = chunks[ref].trim();
      if (text.isNotEmpty) {
        excerptIds.putIfAbsent(text, () => 'E${excerptIds.length}');
      }
    }
  }
  final relevant = StringBuffer();
  for (final entry in excerptIds.entries) {
    relevant.writeln('<excerpt id="${entry.value}">\n${entry.key}\n</excerpt>');
  }
  final includeMissedTopics =
      !isLive && isLastBatch && uncoveredChunks.isNotEmpty;
  final uncovered = StringBuffer();
  if (includeMissedTopics) {
    uncovered.writeln('<uncovered_meeting_excerpts>');
    for (var index = 0; index < uncoveredChunks.length; index++) {
      uncovered.writeln(
        '<uncovered_excerpt id="U$index">\n${uncoveredChunks[index]}\n</uncovered_excerpt>',
      );
    }
    uncovered.writeln('</uncovered_meeting_excerpts>');
  }
  final shorthand = StringBuffer();
  for (var position = 0; position < batch.length; position++) {
    final index = batch[position];
    final note = pendingNotes[index];
    final refs = selectedRefs[index]
        .where((ref) => ref < chunks.length)
        .map((ref) => excerptIds[chunks[ref].trim()] ?? '')
        .where((ref) => ref.isNotEmpty)
        .join(', ');
    final previous = previousEnhanced[note.originalIndex];
    final previousBlock = previous == null || previous.isEmpty
        ? ''
        : '<previous_enhanced>$previous</previous_enhanced>';
    shorthand.writeln(
      '<item id="${position + 1}">\n  <scribble>${note.text}</scribble>\n  $previousBlock\n  <excerpt_refs>$refs</excerpt_refs>\n</item>',
    );
  }
  return (
    relevantExcerpts: relevant.toString(),
    shorthandNotes: shorthand.toString(),
    uncoveredExcerpts: uncovered.toString(),
    includeMissedTopics: includeMissedTopics,
  );
}

final _decisionPattern = RegExp(
  r'\b(decided|decision|agreed|action item|next step|deadline|due date|launch|blocker|risk|approved|budget|assigned|follow up|priority)\b',
  caseSensitive: false,
);

/// The producer sorts batches containing any note absent from the previous
/// enhancement map first, without reordering the notes inside a batch.
void prioritizeNoteEnhancementBatches(
  List<List<int>> batches,
  List<PendingNoteEnhancement> pendingNotes,
  Map<int, String> previousEnhanced,
) {
  bool hasNewNote(List<int> batch) => batch.any(
    (index) => !previousEnhanced.containsKey(pendingNotes[index].originalIndex),
  );
  batches.sort((left, right) {
    final leftNew = hasNewNote(left);
    final rightNew = hasNewNote(right);
    if (leftNew && !rightNew) return -1;
    if (!leftNew && rightNew) return 1;
    return 0;
  });
}
