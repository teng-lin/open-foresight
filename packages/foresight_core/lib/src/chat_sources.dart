import 'web_search.dart';

final _citation = RegExp(r'\[Source\s*[:\s]?\s*[^\]]+\]', caseSensitive: false);
final _leadingCitation = RegExp(
  r'\s*\[Source\s*[:\s]?\s*[^\]]+\]',
  caseSensitive: false,
);
final _numbers = RegExp(r'\d+');

String truncateChatToolResult(String text, int limit) => text.length <= limit
    ? text
    : '${text.substring(0, limit)}\n... [Content Truncated due to length] ...';

/// One ordered source set per send, shared by retrieved and web sources.
class ReferenceChatSources {
  final _values = <(String, String)>[];
  List<(String, String)> get values => List.unmodifiable(_values);

  int add((String, String) source) {
    var index = _values.indexOf(source);
    if (index < 0) {
      index = _values.length;
      _values.add(source);
    }
    return index + 1;
  }

  String formatSearch(WebSearchResult result) {
    final text = StringBuffer();
    if (result.results.isEmpty) {
      text.write(result.error);
    } else {
      for (var i = 0; i < result.sources.length; i++) {
        final number = add(result.sources[i]);
        text.write('[Source:$number] ${result.results[i]}\n\n');
      }
    }
    return truncateChatToolResult(text.toString(), 2000);
  }
}

typedef ResolvedChatCitations = ({String text, List<int> sourceIndices});

/// Validate against the source table, select in first-mention order, and
/// compact numbering. Repeated numbers inside a marker remain repeated.
ResolvedChatCitations resolveChatCitations(String text, int sourceCount) {
  if (sourceCount == 0 || !_citation.hasMatch(text)) {
    return (
      text: text.replaceAll(_leadingCitation, ''),
      sourceIndices: <int>[],
    );
  }
  final selected = <int>{};
  for (final match in _citation.allMatches(text)) {
    for (final number in _numbers.allMatches(match[0]!)) {
      final index = int.tryParse(number[0]!);
      if (index != null && index > 0 && index <= sourceCount)
        selected.add(index);
    }
  }
  final indices = selected.toList();
  final remap = {for (var i = 0; i < indices.length; i++) indices[i]: i + 1};
  final rewritten = text.replaceAllMapped(_leadingCitation, (match) {
    final mapped = [
      for (final number in _numbers.allMatches(match[0]!))
        if (remap[int.tryParse(number[0]!)] case final int index) index,
    ];
    return mapped.isEmpty ? '' : ' [Source:${mapped.join(', ')}]';
  });
  return (text: rewritten, sourceIndices: indices);
}
