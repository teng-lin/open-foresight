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
    final result = jsonDecode(raw) as Map<String, dynamic>;
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
    final inline = RegExp(
      r'\[(S\d+)\]',
    ).allMatches(text).map((m) => m.group(1));
    if (inline.any((id) => !citations.contains(id)))
      throw const FormatException('The answer cites an unselected source');
    return GroundedAnswer(text, citations, true);
  }
  String get rendered {
    final missing = citations
        .where((id) => !text.contains('[$id]'))
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
