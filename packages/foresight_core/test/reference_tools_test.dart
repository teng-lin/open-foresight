import 'dart:async';
import 'package:foresight_core/src/reference_tools.dart';
import 'package:test/test.dart';

Map<String, dynamic> call(Object? args, {String? name = 'google_search'}) => {
  'function': {'name': name, 'arguments': args},
};

void main() {
  test('schema exposes the exact required nonnullable search query', () {
    final tool = referenceGoogleSearchTool();
    expect(tool['name'], 'google_search');
    expect(
      tool['description'],
      contains('Use this ONLY when you do not already know'),
    );
    expect(tool['parameters'], {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              "The search query, formulated from the user's question.",
          'nullable': false,
        },
      },
      'required': ['query'],
    });
  });
  test(
    'string arguments become verbatim query, including JSON-looking strings',
    () async {
      Map<String, dynamic>? seen;
      final dispatcher = ReferenceToolDispatcher({
        'google_search': (args) async {
          seen = args;
          return 'result';
        },
      });
      final result = await dispatcher.execute(call('{"query":"nested"}'));
      expect(seen, {'query': '{"query":"nested"}'});
      expect(result, {
        'tool_name': 'google_search',
        'tool_response': 'result',
        'status': 'success',
        'type': 'tool_response',
        'original_query': '{"query":"nested"}',
      });
    },
  );
  test(
    'invalid shapes and unregistered calls are model-visible error results',
    () async {
      final dispatcher = ReferenceToolDispatcher({});
      expect(
        (await dispatcher.execute(null))['message'],
        'Invalid tool_call format',
      );
      expect(
        (await dispatcher.execute({'function': 'bad'}))['message'],
        'Invalid tool_call format',
      );
      expect(
        (await dispatcher.execute(call(null)))['message'],
        'Invalid function arguments format in tool_call',
      );
      expect(
        (await dispatcher.execute(
          call(<String, dynamic>{}, name: null),
        ))['message'],
        'Invalid function format in tool_call',
      );
      expect(await dispatcher.execute(call(<String, dynamic>{})), {
        'tool_name': 'google_search',
        'status': 'error',
        'message': 'Tool "google_search" not registered',
        'type': 'tool_response',
      });
    },
  );
  test('callback exceptions become error text, preserving siblings', () async {
    final dispatcher = ReferenceToolDispatcher({
      'google_search': (_) async => throw TimeoutException('deadline'),
      'other': (_) async => 'result',
    });
    final message = await dispatcher.handle([
      call({'query': 'q'}),
      call(<String, dynamic>{}, name: 'other'),
    ]);
    expect(
      (message['content'] as List).single['text'],
      'The search results for the previous request are provided below:\n---\n'
      'Error from tool "google_search": TimeoutException: deadline\n---\n'
      'Result for tool "other":\nresult\n---\n',
    );
  });
  test(
    'batch starts concurrently and formats input order despite reverse completion',
    () async {
      final started = <String>[];
      final pending = <String, Completer<Object?>>{};
      final dispatcher = ReferenceToolDispatcher({
        'google_search': (args) {
          final q = args['query'] as String;
          started.add(q);
          return (pending[q] = Completer<Object?>()).future;
        },
      });
      final result = dispatcher.handle([
        call({'query': 'first'}),
        call({'query': 'second'}),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['first', 'second']);
      pending['second']!.complete('second result');
      pending['first']!.complete('first result');
      final text = (await result)['content'][0]['text'] as String;
      expect(
        text.indexOf('first result'),
        lessThan(text.indexOf('second result')),
      );
    },
  );
  test(
    'result block uses UTF-16 four-per-token truncation, preserving exact boundary',
    () {
      final results = [
        {
          'tool_name': 'google_search',
          'status': 'success',
          'tool_response': '🧪' * 100,
        },
      ];
      final full =
          referenceToolResultMessage(results)['content'][0]['text'] as String;
      final bounded =
          referenceToolResultMessage(
                results,
                maxTokens: 30,
              )['content'][0]['text']
              as String;
      expect(bounded, full.substring(0, 120));
      final exact = referenceToolResultMessage(
        results,
        maxTokens: (full.length / 4).ceil(),
      )['content'][0]['text'];
      expect(exact, full);
    },
  );
}
