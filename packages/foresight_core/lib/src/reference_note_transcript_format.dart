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
