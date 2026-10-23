// Run on a disposable bus:
// dbus-run-session -- dart --packages=.dart_tool/package_config.json \
//   test_support/file_manager_fixture_probe.dart
import 'dart:convert';
import 'dart:io';

import 'core_fixture.dart';

import 'file_manager_fixture.dart';

Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync('file-reveal-probe-');
  final report = File('${directory.path}/dispatch.json');
  final spy = FileManagerRevealSpy(report);
  final competitor = FileManagerRevealSpy(report);
  try {
    await spy.start(isolated: true);
    var refused = false;
    try {
      await competitor.start(isolated: true);
    } on StateError catch (error) {
      refused = error.message.contains('existing FileManager1 owner');
    }
    if (!refused)
      throw StateError('The existing file manager was not protected');
    final uri = Uri.file('${directory.path}/a note, literal %2C; dollar.txt');
    await openPlatformUri(uri);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!report.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final observed = jsonDecode(report.readAsStringSync()) as Map;
    final revealed = observed['uris'];
    if (observed['method'] != 'ShowItems' ||
        observed['interface'] != 'org.freedesktop.FileManager1' ||
        observed['path'] != '/org/freedesktop/FileManager1' ||
        observed['startup_id'] != '' ||
        revealed is! List ||
        revealed.length != 1 ||
        revealed.single is! String ||
        Uri.parse(revealed.single as String).toFilePath() != uri.toFilePath()) {
      throw StateError('Unexpected reveal dispatch: $observed');
    }
    stdout.writeln(
      'Real absolute file-reveal dispatch and owner protection passed',
    );
  } finally {
    await competitor.close();
    await spy.close();
    directory.deleteSync(recursive: true);
  }
}
