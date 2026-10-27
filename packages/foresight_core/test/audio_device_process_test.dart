import 'dart:async';
import 'dart:io';
import 'package:foresight_core/src/audio_device_process.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'adapter timeout shares one child and kills and reaps before retry',
    () async {
      final root = createTestTempDirectorySync('audio-process-');
      final pid = File('${root.path}/pid');
      final script = File('${root.path}/adapter')
        ..writeAsStringSync(
          '#!/bin/sh\ntrap "" TERM\nprintf "%s" "\$\$" > "${pid.path}"\nwhile :; do read value; done\n',
        );
      final mode = await Process.run('/bin/chmod', [
        '700',
        script.path,
      ]).timeout(const Duration(seconds: 5));
      expect(mode.exitCode, 0);
      final runner = AudioDeviceProcessRunner(
        timeout: const Duration(milliseconds: 150),
        startProcess: (executable, arguments) async {
          final child = await Process.start(executable, arguments);
          if (executable != script.path) return child;
          try {
            // The timeout tests a running, TERM-resistant adapter. Under load
            // Process.start can return before the shell has executed its trap
            // or PID write; that is not evidence of failed reaping.
            await eventually(
              () => pid.existsSync() && pid.readAsStringSync().isNotEmpty,
              timeout: const Duration(seconds: 3),
            );
            return child;
          } catch (_) {
            child.kill(ProcessSignal.sigkill);
            await child.exitCode.timeout(const Duration(seconds: 3));
            rethrow;
          }
        },
      );
      final first = runner.run(script.path, []);
      expect(identical(first, runner.run(script.path, [])), true);
      await expectLater(
        first,
        throwsA(isA<TimeoutException>()),
      ).timeout(const Duration(seconds: 3));
      final alive = await Process.run('/bin/kill', [
        '-0',
        pid.readAsStringSync(),
      ]).timeout(const Duration(seconds: 3));
      expect(
        alive.exitCode,
        isNot(0),
        reason: 'timeout must reap the actual adapter PID',
      );
      final retry = await runner.run('/bin/sh', [
        '-c',
        "printf '[]'; printf 'adapter failure' >&2; exit 7",
      ]);
      expect(retry.exitCode, 7);
      expect(retry.stdout, '[]');
      expect(retry.stderr, 'adapter failure');
    },
  );
}
