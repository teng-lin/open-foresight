import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart'
    show serviceEndpoint, serviceLaunchCommand;

void main() {
  late Directory scratch;
  setUp(() {
    scratch = Directory(
      Directory.systemTemp
          .createTempSync('foresight-platform-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  test(
    'packaged service uses LaunchServices with isolated explicit overrides',
    () {
      final bundle =
          '${scratch.path}/App With Spaces.app/Contents/Library/Services/Service.app';
      final executable = File('$bundle/Contents/MacOS/service')
        ..createSync(recursive: true);
      File('$bundle/Contents/Info.plist').writeAsStringSync('<plist/>');
      final command = serviceLaunchCommand(executable.path, {
        'FORESIGHT_DATA': '/private/profile with spaces',
        'FORESIGHT_RUNTIME': '/private/runtime',
        'FORESIGHT_LITERT_BACKEND': 'gpu',
        'PYTHONPYCACHEPREFIX': '/private/cache',
        'UNRELATED_SECRET': 'must not be forwarded',
      }, macOS: true);
      expect(command.executable, '/usr/bin/open');
      expect(command.arguments.take(2), ['-g', '-n']);
      expect(
        command.arguments.last,
        Directory(bundle).resolveSymbolicLinksSync(),
      );
      expect(
        command.arguments,
        contains('FORESIGHT_DATA=/private/profile with spaces'),
      );
      expect(command.arguments, contains('FORESIGHT_LITERT_BACKEND=gpu'));
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
        '/override',
      );
    },
  );

  test(
    'canonical aliases resolve to one profile and short deterministic Mac runtime',
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

  test('Mac rejects overflowing explicit Unix socket path', () {
    expect(
      () => ProfilePaths.resolve({
        'HOME': scratch.path,
        'FORESIGHT_RUNTIME': '${scratch.path}/${'x' * 110}',
      }, macOS: true),
      throwsStateError,
    );
  });

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
      Process.runSync('/bin/chmod', ['755', runtime]);
      expect(
        () => serviceEndpoint(ProfilePaths(data, runtime)),
        throwsStateError,
      );
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
      final runtime = Directory('/tmp').createTempSync('of-probe-');
      final socketPath = '${runtime.path}/helper.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final peers = <Socket>[];
      server.listen(peers.add);
      final helper = Helper(socketPath, '${scratch.path}/helper-data');
      try {
        final startup = helper.start();
        await Future<void>.delayed(const Duration(milliseconds: 10));
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
    if (Platform.isMacOS || Platform.isLinux)
      expect(physicalMemoryGb(), greaterThan(0));
  });
}
