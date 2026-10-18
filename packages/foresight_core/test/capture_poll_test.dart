import 'package:foresight_test_support/capture_poll.dart';
import 'package:test/test.dart';

void main() {
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
