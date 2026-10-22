import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late String kernel;
  setUpAll(() async {
    final build = createTestTempDirectorySync('google-verifier-build-');
    kernel = '${build.path}/verify.dill';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '--packages=.dart_tool/package_config.json',
      'tool/verify_google_configuration.dart',
      '-o',
      kernel,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  Future<ProcessResult> verify(Directory root, Map<String, Object?> config) {
    final client = File('${root.path}/client.json')
      ..writeAsStringSync(jsonEncode(config));
    return Process.run(
      Platform.resolvedExecutable,
      [kernel],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '',
        'TMPDIR': root.path,
        'FORESIGHT_GOOGLE_CLIENT': client.path,
      },
      includeParentEnvironment: false,
    );
  }

  test(
    'packaged invitation verifier accepts owned typed cancellation',
    () async {
      final root = createTestTempDirectorySync('google-verifier-');
      final result = await verify(root, {
        'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(jsonDecode(result.stdout as String), {
        'status': 'passed',
        'application_configured': true,
        'browser_invitation_verified': true,
        'account_authorized': false,
        'account_state_created': false,
      });
      expect(result.stderr, isEmpty);
      expect(root.listSync().map((file) => file.uri.pathSegments.last), [
        'client.json',
      ]);
    },
  );

  test('invitation verifier still rejects an invalid registration', () async {
    final root = createTestTempDirectorySync('google-verifier-invalid-');
    final result = await verify(root, {
      'web': {'client_id': 'fixture.apps.googleusercontent.com'},
    });
    expect(result.exitCode, isNot(0));
    expect(result.stdout, isEmpty);
    expect(
      result.stderr,
      contains(
        'Packaged Google application registration is missing or invalid',
      ),
    );
    expect(root.listSync(), hasLength(1));
  });
}
