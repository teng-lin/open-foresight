import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/recording.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final version in <int?>[null, 2]) {
    test(
      'missing/wrong ABI $version refuses dependent symbols and native admission',
      () async {
        final root = createTestTempDirectorySync('native-abi-');
        final source = File('${root.path}/fixture.c')
          ..writeAsStringSync(
            version == null
                ? 'int fixture_only(void) { return 0; }'
                : 'int fs_abi_version(void) { return $version; }',
          );
        final library =
            '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
        final built = await Process.run('cc', [
          Platform.isMacOS ? '-dynamiclib' : '-shared',
          '-fPIC',
          source.path,
          '-o',
          library,
        ]);
        expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
        final refused = isA<StateError>().having(
          (error) => error.message,
          'vetted ABI refusal',
          contains('ABI'),
        );
        expect(
          () => NativeLibrary(DynamicLibrary.open(library)).library,
          throwsA(refused),
        );
        final runtime = NativeRuntime(library);
        await expectLater(
          runtime.load('/usr/bin/true', '/dev/null'),
          throwsA(refused),
        );
        runtime.close();
        await runtime.closed;
        expect(runtime.engine, 0);
        final recording = Recording(library, (_) {}, (_, _, _, _) {});
        await expectLater(
          recording.start('/usr/bin/true', '/dev/null'),
          throwsA(refused),
        );
        recording.dispose();
        await recording.closed;
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
        final environment = Map.of(runtimeConfiguration.environment);
        addTearDown(
          () => runtimeConfiguration.environment
            ..clear()
            ..addAll(environment),
        );
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
        runtimeConfiguration.environment['FORESIGHT_HELPER'] =
            '/owned/unused/helper';
        expect(audioCapabilities, throwsA(refused));
        expect(configureNativeEnvironment, throwsA(refused));
      },
    );
  }
  for (final version in <int?>[null, 1, 3]) {
    test(
      'unsupported lifetime $version refuses before native creation',
      () async {
        final root = createTestTempDirectorySync('native-lifetime-version-');
        final source = File('${root.path}/fixture.c')
          ..writeAsStringSync(
            'int fs_abi_version(void) { return 1; }\n'
            '${version == null ? '' : 'int fs_lifetime_version(void) { return $version; }'}',
          );
        final library =
            '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
        final built = await Process.run('cc', [
          Platform.isMacOS ? '-dynamiclib' : '-shared',
          '-fPIC',
          source.path,
          '-o',
          library,
        ]);
        expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
        final refused = isA<StateError>().having(
          (error) => error.message,
          'lifetime refusal',
          contains('lifetime'),
        );
        final runtime = NativeRuntime(library);
        await expectLater(
          runtime.load('/usr/bin/true', '/dev/null'),
          throwsA(refused),
        );
        runtime.close();
        await runtime.closed;
        expect(runtime.engine, 0);
        final recording = Recording(library, (_) {}, (_, _, _, _) {});
        await expectLater(
          recording.start('/usr/bin/true', '/dev/null'),
          throwsA(refused),
        );
        recording.dispose();
        await recording.closed;
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
      },
    );
  }
  test(
    'compatible base audio ABI does not require lifetime or diagnostic extensions',
    () async {
      final root = createTestTempDirectorySync('native-audio-abi-');
      final source = File('${root.path}/fixture.c')
        ..writeAsStringSync(r'''
#include <stdlib.h>
#include <string.h>
int fs_abi_version(void) { return 1; }
char *fs_audio_capabilities(void) { return strdup("{\"fixture\":true}"); }
void fs_string_free(char *value) { free(value); }
''');
      final library =
          '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
      final built = await Process.run('cc', [
        Platform.isMacOS ? '-dynamiclib' : '-shared',
        '-fPIC',
        source.path,
        '-o',
        library,
      ]);
      expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
      final previous = runtimeConfiguration.environment['FORESIGHT_NATIVE'];
      addTearDown(() {
        if (previous == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
        } else {
          runtimeConfiguration.environment['FORESIGHT_NATIVE'] = previous;
        }
      });
      runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
      expect(audioCapabilities(), {'fixture': true});
      final runtime = NativeRuntime(library);
      await expectLater(
        runtime.load('/usr/bin/true', '/dev/null'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'lifetime capability',
            contains('lifetime'),
          ),
        ),
      );
      runtime.close();
      await runtime.closed;
    },
  );
}
