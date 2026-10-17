/// Unicode scalar budgets never cut a UTF-16 surrogate pair in half.
String runePrefix(String text, int limit) =>
    String.fromCharCodes(text.runes.take(limit));

/// Keep the previous question for short, referential follow-ups in English and
/// CJK scripts. The size budget is independent of whitespace segmentation.
bool isContextualFollowUp(String question) =>
    question.runes.length <= 120 &&
    (RegExp(
          r'\b(it|its|that|those|this|they|them|more|again)\b',
          caseSensitive: false,
        ).hasMatch(question) ||
        RegExp(r'它|这|那|他|她|再|更多|それ|これ|その|では|続|추가|그것|이것|더').hasMatch(question));

String sourceIdentity(Map<String, Object?> source) {
  final uri = source['source_uri'] as String?;
  return uri == null || uri.isEmpty ? source['id'] as String : uri;
}

/// Bound model input by Unicode scalars. Interim CJK text advances one scalar
/// at a time, so a whole unspaced sentence is never treated as one word.
String proactiveTranscriptWindow(String history, {required bool isFinal}) {
  final normalized = history.replaceAll(RegExp(r'\s+'), ' ').trim();
  final units = RegExp(
    r'[\u2e80-\u9fff\uac00-\ud7af\u{20000}-\u{3134f}]|[^\s\u2e80-\u9fff\uac00-\ud7af\u{20000}-\u{3134f}]+',
    unicode: true,
  ).allMatches(normalized).toList();
  final eligible = units.length - (isFinal ? 0 : 5);
  if (eligible <= 0) return '';
  final scalars = normalized
      .substring(0, units[eligible - 1].end)
      .runes
      .toList();
  return String.fromCharCodes(
    scalars.skip(scalars.length > 1000 ? scalars.length - 1000 : 0),
  );
}
