import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'actual native mapping quarantine spans isolates and permits owner cleanup',
    () async {
      // A separate owned VM keeps permanent quarantine out of other test files
      // which legitimately open the same production library concurrently.
      final child = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/native_lifetime_cross_isolate.dart',
        library!,
      ]);
      final output = utf8.decoder.bind(child.stdout).join();
      final errors = utf8.decoder.bind(child.stderr).join();
      late final int code;
      try {
        code = await child.exitCode.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        final stdout = await output, stderr = await errors;
        fail('Owned native control exceeded its watchdog.\n$stdout\n$stderr');
      }
      final stdout = await output, stderr = await errors;
      expect(code, 0, reason: '$stdout\n$stderr');
      expect(jsonDecode(stdout.trim()), {
        'cross_isolate_refused': true,
        'cleanup_joined': true,
      });
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: library == null
        ? 'Requires the current built native lifetime v2 library'
        : false,
  );
}
