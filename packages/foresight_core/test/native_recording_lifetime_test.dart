import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'Dart recording reuses actual joined native speech and closes its model worker',
    () async {
      final root = createTestTempDirectorySync('native-recording-');
      File('${root.path}/model').writeAsStringSync('control model only');
      final capture = File('${root.path}/capture');
      capture.writeAsStringSync(r'''#!/usr/bin/env python3
import pathlib,struct,sys,time
def emit():
 sys.stdout.buffer.write(struct.pack('<h',2000)*48000+b'\0\0'*96000)
 sys.stdout.buffer.flush()
emit()
while not pathlib.Path(__file__+'.next').exists():time.sleep(.005)
emit()
while True:time.sleep(.1)
''');
      final worker = File('${root.path}/speech-worker');
      worker.writeAsStringSync(r'''#!/usr/bin/env python3
import json,os,pathlib,sys,wave
with open(__file__+'.starts','a') as f:f.write(str(os.getpid())+'\n')
assert '--serve' in sys.argv
print('ready 1',flush=True)
count=0
for line in sys.stdin:
 if line.strip()=='shutdown':
  pathlib.Path(__file__+'.closed').write_text('closed')
  break
 command,token,payload=line.rstrip('\n').split(' ',2)
 assert command=='generate'
 request=json.loads(payload)
 with wave.open(request['prompt'],'rb') as audio:assert audio.getnframes()>0 and audio.getsampwidth()==2
 count+=1
 pathlib.Path(__file__+'.requests').write_text(str(count))
 print(token+' text '+json.dumps('native segment '+str(count)),flush=True)
 print(token+' done completed',flush=True)
''');
      final mode = await Process.run('/bin/chmod', [
        '700',
        capture.path,
        worker.path,
      ]);
      expect(mode.exitCode, 0, reason: '${mode.stdout}\n${mode.stderr}');
      final child = await Process.start(
        Platform.resolvedExecutable,
        ['test/fixtures/native_recording_lifetime.dart', library!, root.path],
        environment: {
          ...Platform.environment,
          'FORESIGHT_CAPTURE_RUNTIME': capture.path,
          'FORESIGHT_WHISPER_WORKER': worker.path,
          'FORESIGHT_WHISPER_BACKEND': 'cpu',
          'FORESIGHT_DATA': root.path,
        },
      );
      final output = utf8.decoder.bind(child.stdout).join();
      final errors = utf8.decoder.bind(child.stderr).join();
      late final int code;
      try {
        code = await child.exitCode.timeout(const Duration(seconds: 40));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        fail(
          'Owned recording VM exceeded its watchdog.\n${await output}\n${await errors}',
        );
      }
      final stdout = await output, stderr = await errors;
      expect(code, 0, reason: '$stdout\n$stderr');
      expect(jsonDecode(stdout.trim()), {
        'segments': ['native segment 1', 'native segment 2'],
        'worker_starts': 1,
        'worker_closed': true,
      });
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: library == null
        ? 'Requires the current native library and helper; deterministic worker, no physical audio or model inference'
        : false,
  );
}
