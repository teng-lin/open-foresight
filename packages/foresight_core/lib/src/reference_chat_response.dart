// Response transformations recovered from the original Foresight Dart snapshot.
// See docs/reference-chat-response.md for addresses and evidence boundaries.
import 'dart:convert';

final _streamedTextField = RegExp(
  r'"text":\s*"((?:[^"\\]|\\.|"(?!\s*(?:,\s*"[^"]+"\s*:|}|\s*$)))*)',
);

/// The original stream displays the last text field in JSON-like output, or
/// sanitized plain text. Incomplete JSON/fence headers produce no update.
String? provisionalReferenceChatResponse(String raw) {
  var prefix = raw.trim();
  var json = prefix.startsWith('{');
  if (!json && prefix.startsWith('```')) {
    prefix = prefix.substring(3).trim();
    json = prefix.startsWith('{') || prefix.startsWith('json');
    if (!json && 'json'.startsWith(prefix)) return null;
  }
  String text;
  if (json) {
    final matches = _streamedTextField.allMatches(raw);
    if (matches.isEmpty) return null;
    text = _unescapeStreamedString(matches.last[1]!);
  } else {
    text = raw;
  }
  final sanitized = sanitizeReferenceChatResponse(text);
  return sanitized.isEmpty ? null : sanitized;
}

String _unescapeStreamedString(String value) {
  var trailingSlashes = 0;
  for (var i = value.length - 1; i >= 0 && value.codeUnitAt(i) == 92; i--) {
    trailingSlashes++;
  }
  if (trailingSlashes.isOdd) value = value.substring(0, value.length - 1);
  value = value.replaceAll(RegExp(r'\\u[0-9a-fA-F]{0,3}$'), '');
  final controls = value.replaceAllMapped(
    RegExp(r'[\x00-\x1F]'),
    (m) => r'\u' + m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0'),
  );
  final escaped = StringBuffer();
  var slashes = 0;
  for (final unit in controls.codeUnits) {
    if (unit == 92) {
      slashes++;
      escaped.writeCharCode(unit);
    } else {
      if (unit == 34 && slashes.isEven) escaped.write(r'\');
      escaped.writeCharCode(unit);
      slashes = 0;
    }
  }
  try {
    return jsonDecode('"$escaped"') as String;
  } on FormatException {
    return value
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
        )
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  }
}

final _numberBeforeWords = RegExp(
  r'\b(\d+)\b[\*_]*\s+[\*_]*([a-zA-Z\d]+(?:\s+[a-zA-Z\d]+){0,3})\b',
  caseSensitive: false,
);
final _numberAfterWords = RegExp(
  r'\b([a-zA-Z\d]+(?:\s+[a-zA-Z\d]+){0,3})\b[\*_]*\s+[\*_]*\b(\d+)\b',
  caseSensitive: false,
);
const _numberContextTerms = [
  'am',
  'pm',
  'minute',
  'hour',
  'second',
  'month',
  'year',
  'day',
  'week',
  'quarter',
  'gdoc',
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
  'today',
  'tomorrow',
  'yesterday',
  'date',
  'at',
  'on',
  'from',
  'to',
  'meeting',
  'calendar',
  'event',
];

