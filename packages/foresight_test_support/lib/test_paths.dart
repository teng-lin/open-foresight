import 'dart:io';

import 'package:test_api/scaffolding.dart' show addTearDown;

/// Unix socket tests need a short path on macOS. The override lets concurrent
/// local suites choose a short disposable filesystem without sharing /tmp quota.
/// Defaults use physical, disk-backed paths: macOS /tmp is a symlink, which
/// descriptor-anchored backup operations deliberately refuse to traverse.
Directory get shortTestTempRoot => Directory(
  Platform.environment['FORESIGHT_TEST_TEMP_ROOT'] ??
      (Platform.isMacOS ? '/private/var/tmp' : '/var/tmp'),
);

/// Allocate a disposable directory and remove it after the current test or
/// setUpAll scope. Explicit earlier cleanup remains safe.
Directory createTestTempDirectorySync([String prefix = 'foresight-test-']) {
  final root = shortTestTempRoot..createSync(recursive: true);
  final directory = root.createTempSync(prefix);
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Future<Directory> createTestTempDirectory([
  String prefix = 'foresight-test-',
]) async {
  final root = shortTestTempRoot;
  await root.create(recursive: true);
  final directory = await root.createTemp(prefix);
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}
