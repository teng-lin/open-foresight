import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const _identity =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<void> command(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = utf8.decoder.bind(process.stderr).join();
  var exited = false;
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    exited = true;
    expect(code, 0, reason: '${await output}\n${await errors}');
  } finally {
    if (!exited) process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    final captured = '${await output}\n${await errors}';
    if (captured.trim().isNotEmpty) print(captured);
  }
}

void main() {
  late Directory build;
  late String library, launcher;
  setUpAll(() async {
    build = createTestTempDirectorySync('diag-real-');
    await command('chmod', ['700', build.path]);
    final native = Directory('../../native').absolute.path;
    library = '${build.path}/support.${Platform.isMacOS ? 'dylib' : 'so'}';
    launcher = '${build.path}/launcher';
    final flags = [
      '-std=c11',
      '-DNDEBUG',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-Wpedantic',
      '-I',
      native,
      '-DFORESIGHT_DIAGNOSTIC_NATIVE_ID="$_identity"',
      if (Platform.isMacOS) ...[
        '-mmacosx-version-min=15.0',
        '-DFS_DIAG_TEST_CONTEXT=1',
        '-DFS_DIAG_FIXTURE_BASE=${jsonEncode(build.path)}',
        '-DFS_DIAG_FIXTURE_PREFIX="/ofsession"',
      ],
    ];
    await command('cc', [
      ...flags,
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      for (final source in [
        'diagnostic_support.c',
        'diagnostic_protocol.c',
        'diagnostic_endpoint.c',
        Platform.isMacOS
            ? 'diagnostic_kernel_darwin.c'
            : 'diagnostic_kernel_linux.c',
        'diagnostic_inherited.c',
      ])
        '$native/$source',
      '-o',
      library,
    ]);
    await command('cc', [
      ...flags,
      '$native/diagnostic_launcher.c',
      '$native/diagnostic_protocol.c',
      '-o',
      launcher,
    ]);
    print(
      jsonEncode({
        'fixture_native_only': true,
        'platform': Platform.operatingSystemVersion,
        'flags': flags,
        'source_sha256': {
          for (final file
              in (Directory(native)
                  .listSync()
                  .whereType<File>()
                  .where(
                    (file) =>
                        file.uri.pathSegments.last.startsWith('diagnostic_'),
                  )
                  .toList()
                ..sort((a, b) => a.path.compareTo(b.path))))
            file.uri.pathSegments.last: sha256
                .convert(file.readAsBytesSync())
                .toString(),
        },
        'library_sha256': sha256
            .convert(File(library).readAsBytesSync())
            .toString(),
        'launcher_sha256': sha256
            .convert(File(launcher).readAsBytesSync())
            .toString(),
      }),
    );
  });
  for (final mode in ['normal', 'idle-death', 'alias', 'unsafe-control']) {
    test(
      'real session shared child $mode owns storage and physical close',
      () async {
        final profile = createTestTempDirectorySync('diag-profile-');
        await command('chmod', ['700', profile.path]);
        final process = await Process.start(Platform.resolvedExecutable, [
          'test/fixtures/diagnostics_session_child.dart',
          library,
          launcher,
          profile.path,
          mode,
        ]);
        var exited = false;
        final exit = process.exitCode.then((value) {
          exited = true;
          return value;
        });
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        addTearDown(() async {
          if (!exited) process.kill(ProcessSignal.sigkill);
          await exit.timeout(const Duration(seconds: 5));
          print(
            'real session $mode stdout=${await output} stderr=${await errors}',
          );
        });
        final code = await exit.timeout(const Duration(seconds: 20));
        expect(code, 0, reason: '${await output}\n${await errors}');
        final result = jsonDecode((await output).trim()) as Map;
        expect(result['writer_exited'], isTrue);
        expect(result['owner_settled'], isTrue);
        expect(result['requires_explicit_exit'], isFalse);
        expect(result['close_ms'], lessThan(900));
        if (mode == 'normal') {
          expect(result['flushed'], isTrue);
          expect(result['child_not_live'], isTrue);
          final records =
              Directory('${profile.path}/logs/slot-${result['slot']}')
                  .listSync()
                  .whereType<File>()
                  .where((file) => file.path.endsWith('.jsonl'))
                  .expand((file) => file.readAsLinesSync())
                  .map((line) => jsonDecode(line) as Map)
                  .toList();
          expect(records, hasLength(2));
          expect(records.first, containsPair('schema', 2));
          expect(records.first, containsPair('pid', result['pid']));
          expect(records.first, containsPair('build_id', _identity));
          expect(records.first, containsPair('session', result['session']));
          expect(records.first['producer'], matches(r'^entrypoint:\d+:\d+$'));
          expect(records.first['sequence'], 1);
          expect(records.map((record) => record['event']), [
            'runtime.failed',
            'service.ready',
          ]);
          expect(records.map((record) => record['sequence']), [1, 2]);
          final manifest =
              jsonDecode(
                    File(
                      '${profile.path}/logs/slot-${result['slot']}/manifest.json',
                    ).readAsStringSync(),
                  )
                  as Map;
          expect(manifest['session'], result['session']);
          expect(manifest['pid'], result['pid']);
          expect(manifest['role'], 'service');
          expect(manifest['has_error'], isTrue);
          expect(manifest['failure_order'], greaterThan(0));
        } else if (mode == 'idle-death') {
          expect(result['health'], 'storageWorkerExited');
          expect(result['child_not_live'], isTrue);
        } else {
          expect(result['before'], isTrue);
          expect(result['after'], mode == 'alias');
          expect(result['slot'], isNull);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