/// Repair digit mismatches only where a neighboring phrase matches context.
/// Candidate phrases shrink from four words, and the first context match wins.
String alignReferenceResponseNumbers(String response, String context) {
  if (response.isEmpty || context.isEmpty) return response;
  final replacements = <({int start, int end, String text})>[];
  void collect(RegExp pattern, {required bool numberFirst}) {
    for (final match in pattern.allMatches(response)) {
      final number = match[numberFirst ? 1 : 2]!;
      final words = match[numberFirst ? 2 : 1]!.trim();
      if (words.length < 3 ||
          _numberContextTerms.any(words.toLowerCase().startsWith))
        continue;
      final parts = words.split(RegExp(r'\s+'));
      for (var count = parts.length; count >= 1; count--) {
        final phrase =
            (numberFirst ? parts.take(count) : parts.skip(parts.length - count))
                .join(' ');
        if (phrase.length < 3) continue;
        final sourcePattern = numberFirst
            ? RegExp(
                r'\b(\d+)\b\s*[\*_]*\s*' + RegExp.escape(phrase) + r'\b',
                caseSensitive: false,
              )
            : RegExp(
                r'\b' + RegExp.escape(phrase) + r'\b\s*[\*_]*\s*\b(\d+)\b',
                caseSensitive: false,
              );
        final source = sourcePattern.firstMatch(context);
        if (source == null) continue;
        final actual = source[1]!;
        if (number == actual ||
            (number.startsWith(actual) && number.length > actual.length + 2))
          continue;
        final start = numberFirst
            ? match.start
            : match.start + match[0]!.lastIndexOf(number);
        final end = start + number.length;
        if (!replacements.any((r) => start == r.start && end == r.end)) {
          replacements.add((start: start, end: end, text: actual));
        }
        break;
      }
    }
  }

  collect(_numberBeforeWords, numberFirst: true);
  collect(_numberAfterWords, numberFirst: false);
  replacements.sort((a, b) => b.start.compareTo(a.start));
  for (final replacement in replacements) {
    response = response.replaceRange(
      replacement.start,
      replacement.end,
      replacement.text,
    );
  }
  return response;
}

// Ordered regexes PP[30753] through PP[30781].
final _timestampPatterns = [
  RegExp(
    r'''\b202(02[0-9]|12[0-9]|22[0-9]|32[0-9]|42[0-9]|52[0-9]|62[0-9]|72[0-9]|82[0-9]|92[0-9])\b''',
  ),
  RegExp(r'''\b202\d*(\d{2})\b'''),
  RegExp(
    r'''(\b(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{1,2})?,\s+|\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+)(2[2-9]\d)\b(?!,\s*\d{4})''',
    caseSensitive: false,
  ),
  RegExp(
    r'''(\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+)(2,\s*0?\s*(2\d))\b''',
    caseSensitive: false,
  ),
  RegExp(
    r'''(\b(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{1,2})?,?\s+)(02([2-9]\d))\b''',
    caseSensitive: false,
  ),
  RegExp(
    r'''(\b(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{1,2})?,?\s+|\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+)(20\d)\b(?!,\s*\d{4})''',
    caseSensitive: false,
  ),
  RegExp(
    r'''\b(January|February|March|April|May|June|July|August|September|October|November|December)(\d{1,2})\b''',
    caseSensitive: false,
  ),
  RegExp(
    r'''(\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},)(\d{4}\b)''',
    caseSensitive: false,
  ),
  RegExp(
    r'''\b(\d{1,2}):(\d{1,2}):(\d{2,4})\s*(AM|PM)\b''',
    caseSensitive: false,
  ),
  RegExp(r'''\b(\d{3}):(\d{1,5})\s*(AM|PM)?\b''', caseSensitive: false),
  RegExp(r'''\b(\d{1,2}):(\d{1,5})\s*(AM|PM)\b''', caseSensitive: false),
  RegExp(r'''\b(\d{1,2}:\d{2})(AM|PM)\b''', caseSensitive: false),
  RegExp(
    r'''(AM|PM)\s*-\s*(\d{1,2}:\d{2}\s*(?:AM|PM))''',
    caseSensitive: false,
  ),
  RegExp(r'''(^|\s)-(\d{1,2}:\d{2}\s*(?:AM|PM))''', caseSensitive: false),
  RegExp(
    r'''\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{3,4})(,?\s+\d{4}\b)''',
    caseSensitive: false,
  ),
];

