import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/recording.dart';

void main() {
  test(
    'terminal capture failure survives stopped event and Stop',
    () async {
      final env = Platform.environment;
      final directory = createTestTempDirectorySync('capture-state-');
      final model = File('${directory.path}/model')
        ..writeAsStringSync('probe only');
      final states = <String>[];
      final recorder = Recording(
        env['FORESIGHT_NATIVE']!,
        states.add,
        (_, _, _, _) {},
      );
      try {
        recorder.start(
          '/usr/bin/true',
          model.path,
          playback: false,
          microphoneTarget: 'owned-failure-fixture',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!states.any((s) => s.contains('retries exhausted')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(states.any((s) => s.contains('retries exhausted')), true);
        recorder.drain(flushAll: true);
        expect(recorder.lastError, contains('retries exhausted'));
        expect(states.last, contains('retries exhausted'));
        await expectLater(recorder.stop(), throwsStateError);
        expect(recorder.lastError, contains('retries exhausted'));
        expect(recorder.captures, isEmpty);
        expect(recorder.speeches, isEmpty);
        expect(states, isNot(contains('Transcript saved')));
        expect(states.any((s) => s.startsWith('No speech detected')), false);
      } finally {
        recorder.dispose();
        directory.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['FORESIGHT_CAPTURE_STATE_TEST'] != '1',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
