import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/audio_devices.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String libraryPath;
  late void Function(int) setMode;
  late int Function() balance, microphoneCalls, systemCalls;
  String? previous;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('audio-permission-failures-');
    final source = File('${root.path}/fixture.c')
      ..writeAsStringSync(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int mode, outstanding, microphones, systems;
void set_mode(int value) { mode = value; microphones = systems = 0; }
int balance(void) { return outstanding; }
int microphone_calls(void) { return microphones; }
int system_calls(void) { return systems; }
static char *owned(const char *value) { outstanding++; return strdup(value); }
char *fs_audio_capabilities(void) {
  if (mode == 1) return NULL;
  if (mode == 2) return owned("{broken");
  if (mode == 7) return owned("[]");
  if (mode == 3) return owned("{\"microphone_purpose_present\":false}");
  char result[256];
  snprintf(result, sizeof(result),
    "{\"microphone_purpose_present\":true,\"system_audio_purpose_present\":true,\"microphone\":\"%s\"}",
    microphones ? (mode == 4 ? "denied" : "granted") : "unknown");
  return owned(result);
}
int fs_audio_request_microphone(void) { microphones++; return mode == 4 ? -1 : 0; }
char *fs_audio_request_system(int timeout_ms) {
  systems++;
  if (mode == 5 || timeout_ms != 10000) return NULL;
  if (mode == 6) return owned("{broken");
  if (mode == 8) return owned("[]");
  return owned("{\"system_audio\":\"unknown\",\"permission_verified\":false}");
}
void fs_string_free(char *value) { outstanding--; free(value); }
''');
    libraryPath = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final result = await Process.run('cc', [
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      source.path,
      '-o',
      libraryPath,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final lib = DynamicLibrary.open(libraryPath);
    setMode = lib.lookupFunction<Void Function(Int32), void Function(int)>(
      'set_mode',
    );
    balance = lib.lookupFunction<Int32 Function(), int Function()>('balance');
    microphoneCalls = lib.lookupFunction<Int32 Function(), int Function()>(
      'microphone_calls',
    );
    systemCalls = lib.lookupFunction<Int32 Function(), int Function()>(
      'system_calls',
    );
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    previous = runtimeConfiguration.environment['FORESIGHT_NATIVE'];
    runtimeConfiguration.environment['FORESIGHT_NATIVE'] = libraryPath;
    setMode(0);
  });
  tearDown(() {
    if (previous == null) {
      runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
    } else {
      runtimeConfiguration.environment['FORESIGHT_NATIVE'] = previous!;
    }
    expect(
      balance(),
      0,
      reason:
          'Every owned native response must be freed, including rejected JSON',
    );
  });

  test(
    'capability queries never request permission and null responses fail cleanly',
    () {
      expect(audioCapabilities()['microphone'], 'unknown');
      expect(microphoneCalls(), 0);
      expect(systemCalls(), 0);
      setMode(1);
      expect(audioCapabilities, throwsStateError);
    },
  );

  test('malformed and wrongly shaped capability responses are freed', () {
    setMode(2);
    expect(audioCapabilities, throwsFormatException);
    expect(balance(), 0);
    setMode(7);
    expect(audioCapabilities, throwsA(isA<TypeError>()));
    expect(microphoneCalls(), 0);
    expect(systemCalls(), 0);
  });

  test(
    'microphone results refresh capabilities after granted and denied requests',
    () async {
      final granted = await requestMicrophonePermission();
      expect(granted['granted'], isTrue);
      expect(granted['microphone'], 'granted');
      expect(microphoneCalls(), 1);
      setMode(4);
      final denied = await requestMicrophonePermission();
      expect(denied['granted'], isFalse);
      expect(denied['microphone'], 'denied');
      expect(microphoneCalls(), 1);
      expect(systemCalls(), 0);
    },
  );

  test(
    'missing microphone purpose string fails before a native request',
    () async {
      setMode(3);
      await expectLater(requestMicrophonePermission(), throwsStateError);
      expect(microphoneCalls(), 0);
    },
    skip: !Platform.isMacOS ? 'Purpose strings apply to macOS bundles' : false,
  );

  test(
    'null system permission responses fail without claiming a grant',
    () async {
      setMode(5);
      await expectLater(requestSystemAudioPermission(), throwsStateError);
      expect(systemCalls(), 1);
    },
  );

  test(
    'malformed system permission responses are freed inside their worker isolate',
    () async {
      setMode(6);
      await expectLater(requestSystemAudioPermission(), throwsFormatException);
      expect(balance(), 0);
      setMode(8);
      await expectLater(
        requestSystemAudioPermission(),
        throwsA(isA<TypeError>()),
      );
      expect(systemCalls(), 1);
    },
  );
}
