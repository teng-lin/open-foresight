import 'reference_note_enhancement.dart';

typedef NoteEnhancementMappingPair = ({String shorthand, String enhanced});

/// Consumer edit state recovered from the original meeting note view.
class ReferenceNoteEditMapping {
  ReferenceNoteEditMapping({
    Map<int, String> accepted = const {},
    List<NoteEnhancementMappingPair> pairs = const [],
    List<String> lastSuccessfulShorthand = const [],
    List<String> lastSuccessfulEnhanced = const [],
    Set<int> staleIndices = const {},
  }) : accepted = Map.of(accepted),
       pairs = List.of(pairs),
       lastSuccessfulShorthand = List.of(lastSuccessfulShorthand),
       lastSuccessfulEnhanced = List.of(lastSuccessfulEnhanced),
       staleIndices = Set.of(staleIndices);

  /// Rebuild the ordinal map/pairs from current controller text, as the original
  /// _updateEnhancedBulletsMap does. This does not establish success snapshots.
  factory ReferenceNoteEditMapping.fromNotes({
    required String notes,
    required String enhancedNotes,
  }) {
    final shorthand = _extractShorthand(notes);
    final enhanced = extractEnhancedNoteBullets(enhancedNotes.trim());
    return ReferenceNoteEditMapping(
      accepted: mapNoteEnhancementPriorBullets(
        notes: notes,
        enhancedNotes: enhancedNotes,
      ),
      pairs: [
        for (
          var index = 0;
          index < shorthand.length && index < enhanced.length;
          index++
        )
          (shorthand: shorthand[index], enhanced: enhanced[index]),
      ],
    );
  }

  final Map<int, String> accepted;
  final List<NoteEnhancementMappingPair> pairs;
  final List<String> lastSuccessfulShorthand;
  final List<String> lastSuccessfulEnhanced;
  final Set<int> staleIndices;

  /// Successful manual generation rebuilds map/pairs at 0x100a4ab24 and
  /// replaces raw/enhanced comparison snapshots at 0x100a4ab50/0x100a4ab98.
  /// Live success performs the corresponding writes at 0x100a4c3a4–0x100a4c430.
  /// Cancellation restoration rebuilds only map/pairs, not these snapshots.
  void captureSuccess({required String notes, required String enhancedNotes}) {
    final rebuilt = ReferenceNoteEditMapping.fromNotes(
      notes: notes,
      enhancedNotes: enhancedNotes,
    );
    accepted
      ..clear()
      ..addAll(rebuilt.accepted);
    pairs
      ..clear()
      ..addAll(rebuilt.pairs);
    lastSuccessfulShorthand
      ..clear()
      ..addAll(_extractShorthand(notes));
    lastSuccessfulEnhanced
      ..clear()
      ..addAll(extractEnhancedNoteBullets(enhancedNotes));
  }

  /// Port lifecycle utility for discarding ephemeral workspace state.
  /// This is not an assertion about the original view's disposal behavior.
  void clear() {
    accepted.clear();
    pairs.clear();
    lastSuccessfulShorthand.clear();
    lastSuccessfulEnhanced.clear();
    staleIndices.clear();
  }

  /// _syncBulletsOnShorthandChange (0x100aa70f0): returns replacement enhanced
  /// controller/baseline text, or null when the original performs no write.
  String? syncShorthand({
    required String notes,
    required String enhancedNotes,
  }) {
    if (pairs.isEmpty) return null;
    final shorthand = _extractShorthand(notes);
    if (shorthand.isEmpty) {
      accepted.clear();
      pairs.clear();
      lastSuccessfulShorthand.clear();
      lastSuccessfulEnhanced.clear();
      return '';
    }
    final remaining = List.of(pairs);
    final currentEnhanced = extractEnhancedNoteBullets(enhancedNotes);
    final nextPairs = <NoteEnhancementMappingPair>[];
    final nextAccepted = <int, String>{};
    for (var index = 0; index < shorthand.length; index++) {
      final text = shorthand[index];
      var matched = remaining.indexWhere((pair) => pair.shorthand == text);
      if (matched < 0) {
        final normalized = _normalize(text);
        matched = remaining.indexWhere(
          (pair) => _normalize(pair.shorthand) == normalized,
        );
      }
      String? enhanced;
      if (matched >= 0) {
        enhanced = remaining.removeAt(matched).enhanced;
      } else if (index < currentEnhanced.length) {
        // The ordinal fallback does not consume any unmatched old pair.
        enhanced = currentEnhanced[index];
      }
      if (enhanced != null) {
        nextPairs.add((shorthand: text, enhanced: enhanced));
        nextAccepted[index] = enhanced;
      }
    }
    final changed =
        nextAccepted.length != accepted.length ||
        nextAccepted.entries.any((entry) => accepted[entry.key] != entry.value);
    if (!changed) return null;
    accepted
      ..clear()
      ..addAll(nextAccepted);
    pairs
      ..clear()
      ..addAll(nextPairs);
    // Native arguments 0x100aa79e0–0x100aa79f4 select PP19651 directly.
    // Preserve the substring beginning at the literal, dropping heading prefixes.
    final topicIndex = enhancedNotes.indexOf(_topicHeading);
    final tail = topicIndex < 0
        ? ''
        : enhancedNotes.substring(topicIndex).trim();
    final body = formatEnhancedNotesWithSpacing(nextAccepted.values);
    if (body.isEmpty) return tail;
    return tail.isEmpty ? body : '$body\n\n$tail';
  }

  /// _updateStaleBulletsAndMapping (0x100aa6858): compares current ordinal
  /// positions to the last successful lists; entries outside the current
  /// enhanced-list iteration are deliberately left alone.
  void updateStaleBullets({
    required String notes,
    required String enhancedNotes,
  }) {
    final currentEnhanced = extractEnhancedNoteBullets(enhancedNotes);
    if (currentEnhanced.isEmpty && lastSuccessfulEnhanced.isEmpty) {
      staleIndices.clear();
      return;
    }
    final currentShorthand = _extractShorthand(notes);
    final nextStale = <int>{};
    for (var index = 0; index < currentEnhanced.length; index++) {
      final enhancedChanged =
          index >= lastSuccessfulEnhanced.length ||
          currentEnhanced[index] != lastSuccessfulEnhanced[index];
      if (index < lastSuccessfulShorthand.length &&
          index < currentShorthand.length &&
          currentShorthand[index] == lastSuccessfulShorthand[index] &&
          !enhancedChanged) {
        accepted[index] = currentEnhanced[index];
      } else {
        nextStale.add(index);
        accepted.remove(index);
      }
    }
    staleIndices
      ..clear()
      ..addAll(nextStale);
  }
}

List<String> _extractShorthand(String notes) => notes
    .split('\n')
    .map((line) => line.trim())
    .where(
      (line) => line.isNotEmpty && hasMeaningfulNoteEnhancementContent(line),
    )
    .toList();

String _normalize(String text) =>
    text.replaceAll(_notePrefix, '').trim().toLowerCase();

final _notePrefix = RegExp(r'^[\s\*\-•\d\.\)\:]+');
const _topicHeading = 'Potential Important Topics Not In Notes';
