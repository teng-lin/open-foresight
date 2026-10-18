import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_test_support/capture_poll.dart';
import 'package:foresight_test_support/capture_process.dart';
import 'package:test/test.dart';

void main() {
  test('capture child output drains both pipes without backpressure', () async {
    final directory = createTestTempDirectorySync('capture-child-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final script = File('${directory.path}/capture.dart')
      ..writeAsStringSync('''
import 'dart:io';
void main() {
  stdout.write('o' * 131072);
  stderr.write('e' * 131072);
}
''');
    final result = await runCaptureProcess(Platform.resolvedExecutable, [
      script.path,
    ], timeout: const Duration(seconds: 10));
    expect(result.exitCode, 0);
    expect(result.stdout, 'o' * 131072);
    expect(result.stderr, 'e' * 131072);
  });

  test(
    'stalled capture child is killed and reaped before timeout returns',
    () async {
      CaptureProcessTimeout? failure;
      try {
        await runCaptureProcess('/bin/sh', [
          '-c',
          'exec sleep 30',
        ], timeout: const Duration(milliseconds: 50));
      } on CaptureProcessTimeout catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      final probe = await runCaptureProcess('/bin/kill', [
        '-0',
        '${failure!.pid}',
      ]);
      expect(probe.exitCode, isNot(0));
    },
  );

  test('captures again until rendered pixels satisfy the condition', () async {
    var elapsed = Duration.zero;
    var frames = 0;
    final pauses = <Duration>[];
    final observation = await waitForCapture(
      () async => ++frames,
      (frame) => frame == 3,
      elapsed: () => elapsed,
      pause: (duration) async {
        pauses.add(duration);
        elapsed += duration;
      },
    );
    expect(observation.ready, isTrue);
    expect(observation.snapshot, 3);
    expect(observation.attempts, 3);
    expect(pauses, [
      const Duration(milliseconds: 25),
      const Duration(milliseconds: 25),
    ]);
  });

  test(
    'deadline retains the final failing capture and bounds polling',
    () async {
      var elapsed = Duration.zero;
      var frames = 0;
      final pauses = <Duration>[];
      final observation = await waitForCapture(
        () async => 'frame-${++frames}',
        (_) => false,
        timeout: const Duration(milliseconds: 30),
        interval: const Duration(milliseconds: 20),
        elapsed: () => elapsed,
        pause: (duration) async {
          pauses.add(duration);
          elapsed += duration;
        },
      );
      expect(observation.ready, isFalse);
      expect(observation.snapshot, 'frame-3');
      expect(observation.elapsed, const Duration(milliseconds: 30));
      expect(pauses, [
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 10),
      ]);
    },
  );

  test('capture errors propagate instead of reporting stale success', () async {
    await expectLater(
      waitForCapture<int>(
        () async => throw StateError('grim failed'),
        (_) => true,
      ),
      throwsStateError,
    );
  });
}
