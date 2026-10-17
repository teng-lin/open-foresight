import 'reference_note_enhancement.dart';
import 'reference_note_enhancement_context.dart';

/// Original per-batch preview and accepted-output merge. Callers own generation,
/// response preprocessing, iterator cancellation and conversation disposal.
class NoteEnhancementMerge {
  NoteEnhancementMerge({
    required this.originalNotes,
    required this.pendingNotes,
    Map<int, String> previousEnhanced = const {},
    this.isLive = false,
  }) : accepted = Map.of(previousEnhanced);

  final List<String> originalNotes;
  final List<PendingNoteEnhancement> pendingNotes;
  final bool isLive;
  final Map<int, String> accepted;
  final List<String> savedTopics = [];

  /// Nonempty trimmed terminal response lines and per-note failure fallbacks.
  /// This corresponds to the diagnostic list cleared before batch generation.
  final List<String> diagnosticLines = [];

  ({String body, int activeIndex}) previewCleaned(
    String cleaned,
    List<int> batch,
  ) {
    final parsed = parseNoteEnhancementBatchOutput(cleaned, batch.length).notes;
    final current = <int, String>{};
    var active = pendingNotes[batch.first].originalIndex;
    for (var position = 0; position < parsed.length; position++) {
      active = pendingNotes[batch[position]].originalIndex;
      current[active] = parsed[position];
    }
    final output = [
      for (var index = 0; index < originalNotes.length; index++)
        if (current.containsKey(index))
          current[index]!
        else if (accepted.containsKey(index))
          accepted[index]!
        else
          originalNotes[index],
    ];
    var addedTopic = false;
    if (!isLive) {
      output.addAll(savedTopics);
      for (final raw in cleaned.split('\n')) {
        final line = raw.trim();
        final heading = line.contains(_topicHeading);
        final topicBullet =
            output.any((note) => note.contains(_topicHeading)) &&
            (line.startsWith('*') || line.startsWith('-'));
        if ((heading || topicBullet) && !output.contains(line)) {
          output.add(line);
          addedTopic = true;
        }
      }
    }
    return (
      body: formatEnhancedNotesWithSpacing(output),
      activeIndex: addedTopic ? output.length - 1 : active,
    );
  }

  void acceptCleaned(String cleaned, List<int> batch) {
    // Terminal-response diagnostics at 0x100a301a4–0x100a30390.
    diagnosticLines.addAll(
      cleaned
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty),
    );
    final parsed = parseNoteEnhancementBatchOutput(
      cleaned,
      batch.length,
      parseMissedTopics: !isLive,
    );
    for (final topic in parsed.missedTopics) {
      if (!savedTopics.contains(topic)) savedTopics.add(topic);
    }
    for (var position = 0; position < parsed.notes.length; position++) {
      accepted[pendingNotes[batch[position]].originalIndex] =
          parsed.notes[position];
    }
    for (final index in batch) {
      final note = pendingNotes[index];
      accepted.putIfAbsent(
        note.originalIndex,
        () => toNoteEnhancementFallbackBullet(note.text),
      );
    }
  }

  /// The per-batch catch handler (0x100a30d2c–0x100a31098) replaces every
  /// batch entry unconditionally, including prior accepted enhancements.
  /// Conversation disposal and error logging remain the producer's job.
  void failBatch(List<int> batch) {
    for (final index in batch) {
      final note = pendingNotes[index];
      final fallback = toNoteEnhancementFallbackBullet(note.text);
      diagnosticLines.add(fallback);
      accepted[note.originalIndex] = fallback;
    }
  }

  String get finalBody => formatEnhancedNotesWithSpacing([
    for (var index = 0; index < originalNotes.length; index++)
      if (accepted.containsKey(index))
        accepted[index]!
      else
        originalNotes[index],
    if (!isLive) ...savedTopics,
  ]);
}

const _topicHeading = 'Potential Important Topics Not In Notes';
