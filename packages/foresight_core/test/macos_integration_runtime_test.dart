import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/macos_integration_runtime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late String executable;
  late Map<String, String> environment;
  late File manifest;
  setUp(() {
    final root = createTestTempDirectorySync('mac-runtime-fixture-');
    executable =
        '${root.path}/build/macos/Build/Products/Debug/Test.app/Contents/MacOS/Test';
    File(executable).createSync(recursive: true);
    manifest = File(
      '${root.path}/build/macos/Build/Products/Debug/Test.app/Contents/Resources/runtime.json',
    );
    environment = {
      for (final key in [
        'FORESIGHT_NATIVE',
        'FORESIGHT_HELPER',
        'FORESIGHT_SERVICE',
        'FORESIGHT_MODEL_WORKER',
      ])
        key: (File(
          '${root.path}/$key',
        )..writeAsStringSync('test artifact')).path,
    };
  });

  test('Debug fixture feeds actual sealed resolver before startup', () {
    addTearDown(() => expect(manifest.existsSync(), isFalse));
    final file = prepareMacosIntegrationRuntime(
      registerTearDown: addTearDown,
      executable: executable,
      environment: environment,
      isMacOS: true,
    );
    expect(file?.path, manifest.path);
    final resolved = RuntimeConfiguration.resolve(
      executable: executable,
      environment: {
        for (final key in environment.keys) key: '/untrusted/ambient-override',
      },
    );
    for (final entry in environment.entries) {
      expect(resolved[entry.key], entry.value);
    }
    expect(
      RuntimeConfiguration.resolve(
        executable: executable,
        environment: const {},
      ).nativeLibrary,
      environment['FORESIGHT_NATIVE'],
    );
  });

  test('Linux and nonbundle test executables need no fixture', () {
    expect(
      prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: executable,
        environment: const {},
        isMacOS: false,
      ),
      isNull,
    );
    expect(
      prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: '/dart/test',
        environment: const {},
        isMacOS: true,
      ),
      isNull,
    );
    expect(manifest.existsSync(), isFalse);
  });

  test('production bundle paths are refused without modification', () {
    expect(
      () => prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: '/Applications/Open Foresight.app/Contents/MacOS/App',
        environment: environment,
        isMacOS: true,
      ),
      throwsStateError,
    );
    expect(manifest.existsSync(), isFalse);
  });

  test('existing nonfixture manifest is preserved', () {
    manifest.parent.createSync(recursive: true);
    final original = jsonEncode({'FORESIGHT_NATIVE': '/packaged/native.dylib'});
    manifest.writeAsStringSync(original);
    expect(
      () => prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: executable,
        environment: environment,
        isMacOS: true,
      ),
      throwsStateError,
    );
    expect(manifest.readAsStringSync(), original);
  });

  test('manifest links are refused without touching their target', () {
    final target = File('$executable.fixture')..writeAsStringSync('preserve');
    manifest.parent.createSync(recursive: true);
    Link(manifest.path).createSync(target.path);
    expect(
      () => prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: executable,
        environment: environment,
        isMacOS: true,
      ),
      throwsStateError,
    );
    expect(target.readAsStringSync(), 'preserve');
    expect(Link(manifest.path).existsSync(), isTrue);
  });

  test('missing trusted native input never writes a manifest', () {
    expect(
      () => prepareMacosIntegrationRuntime(
        registerTearDown: addTearDown,
        executable: executable,
        environment: const {},
        isMacOS: true,
      ),
      throwsStateError,
    );
    expect(manifest.existsSync(), isFalse);
  });
}