/// Apply the original ordered date/time typo repairs, including its bounded
/// digit truncation. This intentionally preserves the original narrow grammar.
String normalizeReferenceTimestamps(String text) {
  if (text.isEmpty) return text;
  String minutes(String value) => value == '0'
      ? '00'
      : value.length == 1
      ? '0$value'
      : value.substring(0, 2);
  final transforms = <String Function(Match)>[
    (m) => '20${m[1]!.substring(m[1]!.length - 2)}',
    (m) => m[0]!.length > 4 && m[0]!.startsWith('20') ? '20${m[1]}' : m[0]!,
    (m) => '${m[1]}20${m[2]!.substring(1)}',
    (m) => '${m[1]}20${m[3]!.replaceAll(RegExp(r'\s+'), '')}',
    (m) => '${m[1]}20${m[3]}',
    (m) => '${m[1]}202${m[2]!.substring(2)}',
    (m) => '${m[1]} ${m[2]}',
    (m) => '${m[1]} ${m[2]}',
    (m) => '${m[1]}:${minutes(m[2]!)} ${m[4]!.toUpperCase()}',
    (m) =>
        '${_cleanThreeDigitHour(m[1]!)}:${minutes(m[2]!)}${m[3] == null ? '' : ' ${m[3]!.toUpperCase()}'}',
    (m) => '${m[1]}:${minutes(m[2]!)} ${m[3]!.toUpperCase()}',
    (m) => '${m[1]} ${m[2]!.toUpperCase()}',
    (m) => '${m[1]} - ${m[2]}',
    (m) => '${m[1]}- ${m[2]}',
    (m) {
      final day = m[2]!;
      final firstTwo = int.tryParse(day.substring(0, 2));
      final length = firstTwo != null && firstTwo >= 1 && firstTwo <= 31
          ? 2
          : 1;
      return '${m[1]} ${day.substring(0, length)}${m[3]}';
    },
  ];
  for (var i = 0; i < _timestampPatterns.length; i++) {
    text = text.replaceAllMapped(_timestampPatterns[i], transforms[i]);
  }
  return text;
}

String _cleanThreeDigitHour(String hour) {
  if (hour.length != 3) return hour;
  if (hour == '111') return '11';
  if (hour == '222') return '22';
  if (hour == '122') return '12';
  if (hour.startsWith('10') || hour.startsWith('11')) {
    final last = hour.substring(2);
    return const ['8', '7', '6'].contains(last)
        ? last
        : hour.startsWith('10')
        ? '10'
        : '11';
  }
  final firstTwo = int.tryParse(hour.substring(0, 2));
  return firstTwo != null && firstTwo >= 10 && firstTwo <= 12
      ? hour.substring(0, 2)
      : hour.substring(0, 1);
}

/// Keep the structured message and nontext metadata while replacing the text
/// assembled by the response processor, before display citation compaction.
Map<String, dynamic> referenceResponseWithText(
  Map<String, dynamic> response,
  String text,
) {
  final content = response['content'];
  if (content is String) return {...response, 'content': text};
  final parts = <dynamic>[];
  var replaced = false;
  if (content is List) {
    for (final part in content) {
      if (part is Map && part['type'] == 'text') {
        if (!replaced) parts.add({...part, 'text': text});
        replaced = true;
      } else {
        parts.add(part);
      }
    }
  }
  if (!replaced) parts.add({'type': 'text', 'text': text});
  return {...response, 'content': parts};
}

final _textWrapper = RegExp(r'^\s*\{\s*"text"\s*:\s*"', dotAll: true);
final _internalFields = RegExp(
  r'["\s,]*"?\s*(?:analysis|intent|reasoning|tool_calls)"?\s*:\s*[\{\["].*$',
  dotAll: true,
);
final _internalOnly = RegExp(
  r'^\s*"?\s*"?\s*(?:analysis|intent|reasoning)"?\s*:\s*[\{"]',
  dotAll: true,
);
final _loopPunctuation = RegExp(r'^[:|*+\->=]+$');
final _wordPunctuation = RegExp(r'[,\.!?;:]+$');

