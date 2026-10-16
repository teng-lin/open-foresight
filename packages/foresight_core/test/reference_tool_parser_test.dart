import 'dart:convert';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> call(String query) => {
  'function': {
    'name': 'google_search',
    'arguments': {'query': query},
  },
};
Map<String, dynamic> text(Object? value) => {'type': 'text', 'text': value};

void main() {
  test(
    'native calls win and retain unparsed arguments and invalid entries',
    () {
      final calls = [
        {
          'function': {'name': 'google_search', 'arguments': '{"query":"raw"}'},
        },
        null,
      ];
      expect(
        extractReferenceToolCalls({
          'tool_calls': calls,
          'content': [
            text(
              jsonEncode({
                'tool_calls': [call('ignored')],
              }),
            ),
          ],
        }),
        calls,
      );
    },
  );

  test(
    'content search skips wrong shapes and uses first matching text item',
    () {
      expect(
        extractReferenceToolCalls({
          'tool_calls': [],
          'content': [
            null,
            'text',
            {
              'type': 'image',
              'text': {
                'tool_calls': [call('image')],
              },
            },
            text(null),
            text(123),
            text('Ordinary answer'),
            text({
              'tool_calls': [call('first')],
            }),
            text({
              'tool_calls': [call('second')],
            }),
          ],
        }),
        [call('first')],
      );
      expect(
        extractReferenceToolCalls({
          'content': jsonEncode({
            'tool_calls': [call('not a list')],
          }),
        }),
        isNull,
      );
      expect(
        extractReferenceToolCalls({
          'content': [
            text({
              'nested': {
                'tool_calls': [call('not recursive')],
              },
            }),
          ],
        }),
        isNull,
      );
    },
  );

  test('JSON fence and exact root prefix return the whole call list', () {
    final value = jsonEncode({
      'tool_calls': [call('one'), call('two')],
    });
    expect(parseReferenceToolCallsFromText(value), [call('one'), call('two')]);
    expect(
      parseReferenceToolCallsFromText('Answer\n```json\n$value\n``` trailing'),
      [call('one'), call('two')],
    );
    // The anchored prefix is matched on untrimmed input. Generic fallback takes
    // only the first pair, rather than reconstructing a two-call batch.
    expect(parseReferenceToolCallsFromText(' $value'), [call('one')]);
  });

  test('repair retains original delimiter-counting quirks', () {
    expect(
      repairReferenceToolJson(' {"tool_calls":[{"function":{"name":"x"}}] '),
      '{"tool_calls":[{"function":{"name":"x"}}]}',
    );
    expect(
      repairReferenceToolJson('{"tool_calls":[{"name":"x"]'),
      '{"tool_calls":[{"name":"x"}]}',
    );
    expect(repairReferenceToolJson('{"x":['), '{"x":[}]');
    expect(repairReferenceToolJson('{"x":"{"}'), '{"x":"{"}}');
    expect(repairReferenceToolJson('{"x":[]}'), '{"x":[]}');
    expect(repairReferenceToolJson('}]'), '}]');
  });

  test('generic fallback returns one pair and JSON-decodes its arguments', () {
    expect(
      parseReferenceToolCallsFromText(
        'prefix "name":"google_search", "arguments":{"query":"中文 😀"} suffix',
      ),
      [call('中文 😀')],
    );
    expect(
      parseReferenceToolCallsFromText(
        r'"name":"google_search", "arguments":"a\"b"',
      ),
      [
        {
          'function': {'name': 'google_search', 'arguments': 'a"b'},
        },
      ],
    );
    expect(
      parseReferenceToolCallsFromText(
        '"name":"google_search", "arguments":{\n"query":"line"\n}',
      ),
      [call('line')],
    );
    expect(
      parseReferenceToolCallsFromText('"name":"x", "arguments":{broken}'),
      isNull,
    );
    expect(
      parseReferenceToolCallsFromText('"NAME":"x", "arguments":{}'),
      isNull,
    );
    expect(
      parseReferenceToolCallsFromText('call:google_search{query:<|"|>q<|"|>}'),
      isNull,
    );
  });

  test('failed fenced JSON falls back within the repaired block only', () {
    final outside = '"name":"outside", "arguments":{}';
    final inside = '"name":"inside", "arguments":{} trailing';
    expect(parseReferenceToolCallsFromText('$outside\n```json\n$inside\n```'), [
      {
        'function': {'name': 'inside', 'arguments': {}},
      },
    ]);
    expect(
      parseReferenceToolCallsFromText(
        '```json\n{"tool_calls":[]}\n``` $outside',
      ),
      isNull,
    );
  });

  test('text fragments are not combined into a JSON fence or call', () {
    expect(
      extractReferenceToolCalls({
        'content': [text('{"tool_calls":['), text('{"function":'), text('}]}')],
      }),
      isNull,
    );
  });
}
