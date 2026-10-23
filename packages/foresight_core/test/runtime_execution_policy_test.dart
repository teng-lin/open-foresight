import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/runtime_execution_policy.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, String> environment;
  setUp(() {
    root = createTestTempDirectorySync('runtime-policy-');
    environment = Map.of(runtimeConfiguration.environment);
    addTearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });
  final denied = isA<RpcError>().having(
    (error) => error.code,
    'code',
    RpcErrorCode.denied,
  );

  test('installed runtime roots reject external files and symlink escapes', () {
    final installed = Directory('${root.path}/installed')..createSync();
    runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = installed.path;
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
    'restored query registrations refuse execution before spawning',
    () async {
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = root.path;
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
    runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = root.path;
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
}
