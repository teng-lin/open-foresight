import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'application_operations_test.dart' show ArtifactGenerator;

void main() {
  test(
    'registered detector is reused, replaced, and closed with its application',
    () async {
      final root = createTestTempDirectorySync('detector-app-');
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final helper = Helper(
        '${root.path}/unused.sock',
        root.path,
        manageProcess: false,
      );
      addTearDown(helper.close);
      final runtime = ArtifactGenerator();
      addTearDown(runtime.close);
      final domain = Domain(store, helper)..generator = runtime;
      addTearDown(domain.close);
      final app = Application(domain);
      addTearDown(app.close);
      final environment = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(environment),
      );
      final worker = File('${root.path}/worker.py')
        ..writeAsStringSync('''
import json,sys,os,pathlib
model=pathlib.Path(sys.argv[-1])
with open(str(model)+'.pids','a') as log: log.write(str(os.getpid())+'\\n')
print('{"type":"ready"}',flush=True)
for line in sys.stdin:
 request=json.loads(line)
 print(json.dumps({'type':'result','id':request['id'],'text':''}),flush=True)
''');
      runtimeConfiguration.environment['FORESIGHT_QUERY_WORKER'] = worker.path;
      final first = File('${root.path}/first.model')
        ..writeAsStringSync('fixture one');
      await store.register(
        dedicatedQueryModelKind,
        first.path,
        'python3',
        backend: dedicatedQueryBackend,
      );
      final meeting = store.meeting('Detector lifecycle');
      final queue = app.proactive;
      queue.begin(meeting);
      Future<void> detect(int offset) async {
        store.transcript(
          meeting,
          'A sufficiently long transcript without a question. Segment $offset.',
          true,
          offset,
          offset + 1000,
          'microphone',
        );
        queue.notify(meeting);
        await queue.process();
        expect(queue.errors, isEmpty);
      }

      await detect(0);
      final firstPid = int.parse(
        File('${first.path}.pids').readAsLinesSync().single,
      );
      await detect(2000);
      expect(File('${first.path}.pids').readAsLinesSync(), ['$firstPid']);
      final second = File('${root.path}/second.model')
        ..writeAsStringSync('fixture two');
      await store.register(
        dedicatedQueryModelKind,
        second.path,
        'python3',
        backend: dedicatedQueryBackend,
      );
      await detect(4000);
      expect(
        (await Process.run('kill', ['-0', '$firstPid'])).exitCode,
        isNot(0),
      );
      final secondPid = int.parse(
        File('${second.path}.pids').readAsLinesSync().single,
      );
      expect(secondPid, isNot(firstPid));
      await app.close();
      expect(
        (await Process.run('kill', ['-0', '$secondPid'])).exitCode,
        isNot(0),
      );
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(store.rows('SELECT * FROM transcript'), hasLength(3));
    },
  );
}
