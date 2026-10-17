import 'dart:convert';

/// Shared live segment formatter at 0x1009ec80c. Parent note-generation calls
/// map this over all segments; whitespace and blank text remain unchanged.
String formatNoteTranscriptSegment({
  required String speaker,
  required String text,
}) => speaker.isEmpty ? text : '$speaker: $text';

/// Transcript manager formatSegments (0x1009ec774) filters on trimmed text
/// emptiness, then uses the shared formatter without trimming either field.
String formatLiveNoteTranscript(
  Iterable<({String speaker, String text})> segments,
) => segments
    .where((segment) => segment.text.trim().isNotEmpty)
    .map(
      (segment) => formatNoteTranscriptSegment(
        speaker: segment.speaker,
        text: segment.text,
      ),
    )
    .join('\n');

/// Saved transcript schema recovered from TranscriptSegment.fromJson.
class ReferenceTranscriptSegment {
  ReferenceTranscriptSegment({
    required this.title,
    required this.turns,
    this.durationSeconds,
  });

  final String title;
  final List<({String speaker, String text})> turns;
  final int? durationSeconds;
}

/// The original accepts a JSON list, falling back to legacy text on any
/// decoding/schema error. One malformed element invalidates the whole list.
List<ReferenceTranscriptSegment> parseStructuredTranscript(String raw) {
  if (raw.isEmpty) return [];
  if (raw.trim().startsWith('[')) {
    try {
      return (jsonDecode(raw.trim()) as List).map((value) {
        final map = value as Map<String, dynamic>;
        return ReferenceTranscriptSegment(
          title: (map['segment_title'] as String?) ?? 'Untitled Segment',
          turns:
              (map['turns'] as List?)?.map((value) {
                final turn = value as Map<String, dynamic>;
                return (
                  speaker: (turn['speaker'] as String?) ?? 'Unknown',
                  text: (turn['text'] as String?) ?? '',
                );
              }).toList() ??
              [],
          durationSeconds: (map['duration_seconds'] as num?)?.toInt(),
        );
      }).toList();
    } catch (_) {
      // The original catch retries the complete input as legacy text.
    }
  }
  final segments = <ReferenceTranscriptSegment>[];
  ReferenceTranscriptSegment? current;
  for (final rawLine in raw.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('--- [') && line.endsWith('] ---')) {
      current = ReferenceTranscriptSegment(
        title: line.substring(5, line.length - 5),
        turns: [],
      );
      segments.add(current);
      continue;
    }
    if (current == null) {
      current = ReferenceTranscriptSegment(title: 'Transcript', turns: []);
      segments.add(current);
    }
    final separator = line.indexOf(': ');
    current.turns.add((
      speaker: separator < 0 ? 'Transcript' : line.substring(0, separator),
      text: separator < 0 ? line : line.substring(separator + 2),
    ));
  }
  return segments;
}

bool isGenericTranscriptSpeaker(String speaker) {
  final normalized = speaker
      .replaceAll(RegExp(r'^[\[\(\*]+|[\]\)\*]+$'), '')
      .trim()
      .toLowerCase();
  return const {
    '',
    'microphone',
    'remote',
    'speaker',
    'unknown',
    'transcript',
  }.contains(normalized);
}

String formatStructuredTranscriptToText(
  Iterable<ReferenceTranscriptSegment> segments,
) {
  final buffer = StringBuffer();
  for (final segment in segments) {
    buffer.writeln('--- [${segment.title}] ---');
    for (final turn in segment.turns) {
      final speaker = turn.speaker.trim();
      buffer.writeln(
        isGenericTranscriptSpeaker(speaker)
            ? turn.text
            : '$speaker: ${turn.text}',
      );
    }
    buffer.writeln();
  }
  return buffer.toString();
}

/// Saved extraction probes JSON-like inputs only. Ordinary text is returned
/// verbatim; loadSavedTranscript trims each extracted record before joining.
String extractSavedTranscriptText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('[') ||
      (trimmed.startsWith('{') && trimmed.contains('"turns"'))) {
    final segments = parseStructuredTranscript(trimmed);
    if (segments.isNotEmpty) return formatStructuredTranscriptToText(segments);
  }
  return raw;
}
