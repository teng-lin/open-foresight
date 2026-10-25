import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/startup.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:test/test.dart';

void main() {
  for (final args in <List<String>>[
    ['--diagnostic-storage-worker'],
    ['--diagnostic-native-support', '/x'],
    ['--diagnostic-native-support=foreign'],
    ['--diagnostic-storage-worker=22'],
    ['--diagnostic-storage-worker', '1', '--diagnostic-native-support', '/x'],
    ['--diagnostic-storage-worker', '02', '--diagnostic-native-support', '/x'],
    [
      '--diagnostic-storage-worker',
      '2147483648',
      '--diagnostic-native-support',
      '/x',
    ],
    [
      '--diagnostic-storage-worker',
      '22',
      '--diagnostic-native-support',
      'relative',
    ],
    [
      '--diagnostic-storage-worker',
      '22',
      '--diagnostic-native-support',
      '/x/../y',
    ],
    [
      '--model-transport-worker',
      '--diagnostic-storage-worker',
      '22',
      '--diagnostic-native-support',
      '/x',
    ],
  ]) {
    test('internal grammar rejects ${args.join(" ")}', () {
      expect(
        DiagnosticWorkerInvocation.parse(args).kind,
        DiagnosticWorkerInvocationKind.invalid,
      );
    });
  }
  test('ordinary and model-worker arguments have no diagnostic authority', () {
    for (final args in <List<String>>[
      [],
      ['--status'],
      ['--model-transport-worker'],
    ]) {
      expect(
        DiagnosticWorkerInvocation.parse(args).kind,
        DiagnosticWorkerInvocationKind.absent,
      );
    }
    final parsed = DiagnosticWorkerInvocation.parse([
      '--diagnostic-storage-worker',
      '22',
      '--diagnostic-native-support',
      '/owned/lib.so',
    ]);
    expect(parsed.kind, DiagnosticWorkerInvocationKind.valid);
    expect(parsed.parentPid, 22);
    expect(parsed.support, '/owned/lib.so');
  });

  test(
    'system writable directory exceptions are exact owner/group/mode rules',
    () {
      bool allowed(String path, int permissions, int uid, int gid) =>
          diagnosticDirectoryModeAllowed(
            path: path,
            mode: 0x4000 | permissions,
            uid: uid,
            gid: gid,
            effectiveUid: 501,
            macOS: true,
          );
      expect(allowed('/Applications', 0x1fd, 0, 80), isTrue);
      expect(allowed('/Applications', 0x1fd, 0, 20), isFalse);
      expect(allowed('/Applications', 0x1fd, 501, 80), isFalse);
      expect(allowed('/Applications/other', 0x1fd, 0, 80), isFalse);
      expect(allowed('/usr/local', 0x5fd, 0, 20), isTrue);
      expect(allowed('/usr/local', 0x5fd, 0, 80), isFalse);
      expect(allowed('/usr/local', 0x1fd, 0, 20), isFalse);
      expect(allowed('/private/var/tmp', 0x3ff, 0, 0), isTrue);
      expect(allowed('/var/tmp', 0x3ff, 0, 0), isFalse);
      expect(allowed('/private/var/tmp', 0x1ff, 0, 0), isFalse);
      expect(allowed('/private/var/tmp', 0x3ff, 501, 20), isFalse);
    },
  );

  DiagnosticStartupContext context(
    String root, {
    DiagnosticHost host = DiagnosticHost.service,
    bool source = false,
    String nativeId = 'a',
    String dartId = 'b',
    String mode = 'aot',
    String? dartOverride,
  }) => DiagnosticStartupContext(
    host: host,
    executable: source && mode == 'jit'
        ? '$root/sdk/bin/dart'
        : '$root/bin/foresight-${host == DiagnosticHost.service ? 'service' : 'mcp'}',
    script: '$root/packages/foresight_core/bin/service.dart',
    nativeId: nativeId * 64,
    dartId: dartId * 64,
    catalogId: 'c' * 64,
    workerMode: mode,
    sourceAnchor: root,
    sourceContext: source,
    dartExecutable: dartOverride ?? '$root/sdk/bin/dart',
    dartSdkRoot: '$root/sdk',
    dartSdkIdentity: 'd' * 64,
    packageConfig: '$root/.dart_tool/package_config.json',
    sourceWorker:
        '$root/packages/foresight_core/bin/diagnostic_storage_worker.dart',
  );

  Future<void> file(String path, {bool executable = false}) async {
    final target = File(path);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(
      'controlled code candidate; no ELF/MachO authority',
    );
    final result = await Process.run('/bin/chmod', [
      executable ? '700' : '600',
      path,
    ]);
    expect(result.exitCode, 0);
  }

  Future<Directory> installation() async {
    final root = createTestTempDirectorySync('startup-');
    for (final name in [
      'bin/foresight-service',
      'bin/foresight-diagnostic-worker',
      'bin/foresight-mcp',
      'bin/foresight-diagnostic-launcher',
      'sdk/bin/dart',
    ]) {
      await file('${root.path}/$name', executable: true);
    }
    for (final name in [
      'lib/libforesight_diagnostic_support.so',
      'lib/libforesight_sql_support.so',
      '.dart_tool/package_config.json',
      'packages/foresight_core/bin/diagnostic_storage_worker.dart',
    ]) {
      await file('${root.path}/$name');
    }
    return root;
  }

  test('off and unavailable worker identity perform no candidate load', () {
    final c = context('/not-an-installation');
    final off = DiagnosticStartup.beforeApplication(
      environment: {
        'FORESIGHT_LOG_LEVEL': 'off',
        'FORESIGHT_SERVICE_TRACE': '1',
      },
      context: c,
    );
    expect(off.configuration.enabled, isFalse);
    expect(off.available, isFalse);
    expect(off.functions, isNull);
    final unavailable = DiagnosticStartup.beforeApplication(
      environment: {},
      context: context('/not-an-installation', dartId: ''),
    );
    expect(unavailable.available, isFalse);
    expect(unavailable.selection, isNull);
  });

  test(
    'early support mapping defers absent command candidates until eligibility',
    () async {
      final root = createTestTempDirectorySync('startup-lazy-');
      final support = '${root.path}/lib/libforesight_diagnostic_support.so';
      File(support).parent.createSync(recursive: true);
      await buildCachedNativeFixture(
        source: 'test/fixtures/diagnostics_owner_ffi.cpp',
        output: support,
      );
      final selected = DiagnosticStartup.beforeApplication(
        environment: {},
        context: context(root.path),
      );
      expect(selected.available, isTrue);
      expect(selected.functions, isNotNull);
      // No service or launcher exists. Mapping support must not check either.
      expect(File('${root.path}/bin/foresight-service').existsSync(), isFalse);
      expect(
        File('${root.path}/bin/foresight-diagnostic-launcher').existsSync(),
        isFalse,
      );
      expect(
        () => selected.selection!.command(22),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
    },
  );

  test('compiled hosts select the standalone companion immutably', () async {
    final root = await installation();
    for (final host in [DiagnosticHost.service, DiagnosticHost.mcp]) {
      final selection = DiagnosticStartupSelection.resolve(
        context(root.path, host: host),
      );
      final command = selection.command(22);
      expect(command.arguments, [
        '${root.path}/bin/foresight-diagnostic-launcher',
        'a' * 64,
        '22',
        '${root.path}/bin/foresight-diagnostic-worker',
        '--diagnostic-storage-worker',
        '22',
        '--diagnostic-native-support',
        '${root.path}/lib/libforesight_diagnostic_support.so',
      ]);
      expect(
        command.arguments,
        isNot(contains('${root.path}/bin/foresight-mcp')),
      );
      expect(() => command.arguments.add('foreign'), throwsUnsupportedError);
    }
  });

  test(
    'installed entrypoints ignore a compiled source-fixture selector',
    () async {
      final root = await installation();
      final selected = DiagnosticStartupSelection.resolve(
        context(root.path, source: true),
      );
      expect(
        selected.support,
        '${root.path}/lib/libforesight_diagnostic_support.so',
      );
      expect(selected.prefix, isEmpty);
      expect(
        selected.command(22).arguments[3],
        '${root.path}/bin/foresight-diagnostic-worker',
      );
    },
  );

  test(
    'metadata refuses symlink, hardlink and writable ordinary candidates',
    () async {
      final root = await installation();
      final path = '${root.path}/lib/libforesight_diagnostic_support.so';
      final candidate = File(path);
      candidate.renameSync('$path.original');
      Link(path).createSync('$path.original');
      expect(
        () => DiagnosticStartupSelection.resolve(context(root.path)),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
      Link(path).deleteSync();
      expect(
        (await Process.run('/bin/ln', ['$path.original', path])).exitCode,
        0,
      );
      expect(
        () => DiagnosticStartupSelection.resolve(context(root.path)),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
      File(path).deleteSync();
      File('$path.original').renameSync(path);
      expect((await Process.run('/bin/chmod', ['666', path])).exitCode, 0);
      expect(
        () => DiagnosticStartupSelection.resolve(context(root.path)),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
    },
  );

  test('SQL selection remains mandatory without diagnostic identity', () async {
    final root = await installation();
    final c = context(root.path, dartId: '');
    expect(c.identitiesAvailable, isFalse);
    expect(
      RuntimeSupportSelection.resolve(c).sqlSupport,
      '${root.path}/lib/libforesight_sql_support.so',
    );
    File('${root.path}/lib/libforesight_sql_support.so').deleteSync();
    expect(
      () => RuntimeSupportSelection.resolve(c),
      throwsA(isA<DiagnosticStartupUnavailable>()),
    );
  });

  test(
    'writable ancestor outside a private install anchor is refused',
    () async {
      final original = await installation();
      final parent = createTestTempDirectorySync('ancestor-');
      final shared = Directory('${parent.path}/untrusted')..createSync();
      final relocated = original.renameSync('${shared.path}/application');
      expect(
        (await Process.run('/bin/chmod', ['777', shared.path])).exitCode,
        0,
      );
      expect(
        () => DiagnosticStartupSelection.resolve(context(relocated.path)),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
    },
  );

  test(
    'source executable cannot choose its own alternative SDK anchor',
    () async {
      final root = await installation();
      await file(
        '${root.path}/build/native/foresight-diagnostic-launcher',
        executable: true,
      );
      await file(
        '${root.path}/build/native/libforesight_diagnostic_support.so',
      );
      await file('${root.path}/foreign-sdk/bin/dart', executable: true);
      expect(
        () => DiagnosticStartupSelection.resolve(
          context(
            root.path,
            host: DiagnosticHost.mcp,
            source: true,
            mode: 'jit',
            dartOverride: '${root.path}/foreign-sdk/bin/dart',
          ),
        ),
        throwsA(isA<DiagnosticStartupUnavailable>()),
      );
    },
  );

  test(
    'explicit external build root preserves source and code authorities',
    () async {
      final source = createTestTempDirectorySync('startup-source-');
      final build = createTestTempDirectorySync('startup-output-');
      for (final name in [
        'application/foresight-service',
        'application/foresight-diagnostic-worker',
        'native/foresight-diagnostic-launcher',
      ]) {
        await file('${build.path}/$name', executable: true);
      }
      for (final name in [
        'native/libforesight_diagnostic_support.so',
        'native/libforesight_sql_support.so',
      ]) {
        await file('${build.path}/$name');
      }
      final c = DiagnosticStartupContext(
        host: DiagnosticHost.service,
        executable: '${build.path}/application/foresight-service',
        script: '',
        nativeId: 'a' * 64,
        dartId: 'b' * 64,
        catalogId: 'c' * 64,
        workerMode: 'aot',
        sourceContext: true,
        sourceAnchor: source.path,
        buildRoot: build.path,
      );
      expect(
        RuntimeSupportSelection.resolve(c).sqlSupport,
        '${build.path}/native/libforesight_sql_support.so',
      );
      final support = DiagnosticPreparedSupport.resolveEarly(c);
      expect(support.anchor, build.path);
      final command = support.command(22);
      expect(
        command.arguments.first,
        '${build.path}/native/foresight-diagnostic-launcher',
      );
      expect(
        command.arguments[3],
        '${build.path}/application/foresight-diagnostic-worker',
      );
      expect(
        command.arguments.last,
        '${build.path}/native/libforesight_diagnostic_support.so',
      );
      expect(command.arguments.any((s) => s.startsWith(source.path)), isFalse);
    },
  );

  test(
    'source descriptor stays within16 entries and carries only reviewed public metadata',
    () async {
      final root = await installation();
      for (final name in ['build/native/foresight-diagnostic-launcher']) {
        await file('${root.path}/$name', executable: true);
      }
      await file(
        '${root.path}/build/native/libforesight_diagnostic_support.so',
      );
      final selection = DiagnosticStartupSelection.resolve(
        context(root.path, host: DiagnosticHost.mcp, source: true, mode: 'jit'),
      );
      final command = selection.command(22);
      expect(command.arguments.length, 15);
      expect(command.arguments[3], '${root.path}/sdk/bin/dart');
      expect(command.arguments.any((s) => s == 'run'), isFalse);
      expect(
        command.arguments.fold<int>(0, (n, s) => n + utf8.encode(s).length + 1),
        lessThanOrEqualTo(2048),
      );
      final encoded = command.arguments
          .singleWhere(
            (s) => s.startsWith('-DFORESIGHT_DIAGNOSTIC_SOURCE_DESCRIPTOR='),
          )
          .split('=')
          .skip(1)
          .join('=');
      final descriptor =
          jsonDecode(utf8.decode(base64Url.decode(encoded))) as Map;
      expect(descriptor.keys.toSet(), {
        'schema',
        'anchor',
        'build',
        'dart',
        'packages',
        'source',
        'kernel',
        'mode',
        'sdk',
        'sdk_id',
      });
      expect(descriptor['anchor'], root.path);
      expect(descriptor['mode'], 'jit');
      expect(
        descriptor['source'],
        '${root.path}/packages/foresight_core/bin/diagnostic_storage_worker.dart',
      );
      expect(command.arguments.join(), isNot(contains('FORESIGHT_SERVICE=')));
    },
  );
}
