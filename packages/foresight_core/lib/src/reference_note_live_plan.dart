import 'reference_note_enhancement.dart';

/// Immediate raw-edit planning from _onShorthandChanged (0x100aa6d00).
/// Null means the LF-growth/enhanceable guard did not select this branch, so the
/// caller continues to its debounce path. An empty set means the branch was
/// selected but no indices need enhancement; the original returns immediately.
/// The caller supplies the recovered hasEnhanceableScribbles result and owns
/// auto-enhancement, live-meeting, active-generation and timer guards.
Set<int>? planNoteLiveEnhancementTargets({
  required String previousNotes,
  required String notes,
  required bool hasEnhanceableScribbles,
  required List<String> lastSuccessfulShorthand,
  Set<int> staleIndices = const {},
}) {
  // The growth guard counts raw LF-delimited lines, including blank lines and
  // lines which meaningful-content extraction subsequently removes.
  if (notes.split('\n').length <= previousNotes.split('\n').length ||
      !hasEnhanceableScribbles) {
    return null;
  }
  final current = notes
      .split('\n')
      .map((line) => line.trim())
      .where(
        (line) => line.isNotEmpty && hasMeaningfulNoteEnhancementContent(line),
      )
      .toList();
  return {
    for (var index = 0; index < current.length; index++)
      if (index >= lastSuccessfulShorthand.length ||
          current[index] != lastSuccessfulShorthand[index] ||
          staleIndices.contains(index))
        index,
  };
}
