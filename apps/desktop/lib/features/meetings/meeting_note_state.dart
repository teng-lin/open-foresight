/// The original editor uses different timestamp priorities for stored and local
/// state. These are null fallbacks, never chronological maxima.
class MeetingNoteSnapshot {
  const MeetingNoteSnapshot({
    this.body = '',
    this.enhanced = '',
    this.timestamp,
    this.lastEnhanced,
    this.lastManualEdit,
  });
  final String body, enhanced;
  final int? timestamp, lastEnhanced, lastManualEdit;

  bool sameRecord(MeetingNoteSnapshot? other) =>
      other != null &&
      body == other.body &&
      enhanced == other.enhanced &&
      timestamp == other.timestamp &&
      lastEnhanced == other.lastEnhanced &&
      lastManualEdit == other.lastManualEdit;

  bool shouldReload({
    required String currentBody,
    required String currentEnhanced,
    required int? localManualEdit,
    required int? localEnhanced,
    required bool dirty,
    required bool programmaticWrite,
  }) {
    if (dirty || programmaticWrite) return false;
    final storedDate = lastEnhanced ?? lastManualEdit ?? timestamp;
    final localDate = localManualEdit ?? localEnhanced;
    final newer =
        storedDate != null && localDate != null && storedDate > localDate;
    return (enhanced.trim().isNotEmpty && currentEnhanced.trim().isEmpty) ||
        newer ||
        body != currentBody ||
        enhanced != currentEnhanced;
  }
}
