import 'dart:math' as math;

/// TranscriptEmbeddingManager._chunkAndEmbed trims input, selects live
/// (120/20) or saved (300/40) word windows, and retains the latest 50 chunks.
List<String> chunkNoteEnhancementTranscript(
  String text, {
  bool isLive = false,
  int? maxChunks = 50,
}) {
  text = text.trim();
  if (text.isEmpty) return [];
  final maxWords = isLive ? 120 : 300;
  final overlap = isLive ? 20 : 40;
  final words = text
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length <= maxWords) return [text];
  final chunks = <String>[];
  var start = 0;
  while (start < words.length) {
    var end = math.min(start + maxWords, words.length);
    if (end < words.length) {
      final searchStart = math.max(
        end - math.min(overlap, 40),
        start + maxWords ~/ 3,
      );
      for (var index = end - 1; index >= searchStart; index--) {
        if (_sentenceEndPattern.hasMatch(words[index])) {
          end = index + 1;
          break;
        }
      }
    }
    chunks.add(words.sublist(start, end).join(' '));
    if (end >= words.length) break;
    start = end - overlap > start ? end - overlap : end;
  }
  return maxChunks != null && chunks.length > maxChunks
      ? chunks.sublist(chunks.length - maxChunks)
      : chunks;
}

final _sentenceEndPattern = RegExp(r'[\.\?\!\;]["\x27\)]?$');
