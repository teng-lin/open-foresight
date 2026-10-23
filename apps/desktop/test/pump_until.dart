import 'package:flutter_test/flutter_test.dart';

/// Pump widget microtasks and give real I/O producers a turn until their event
/// is observable. No assumption about runner speed or a fixed sleep is needed.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < timeout) {
    await tester.pump();
    await tester.runAsync(() => Future<void>(() {}));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Expected widget event before $timeout deadline',
  );
  await tester.pump();
}

/// Drain work started by widget callbacks in their FakeAsync zone while real
/// worker I/O settles. Awaiting that work inside runAsync would freeze its
/// originating widget microtasks.
Future<void> pumpUntilCompleted(
  WidgetTester tester,
  Future<void> pending,
) async {
  var settled = false;
  Object? failure;
  StackTrace? trace;
  final joined = pending.then<void>(
    (_) => settled = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      settled = true;
    },
  );
  await pumpUntil(tester, () => settled);
  await joined;
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
}
