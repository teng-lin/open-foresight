import 'dart:io';

import 'package:foresight_core/src/google_credential_cleanup.dart';
import 'package:foresight_core/src/secret_store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test('Secret Service failure retains cleanup work across restart', () async {
    final root = createTestTempDirectorySync('secret-cleanup-');
    final executable = File('${root.path}/secret-tool');
    executable.writeAsStringSync(
      '#!/bin/sh\nprintf "secret-tool: Could not connect\\n" >&2\nexit 1\n',
    );
    final permissions = await Process.run('/bin/chmod', [
      '700',
      root.path,
      executable.path,
    ]);
    expect(permissions.exitCode, 0, reason: permissions.stderr.toString());
    final secrets = PlatformSecretStore.forTesting(
      executable: executable.path,
      macOS: false,
    );
    final journal = File('${root.path}/credential-cleanup.json');
    final cleanup = GoogleCredentialCleanup(root, secrets, 'profile');
    cleanup.add({'profile': false});
    await expectLater(
      cleanup.retry(revoke: (_) async {}, activeKeys: {}),
      throwsStateError,
    );
    expect(journal.readAsStringSync(), contains('profile'));

    // libsecret reports an absent key with the same status and no diagnostic.
    // A fresh cleanup owner must retain the failed work until that result.
    executable.writeAsStringSync('#!/bin/sh\nexit 1\n');
    final restored = GoogleCredentialCleanup(root, secrets, 'profile');
    await restored.retry(revoke: (_) async {}, activeKeys: {});
    expect(journal.existsSync(), isFalse);
  });

  test(
    'Keychain item-not-found completes cleanup despite its diagnostic',
    () async {
      final root = createTestTempDirectorySync('keychain-cleanup-');
      final executable = File('${root.path}/security');
      executable.writeAsStringSync(
        '#!/bin/sh\nprintf "security: The specified item could not be found\\n" >&2\nexit 44\n',
      );
      final permissions = await Process.run('/bin/chmod', [
        '700',
        root.path,
        executable.path,
      ]);
      expect(permissions.exitCode, 0, reason: permissions.stderr.toString());
      final secrets = PlatformSecretStore.forTesting(
        executable: executable.path,
        macOS: true,
      );
      final cleanup = GoogleCredentialCleanup(root, secrets, 'profile');
      cleanup.add({'profile': false});
      await cleanup.retry(revoke: (_) async {}, activeKeys: {});
      expect(
        File('${root.path}/credential-cleanup.json').existsSync(),
        isFalse,
      );
    },
  );
}
