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
