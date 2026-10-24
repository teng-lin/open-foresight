import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final ownership in ['manual', 'historical']) {
    for (final readiness in ['unconfigured', 'snapshot-null']) {
      test(
        '$ownership $readiness indexing and recovery yield with durable pending work',
        () async {
          final root = createTestTempDirectorySync('index-ready-');
          final child = await Process.start(Platform.resolvedExecutable, [
            'run',
            'test/fixtures/meeting_index_readiness.dart',
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
