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
