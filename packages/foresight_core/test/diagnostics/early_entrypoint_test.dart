import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/capture_process.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late String service;
  setUpAll(() async {
    final root = createTestTempDirectorySync('diagnostic-entry-');
    service = '${root.path}/service';
    final compiled = await runCaptureProcess(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/service.dart',
      '-o',
      service,
    ], timeout: const Duration(seconds: 90));
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
  });

  Future<ProcessResult> run(
    List<String> arguments,
    Directory root, {
    String? input,
  }) async {
    final process = await Process.start(
      service,
      arguments,
      environment: {
        'FORESIGHT_DATA': '${root.path}/data',
        'FORESIGHT_RUNTIME': '${root.path}/runtime',
        'FORESIGHT_NATIVE_LIBRARY': '${root.path}/missing-application-native',
        'FORESIGHT_TEST_SQL_SUPPORT_LIBRARY':
            '${root.path}/missing-sql-support',
        'FORESIGHT_LOG_LEVEL': 'trace',
      },
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    var exited = false;
    final exit = process.exitCode.then((value) {
      exited = true;
      return value;
    });
    addTearDown(() async {
      if (!exited) process.kill(ProcessSignal.sigkill);
      await exit.timeout(const Duration(seconds: 2));
      await Future.wait([output, errors]).timeout(const Duration(seconds: 2));
    });
    if (input != null) process.stdin.write(input);
    await process.stdin.close().timeout(const Duration(seconds: 2));
    return ProcessResult(
      process.pid,
      await exit.timeout(const Duration(seconds: 3)),
      await output.timeout(const Duration(seconds: 2)),
      await errors.timeout(const Duration(seconds: 2)),
    );
  }

  test(
    'compiled internal modes refuse before any profile SQL or app-native bootstrap',
    () async {
      final root = createTestTempDirectorySync('diag-early-modes-');
      for (final args in [
        ['--diagnostic-storage-worker'],
        ['--diagnostic-storage-worker=22'],
        [
          '--diagnostic-storage-worker',
          '22',
          '--diagnostic-native-support',
          '${root.path}/missing',
        ],
        ['--model-transport-worker=foreign'],
        ['--model-transport-worker', '--diagnostic-storage-worker'],
      ]) {
        final result = await run(args, root);
        expect(result.exitCode, args.length == 4 ? 65 : 64);
        expect(result.stdout, isEmpty);
        expect(result.stderr, isEmpty);
        expect(Directory('${root.path}/data').existsSync(), isFalse);
        expect(Directory('${root.path}/runtime').existsSync(), isFalse);
      }
    },
  );

  test(
    'compiled model worker preserves framed protocol and skips SQL and logging',
    () async {
      final root = createTestTempDirectorySync('model-early-mode-');
      final result = await run(['--model-transport-worker'], root, input: '{}');
      expect(result.exitCode, 0);
      expect(jsonDecode((result.stdout as String).trim()), {
        'ok': false,
        'kind': 'transport',
      });
      expect(result.stderr, isEmpty);
      expect(Directory('${root.path}/data').existsSync(), isFalse);
      expect(Directory('${root.path}/runtime').existsSync(), isFalse);
    },
  );
}
