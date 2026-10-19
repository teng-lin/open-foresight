import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';

import '../test_support/file_manager_fixture.dart';

void main() {
  if (Platform.isLinux) {
    test(
      'real absolute file reveal reaches an isolated FileManager1 owner',
      () async {
        final result = await Process.run('dbus-run-session', [
          '--',
          Platform.environment['FORESIGHT_DART_EXECUTABLE'] ?? 'dart',
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('test_support/file_manager_fixture_probe.dart').absolute.path,
        ]).timeout(const Duration(seconds: 45));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains(
            'Real absolute file-reveal dispatch and owner protection passed',
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test('file reveal spy records only the exact ShowItems protocol', () async {
    final directory = createTestTempDirectorySync('file-reveal-');
    final report = File('${directory.path}/dispatch.json');
    final spy = FileManagerRevealSpy(report);
    const uri = 'file:///tmp/imported%20note.md';
    final response = await spy.handleMethodCall(
      DBusMethodCall(
        sender: ':1.42',
        interface: 'org.freedesktop.FileManager1',
        name: 'ShowItems',
        values: [
          DBusArray.string([uri]),
          const DBusString(''),
        ],
      ),
    );
    expect(response, isA<DBusMethodSuccessResponse>());
    expect(jsonDecode(report.readAsStringSync()), {
      'interface': 'org.freedesktop.FileManager1',
      'path': '/org/freedesktop/FileManager1',
      'method': 'ShowItems',
      'uris': [uri],
      'startup_id': '',
    });
    report.deleteSync();
    for (final call in [
      DBusMethodCall(sender: null, interface: 'other', name: 'ShowItems'),
      DBusMethodCall(
        sender: null,
        interface: 'org.freedesktop.FileManager1',
        name: 'Open',
      ),
      DBusMethodCall(
        sender: null,
        interface: 'org.freedesktop.FileManager1',
        name: 'ShowItems',
      ),
      DBusMethodCall(
        sender: null,
        interface: 'org.freedesktop.FileManager1',
        name: 'ShowItems',
        values: [
          DBusArray.string(['https://example.test']),
          const DBusString(''),
        ],
      ),
    ]) {
      expect(await spy.handleMethodCall(call), isA<DBusMethodErrorResponse>());
      expect(report.existsSync(), isFalse);
    }
  });

  test(
    'file reveal spy refuses a non-isolated bus before connecting',
    () async {
      final spy = FileManagerRevealSpy(File('unused-report'));
      await expectLater(spy.start(isolated: false), throwsStateError);
      await spy.close();
    },
  );
}
