import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, String> previous;
  setUp(() {
    root = Directory.systemTemp.createTempSync('platform-adapter-');
    previous = Map.of(runtimeConfiguration.environment);
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(previous);
    root.deleteSync(recursive: true);
  });

  Future<File> script(String body) async {
    final file = File('${root.path}/adapter')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    expect((await Process.run('/bin/chmod', ['700', file.path])).exitCode, 0);
    return file;
  }

  test(
    'notification adapters preserve arguments and distinguish denial from failure',
    () async {
      runtimeConfiguration.environment.remove('FORESIGHT_NOTIFICATIONS');
      await expectLater(notificationCapabilities(), throwsStateError);
      await expectLater(
        platformNotification('title', 'message'),
        throwsStateError,
      );
      final adapter = await script(
        'case "\$1" in\n --capabilities) printf \'{"available":true,"granted":true}\';;\n --request-permission) printf \'{"granted":false}\'; exit 1;;\n --title) [ "\$2" = "Apollo title" ] && [ "\$3" = "--message" ] && [ "\$4" = "Body with spaces" ];;\nesac',
      );
      runtimeConfiguration.environment['FORESIGHT_NOTIFICATIONS'] =
          adapter.path;
      expect((await notificationCapabilities())['available'], isTrue);
      expect(
        (await notificationCapabilities(requestPermission: true))['granted'],
        isFalse,
      );
      await platformNotification('Apollo title', 'Body with spaces');
      for (final body in [
        'printf \'{"error":"adapter unavailable"}\'; exit 1',
        'printf \'not json\'; printf \'stderr detail\' >&2; exit 1',
        'printf \'{}\'; exit 1',
      ]) {
        await script(body);
        await expectLater(
          platformNotification('title', 'message'),
          throwsStateError,
        );
      }
      await script('printf \'{"error":"capability unavailable"}\'; exit 1');
      await expectLater(
        notificationCapabilities(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'detail',
            'capability unavailable',
          ),
        ),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'native environment setup filters keys, retries failures and freezes after success',
    () async {
      final source = File('${root.path}/env.c')
        ..writeAsStringSync(r'''
#include <stdio.h>
#include <string.h>
static int mode = 1, calls;
static char values[4096];
void set_mode(int value) { mode = value; }
int get_calls(void) { return calls; }
const char *get_values(void) { return values; }
int fs_set_runtime_environment(const char *key, const char *value) {
  calls++;
  if (mode) return -1;
  size_t used = strlen(values);
  snprintf(values + used, sizeof(values) - used, "%s=%s\n", key, value);
  return 0;
}
''');
      final path = '${root.path}/env.${Platform.isMacOS ? 'dylib' : 'so'}';
      final compile = await Process.run('cc', [
        Platform.isMacOS ? '-dynamiclib' : '-shared',
        '-fPIC',
        source.path,
        '-o',
        path,
      ]);
      expect(compile.exitCode, 0, reason: compile.stderr.toString());
      runtimeConfiguration.environment
        ..clear()
        ..addAll({
          'FORESIGHT_NATIVE': path,
          'FORESIGHT_HELPER': '/owned/helper',
          'UNRELATED_SECRET': 'do not forward',
          'FORESIGHT_ONNX_LIBRARY': '',
        });
      expect(() => configureProfileRuntime(root.path), throwsStateError);
      final library = DynamicLibrary.open(path);
      library.lookupFunction<Void Function(Int32), void Function(int)>(
        'set_mode',
      )(0);
      configureProfileRuntime(root.path);
      final count = library.lookupFunction<Int32 Function(), int Function()>(
        'get_calls',
      );
      final before = count();
      final values = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'get_values',
          )()
          .toDartString();
      expect(values, contains('FORESIGHT_HELPER=/owned/helper'));
      expect(
        values,
        contains('FORESIGHT_LITERT_CACHE=${root.path}/cache/litert'),
      );
      expect(values, contains('PYTHONPYCACHEPREFIX=${root.path}/cache/python'));
      expect(values, isNot(contains('UNRELATED_SECRET')));
      expect(values, isNot(contains('FORESIGHT_ONNX_LIBRARY')));
      configureNativeEnvironment();
      expect(count(), before);
    },
  );

  test(
    'private directories and installation locks reject symlinks without modifying their targets',
    () {
      final directory = Directory('${root.path}/private');
      privateDirectory(directory.path);
      final alias = Link('${root.path}/alias')..createSync(directory.path);
      expect(() => privateDirectory(alias.path), throwsStateError);
      final public = Directory('${root.path}/public')..createSync();
      Process.runSync('/bin/chmod', ['755', public.path]);
      expect(() => privateDirectory(public.path), throwsStateError);
      final app = Directory('${root.path}/App.app')..createSync();
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = app.path;
      final lockPath = installationLockPath(app.path);
      privateDirectory(File(lockPath).parent.path);
      final target = File('${root.path}/target')
        ..writeAsStringSync('unchanged');
      Link(lockPath).createSync(target.path);
      addTearDown(
        () => Directory(File(lockPath).parent.path).deleteSync(recursive: true),
      );
      expect(acquireInstallationLock, throwsStateError);
      expect(target.readAsStringSync(), 'unchanged');
      Link(lockPath).deleteSync();
      final lock = acquireInstallationLock()!;
      expect(lock.lengthSync(), 0);
      lock.unlockSync();
      lock.closeSync();
      expect(configuredInstallationRoot, app.resolveSymbolicLinksSync());
    },
  );

  test(
    'runtime metadata rejects non-resource keys and preserves explicit overrides',
    () {
      final resources = Directory('${root.path}/Resources')..createSync();
      final file = File('${resources.path}/runtime.json');
      for (final entry in <Map<String, Object?>>[
        {'PATH': '/unsafe'},
        {'FORESIGHT_NATIVE': 42},
      ]) {
        file.writeAsStringSync(jsonEncode(entry));
        expect(
          () => RuntimeConfiguration.resolve(
            environment: {'FORESIGHT_RESOURCES': resources.path},
          ),
          throwsFormatException,
        );
      }
      file.writeAsStringSync(
        jsonEncode({
          'FORESIGHT_NATIVE': 'lib/native',
          'FORESIGHT_LITERT_BACKEND': 'gpu',
        }),
      );
      final config = RuntimeConfiguration.resolve(
        environment: {
          'FORESIGHT_RESOURCES': resources.path,
          'FORESIGHT_NATIVE': '/explicit/library',
        },
      );
      expect(config.nativeLibrary, '/explicit/library');
      expect(config['FORESIGHT_LITERT_BACKEND'], 'gpu');
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      expect(acquireInstallationLock(), isNull);
    },
  );
}
