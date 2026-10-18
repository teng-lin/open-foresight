import 'dart:convert';

final _jsonBlock = RegExp(r'```json\s*([\s\S]*?)\s*```');
final _toolStart = RegExp(r'^(\{"tool_calls":\s*\[[\s\S]*)', dotAll: true);
final _genericCall = RegExp(
  r'"name"\s*:\s*"([^"]+)"[^}]*"arguments"\s*:\s*(\{.*?\}|"(?:[^"\\]|\\.)*")',
  dotAll: true,
);

/// Original repairJson counts literal delimiters, including inside strings.
String repairReferenceToolJson(String input) {
  var text = input.trim();
  var braces = 0, brackets = 0;
  for (final unit in text.codeUnits) {
    if (unit == 123) braces++;
    if (unit == 125) braces--;
    if (unit == 91) brackets++;
    if (unit == 93) brackets--;
  }
  if (braces > 0) {
    if (text.endsWith(']') &&
        (text.length == 1 || text[text.length - 2] != '}')) {
      text = '${text.substring(0, text.length - 1)}}]${'}' * (braces - 1)}';
    } else {
      text += '}' * braces;
    }
  }
  if (brackets > 0) text += ']' * brackets;
  return text;
}

List<dynamic>? _nonemptyCalls(Object? value) =>
    value is List && value.isNotEmpty ? List<dynamic>.of(value) : null;

List<dynamic>? _regexToolCalls(String text) {
  final match = _genericCall.firstMatch(text);
  if (match == null) return null;
  try {
    return [
      {
        'function': {'name': match[1], 'arguments': jsonDecode(match[2]!)},
      },
    ];
  } on FormatException {
    return null;
  }
}

List<dynamic>? parseReferenceToolCallsFromText(String text) {
  final trimmed = text.trim();
  if (!trimmed.contains('{') &&
      !trimmed.contains('```json') &&
      !trimmed.contains('"name"')) {
    return null;
  }
  // Matching deliberately uses the original text, including leading spaces.
  final match = _jsonBlock.firstMatch(text) ?? _toolStart.firstMatch(text);
  if (match == null) return _regexToolCalls(text);
  final repaired = repairReferenceToolJson(match[1]!);
  try {
    final value = jsonDecode(repaired) as Map<String, dynamic>;
    return _nonemptyCalls(value['tool_calls']);
  } catch (_) {
    return _regexToolCalls(repaired);
  }
}

/// Root native calls win; otherwise inspect text items in order, returning the
/// first item with calls. Separate text fragments are never concatenated.
List<dynamic>? extractReferenceToolCalls(Map<String, dynamic> response) {
  final root = _nonemptyCalls(response['tool_calls']);
  if (root != null) return root;
  final content = response['content'];
  if (content is! List) return null;
  for (final item in content) {
    if (item is! Map<String, dynamic> || item['type'] != 'text') continue;
    final text = item['text'];
    final calls = text is String
        ? parseReferenceToolCallsFromText(text)
        : text is Map<String, dynamic>
        ? _nonemptyCalls(text['tool_calls'])
        : null;
    if (calls != null) return calls;
  }
  return null;
}
