import 'dart:async';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart'
    show
        EndpointInvalid,
        readEndpointRecord,
        serviceEndpoint,
        serviceLaunchCommand,
        writeServiceStartupEnvironment;

void main() {
  // CI also runs this test with -DFORESIGHT_ENABLE_TEST_HOOKS=true by name.
  test('crash and delay hooks require an explicit test compilation', () {
    final configuration = RuntimeConfiguration.resolve(
      environment: {
        'FORESIGHT_CRASH_AT': 'commit',
        'FORESIGHT_TEST_DELAY_MS': '500',
        'FORESIGHT_SERVICE_GATES': '/gates',
      },
      executable: '/service',
    );
    expect(
      configuration['FORESIGHT_CRASH_AT'],
      foresightTestHooksEnabled ? 'commit' : isNull,
    );
    expect(
      configuration['FORESIGHT_TEST_DELAY_MS'],
      foresightTestHooksEnabled ? '500' : isNull,
    );
    // Lifecycle gates are test hooks too: a release service never holds.
    expect(
      configuration['FORESIGHT_SERVICE_GATES'],
      foresightTestHooksEnabled ? '/gates' : isNull,
    );
  });

  test(
    'local sources are revealed even for executable document extensions',
    () {
      for (final extension in [
        'command',
        'terminal',
        'txt',
        'md',
        'pdf',
        'rtf',
      ]) {
        final uri = Uri.file('/home/user/document.$extension');
        final mac = platformUriLaunch(uri, macOS: true);
        expect(mac.executable, '/usr/bin/open');
        expect(mac.arguments, ['-R', '--', uri.toFilePath()]);
        final linux = platformUriLaunch(uri, macOS: false);
        expect(linux.executable, '/usr/bin/dbus-send');
        expect(
          linux.arguments,
          contains('org.freedesktop.FileManager1.ShowItems'),
        );
      }
      expect(
        platformUriLaunch(
          Uri.parse('https://example.test'),
          macOS: false,
        ).executable,
        '/usr/bin/xdg-open',
      );
      expect(
        () => platformUriLaunch(Uri.parse('file://remote/secret.command')),
        throwsArgumentError,
      );
    },
  );

  test('Linux file reveal encodes commas without changing file identity', () {
    final uri = Uri.file('/home/user/notes, budget %2C.md');
    final launch = platformUriLaunch(uri, macOS: false);
    expect(launch.executable, '/usr/bin/dbus-send');
    expect(
      launch.arguments[5],
      'array:string:file:///home/user/notes%2C%20budget%20%252C.md',
    );
    final encoded = launch.arguments[5].substring('array:string:'.length);
    expect(encoded.split(','), hasLength(1));
    expect(Uri.parse(encoded).toFilePath(), uri.toFilePath());
  });

  late Directory scratch;
  setUp(() {
    scratch = Directory(
      createTestTempDirectorySync(
        'foresight-platform-',
      ).resolveSymbolicLinksSync(),
    );
  });
  setUp(() {
    addTearDown(() => scratch.deleteSync(recursive: true));
  });

  test('private file permissions use literal paths and report failures', () {
    final file = File('${scratch.path}/private file \u03bb;literal')
      ..writeAsStringSync('private');
    expect(Process.runSync('/bin/chmod', ['777', file.path]).exitCode, 0);
    protectPrivateFile(file.path);
    expect(file.statSync().mode & 0x1ff, 0x180);
    expect(file.readAsStringSync(), 'private');
    final missing = '${scratch.path}/missing';
    expect(
      () => protectPrivateFile(missing),
      throwsA(
        isA<FileSystemException>().having((e) => e.path, 'path', missing),
      ),
    );
    expect(
      () => protectPrivateFile('${file.path}\u0000other'),
      throwsArgumentError,
    );
  });

  test('private startup handoff hides API keys and is consumed once', () async {
    final runtime = Directory('${scratch.path}/runtime');
    final handoff = await writeServiceStartupEnvironment(runtime, {
      'FORESIGHT_SEARCH_API_KEY': 'private-api-marker',
      'FORESIGHT_RUNTIME': runtime.path,
      'UNRELATED_SECRET': 'do-not-forward',
    });
    expect(handoff.statSync().mode & 0x1ff, 0x180);
    final resolved = RuntimeConfiguration.resolve(
      environment: {'FORESIGHT_STARTUP_ENV': handoff.path},
      executable: '/service',
    );
    expect(resolved['FORESIGHT_SEARCH_API_KEY'], 'private-api-marker');
    expect(resolved['UNRELATED_SECRET'], isNull);
    expect(handoff.existsSync(), isFalse);
    expect(
      () => consumeServiceStartupEnvironment(handoff.path),
      throwsStateError,
    );
  });

  test(
    'packaged service uses LaunchServices with isolated explicit overrides',
    () {
      final bundle =
          '${scratch.path}/App With Spaces.app/Contents/Library/Services/Service.app';
      final executable = File('$bundle/Contents/MacOS/service')
        ..createSync(recursive: true);
      File('$bundle/Contents/Info.plist').writeAsStringSync('<plist/>');
      final command = serviceLaunchCommand(
        executable.path,
        {
          'FORESIGHT_DATA': '/private/profile with spaces',
          'FORESIGHT_RUNTIME': '/private/runtime',
          'FORESIGHT_LITERT_BACKEND': 'gpu',
          'PYTHONPYCACHEPREFIX': '/private/cache',
          'UNRELATED_SECRET': 'must not be forwarded',
          'FORESIGHT_SEARCH_API_KEY': 'argv-must-not-contain-this-key',
        },
        macOS: true,
        startupEnvironmentFile: '/private/startup.json',
      );
      expect(
        command.arguments.join(' '),
        isNot(contains('argv-must-not-contain-this-key')),
      );
      expect(command.executable, '/usr/bin/open');
      expect(command.arguments.take(2), ['-g', '-n']);
      expect(
        command.arguments.last,
        Directory(bundle).resolveSymbolicLinksSync(),
      );
      expect(
        command.arguments,
        contains('FORESIGHT_STARTUP_ENV=/private/startup.json'),
      );
      expect(
        command.arguments.join(' '),
        isNot(contains('FORESIGHT_LITERT_BACKEND=gpu')),
      );
      expect(
        command.arguments.join(' '),
        isNot(contains('must not be forwarded')),
      );
      expect(
        serviceLaunchCommand(executable.path, {}, macOS: false).executable,
        executable.path,
      );
      final plain = File('${scratch.path}/dev-service')..createSync();
      expect(
        serviceLaunchCommand(plain.path, {}, macOS: true).executable,
        plain.path,
      );
      File('$bundle/Contents/Info.plist').deleteSync();
      expect(
        () => serviceLaunchCommand(executable.path, {}, macOS: true),
        throwsStateError,
      );
    },
  );

  test(
    'bundle resource lookup survives spaces, nested service and minimal environment',
    () {
      final app = '${scratch.path}/Open Foresight.app';
      final resources = Directory('$app/Contents/Resources')
        ..createSync(recursive: true);
      File('${resources.path}/runtime.json').writeAsStringSync(
        jsonEncode({
          'FORESIGHT_SERVICE':
              '../Library/Services/Open Foresight Service.app/Contents/MacOS/foresight-service',
          'FORESIGHT_NATIVE': 'lib/libforesight_native.dylib',
          'FORESIGHT_LITERT_BACKEND': 'gpu',
          'FORESIGHT_SEARCH_API_KEY': 'dummy-search-key',
          'FORESIGHT_WEB_CONTENT_API_KEY': 'dummy-summary-key',
        }),
      );
      final settings = RuntimeConfiguration.resolve(
        environment: {},
        executable: '$app/Contents/MacOS/foresight-mcp',
      );
      expect(
        settings.nativeLibrary,
        '${resources.path}/lib/libforesight_native.dylib',
      );
      expect(
        settings['FORESIGHT_SERVICE'],
        contains('Open Foresight Service.app'),
      );
      expect(settings['FORESIGHT_LITERT_BACKEND'], 'gpu');
      expect(settings['FORESIGHT_SEARCH_API_KEY'], 'dummy-search-key');
      expect(settings['FORESIGHT_WEB_CONTENT_API_KEY'], 'dummy-summary-key');
      final nested = Directory(
        '$app/Contents/Library/Services/Open Foresight Service.app/Contents/Resources',
      )..createSync(recursive: true);
      File('${nested.path}/runtime.json').writeAsStringSync(
        jsonEncode({
          'FORESIGHT_NATIVE':
              '../../../../Resources/lib/libforesight_native.dylib',
        }),
      );
      final service = RuntimeConfiguration.resolve(
        environment: {},
        executable: '${nested.parent.path}/MacOS/foresight-service',
      );
      expect(
        service.nativeLibrary,
        '${nested.path}/../../../../Resources/lib/libforesight_native.dylib',
      );
      expect(
        RuntimeConfiguration.resolve(
          environment: {'FORESIGHT_NATIVE': '/override'},
          executable: '$app/Contents/MacOS/app',
        ).nativeLibrary,
        '${resources.path}/lib/libforesight_native.dylib',
      );
    },
  );

  test(
    'bundled runtime rejects ambient and private-handoff code overrides',
    () async {
      final app = '${scratch.path}/Trusted.app';
      final resources = Directory('$app/Contents/Resources')
        ..createSync(recursive: true);
      File('${resources.path}/runtime.json').writeAsStringSync(
        jsonEncode({
          'FORESIGHT_NATIVE': 'lib/trusted.dylib',
          'FORESIGHT_HELPER': 'bin/trusted-helper',
          'FORESIGHT_RUNTIME_REVISION': 'trusted-revision',
        }),
      );
      final untrusted = Directory('${scratch.path}/untrusted')..createSync();
      File(
        '${untrusted.path}/runtime.json',
      ).writeAsStringSync(jsonEncode({'FORESIGHT_NATIVE': '/attacker.dylib'}));
      final injected = {
        'FORESIGHT_RESOURCES': untrusted.path,
        'FORESIGHT_NATIVE': '/attacker.dylib',
        'FORESIGHT_HELPER': '/attacker-helper',
        'FORESIGHT_QUERY_WORKER': '/attacker-query',
        'FORESIGHT_RUNTIME_REVISION': 'attacker-revision',
        'FORESIGHT_DATA': '${scratch.path}/requested-profile',
        // A launcher's status file; the service validates its location.
        'FORESIGHT_STARTUP_STATUS': '${scratch.path}/runtime/startup-1.json',
      };
      for (final handoff in [false, true]) {
        final file = handoff
            ? await writeServiceStartupEnvironment(
                Directory('${scratch.path}/runtime'),
                injected,
              )
            : null;
        final settings = RuntimeConfiguration.resolve(
          environment: file == null
              ? injected
              : {'FORESIGHT_STARTUP_ENV': file.path},
          executable: '$app/Contents/MacOS/service',
        );
        expect(settings.nativeLibrary, '${resources.path}/lib/trusted.dylib');
        expect(
          settings['FORESIGHT_HELPER'],
          '${resources.path}/bin/trusted-helper',
        );
        expect(settings['FORESIGHT_RESOURCES'], resources.path);
        expect(settings['FORESIGHT_QUERY_WORKER'], isNull);
        expect(settings['FORESIGHT_RUNTIME_REVISION'], 'trusted-revision');
        expect(settings['FORESIGHT_DATA'], injected['FORESIGHT_DATA']);
        expect(
          settings['FORESIGHT_STARTUP_STATUS'],
          injected['FORESIGHT_STARTUP_STATUS'],
        );
      }
      expect(
        RuntimeConfiguration.resolve(
          environment: injected,
          executable: '/development/service',
        ).nativeLibrary,
        '/attacker.dylib',
      );
      File('${resources.path}/runtime.json').deleteSync();
      expect(
        () => RuntimeConfiguration.resolve(
          environment: injected,
          executable: '$app/Contents/MacOS/service',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'packaged query terms cannot be enabled or replaced by launch overrides',
    () async {
      final resources = Directory(
        '${scratch.path}/Terms.app/Contents/Resources',
      )..createSync(recursive: true);
      final manifest = File('${resources.path}/runtime.json');
      const injected = {
        'FORESIGHT_QUERY_TERMS_URL': 'https://untrusted.example/terms',
      };
      for (final packagedTerms in [null, 'https://publisher.example/terms']) {
        manifest.writeAsStringSync(
          jsonEncode({
            'FORESIGHT_NATIVE': 'lib/native.dylib',
            if (packagedTerms != null)
              'FORESIGHT_QUERY_TERMS_URL': packagedTerms,
          }),
        );
        for (final handoff in [false, true]) {
          final file = handoff
              ? await writeServiceStartupEnvironment(
                  Directory('${scratch.path}/runtime'),
                  injected,
                )
              : null;
          final resolved = RuntimeConfiguration.resolve(
            environment: file == null
                ? injected
                : {'FORESIGHT_STARTUP_ENV': file.path},
            executable: '${resources.parent.path}/MacOS/service',
          );
          expect(resolved['FORESIGHT_QUERY_TERMS_URL'], packagedTerms);
        }
        final development = RuntimeConfiguration.resolve(
          environment: {...injected, 'FORESIGHT_RESOURCES': resources.path},
          executable: '/development/service',
        );
        expect(
          development['FORESIGHT_QUERY_TERMS_URL'],
          injected['FORESIGHT_QUERY_TERMS_URL'],
        );
      }
    },
  );

  test('native runner resolves Finder resource configuration', () {
    const key = 'FORESIGHT_LITERT_RUNNER';
    final previous = runtimeConfiguration.environment[key];
    try {
      runtimeConfiguration.environment[key] =
          '/bundle with spaces/bin/foresight-model';
      expect(
        liteRtRunner('/obsolete/python-runner'),
        '/bundle with spaces/bin/foresight-model',
      );
    } finally {
      if (previous == null) {
        runtimeConfiguration.environment.remove(key);
      } else {
        runtimeConfiguration.environment[key] = previous;
      }
    }
  });

  test(
    'canonical aliases resolve to one profile under the user Mac temporary root',
    () {
      final home = Directory('${scratch.path}/home')..createSync();
      final profile = Directory('${scratch.path}/profile')..createSync();
      final alias = Link('${scratch.path}/alias')..createSync(profile.path);
      final first = ProfilePaths.resolve({
        'HOME': home.path,
        'FORESIGHT_DATA': '${profile.path}/new',
      }, macOS: true);
      final second = ProfilePaths.resolve({
        'HOME': home.path,
        'FORESIGHT_DATA': '${alias.path}/new',
      }, macOS: true);
      expect(first.data, second.data);
      final privateTemp = Directory('${scratch.path}/T')..createSync();
      Process.runSync('/bin/chmod', ['700', privateTemp.path]);
      final scoped = ProfilePaths.resolve({
        'HOME': home.path,
        'TMPDIR': privateTemp.path,
      }, macOS: true);
      expect(
        scoped.runtime,
        startsWith('${privateTemp.resolveSymbolicLinksSync()}/of-'),
      );
      expect(first.runtime, second.runtime);
      expect(
        utf8.encode('${first.runtime}/application.sock').length,
        lessThan(104),
      );
      expect(
        ProfilePaths.resolve({'HOME': home.path}, macOS: true).data,
        '${home.path}/Library/Application Support/Open Foresight',
      );
    },
  );

  test('explicit Mac runtime does not depend on an unused temporary root', () {
    final runtime = Directory('${scratch.path}/run')..createSync();
    expect(
      ProfilePaths.resolve({
        'HOME': scratch.path,
        'TMPDIR': '/does-not-exist',
        'FORESIGHT_DATA': '${scratch.path}/data',
        'FORESIGHT_RUNTIME': runtime.path,
      }, macOS: true).runtime,
      runtime.path,
    );
  });

  test('Mac rejects overflowing explicit Unix socket path', () {
    expect(
      () => ProfilePaths.resolve({
        'HOME': scratch.path,
        'FORESIGHT_RUNTIME': '${scratch.path}/${'x' * 110}',
      }, macOS: true),
      throwsStateError,
    );
  });

  test(
    'owned temporary directories are private under a permissive umask',
    () async {
      final result = await Process.run('/bin/sh', [
        '-c',
        r'umask 000; exec "$@"',
        'private-temp-test',
        Platform.resolvedExecutable,
        'run',
        'test/fixtures/private_temp_directory.dart',
        scratch.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      final modes = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(modes['temporary'], 0x1c0); // 0700, independent of umask.
      expect(modes['parentAfter'], modes['parentBefore']);
      expect(modes['publicAfter'], 0x1ff); // Existing 0777 stays rejected.
      expect(modes['publicRejected'], isTrue);
      expect(modes['linkRejected'], isTrue);
      expect(scratch.listSync(), isEmpty);
      await expectLater(
        createPrivateTempDirectory(scratch, '../escape-'),
        throwsArgumentError,
      );
      await expectLater(
        createPrivateTempDirectory(Directory('${scratch.path}/missing'), 'p-'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('private directory refuses public mode and symlink', () {
    final path = '${scratch.path}/private';
    privateDirectory(path);
    expect(Directory(path).statSync().mode & 0x3f, 0);
    final alias = Link('${scratch.path}/private-alias')..createSync(path);
    expect(() => privateDirectory(alias.path), throwsStateError);
    Process.runSync('/bin/chmod', ['755', path]);
    expect(() => privateDirectory(path), throwsStateError);
  });

  test(
    'owned legacy profile permissions are repaired without changing data',
    () {
      final path = '${scratch.path}/legacy-profile';
      Directory(path).createSync();
      final model = File('$path/model.bin')..writeAsStringSync('keep model');
      Process.runSync('/bin/chmod', ['755', path]);
      privateDirectory(path, repairOwnedPermissions: true);
      expect(Directory(path).statSync().mode & 0x1ff, 0x1c0);
      expect(model.readAsStringSync(), 'keep model');
      privateDirectory(path, repairOwnedPermissions: true);
      final alias = Link('${scratch.path}/legacy-alias')..createSync(path);
      expect(
        () => privateDirectory(alias.path, repairOwnedPermissions: true),
        throwsStateError,
      );
      Process.runSync('/bin/chmod', ['777', path]);
      expect(
        () => privateDirectory(path, repairOwnedPermissions: true),
        throwsStateError,
      );
      expect(Directory(path).statSync().mode & 0x1ff, 0x1ff);
      expect(model.readAsStringSync(), 'keep model');
      // A caller cannot adopt another user's directory, even in repair mode.
      if (Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() !=
          '0') {
        expect(
          () => privateDirectory('/usr', repairOwnedPermissions: true),
          throwsStateError,
        );
      }
    },
  );

  test(
    'profile endpoint attaches across runtime overrides and validates privacy',
    () {
      final data = '${scratch.path}/data', runtime = '${scratch.path}/owner';
      privateDirectory(data);
      privateDirectory(runtime);
      File(
        '$data/.application-endpoint.json',
      ).writeAsStringSync(jsonEncode({'data': data, 'runtime': runtime}));
      expect(
        serviceEndpoint(ProfilePaths(data, '${scratch.path}/other')),
        '$runtime/application.sock',
      );
      // A record naming a non-private runtime is never used. Clients fall back
      // to their own runtime instead of failing on record content, and that
      // runtime must be private too.
      Process.runSync('/bin/chmod', ['755', runtime]);
      expect(
        () => serviceEndpoint(ProfilePaths(data, runtime)),
        throwsStateError,
      );
      final other = ProfilePaths(data, '${scratch.path}/other');
      expect(
        readEndpointRecord(other),
        isA<EndpointInvalid>().having(
          (record) => record.reason,
          'reason',
          contains('Requires private user-owned directory: $runtime'),
        ),
      );
      expect(serviceEndpoint(other), '${other.runtime}/application.sock');
    },
  );

  test(
    'closing during the helper startup probe cannot launch an orphan',
    () async {
      final marker = File('${scratch.path}/launched');
      final script = File('${scratch.path}/helper');
      script.writeAsStringSync('#!/bin/sh\ntouch "${marker.path}"\n');
      Process.runSync('/bin/chmod', ['700', script.path]);
      final previous = runtimeConfiguration.environment['FORESIGHT_HELPER'];
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = script.path;
      final runtime = createTestTempDirectorySync('of-probe-');
      final socketPath = '${runtime.path}/helper.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final peers = <Socket>[];
      final probed = Completer<void>();
      server.listen((peer) {
        peers.add(peer);
        if (!probed.isCompleted) probed.complete();
      });
      final helper = Helper(socketPath, '${scratch.path}/helper-data');
      try {
        final startup = helper.start();
        await probed.future.timeout(const Duration(seconds: 2));
        await Future.wait([helper.close(), helper.close()]);
        await startup;
        expect(marker.existsSync(), false);
      } finally {
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
        runtime.deleteSync(recursive: true);
        if (previous == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
        } else {
          runtimeConfiguration.environment['FORESIGHT_HELPER'] = previous;
        }
      }
    },
  );

  test('physical memory is detected on supported hosts', () {
    if (Platform.isMacOS || Platform.isLinux) {
      expect(physicalMemoryGb(), greaterThan(0));
    }
  });
}
