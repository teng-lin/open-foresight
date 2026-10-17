import 'reference_note_enhancement.dart';
import 'reference_note_enhancement_context.dart';

/// Input classification recovered from enhanceStream (0x100a2c118–0x100a2cb98).
/// Indices refer to the filtered originalNotes list, not source line numbers.
class NoteEnhancementPlan {
  const NoteEnhancementPlan({
    required this.originalNotes,
    required this.acceptedEnhancements,
    required this.pendingNotes,
    required this.skippedNotes,
    required this.initialEnhancedBody,
  });

  final List<String> originalNotes;
  final Map<int, String> acceptedEnhancements;
  final List<PendingNoteEnhancement> pendingNotes;

  /// Skipped text in encounter order, rather than indexed by original position.
  final List<String> skippedNotes;

  /// The prior-map snapshot emitted before classifying pending notes, if any.
  /// An empty original note list takes the producer's separate empty-input path.
  final String? initialEnhancedBody;
}

NoteEnhancementPlan planNoteEnhancement({
  required String notes,
  Map<int, String>? existingEnhancedBullets,
  Set<int>? targetBulletIndices,
  bool updateExistingWithTranscript = false,
}) {
  final meaningfulLines = notes
      .split('\n')
      .map((line) => line.trim())
      .where(
        (line) => line.isNotEmpty && hasMeaningfulNoteEnhancementContent(line),
      )
      .toList();
  final withoutTopics = <String>[];
  var inTopics = false;
  for (final line in meaningfulLines) {
    if (line.contains('Potential Important Topics Not In Notes')) {
      inTopics = true;
    } else if (!inTopics || (!line.startsWith('*') && !line.startsWith('-'))) {
      withoutTopics.add(line);
    }
  }
  final originalNotes = withoutTopics.isNotEmpty
      ? withoutTopics
      : meaningfulLines;
  final accepted = <int, String>{...?existingEnhancedBullets};
  final initialBody = originalNotes.isNotEmpty && accepted.isNotEmpty
      ? formatEnhancedNotesWithSpacing([
          for (var index = 0; index < originalNotes.length; index++)
            accepted[index] ?? originalNotes[index],
        ])
      : null;
  final skipped = <String>[];
  final pending = <PendingNoteEnhancement>[];
  for (var index = 0; index < originalNotes.length; index++) {
    final text = originalNotes[index];
    if ((targetBulletIndices != null && !targetBulletIndices.contains(index)) ||
        (!updateExistingWithTranscript &&
            (accepted.containsKey(index) || isAlreadyEnhancedNoteLine(text)))) {
      final preserved = accepted[index] ?? text;
      skipped.add(preserved);
      accepted[index] = preserved;
    } else {
      pending.add((originalIndex: index, text: text));
    }
  }
  return NoteEnhancementPlan(
    originalNotes: originalNotes,
    acceptedEnhancements: accepted,
    pendingNotes: pending,
    skippedNotes: skipped,
    initialEnhancedBody: initialBody,
  );
}
