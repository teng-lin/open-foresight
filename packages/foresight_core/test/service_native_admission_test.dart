import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  final needsNative = native == null
      ? 'Requires the freshly built native and SQL support products'
      : false;
  for (final mode in ['selected', 'quarantined', 'unselected']) {
    test('direct service native admission: $mode', () async {
      final root = createTestTempDirectorySync('service-admission-');
      final result = await Process.run(Platform.resolvedExecutable, [
        'test/fixtures/service_native_admission_probe.dart',
        mode,
        root.path,
        native!,
      ]).timeout(const Duration(seconds: 30));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final state =
          jsonDecode(LineSplitter.split(result.stdout as String).last)
              as Map<String, dynamic>;
      expect(state['local_owner'], false);
      if (mode == 'quarantined') {
        expect(state['started'], false);
        expect(state['restarted'], false);
        expect(state['failure'], contains('Native ownership is unconfirmed'));
        expect(state['media_opened'], false);
        expect(state['native_admission'], 0);
      } else {
        expect(state['started'], true, reason: '$state');
        expect(state['restarted'], true, reason: '$state');
        expect(state['failure'], null);
        expect(state['native_admission'], 1);
        expect(state['media_opened'], mode == 'selected');
      }
    }, skip: needsNative);
  }
}
