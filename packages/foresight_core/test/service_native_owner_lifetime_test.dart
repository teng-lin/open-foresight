import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Future<bool> controlAlive(int child, String path) async {
  final probe = await Process.start('/bin/ps', [
    '-ww',
    '-p',
    '$child',
    '-o',
    'command=',
  ]);
  final output = utf8.decoder.bind(probe.stdout).join();
  final errors = probe.stderr.drain<void>();
  try {
    return await probe.exitCode.timeout(const Duration(seconds: 2)) == 0 &&
        (await output).contains(path);
  } on TimeoutException {
    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode;
    return false;
  } finally {
    await output;
    await errors;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  for (final mode in ['work_loss', 'ack_loss', 'clean', 'sql_loss']) {
    test(
      'native frontend ownership $mode keeps replacement admission safe',
      () async {
        final root = createTestTempDirectorySync('native-front-');
        File(
          '${root.path}/model',
        ).writeAsStringSync('control model, no inference weights');
        final worker = File('${root.path}/model-worker');
        worker.writeAsStringSync(r'''#!/usr/bin/env python3
import json,os,pathlib,sys,time
def trace(message):
 with open(__file__+'.trace','a') as output:output.write(message+'\n')
if '--probe' in sys.argv:
 pathlib.Path(__file__+'.probed').write_text('ready')
 print(json.dumps({'worker_protocol':1,'native_stop_token_sequences':True}));sys.exit(0)
assert '--serve' in sys.argv
with open(__file__+'.starts','a') as output:output.write(str(os.getpid())+'\n')
print('ready 1',flush=True)
for line in sys.stdin:
 trace('input '+repr(line))
 if line.strip()=='shutdown':
  pathlib.Path(__file__+'.closed.'+str(os.getpid())).write_text('closed')
  break
 command,token,payload=line.rstrip('\n').split(' ',2)
 assert command=='generate'
 pathlib.Path(__file__+'.entered').write_text(str(os.getpid()))
 while not pathlib.Path(__file__+'.release').exists():time.sleep(.005)
 answer={'role':'assistant','content':[{'type':'text','text':'Mira owns release.'}]}
 print(token+' delta '+json.dumps({'content':'Mira owns release.'}),flush=True)
 print(token+' model '+json.dumps(answer),flush=True)
 control=sys.stdin.readline().strip()
 trace('control '+repr(control))
 if control.startswith('cancel '):print(token+' done cancelled',flush=True)
 else:
  print(token+' answer '+json.dumps(answer),flush=True)
  print(token+' done completed',flush=True)
''');
        final permission = await Process.run('/bin/chmod', [
          '700',
          worker.path,
        ]);
        expect(
          permission.exitCode,
          0,
          reason: '${permission.stdout}\n${permission.stderr}',
        );
        final child = await Process.start(
          Platform.resolvedExecutable,
          [
            '-DFORESIGHT_ENABLE_TEST_HOOKS=true',
            'test/fixtures/service_native_owner_lifetime.dart',
            root.path,
            mode,
            library!,
          ],
          environment: {...Platform.environment, 'FORESIGHT_NATIVE': library},
        );
        final output = utf8.decoder.bind(child.stdout).join();
        final errors = utf8.decoder.bind(child.stderr).join();
        late final int code;
        try {
          code = await child.exitCode.timeout(const Duration(seconds: 50));
        } on TimeoutException {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          fail(
            'Owned frontend control exceeded watchdog.\n${await output}\n${await errors}',
          );
        }
        final stdout = await output, stderr = await errors;
        expect(code, 0, reason: '$stdout\n$stderr');
        final report = jsonDecode(stdout.trim().split('\n').last) as Map;
        final nativeLoss = mode == 'work_loss' || mode == 'ack_loss';
        expect(report['mode'], mode);
        expect(report['restart_required'], nativeLoss);
        expect(report['replacement_allowed'], !nativeLoss);
        expect(
          report['native_workers_before_replacement'],
          mode == 'work_loss' || mode == 'clean' ? 1 : 0,
        );
        final starts = File('${worker.path}.starts');
        final children = starts.existsSync()
            ? starts.readAsLinesSync().map(int.parse).toList()
            : <int>[];
        final deadline = Stopwatch()..start();
        for (final process in children) {
          while (await controlAlive(process, worker.path)) {
            expect(
              deadline.elapsed,
              lessThan(const Duration(seconds: 5)),
              reason:
                  'Native supervisor retained control worker after its owning VM exit',
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
      skip: library == null
          ? 'Requires the current native library/helper; controlled models, no physical audio/GPU/model inference'
          : false,
    );
  }
}
