import 'reference_note_transcript_format.dart';

String cleanSummaryTranscript(String text) => extractSavedTranscriptText(text)
    .replaceAll(
      RegExp(
        r'^\s*(?:\*{0,2}\[?(?:Microphone|Remote)\]?\*{0,2})\s*[:\-]\s*',
        multiLine: true,
      ),
      '',
    )
    .trim();

/// Ordered phrase rewrites recovered at 0x10092fe0c. Case-insensitive.
String sanitizeSummary(String text) {
  var result = text.trim();
  for (final rule in _attributionRules) {
    result = result.replaceAll(RegExp(rule.$1, caseSensitive: false), rule.$2);
  }
  // Product policy: remove a remaining channel label after a Markdown heading.
  // This guard is intentionally separate from the recovered phrase rewrites.
  return result
      .replaceAllMapped(
        RegExp(
          r'(\*\s*\*\*[^*]+\*\*\s*:\s*)(?:Microphone|Remote)\s+(?=(?:approved|confirmed|decided|reported|requested)\b)',
        ),
        (match) => match[1]!,
      )
      .trim();
}

const _attributionRules = <(String, String)>[
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\s+(?:discussed|agreed)\s+that\b''',
    r'''It was discussed that''',
  ),
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\s+(?:observed|noted)\s+that\b''',
    r'''It was noted that''',
  ),
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\s+discussed\b''',
    r'''The discussion addressed''',
  ),
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\s+(?:agreed|concluded)\s+that\b''',
    r'''It was agreed that''',
  ),
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\s+debated\b''',
    r'''Participants debated''',
  ),
  (
    r'''\bbetween\s+(?:Microphone and Remote|Remote and Microphone)\b''',
    r'''among participants''',
  ),
  (
    r'''\b(?:Both\s+)?(?:Microphone and Remote|Remote and Microphone)\b''',
    r'''Participants''',
  ),
  (
    r'''\bAccording to\s+(?:Microphone|Remote),?\s*''',
    r'''It was noted that ''',
  ),
  (
    r'''\b(?:as\s+)?noted by\s+(?:Microphone|Remote)\b''',
    r'''noted in the discussion''',
  ),
  (r'''\bby\s+(?:Microphone|Remote)\b''', r'''in the discussion'''),
  (
    r'''\b(?:Microphone|Remote)\s+(?:questioned|asked|inquired)\s+whether\b''',
    r'''Questions were raised whether''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+(?:questioned|asked|inquired)\s+if\b''',
    r'''Questions were raised if''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+(?:questioned|asked|inquired)\b''',
    r'''Questions were raised regarding''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+raised\s+concerns?\b''',
    r'''Concerns were raised''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+expressed\s+doubts?\b''',
    r'''Doubts were expressed''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+explained\s+that\b''',
    r'''It was explained that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+explained\b''',
    r'''The discussion explained''',
  ),
  (r'''\b(?:Microphone|Remote)\s+stated\s+that\b''', r'''It was stated that'''),
  (r'''\b(?:Microphone|Remote)\s+stated\b''', r'''The discussion stated'''),
  (r'''\b(?:Microphone|Remote)\s+noted\s+that\b''', r'''It was noted that'''),
  (r'''\b(?:Microphone|Remote)\s+noted\b''', r'''The discussion noted'''),
  (
    r'''\b(?:Microphone|Remote)\s+pointed\s+out\s+that\b''',
    r'''It was pointed out that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+pointed\s+out\b''',
    r'''It was pointed out that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+emphasized\s+that\b''',
    r'''It was emphasized that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+emphasized\b''',
    r'''The discussion emphasized''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+highlighted\s+that\b''',
    r'''It was highlighted that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+highlighted\b''',
    r'''The discussion highlighted''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+suggested\s+that\b''',
    r'''It was suggested that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+suggested\b''', r'''It was suggested that'''),
  (
    r'''\b(?:Microphone|Remote)\s+proposed\s+that\b''',
    r'''It was proposed that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+proposed\b''', r'''It was proposed that'''),
  (
    r'''\b(?:Microphone|Remote)\s+recommended\s+that\b''',
    r'''It was recommended that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+recommended\b''',
    r'''It was recommended that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+clarified\s+that\b''',
    r'''It was clarified that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+clarified\b''', r'''It was clarified that'''),
  (r'''\b(?:Microphone|Remote)\s+shared\s+that\b''', r'''It was shared that'''),
  (r'''\b(?:Microphone|Remote)\s+shared\b''', r'''The discussion shared'''),
  (
    r'''\b(?:Microphone|Remote)\s+cautioned\s+that\b''',
    r'''It was cautioned that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+cautioned\b''',
    r'''Caution was advised that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+observed\s+that\b''',
    r'''It was observed that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+observed\b''', r'''Observations indicated'''),
  (r'''\b(?:Microphone|Remote)\s+said\s+that\b''', r'''It was stated that'''),
  (r'''\b(?:Microphone|Remote)\s+said\b''', r'''It was stated that'''),
  (
    r'''\b(?:Microphone|Remote)\s+indicated\s+that\b''',
    r'''It was indicated that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+indicated\b''', r'''It was indicated that'''),
  (
    r'''\b(?:Microphone|Remote)\s+reported\s+that\b''',
    r'''It was reported that''',
  ),
  (r'''\b(?:Microphone|Remote)\s+reported\b''', r'''It was reported that'''),
  (
    r'''\b(?:Microphone|Remote)\s+discussed\s+that\b''',
    r'''It was discussed that''',
  ),
  (
    r'''\b(?:Microphone|Remote)\s+discussed\b''',
    r'''The discussion focused on''',
  ),
];
