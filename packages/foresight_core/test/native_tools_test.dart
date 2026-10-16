import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  group(
    'native tool conversation',
    () {
      late Directory directory;
      late NativeRuntime runtime;
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'foresight-tool-test-',
        );
        final runner = File('${directory.path}/runner');
        await runner.writeAsString('''#!/usr/bin/env python3
import hashlib,json,sys
if '--probe' in sys.argv: sys.exit(0)
assert '--tools' in sys.argv
options=json.loads(sys.argv[sys.argv.index('--tools')+1])
tools=options['tools']
prompt=sys.argv[sys.argv.index('--prompt')+1]
if prompt=='Reference question':
 assert hashlib.sha256(options['system_message'].encode()).hexdigest()=='71a908bf5b041da7cff1c7ad1d397a62b2fc3d433774bad7dcaf26a351762f78'
else:
 assert options['system_message']=='Follow the requested task faithfully. Do not invent facts.'
 assert prompt in ['Question','Text fallback question','Turn limit question','Final turn question'], 'System instructions leaked into user content'
assert tools[0]['name']=='google_search'
assert options['delegate_tool_detection'] is True
calls=[{'function':{'name':'google_search','arguments':{'query':'Current query'}}}]
answer={'role':'assistant','content':[{'type':'text','text':'Answer [Source:1]'}]}
if prompt=='Reference question':
 print('tool '+json.dumps(calls),flush=True)
 message=json.loads(sys.stdin.readline())
else:
 for turn in range(20):
  value={'tool_calls':calls}
  if prompt=='Text fallback question':
   value={'content':[{'type':'text','text':json.dumps({'tool_calls':calls},separators=(',',':'))[:-1]}]}
  if prompt=='Final turn question' and turn==19: value=answer
  print('model '+json.dumps(value),flush=True)
  control=json.loads(sys.stdin.readline())
  if prompt=='Final turn question' and turn==19:
   assert control=={'finish':True}
   print('answer '+json.dumps(answer),flush=True)
   sys.exit(0)
  if turn==19:
   assert control=={'finish':True,'error':'Max turns reached after tool call detection'}
   print('answer '+json.dumps({'error':control['error']}),flush=True)
   sys.exit(0)
  message=control['message']
  if prompt not in ['Turn limit question','Final turn question']: break
assert message['role']=='user'
assert message['content'][0]['text'].startswith('The search results for the previous request are provided below:')
if prompt!='Reference question':
 print('model '+json.dumps(answer),flush=True)
 assert json.loads(sys.stdin.readline())=={'finish':True}
print('answer '+json.dumps(answer),flush=True)
''');
        await Process.run('chmod', ['+x', runner.path]);
        final model = File('${directory.path}/asset');
        await model.writeAsString('fixture');
        runtime = NativeRuntime(library!);
        await runtime.load(runner.path, model.path, backend: 'litert_lm');
        expect(runtime.effectiveState['tools'], isTrue);
      });
      tearDown(() async {
        runtime.close();
        await directory.delete(recursive: true);
      });

      test(
        'native worker calls search and receives its reference user message',
        () async {
          final queries = <String>[];
          final search = SearchCallbacks(
            search: (q) async {
              queries.add(q);
              return [
                const WebSearchItem(
                  title: 'Web',
                  link: 'https://example.org',
                  snippet: 'Snippet',
                ),
              ];
            },
            summarize: (_, _) async => '',
          );
          String? delivered;
          final dispatcher = ReferenceToolDispatcher({
            'google_search': (args) async {
              delivered = formatSearchToolResult(
                await search.handleGoogleSearch(args),
              );
              return delivered;
            },
          });
          final events = await runtime
              .generateWithTools(
                'search-owner',
                'Reference question',
                systemPrompt: referenceChatInstructions,
                tools: [referenceGoogleSearchTool()],
                dispatcher: dispatcher,
              )
              .toList();
          expect(queries, ['Current query']);
          expect(delivered, '[Source:1] title: Web\nsnippet: Snippet\n\n');
          expect(
            events
                .where((e) => e['type'] == 'delta')
                .map((e) => e['text'])
                .join(),
            'Answer [Source:1]',
          );
          expect(events.last['status'], 'completed');
          expect(runtime.generating, isFalse);
        },
      );

      test(
        'textual calls are repaired and delegated before accepting the final answer',
        () async {
          var batches = 0;
          final events = await runtime
              .generateWithTools(
                'text-fallback',
                'Text fallback question',
                tools: [referenceGoogleSearchTool()],
                dispatcher: ReferenceToolDispatcher({
                  'google_search': (args) async {
                    batches++;
                    expect(args, {'query': 'Current query'});
                    return 'Search result';
                  },
                }),
              )
              .toList();
          expect(batches, 1);
          expect(
            events.where((event) => event['type'] == 'delta').single['text'],
            'Answer [Source:1]',
          );
          expect(events.last['status'], 'completed');
        },
      );

      test(
        'delegated ordinary twentieth answer completes after nineteen batches',
        () async {
          var batches = 0;
          final events = await runtime
              .generateWithTools(
                'final-turn',
                'Final turn question',
                tools: [referenceGoogleSearchTool()],
                dispatcher: ReferenceToolDispatcher({
                  'google_search': (_) async {
                    batches++;
                    return 'Search result';
                  },
                }),
              )
              .toList();
          expect(batches, 19);
          expect(events.last['status'], 'completed');
        },
      );

      test(
        'delegated twentieth call fails without executing a twentieth batch',
        () async {
          var batches = 0;
          await expectLater(
            runtime
                .generateWithTools(
                  'turn-limit',
                  'Turn limit question',
                  tools: [referenceGoogleSearchTool()],
                  dispatcher: ReferenceToolDispatcher({
                    'google_search': (_) async {
                      batches++;
                      return 'Search result';
                    },
                  }),
                )
                .toList(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Max turns reached after tool call detection',
              ),
            ),
          );
          expect(batches, 19);
        },
      );

      test(
        'cancellation interrupts a pending callback and rejects its late result',
        () async {
          final entered = Completer<void>(), reply = Completer<Object?>();
          final dispatcher = ReferenceToolDispatcher({
            'google_search': (_) {
              entered.complete();
              return reply.future;
            },
          });
          final pending = runtime
              .generateWithTools(
                'cancel-owner',
                'Question',
                tools: [referenceGoogleSearchTool()],
                dispatcher: dispatcher,
              )
              .toList();
          await entered.future;
          expect(runtime.cancel(requestId: 'another-owner'), isFalse);
          expect(runtime.cancel(requestId: 'cancel-owner'), isTrue);
          await expectLater(
            pending.timeout(const Duration(seconds: 2)),
            throwsStateError,
          );
          reply.complete('late reply');
          await Future<void>.delayed(const Duration(milliseconds: 40));
          final next = await runtime
              .generateWithTools(
                'next-owner',
                'Question',
                tools: [referenceGoogleSearchTool()],
                dispatcher: ReferenceToolDispatcher({
                  'google_search': (_) async => 'new result',
                }),
              )
              .toList();
          expect(next.last['status'], 'completed');
        },
      );

      test(
        'closing during a pending callback prevents a late FFI reply',
        () async {
          final entered = Completer<void>(), reply = Completer<Object?>();
          final pending = runtime
              .generateWithTools(
                'close-owner',
                'Question',
                tools: [referenceGoogleSearchTool()],
                dispatcher: ReferenceToolDispatcher({
                  'google_search': (_) {
                    entered.complete();
                    return reply.future;
                  },
                }),
              )
              .toList();
          await entered.future;
          runtime.close();
          await expectLater(
            pending.timeout(const Duration(seconds: 2)),
            throwsStateError,
          );
          reply.complete('late reply after close');
          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(runtime.loaded, isFalse);
          expect(runtime.generating, isFalse);
        },
      );

      test('deadline applies while a callback is pending', () async {
        final entered = Completer<void>(), reply = Completer<Object?>();
        final pending = runtime
            .generateWithTools(
              'deadline-owner',
              'Question',
              tools: [referenceGoogleSearchTool()],
              timeout: const Duration(seconds: 3),
              dispatcher: ReferenceToolDispatcher({
                'google_search': (_) {
                  entered.complete();
                  return reply.future;
                },
              }),
            )
            .toList();
        await entered.future;
        await expectLater(pending, throwsA(isA<TimeoutException>()));
        expect(runtime.generating, isFalse);
        reply.complete('too late');
      });
    },
    skip: library == null
        ? 'Requires a built FORESIGHT_NATIVE_LIBRARY and its process supervisor'
        : false,
  );
}
