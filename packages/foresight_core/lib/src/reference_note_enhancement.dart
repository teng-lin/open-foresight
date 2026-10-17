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

/// NotesEnhancer._cleanModelOutput (0x100a322b0). The header expression
/// applies to the complete response, with caseSensitive=true and multiline=false.
String cleanNoteEnhancementModelOutput(String text) {
  var end = text.length;
  for (final marker in const [
    '</output>',
    '<turn|>',
    '<eos>',
    '<end_of_turn>',
  ]) {
    final index = text.indexOf(marker);
    if (index >= 0 && index < end) end = index;
  }
  return text.substring(0, end).replaceAll(_keyNotesHeaderPattern, '').trim();
}

final _keyNotesHeaderPattern = RegExp(r'^\s*#+\s*Key\s*Notes\s*$');

/// Interim enhanceStream cleanup (0x100a2f1e0–0x100a2f590). Fence removal
/// applies to previews only; final batch acceptance uses the model cleaner.
String cleanNoteEnhancementPreviewOutput(String text) {
  var cleaned = cleanNoteEnhancementModelOutput(text.trim());
  if (cleaned.startsWith('```markdown')) {
    cleaned = cleaned.substring(11).trim();
  } else if (cleaned.startsWith('```')) {
    cleaned = cleaned.substring(3).trim();
  }
  if (cleaned.endsWith('```')) {
    cleaned = cleaned.substring(0, cleaned.length - 3).trim();
  }
  return cleaned;
}

/// Original _clusterScribblesIntoBatches (0x100a328bc), returning note indices.
/// References are indexed by note. The initial seed is never budget-rejected.
List<List<int>> clusterNoteEnhancementBatches(
  List<List<int>> transcriptReferences,
  int noteCount,
) {
  final remaining = List<int>.generate(noteCount, (index) => index);
  final batches = <List<int>>[];
  while (remaining.isNotEmpty) {
    final seed = remaining.removeAt(0);
    final batch = [seed];
    final excerpts = transcriptReferences[seed].toSet();
    void scan({required bool requireOverlap}) {
      var index = 0;
      while (index < remaining.length && batch.length < 4) {
        final candidate = remaining[index];
        final refs = transcriptReferences[candidate];
        if (requireOverlap && !refs.any(excerpts.contains)) {
          index++;
          continue;
        }
        final union = {...excerpts, ...refs};
        if (union.length * 350 + (batch.length + 1) * 50 + 300 > 2000) {
          index++;
          continue;
        }
        batch.add(candidate);
        excerpts.addAll(refs);
        remaining.removeAt(index);
      }
    }

    scan(requireOverlap: true);
    if (batch.length < 2 && remaining.isNotEmpty) {
      scan(requireOverlap: false);
    }
    batches.add(batch);
  }
  return batches;
}

/// Original parseBatchOutput returns two lists in X0/X1. The topic heading
/// itself belongs to missedTopics when parseMissedTopics is enabled.
({List<String> notes, List<String> missedTopics})
parseNoteEnhancementBatchOutput(
  String text,
  int maxNotes, {
  bool parseMissedTopics = false,
}) {
  final notes = <String>[];
  final missedTopics = <String>[];
  var inMissedTopics = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (inMissedTopics) {
      missedTopics.add(line);
      continue;
    }
    if (line.contains('Potential Important Topics Not In Notes')) {
      if (!parseMissedTopics) break;
      missedTopics.add(line);
      inMissedTopics = true;
      continue;
    }
    if (notes.length >= maxNotes || _noteMarkerOnlyPattern.hasMatch(line)) {
      continue;
    }
    if (line.startsWith('**')) {
      notes.add('* $line');
    } else if (line.startsWith('*') || line.startsWith('-')) {
      notes.add(line);
    }
  }
  return (notes: notes, missedTopics: missedTopics);
}

final _noteMarkerOnlyPattern = RegExp(r'^[*\-]+$', caseSensitive: false);

/// Original hasMeaningfulContent removes only the recovered leading markers.
bool hasMeaningfulNoteEnhancementContent(String text) =>
    text.replaceAll(_meaninglessNotePrefix, '').trim().isNotEmpty;

final _meaninglessNotePrefix = RegExp(r'^[\s\*\-•\d\.\)\:]+');

String toNoteEnhancementFallbackBullet(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('*') || trimmed.startsWith('-')
      ? trimmed
      : '* $trimmed';
}

/// Original consumer map rebuild (0x1006ea688–0x1006ea8d8) pairs by ordinal.
/// Raw extraction retains topic headings, unlike producer input planning.
Map<int, String> mapNoteEnhancementPriorBullets({
  required String notes,
  required String enhancedNotes,
}) {
  final enhancedText = enhancedNotes.trim();
  if (enhancedText.isEmpty) return {};
  final shorthand = notes
      .split('\n')
      .map((line) => line.trim())
      .where(
        (line) => line.isNotEmpty && hasMeaningfulNoteEnhancementContent(line),
      )
      .toList();
  final enhanced = extractEnhancedNoteBullets(enhancedText);
  return {
    for (
      var index = 0;
      index < shorthand.length && index < enhanced.length;
      index++
    )
      index: enhanced[index],
  };
}

/// NotesEnhancer.hasEnhanceableScribbles (0x100a4cca0): trim and retain
/// meaningful lines, then accept any line not already in enhanced form.
bool hasEnhanceableNoteScribbles(String notes) => notes
    .split('\n')
    .map((line) => line.trim())
    .where(
      (line) => line.isNotEmpty && hasMeaningfulNoteEnhancementContent(line),
    )
    .any((line) => !isAlreadyEnhancedNoteLine(line));
