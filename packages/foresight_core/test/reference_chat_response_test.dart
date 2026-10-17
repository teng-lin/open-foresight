import 'package:foresight_core/src/reference_chat_response.dart';
import 'package:test/test.dart';

void main() {
  test(
    'payload parsing reads analysis-first maps and preserves canonical values',
    () {
      expect(
        parseReferenceChatResponse(
          '{"analysis":{"intent":"answer","reasoning":"hidden"},"text":"May11,202026","tool_calls":[{"fixture":true}],"extra":"discard"}',
        ),
        {
          'text': 'May 11, 2026',
          'analysis': {'intent': 'answer', 'reasoning': 'hidden'},
          'tool_calls': [
            {'fixture': true},
          ],
        },
      );
      expect(
        parseReferenceChatResponse(
          '```json\n{"analysis":{"text":42},"intent":"root","reasoning":"why"}\n```',
        ),
        {
          'text': '42',
          'analysis': {'intent': 'root', 'reasoning': 'why'},
          'tool_calls': [],
        },
      );
    },
  );
  test(
    'malformed payload recovery selects last fields and decodes literal escapes',
    () {
      expect(
        parseReferenceChatResponse(
          r'{"text":"First","text":"Last\n中文","intent":"old","intent":"answer","reasoning":"why\u003f"',
        ),
        {
          'text': 'Last\n中文',
          'analysis': {'intent': 'answer', 'reasoning': 'why?'},
          'tool_calls': [],
        },
      );
      expect(parseReferenceChatResponse('{"analysis":'), {
        'text': '',
        'analysis': {'intent': 'unknown', 'reasoning': ''},
        'tool_calls': [],
      });
      expect(
        parseReferenceChatResponse('```\n Plain May11,202026 \n```')['text'],
        'Plain May 11, 2026',
      );
    },
  );
  test(
    'completion recovers sanitized raw text before considering date fallback',
    () {
      final now = DateTime(2026, 10, 16, 23, 59);
      expect(
        completeReferenceChatResponse(
          'Aligned answer.',
          raw: 'Original answer.',
          question: 'current date',
          now: now,
        ),
        'Aligned answer.',
      );
      expect(
        completeReferenceChatResponse(
          '<|channel>thought hidden',
          raw: '```json\n{"text":"Recovered answer."}\n```',
          question: 'current date',
          now: now,
        ),
        'Recovered answer.',
      );
    },
  );
  test('empty completion uses only the recovered date-query substrings', () {
    final now = DateTime(2026, 10, 16, 23, 59);
    for (final query in [
      'WHAT DAY IS TODAY?',
      'Please tell me what is today.',
      "What's today?",
      'today date',
      'Show the current date please',
    ]) {
      expect(
        completeReferenceChatResponse(
          '',
          raw: '<|channel>thought hidden',
          question: query,
          now: now,
        ),
        'Today is Friday, October 16, 2026.',
        reason: query,
      );
    }
    for (final query in [
      'What is the date?',
      'What day is tomorrow?',
      'Hello',
    ]) {
      expect(
        completeReferenceChatResponse('', raw: '', question: query, now: now),
        '',
        reason: query,
      );
    }
  });
  test('stream previews hide JSON headers and select the last text field', () {
    expect(provisionalReferenceChatResponse('{"analysis":"private"'), isNull);
    expect(provisionalReferenceChatResponse('```js'), isNull);
    expect(
      provisionalReferenceChatResponse('```json\n{"intent":"search"'),
      isNull,
    );
    expect(
      provisionalReferenceChatResponse('{"text":"First","text":"Second'),
      'Second',
    );
    expect(
      provisionalReferenceChatResponse('```\n{"text":"Visible'),
      'Visible',
    );
    expect(
      provisionalReferenceChatResponse(' Plain answer. '),
      'Plain answer.',
    );
  });
  test(
    'stream previews tolerate split escapes, controls and unescaped quotes',
    () {
      expect(provisionalReferenceChatResponse(r'{"text":"Hello\'), 'Hello');
      expect(provisionalReferenceChatResponse(r'{"text":"Hello\u00'), 'Hello');
      expect(
        provisionalReferenceChatResponse(r'{"text":"A\nB\u4e2d\u6587'),
        'A\nB中文',
      );
      expect(provisionalReferenceChatResponse('{"text":"A\nB'), 'A\nB');
      expect(
        provisionalReferenceChatResponse('{"text":"Say "yes" please'),
        'Say "yes" please',
      );
      expect(
        provisionalReferenceChatResponse(r'{"text":"A\q B\nC\u0044'),
        'Aq B\nCD',
      );
    },
  );
  test('cleanup unwraps text envelopes and removes internal metadata', () {
    expect(
      sanitizeReferenceChatResponse(
        '```json\n{"text":"First\\nSecond", "analysis":"private"}\n```',
      ),
      'First\nSecond',
    );
    expect(
      sanitizeReferenceChatResponse('"reasoning": {"details":"private"}'),
      '',
    );
  });
  test('cleanup removes thought spans and incomplete channel prefixes', () {
    expect(
      sanitizeReferenceChatResponse(
        'Visible <|channel>thought hidden<channel|>\nanswer',
      ),
      'Visible answer',
    );
    expect(
      sanitizeReferenceChatResponse('Visible <|channel>thought hidden'),
      'Visible',
    );
    expect(sanitizeReferenceChatResponse('Visible <|chan'), 'Visible');
  });
  test('cleanup strips terminal loops while preserving formatting tokens', () {
    expect(
      sanitizeReferenceChatResponse('Useful. ${'Again! ' * 8}'),
      'Useful.',
    );
    expect(
      sanitizeReferenceChatResponse(
        'Useful<channel|>${'alpha beta gamma delta ' * 2}',
      ),
      'Useful',
    );
    expect(sanitizeReferenceChatResponse('= ' * 8), '= = = = = = = =');
  });
  test(
    'cleanup balances unescaped quotes and normalizes visible timestamps',
    () {
      expect(sanitizeReferenceChatResponse('"Hello'), '"Hello"');
      expect(sanitizeReferenceChatResponse('Hello"'), 'Hello');
      expect(
        sanitizeReferenceChatResponse('```May11,202026```'),
        'May 11, 2026',
      );
    },
  );
  test('original trailing cleanup strips a bare terminal citation bracket', () {
    expect(
      sanitizeReferenceChatResponse('Answer [Source:2]'),
      'Answer [Source:2',
    );
    expect(
      sanitizeReferenceChatResponse('Answer [Source:2].'),
      'Answer [Source:2].',
    );
  });
  test('number alignment repairs both sides without shifting later spans', () {
    expect(
      alignReferenceResponseNumbers(
        'There are 123 widgets. The invoice total is 876.',
        'There are 12 widgets. The invoice total is 87.',
      ),
      'There are 12 widgets. The invoice total is 87.',
    );
  });
  test('number alignment preserves calendar phrases and long prefixes', () {
    expect(
      alignReferenceResponseNumbers(
        '123 minutes and 123456 widgets',
        '12 minutes and 12 widgets',
      ),
      '123 minutes and 123456 widgets',
    );
  });
  test(
    'number alignment requires a neighboring phrase in retrieved context',
    () {
      expect(
        alignReferenceResponseNumbers(
          'There are 15 widgets.',
          'Available 2 crates.',
        ),
        'There are 15 widgets.',
      );
      expect(alignReferenceResponseNumbers('123 x', '12 x'), '123 x');
    },
  );
  test('timestamp repair handles malformed dates in the recovered order', () {
    expect(normalizeReferenceTimestamps('May 11, 202026'), 'May 11, 2026');
    expect(normalizeReferenceTimestamps('May11,2026'), 'May 11, 2026');
    expect(normalizeReferenceTimestamps('May 111, 2026'), 'May 11, 2026');
    expect(normalizeReferenceTimestamps('May 391, 2026'), 'May 3, 2026');
  });
  test(
    'timestamp repair normalizes seconds, overlong minutes and time ranges',
    () {
      expect(
        normalizeReferenceTimestamps('10:000 AM-11:5PM'),
        '10:00 AM - 11:05 PM',
      );
      expect(normalizeReferenceTimestamps('10:5:1234 pm'), '10:05 PM');
      expect(normalizeReferenceTimestamps(' -10:00am'), ' - 10:00 AM');
    },
  );
  test('valid dates and unrelated Unicode stay unchanged', () {
    const text = '中文 🧭 Monday, May 11, 2026, 10:00 AM - 11:30 AM';
    expect(normalizeReferenceTimestamps(text), text);
    expect(normalizeReferenceTimestamps(''), '');
  });
  test('year fragments and three-digit hours retain original repair rules', () {
    for (final fragment in ['226', '2, 026', '0226', '206', '20202026']) {
      expect(
        normalizeReferenceTimestamps('May 11, $fragment'),
        'May 11, 2026',
        reason: fragment,
      );
    }
    for (final entry in {
      '111': '11',
      '222': '22',
      '122': '12',
      '108': '8',
      '117': '7',
      '109': '10',
      '120': '12',
      '333': '3',
    }.entries) {
      expect(
        normalizeReferenceTimestamps('${entry.key}:000 PM'),
        '${entry.value}:00 PM',
      );
    }
  });
  test(
    'rewritten history replaces content while retaining outer metadata and original map',
    () {
      final response = {
        'role': 'assistant',
        'metadata': {'channel': 'final'},
        'content': [
          {'type': 'text', 'text': 'Earlier', 'annotation': 'keep'},
          {'type': 'image', 'url': 'fixture://image'},
          {'type': 'text', 'text': ' part'},
        ],
      };
      final rewritten = referenceResponseWithText(response, 'Repaired 中文');
      expect(rewritten['metadata'], response['metadata']);
      expect(rewritten['content'], [
        {'type': 'text', 'text': 'Repaired 中文'},
      ]);
      expect((response['content'] as List).length, 3);
      expect((response['content'] as List).first['text'], 'Earlier');
    },
  );
}
