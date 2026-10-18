class CaptureObservation<T> {
  final T snapshot;
  final bool ready;
  final int attempts;
  final Duration elapsed;
  const CaptureObservation(
    this.snapshot,
    this.ready,
    this.attempts,
    this.elapsed,
  );
}

/// Keep the last capture even on timeout so its pixels and diagnostics can be
/// retained and asserted by the caller instead of losing the failing image.
Future<CaptureObservation<T>> waitForCapture<T>(
  Future<T> Function() capture,
  bool Function(T) ready, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 25),
  Future<void> Function(Duration)? pause,
  Duration Function()? elapsed,
}) async {
  if (interval <= Duration.zero || timeout < Duration.zero) {
    throw ArgumentError(
      'Capture polling needs a positive interval and deadline',
    );
  }
  final stopwatch = Stopwatch()..start();
  final measure = elapsed ?? () => stopwatch.elapsed;
  final wait = pause ?? Future<void>.delayed;
  var attempts = 0;
  while (true) {
    final snapshot = await capture();
    attempts++;
    final observed = ready(snapshot);
    final duration = measure();
    if (observed || duration >= timeout) {
      return CaptureObservation(snapshot, observed, attempts, duration);
    }
    final remaining = timeout - duration;
    await wait(remaining < interval ? remaining : interval);
  }
}
