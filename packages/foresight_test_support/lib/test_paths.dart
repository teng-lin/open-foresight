import 'dart:io';

/// Unix socket tests need a short path on macOS. The override lets concurrent
/// local suites choose a short disposable filesystem without sharing /tmp quota.
Directory get shortTestTempRoot =>
    Directory(Platform.environment['FORESIGHT_TEST_TEMP_ROOT'] ?? '/tmp');
