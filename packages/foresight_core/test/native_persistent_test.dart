import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'persistent worker isolates generations, survives cancellation and restarts after a bad frame',
    () async {
      final directory = createTestTempDirectorySync('persistent-native-');
      final runner = File('${directory.path}/runner');
      final model = File('${directory.path}/model')
        ..writeAsStringSync('fixture');
      runner.writeAsStringSync('''#!/usr/bin/env python3
import json,os,pathlib,sys
if '--probe' in sys.argv:
 print('{"worker_protocol":1}',flush=True)
 sys.exit(0)
assert '--serve' in sys.argv
with open(__file__+'.starts','a') as f: f.write(str(os.getpid())+'\\n')
print('ready 1',flush=True)
seen=set()
for line in sys.stdin:
 if line.strip()=='shutdown':
  pathlib.Path(__file__+'.closed').write_text('closed')
  break
 command,token,payload=line.rstrip('\\n').split(' ',2)
 assert command=='generate' and token not in seen
 seen.add(token)
 request=json.loads(payload)
 if 'tools' not in request:
  assert 'schema' in request
  if 'cancel plain' in request['prompt']:
   print(token+' text '+json.dumps('first chunk'),flush=True)
   assert sys.stdin.readline().strip()=='cancel '+token
   print(token+' done cancelled',flush=True)
   continue
  print(token+' text '+json.dumps('plain answer\\nwith Unicode λ'),flush=True)
  print(token+' done completed',flush=True)
  continue
 assert request['tools']['delegate_tool_detection'] is True
 prompt=request['prompt']
 if prompt=='stale frame':
  print(str(int(token)-1)+' delta '+json.dumps({'content':'stale'}),flush=True)
  continue
 print(token+' delta '+json.dumps({'content':prompt}),flush=True)
 if prompt in ['cancel','ignore cancellation']:
  while True:
   control=sys.stdin.readline().strip()
   if control=='cancel '+token and prompt=='cancel': break
  print(token+' done cancelled',flush=True)
  continue
 answer={'role':'assistant','content':[{'type':'text','text':prompt}]}
 print(token+' model '+json.dumps(answer),flush=True)
 control=sys.stdin.readline().rstrip('\\n').split(' ',2)
 assert control[:2]==['reply',token] and json.loads(control[2])=={'finish':True}
 print(token+' answer '+json.dumps(answer),flush=True)
 print(token+' done completed',flush=True)
''');
      await Process.run('chmod', ['+x', runner.path]);
      final runtime = NativeRuntime(library!);
      try {
        await runtime.load(runner.path, model.path, backend: 'litert_lm');
        expect(runtime.effectiveState['load_policy'], 'persistent_worker');
        Future<List<Map<String, dynamic>>> generate(
          String id,
          String prompt, {
          bool cancel = false,
        }) async {
          final events = <Map<String, dynamic>>[];
          await for (final event in runtime.generateWithTools(
            id,
            prompt,
            tools: [referenceGoogleSearchTool()],
            dispatcher: ReferenceToolDispatcher({}),
          )) {
            events.add(event);
            if (cancel && event['type'] == 'preview') {
              expect(runtime.cancel(requestId: id), isTrue);
            }
          }
          return events;
        }

        for (final prompt in ['first', 'second']) {
          final events = await generate(prompt, prompt);
          expect(events.last['status'], 'completed');
          expect(
            events.where((e) => e['type'] == 'delta').single['text'],
            prompt,
          );
        }
        for (final schema in [
          <String, dynamic>{
            'x-foresight-grounded-request': {'version': 1},
          },
          <String, dynamic>{'type': 'object'},
          null,
        ]) {
          final events = await runtime
              .generate(
                'plain-${schema.hashCode}',
                'summary',
                responseSchema: schema,
              )
              .toList();
          expect(events.last['status'], 'completed');
          expect(
            events.where((event) => event['type'] == 'delta').single['text'],
            'plain answer\nwith Unicode λ',
          );
        }
        final plainEvents = <Map<String, dynamic>>[];
        await for (final event in runtime.generate(
          'cancel-plain',
          'cancel plain',
        )) {
          plainEvents.add(event);
          if (event['type'] == 'delta') {
            expect(event['text'], 'first chunk');
            expect(runtime.cancel(requestId: 'cancel-plain'), isTrue);
          }
        }
        expect(plainEvents.last['status'], 'cancelled');
        expect(
          plainEvents.where((event) => event['type'] == 'delta'),
          hasLength(1),
        );
        final cancelled = await generate(
          'cancel-owner',
          'cancel',
          cancel: true,
        );
        expect(cancelled.last['status'], 'cancelled');
        expect(
          (await generate('after-cancel', 'third')).last['status'],
          'completed',
        );
        final starts = File('${runner.path}.starts');
        expect(starts.readAsLinesSync(), hasLength(1));
        final bad = await generate('bad-owner', 'stale frame');
        expect(
          bad.where((e) => e['type'] == 'error').single['code'],
          'tool_protocol',
        );
        expect(bad.last['status'], 'failed');
        expect(bad.any((e) => e['text'] == 'stale'), isFalse);
        expect(
          (await generate('restarted', 'fourth')).last['status'],
          'completed',
        );
        expect(starts.readAsLinesSync(), hasLength(2));
        final clock = Stopwatch()..start();
        final forced = await generate(
          'unresponsive',
          'ignore cancellation',
          cancel: true,
        );
        expect(forced.last['status'], 'cancelled');
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
        expect(
          (await generate('after-force', 'fifth')).last['status'],
          'completed',
        );
        expect(starts.readAsLinesSync(), hasLength(3));
        runtime.close();
        await runtime.closed;
        expect(File('${runner.path}.closed').readAsStringSync(), 'closed');
      } finally {
        runtime.close();
        await runtime.closed;
        directory.deleteSync(recursive: true);
      }
    },
    skip: library == null,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