/// Original user-facing cleanup: text wrappers, internal thought channels,
/// terminal repetition, quote balancing, then timestamp normalization.
String sanitizeReferenceChatResponse(String text) {
  if (text.isEmpty) return text;
  text = text.trim();
  if (text.startsWith('```json')) {
    text = text.substring(7).trim();
  } else if (text.startsWith('```')) {
    text = text.substring(3).trim();
  }
  if (text.endsWith('```')) text = text.substring(0, text.length - 3).trim();
  final wrapper = _textWrapper.firstMatch(text);
  if (wrapper != null) text = text.substring(wrapper.end);
  text = text.replaceAll(_internalFields, '');
  if (_internalOnly.hasMatch(text)) return '';
  if (wrapper != null) {
    text = text
        .replaceAll(RegExp(r'[\s"\}\],]+$'), '')
        .replaceAll(RegExp(r'^[\s"]+'), '')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\"', '"');
  } else {
    text = text.replaceAll(RegExp(r'[\s\}\],]+$'), '');
  }
  text = _cleanThoughtTraces(text);
  final channel = text.lastIndexOf('<channel|>');
  if (channel >= 0) {
    final tail = text.substring(channel + 10).trim();
    if (tail.isEmpty ||
        _hasTerminalRepeat(tail, strict: false) ||
        _hasTerminalRepeat(tail, strict: true)) {
      text = text.substring(0, channel).trimRight();
    }
  }
  text = text
      .replaceAll(RegExp(r'<\/?\|?channel(?:\|>|>|\b)'), '')
      .replaceAll('<|think|>', '')
      .replaceAll('<turn|>', '');
  text = _stripTerminalRepeat(text);
  if (RegExp(r'(?<!\\)"').allMatches(text).length.isOdd) {
    text = text.endsWith('"')
        ? text.substring(0, text.length - 1).trimRight()
        : '$text"';
  }
  return normalizeReferenceTimestamps(text).trim();
}

String _cleanThoughtTraces(String text) {
  const thought = '<|channel>thought';
  if (!text.contains('<')) return text;
  var start = text.indexOf(thought);
  while (start >= 0) {
    final close = text.indexOf('<channel|>', start + 17);
    if (close < 0) {
      text = text.substring(0, start);
      break;
    }
    var end = close + 10;
    if (end < text.length && text[end] == '\n') end++;
    text = text.substring(0, start) + text.substring(end);
    start = text.indexOf(thought);
  }
  final partial = text.lastIndexOf('<');
  if (partial >= 0 && thought.startsWith(text.substring(partial))) {
    text = text.substring(0, partial);
  }
  return text;
}

bool _wordsEqual(String a, String b) {
  if (a == b) return true;
  a = a.replaceAll(_wordPunctuation, '').toLowerCase();
  b = b.replaceAll(_wordPunctuation, '').toLowerCase();
  return a.isNotEmpty && a == b;
}

int? _terminalRepeatStart(List<String> words, {required bool strict}) {
  for (var length = 1; length <= words.length ~/ 2; length++) {
    final repetitions = length <= 3
        ? 8
        : strict
        ? 2
        : 4;
    if (words.length < length * repetitions) continue;
    final last = words.length - length;
    var matches = true;
    for (var repeat = 1; repeat < repetitions && matches; repeat++) {
      final previous = words.length - (repeat + 1) * length;
      for (var i = 0; i < length; i++) {
        if (strict
            ? words[last + i] != words[previous + i]
            : !_wordsEqual(words[last + i], words[previous + i])) {
          matches = false;
          break;
        }
      }
    }
    if (!matches || words.skip(last).every(_loopPunctuation.hasMatch)) continue;
    var start = words.length - length * repetitions;
    if (!strict) {
      while (start >= length) {
        var same = true;
        for (var i = 0; i < length; i++) {
          if (!_wordsEqual(words[start - length + i], words[last + i])) {
            same = false;
            break;
          }
        }
        if (!same) break;
        start -= length;
      }
    }
    return start;
  }
  return null;
}

bool _hasTerminalRepeat(String text, {required bool strict}) =>
    _terminalRepeatStart(
      text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(),
      strict: strict,
    ) !=
    null;

String _stripTerminalRepeat(String text) {
  final matches = RegExp(r'\S+').allMatches(text).toList();
  final words = [for (final match in matches) match[0]!];
  final start = _terminalRepeatStart(words, strict: false);
  if (start == null) return text;
  return start == 0
      ? ''
      : text.substring(0, matches[start - 1].end).trimRight();
}
