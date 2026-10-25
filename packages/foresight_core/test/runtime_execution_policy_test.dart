import 'dart:io';
import 'dart:convert';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/runtime_execution_policy.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Install a derived snapshot; the captured configuration itself is immutable.
void _configure(Map<String, String?> values) =>
    installRuntimeConfiguration(runtimeConfiguration.withOverrides(values));

void main() {
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('runtime-policy-');
    final previous = runtimeConfiguration;
    addTearDown(() => installRuntimeConfiguration(previous));
  });
  final denied = isA<RpcError>().having(
    (error) => error.code,
    'code',
    RpcErrorCode.denied,
  );

  test('installed runtime roots reject external files and symlink escapes', () {
    final installed = Directory('${root.path}/installed')..createSync();
    _configure({'FORESIGHT_INSTALL_ROOT': installed.path});
    final inside = File('${installed.path}/runner')
      ..writeAsStringSync('fixture');
    final outside = File('${root.path}/outside')..writeAsStringSync('fixture');
    requireInstalledRuntime(inside.path);
    Link('${installed.path}/escape').createSync(outside.path);
    expect(() => requireInstalledRuntime(outside.path), throwsA(denied));
    expect(
      () => requireInstalledRuntime('${installed.path}/escape'),
      throwsA(denied),
    );
    expect(
      () => requireInstalledRuntime('${installed.path}/../outside'),
      throwsA(denied),
    );
  });

  test(
    'empty and unbundled runtime selections keep their existing meaning',
    () {
      _configure({'FORESIGHT_INSTALL_ROOT': root.path});
      expect(requireInstalledRuntime(''), '');
      final bundledWhitespace = File('${root.path}/ ')
        ..writeAsStringSync('data');
      expect(
        requireInstalledRuntime(bundledWhitespace.path),
        bundledWhitespace.resolveSymbolicLinksSync(),
      );
      _configure({'FORESIGHT_INSTALL_ROOT': null});
      expect(requireInstalledRuntime(' '), ' ');
      expect(requireInstalledRuntime(''), '');
    },
  );

  test(
    'whitespace query runtime cannot execute outside the installation',
    () async {
      final installed = Directory('${root.path}/installed')..createSync();
      final outside = Directory('${root.path}/outside')..createSync();
      final marker = File('${outside.path}/executed');
      final executable = File('${outside.path}/ ')
        ..writeAsStringSync('''#!/bin/sh
printf executed > ${jsonEncode(marker.path)}
printf '%s\\n' '{"type":"ready"}'
while IFS= read -r request; do
  printf '%s\\n' '{"type":"result","id":"request","text":"outside"}'
done
''');
      expect(
        (await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
        0,
      );
      final childEnvironment = {'PATH': outside.path};
      // This is a real executable name, not an absent/default runtime value.
      final control = await Process.run(
        ' ',
        [],
        environment: childEnvironment,
        workingDirectory: outside.path,
      ).timeout(const Duration(seconds: 3));
      expect(control.exitCode, 0, reason: '${control.stderr}');
      expect(marker.readAsStringSync(), 'executed');
      marker.deleteSync();

      _configure({'FORESIGHT_INSTALL_ROOT': installed.path});
      var spawned = false;
      final runtime = DedicatedQueryRuntime(
        python: ' ',
        worker: ' ',
        model: '/model-data',
        timeout: const Duration(seconds: 3),
        startProcess: (program, arguments) {
          spawned = true;
          return Process.start(
            program,
            arguments,
            environment: childEnvironment,
            workingDirectory: outside.path,
          );
        },
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.complete('question', 'request'),
        throwsA(denied),
      );
      expect(spawned, false);
      expect(marker.existsSync(), false);
    },
  );

  test(
    'installed query processes execute canonical runtime and worker paths',
    () async {
      _configure({'FORESIGHT_INSTALL_ROOT': root.path});
      final report = File('${root.path}/paths');
      final python = File('${root.path}/python')
        ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$0" > ${jsonEncode(report.path)}
exec python3 "\$@"
''');
      final worker = File('${root.path}/worker.py')
        ..writeAsStringSync('''
import json,sys
with open(${jsonEncode(report.path)},'a') as output: output.write(sys.argv[0]+'\\n')
print('{"type":"ready"}',flush=True)
for line in sys.stdin:
 request=json.loads(line)
 print(json.dumps({'type':'result','id':request['id'],'text':'selected'}),flush=True)
''');
      expect(
        (await Process.run('/bin/chmod', ['700', python.path])).exitCode,
        0,
      );
      final pythonAlias = Link('${root.path}/python-alias')
        ..createSync(python.path);
      final workerAlias = Link('${root.path}/worker-alias.py')
        ..createSync(worker.path);
      final runtime = DedicatedQueryRuntime(
        python: pythonAlias.path,
        worker: workerAlias.path,
        model: '/data-only',
      );
      addTearDown(runtime.close);
      expect(await runtime.complete('question', 'canonical'), 'selected');
      expect(report.readAsLinesSync(), [
        python.resolveSymbolicLinksSync(),
        worker.resolveSymbolicLinksSync(),
      ]);
    },
  );

  test(
    'restored query registrations refuse execution before spawning',
    () async {
      _configure({'FORESIGHT_INSTALL_ROOT': root.path});
      var spawned = false;
      final runtime = DedicatedQueryRuntime(
        python: '/outside/python',
        worker: '/outside/worker.py',
        model: '/model-data',
        startProcess: (_, _) async {
          spawned = true;
          throw StateError('Must not execute');
        },
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.complete('question', 'request'),
        throwsA(denied),
      );
      expect(spawned, false);
    },
  );

  test('restored generation refuses execution before native probing', () async {
    _configure({'FORESIGHT_INSTALL_ROOT': root.path});
    await expectLater(
      probeNativeModel(
        '/missing-native-fixture',
        '/outside/runner',
        '/model-data',
      ),
      throwsA(denied),
    );
    final runtime = NativeRuntime(
      Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
    );
    addTearDown(runtime.close);
    await expectLater(
      runtime.load('/outside/runner', '/model-data'),
      throwsA(denied),
    );
  });

  test(
    'stored speech runtimes cannot start outside the installation',
    () async {
      _configure({'FORESIGHT_INSTALL_ROOT': root.path});
      final recording = Recording(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, _, _, _) {},
      );
      addTearDown(() async {
        recording.dispose();
        await recording.closed;
      });
      await expectLater(
        recording.start('/outside/speech', '/model-data'),
        throwsA(denied),
      );
    },
  );
}
