import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

String _profile() {
  final parent = BackupDirectory(
    createTestTempDirectorySync('diag-process-').path,
    private: false,
  );
  try {
    final child = parent.child('profile');
    final path = child.path;
    child.close();
    return path;
  } finally {
    parent.close();
  }
}

void main() {
  late String executable;
  setUpAll(() async {
    executable = '${createTestTempDirectorySync('diag-exe-').path}/diagnostics';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/diagnostics_storage_process.dart',
      '-o',
      executable,
    ]).timeout(const Duration(minutes: 2));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  Future<Map<String, dynamic>> once(List<String> arguments) async {
    final result = await Process.run(
      executable,
      arguments,
    ).timeout(const Duration(seconds: 5));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  Future<({Process process, Map<String, dynamic> proof})> hold(
    String profile,
    String role,
  ) async {
    final process = await Process.start(executable, [
      'hold',
      profile,
      role,
      'fill',
    ]);
    final errors = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(errors.write)
        .asFuture<void>();
    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
      await stderrDone;
    });
    final first = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    final proof = jsonDecode(first) as Map<String, dynamic>;
    expect(proof['slot'], isNotNull, reason: errors.toString());
    return (process: process, proof: proof);
  }

  test(
    'compiled leases bound ten concurrent writers and crash releases the exact lease',
    () async {
      final profile = _profile();
      final active = [
        for (var i = 0; i < 3; i++) await hold(profile, 'service'),
        for (var i = 0; i < 2; i++) await hold(profile, 'desktop'),
        for (var i = 0; i < 5; i++) await hold(profile, 'mcp'),
      ];
      expect(active.map((value) => value.proof['slot']).toSet(), hasLength(10));
      final payloads = Directory('$profile/logs')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .toList();
      expect(payloads, hasLength(30));
      expect(
        payloads.every(
          (file) => file.lengthSync() <= DiagnosticStorage.segmentBytes,
        ),
        isTrue,
      );
      final total = payloads.fold<int>(
        0,
        (sum, file) => sum + file.lengthSync(),
      );
      expect(total, greaterThan(55 * 1024 * 1024));
      expect(total, lessThanOrEqualTo(DiagnosticStorage.maximumPayloadBytes));

      for (final value in active) {
        expect(value.proof['inherited'], isEmpty);
        expect(value.proof['cloexec'], isTrue);
        expect(value.proof['minimum'], greaterThanOrEqualTo(10));
      }
      expect((await once(['once', profile, 'mcp']))['slot'], isNull);
      expect((await once(['once', profile, 'service']))['slot'], isNull);
      final victim = active.last;
      victim.process.kill(ProcessSignal.sigkill);
      expect(await victim.process.exitCode, isNot(0));
      expect(
        (await once(['lease', profile, '${victim.proof['slot']}']))['acquired'],
        isTrue,
      );
      expect(
        (await once(['once', profile, 'mcp']))['slot'],
        victim.proof['slot'],
      );
    },
  );
  test(
    'all eight closed-stdio combinations preserve fd separation and CLOEXEC',
    () async {
      for (var mask = 0; mask < 8; mask++) {
        final profile = _profile();
        final close = [
          for (var fd = 0; fd < 3; fd++)
            if (mask & (1 << fd) != 0) 'exec $fd>&-;',
        ].join(' ');
        final result = await Process.run('/bin/bash', [
          '-c',
          '$close exec "\$@"',
          'fixture',
          executable,
          'stdio',
          profile,
          'desktop',
        ]).timeout(const Duration(seconds: 5));
        expect(
          result.exitCode,
          0,
          reason: 'mask=$mask ${result.stdout}\n${result.stderr}',
        );
        final descriptors =
            jsonDecode(File('$profile/fd-proof.json').readAsStringSync())
                as List;
        expect(descriptors, isNotEmpty);
        for (final descriptor in descriptors) {
          expect(descriptor['descriptor'], greaterThanOrEqualTo(10));
          expect(descriptor['cloexec'], isTrue);
        }
      }
    },
  );
  test(
    'latest service failure survives twenty MCP launches and cold candidates consume no slot',
    () async {
      final profile = _profile();
      final failed = await once([
        'once',
        profile,
        'service',
        'shared',
        'failed',
      ]);
      final failedManifest = File(
        '$profile/logs/slot-${failed['slot']}/manifest.json',
      );
      final expected = failedManifest.readAsStringSync();
      for (var i = 0; i < 20; i++) {
        final next = await once(['once', profile, 'mcp']);
        expect(next['slot'], isNot(failed['slot']));
        expect(failedManifest.readAsStringSync(), expected);
      }
      for (final decision in [
        'contended',
        'withdrawn',
        'failedBeforeLock',
        'unknown',
      ]) {
        final cold = _profile();
        expect(
          (await once(['cold', cold, 'candidate', decision]))['exited'],
          isTrue,
        );
        expect(Directory('$cold/logs').existsSync(), isFalse);
      }
      final files = Directory(
        '$profile/logs',
      ).listSync(recursive: true).whereType<File>();
      expect(
        files
            .where((file) => file.path.endsWith('.jsonl'))
            .fold<int>(0, (n, f) => n + f.lengthSync()),
        lessThanOrEqualTo(DiagnosticStorage.maximumPayloadBytes),
      );
      expect(
        files
            .where((file) => !file.path.endsWith('.jsonl'))
            .fold<int>(0, (n, f) => n + f.lengthSync()),
        lessThanOrEqualTo(DiagnosticStorage.maximumMetadataBytes),
      );
    },
  );
  test(
    'compiled producer flood records timing and RSS without exceeding traffic credits',
    () async {
      final metrics = await once(['metrics', _profile(), 'transient']);
      expect(metrics['writer_exited'], isTrue);
      expect(metrics['accepted'], lessThanOrEqualTo(256));
      expect(
        metrics['charged_high_water_bytes'],
        lessThanOrEqualTo(256 * 1024),
      );
      expect(metrics['record_high_water'], lessThanOrEqualTo(256));
      // Test artifact only; total RSS includes runtime allocator/GC overhead and
      // is not the512KiB logger traffic acceptance bound.
      print('diagnostics.metrics ${jsonEncode(metrics)}');
    },
  );
  test(
    'real partial write disables the sink and preserves its incomplete tail',
    () async {
      final profile = _profile();
      final result = await once(['quota', profile, 'desktop']);
      expect(result['first'], isTrue);
      expect(result['second'], isFalse);
      expect(result['third'], isFalse);
      expect(result['failed'], isTrue);
      final payload = File(
        '$profile/logs/slot-${result['slot']}/0.jsonl',
      ).readAsBytesSync();
      expect(payload.length, 8192);
      expect(payload.last, isNot(10));
      expect(payload.where((byte) => byte == 10), hasLength(2));
    },
  );
  test(
    'real blocked FFI closes within coordinator budget then preserves protocol and exit status',
    () async {
      final profile = _profile();
      final elapsed = Stopwatch()..start();
      final result = await Process.run(executable, [
        'blocked',
        profile,
      ]).timeout(const Duration(seconds: 5));
      expect(result.exitCode, 37, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, 'Content-Length: 2\r\n\r\n{}');
      expect(result.stderr, 'intentional presentation\n');
      expect(File('$profile/cleanup-complete').readAsStringSync(), 'complete');
      final proof =
          jsonDecode(File('$profile/close-proof.json').readAsStringSync())
              as Map;
      expect(proof['writer_exited'], isFalse);
      expect(proof['explicit_exit'], isTrue);
      expect(proof['elapsed_ms'], inInclusiveRange(450, 1000));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        (await once(['lease', profile, '${proof['slot']}']))['acquired'],
        isTrue,
      );
    },
  );
}
