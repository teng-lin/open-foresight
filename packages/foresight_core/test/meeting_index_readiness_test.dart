import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/capture_process.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late String fixture;
  setUpAll(() async {
    final build = createTestTempDirectorySync('index-build-');
    fixture = '${build.path}/readiness';
    // Compile the actual child once, outside each producer/recovery watchdog.
    // Direct execution also makes the watchdog own the producer's actual PID.
    final compiled = await runCaptureProcess(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/meeting_index_readiness.dart',
      '-o',
      fixture,
    ], timeout: const Duration(seconds: 90));
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
  });
  for (final ownership in ['manual', 'historical']) {
    for (final readiness in ['unconfigured', 'snapshot-null']) {
      test(
        '$ownership $readiness indexing and recovery yield with durable pending work',
        () async {
          final root = createTestTempDirectorySync('index-ready-');
          final child = await Process.start(fixture, [
            root.path,
            ownership,
            readiness,
          ]);
          final output = child.stdout.transform(utf8.decoder).join();
          final errors = child.stderr.transform(utf8.decoder).join();
          var timedOut = false;
          var reaped = false;
          try {
            final exitCode = await child.exitCode.timeout(
              const Duration(seconds: 12),
              onTimeout: () async {
                timedOut = true;
                child.kill(ProcessSignal.sigkill);
                return child.exitCode.timeout(const Duration(seconds: 5));
              },
            );
            reaped = true;
            final diagnostics =
                '${await output.timeout(const Duration(seconds: 5))}\n${await errors.timeout(const Duration(seconds: 5))}';
            expect(
              timedOut,
              false,
              reason: 'Owned producer exceeded watchdog; $diagnostics',
            );
            expect(exitCode, 0, reason: diagnostics);
            expect(diagnostics, contains('index_returned'));
            expect(diagnostics, contains('recover_returned'));
            expect(
              diagnostics,
              contains(
                'retained_intent calls=${readiness == 'unconfigured' ? 0 : 2}',
              ),
            );
            expect(
              diagnostics,
              contains(
                'readiness_returned calls=${readiness == 'unconfigured' ? 1 : 3}',
              ),
            );
          } finally {
            if (!reaped) {
              child.kill(ProcessSignal.sigkill);
              await child.exitCode.timeout(const Duration(seconds: 5));
            }
          }
        },
      );
    }
  }
}
