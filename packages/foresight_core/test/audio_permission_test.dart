import 'package:foresight_test_support/test_paths.dart';
import 'dart:ffi';
import 'dart:io';
import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  test(
    'system permission is explicit, asynchronous and preserves uncertainty',
    () async {
      final scratch = createTestTempDirectorySync('audio-permission-');
      final previous = runtimeConfiguration.environment['FORESIGHT_NATIVE'];
      try {
        final source = File('${scratch.path}/fixture.c')
          ..writeAsStringSync(r'''
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int calls = 0, mode = 0;
int request_count(void) { return calls; }
void set_mode(int value) { mode = value; }
int fs_abi_version(void) { return 1; }
char *fs_audio_capabilities(void) {
  return strdup(mode == 3 ? "{\"system_audio_purpose_present\":false}" :
    "{\"system_audio_purpose_present\":true,\"system_audio\":\"unknown\"}");
}
char *fs_audio_request_system(int timeout_ms) {
  calls++;
  if (timeout_ms != 10000) return NULL;
  usleep(150000);
  if (mode == 1) return strdup("{\"system_audio\":\"pending\",\"system_audio_request\":\"requesting\",\"permission_verified\":false}");
  if (mode == 2) return strdup("{\"system_audio\":\"denied\",\"system_audio_request\":\"failed\",\"permission_verified\":false,\"message\":\"Enable system audio recording in Settings\"}");
  return strdup("{\"system_audio\":\"unknown\",\"system_audio_request\":\"completed\",\"permission_verified\":false}");
}
void fs_string_free(char *value) { free(value); }
''');
        final path =
            '${scratch.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
        final compile = await Process.run('cc', [
          Platform.isMacOS ? '-dynamiclib' : '-shared',
          '-fPIC',
          source.path,
          '-o',
          path,
        ]);
        expect(compile.exitCode, 0, reason: compile.stderr.toString());
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = path;
        final library = DynamicLibrary.open(path);
        final count = library.lookupFunction<Int32 Function(), int Function()>(
          'request_count',
        );
        final mode = library
            .lookupFunction<Void Function(Int32), void Function(int)>(
              'set_mode',
            );
        expect(audioCapabilities()['system_audio'], 'unknown');
        expect(count(), 0, reason: 'Capabilities must never prompt');
        final pending = requestSystemAudioPermission();
        expect(
          await Future.any([
            pending.then((_) => false),
            Future<bool>(() => true),
          ]),
          isTrue,
          reason: 'The consent call must not block the service event loop',
        );
        final result = await pending;
        expect(result['system_audio'], 'unknown');
        expect(result['system_audio_request'], 'completed');
        expect(result['permission_verified'], isFalse);
        expect(result.containsKey('granted'), isFalse);
        mode(1);
        expect(
          (await requestSystemAudioPermission())['system_audio'],
          'pending',
        );
        mode(2);
        expect(
          (await requestSystemAudioPermission())['message'],
          contains('Settings'),
        );
        expect(count(), 3);
        if (Platform.isMacOS) {
          mode(3);
          await expectLater(requestSystemAudioPermission(), throwsStateError);
          expect(
            count(),
            3,
            reason: 'Missing purpose string must not call TCC',
          );
        }
      } finally {
        if (previous == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
        } else {
          runtimeConfiguration.environment['FORESIGHT_NATIVE'] = previous;
        }
        scratch.deleteSync(recursive: true);
      }
    },
  );
}
