import 'dart:convert';

Map<String, dynamic> groundedAnswerSchema(Set<String> allowed) {
  // Keep the decoding grammar shallow. Branching on a literal answer string
  // can fail inside LLGuidance's token parser; validate branch rules below.
  return {
    'type': 'object',
    'properties': {
      'answer': {'type': 'string'},
      'citations': {
        'type': 'array',
        'items': {'type': 'string', 'enum': allowed.toList()},
        'minItems': 0,
        'maxItems': allowed.length,
      },
    },
    'required': ['answer', 'citations'],
    'additionalProperties': false,
  };
}

class GroundedAnswer {
  final String text;
  final List<String> citations;
  final bool sufficient;
  GroundedAnswer(this.text, this.citations, this.sufficient);
  factory GroundedAnswer.parse(String raw, Set<String> allowed) {
    final result = jsonDecode(raw);
    if (result is! Map<String, dynamic> ||
        result['answer'] is! String ||
        result['citations'] is! List ||
        (result['citations'] as List).any((id) => id is! String) ||
        (result.containsKey('status') && result['status'] is! String)) {
      throw const FormatException('Invalid grounded-answer shape');
    }
    final text = result['answer'] as String;
    final citations = (result['citations'] as List)
        .cast<String>()
        .toSet()
        .toList();
    final status =
        result['status'] ??
        (citations.isEmpty ? 'insufficient_context' : 'answered');
    if (status == 'insufficient_context') {
      if (citations.isNotEmpty)
        throw const FormatException('Invalid insufficient-context response');
      return GroundedAnswer('Insufficient context', [], false);
    }
    if (status != 'answered' ||
        text.trim().isEmpty ||
        citations.isEmpty ||
        citations.any((id) => !allowed.contains(id))) {
      throw const FormatException(
        'The answer has missing or unknown source citations',
      );
    }
    final inline = citationIds(text, citations.length);
    if (inline.any((id) => !citations.contains(id)))
      throw const FormatException('The answer cites an unselected source');
    return GroundedAnswer(text, citations, true);
  }
  String get rendered {
    final inline = citationIds(text, citations.length);
    final missing = citations
        .where((id) => !inline.contains(id))
        .map((id) => '[$id]')
        .join(' ');
    return missing.isEmpty ? text : '$text $missing';
  }
}

/// Show only the answer field while streaming. Incomplete JSON is provisional;
/// it is never committed as a validated answer.
String? provisionalAnswer(String raw) {
  final match = RegExp(
    r'"answer"\s*:\s*"((?:[^"\\]|\\.)*)(?:"|$)',
  ).firstMatch(raw);
  if (match == null) return null;
  try {
    return jsonDecode('"${match.group(1)}"') as String;
  } on FormatException {
    return null;
  }
}

/// Citation groups support comma/space lists and inclusive source ranges.
/// Fail closed on malformed groups and bound ranges by the selected sources.
Set<String> citationIds(String text, int limit) {
  final ids = <String>{};
  const item = r'S([1-9][0-9]*)(?:\s*[-–—]\s*S?([1-9][0-9]*))?';
  for (final bracket in RegExp(
    r'\[[^\[\]]*\bS[0-9]+[^\[\]]*\]',
  ).allMatches(text)) {
    final content = bracket
        .group(0)!
        .substring(1, bracket.group(0)!.length - 1)
        .trim();
    if (!RegExp('^$item(?:(?:\\s*,\\s*|\\s+)$item)*\$').hasMatch(content)) {
      throw const FormatException('Malformed citation group');
    }
    for (final match in RegExp(item).allMatches(content)) {
      final first = int.tryParse(match.group(1)!);
      final last = int.tryParse(match.group(2) ?? match.group(1)!);
      if (first == null ||
          last == null ||
          last < first ||
          last - first >= limit) {
        throw const FormatException('Invalid citation range');
      }
      for (var n = first; ; n++) {
        ids.add('S$n');
        if (n == last) break;
      }
    }
  }
  return ids;
}
