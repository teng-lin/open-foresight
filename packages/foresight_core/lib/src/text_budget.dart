import 'dart:convert';

/// Unicode scalar budgets never cut a UTF-16 surrogate pair in half.
String runePrefix(String text, int limit) =>
    String.fromCharCodes(text.runes.take(limit));

/// Keep the previous question for short, referential follow-ups in English and
/// CJK scripts. The size budget is independent of whitespace segmentation.
bool isContextualFollowUp(
  String question, {
  Iterable<String> sourceTitles = const [],
}) =>
    question.runes.length <= 120 &&
    (RegExp(
          r'\b(it|its|that|those|this|they|them|more|again)\b',
          caseSensitive: false,
        ).hasMatch(question) ||
        RegExp(
          r'这个|那个|这些|那些|它们|他们|她们|之前|更多|再解释|再说|それ|これ|その|では|続|추가|그것|이것|더 자세히|더 설명|더 알려',
        ).hasMatch(question)) &&
    !_namesSourceSubject(question, sourceTitles);

// A pronoun may refer to a subject in the same question, rather than to the
// previous turn. Verify multiword names against current source titles before
// importing that previous question into retrieval and grounding. Matching is
// case-insensitive, so typing "project juniper" has the same scope.
bool _namesSourceSubject(String question, Iterable<String> titles) {
  // Comparisons and other references can still name one subject while relying
  // on the previous turn for another. Only resolve local "it"/"its" here.
  if (RegExp(
    r'\b(compare|compares|compared|comparison|before|after|earlier|later|versus|vs|than|previous|last|same|that|those|this|they|them|more|again)\b',
    caseSensitive: false,
  ).hasMatch(question)) {
    return false;
  }
  String normalized(String value) =>
      ' ${value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim()} ';
  final query = normalized(question);
  final reference = RegExp(r'\b(it|its)\b').firstMatch(query);
  if (reference == null) return false;
  // Resolve only the subject of a later question clause ("when does it...",
  // "what is its..."). An object such as "can Juniper replace it?" still
  // needs the previous turn even though a known name occurs first.
  final localClause = RegExp(
    r'\b(?:when|what|where|why|how|who)\s+(?:does|do|is|was|will|can|would|should|did)\s+(it|its)\b',
  ).firstMatch(query);
  if (localClause == null ||
      localClause.end - localClause[1]!.length != reference.start) {
    return false;
  }
  final names = RegExp(
    r'\p{Lu}[\p{L}\p{N}]*(?:\s+\p{Lu}[\p{L}\p{N}]*)+',
    unicode: true,
  );
  for (final title in titles) {
    for (final match in names.allMatches(title)) {
      final words = match[0]!.split(RegExp(r'\s+'));
      for (var i = 0; i + 1 < words.length; i++) {
        if (RegExp(
          r'^(the|a|an|this|that|these|those|my|our|your|their)$',
          caseSensitive: false,
        ).hasMatch(words[i])) {
          continue;
        }
        final subject = query.indexOf(
          normalized('${words[i]} ${words[i + 1]}'),
        );
        if (subject >= 0 && subject < reference.start) return true;
      }
    }
  }
  return false;
}

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

/// UTF-8 byte limit is conservative for byte-level model tokenizers; no silent Unicode corruption.
String boundUtf8(String text, int budget) {
  final output = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final part = String.fromCharCode(rune);
    final size = utf8.encode(part).length;
    if (used + size > budget) break;
    output.write(part);
    used += size;
  }
  return output.toString();
}
