/// NotesEnhancer.cleanTags in the original removes these three marker patterns
/// in order. All four RegExp flags are explicitly false, including caseSensitive.
String cleanNoteEnhancementTags(String text) {
  for (final pattern in _noteMarkerPatterns) {
    text = text.replaceAll(pattern, '');
  }
  return text;
}

final _noteMarkerPatterns = [
  RegExp(
    r'(?:<\s*/?\s*[lL]?\s*:?\s*\d*(?::\d+)*\s*>|[lL]?\s*:?\s*\d+(?::\d+)*\s*>|</?line(\s+id="\d+")?>\s*)',
    caseSensitive: false,
  ),
  RegExp(r'<\s*[lL]\s*:\s*', caseSensitive: false),
  RegExp(r'</?\s*[lL](?:\s*:\s*\d*)?\s*$', caseSensitive: false),
];
