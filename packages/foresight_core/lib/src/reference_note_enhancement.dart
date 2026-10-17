/// NotesEnhancer.cleanTags in the original removes these three marker patterns
/// in order. All four RegExp flags are explicitly false, including caseSensitive.
String cleanNoteEnhancementTags(String text) {
  for (final pattern in _noteMarkerPatterns) {
    text = text.replaceAll(pattern, '');
  }
  return text;
}

bool isAlreadyEnhancedNoteLine(String line) {
  final text = line.trim();
  return const ['### 💡', '💡', '## ', '# '].any(text.startsWith) ||
      _enhancedBulletPattern.hasMatch(text);
}

bool isNoteEnhancementStatus(String text) => const [
  'Evaluating notes...',
  'Scanning the transcripts...',
  'Structuring notes...',
].contains(text);

String formatEnhancedNotesWithSpacing(Iterable<String> notes) => notes
    .map((note) => note.trim())
    .where((note) => note.isNotEmpty)
    .join('\n\n');

List<String> extractEnhancedNoteBullets(String text) =>
    extractEnhancedNoteBulletsFromLines(text.trim().split('\n'));

List<String> extractEnhancedNoteBulletsFromLines(Iterable<String> lines) {
  final bullets = <String>[];
  for (final text
      in lines.map((line) => line.trim()).where((line) => line.isNotEmpty)) {
    if (text.contains('Potential Important Topics Not In Notes')) break;
    if (!text.startsWith('#') &&
        (const ['* ', '- ', '+ ', '• '].any(text.startsWith) ||
            isAlreadyEnhancedNoteLine(text))) {
      bullets.add(text);
    }
  }
  return bullets;
}

final _enhancedBulletPattern = RegExp(
  r'^[\*\-]\s+\*\*(.+?)\*\*:?\s*(.+)',
  caseSensitive: false,
);

final _noteMarkerPatterns = [
  RegExp(
    r'(?:<\s*/?\s*[lL]?\s*:?\s*\d*(?::\d+)*\s*>|[lL]?\s*:?\s*\d+(?::\d+)*\s*>|</?line(\s+id="\d+")?>\s*)',
    caseSensitive: false,
  ),
  RegExp(r'<\s*[lL]\s*:\s*', caseSensitive: false),
  RegExp(r'</?\s*[lL](?:\s*:\s*\d*)?\s*$', caseSensitive: false),
];
