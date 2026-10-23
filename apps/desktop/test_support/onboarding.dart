import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/onboarding/onboarding_view.dart';

/// Workspace acceptance starts with a fresh profile, just like a first launch.
/// Use the real skip/complete actions; model fixtures are installed separately.
Future<void> finishOnboarding(WidgetTester tester) async {
  final onboarding = find.byType(OnboardingView);
  const actions = [
    'Start Foresight',
    'Skip for now',
    'Skip for now',
    'Continue',
    'Skip for now',
    'Get started',
  ];
  Future<void> waitFor(bool Function() ready, String reason) async {
    final clock = Stopwatch()..start();
    while (!ready() && clock.elapsed < const Duration(seconds: 60)) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>(() {}));
    }
    expect(ready(), isTrue, reason: reason);
  }

  for (var attempt = 0; onboarding.evaluate().isNotEmpty; attempt++) {
    expect(
      attempt,
      lessThan(actions.length),
      reason: 'Onboarding did not advance',
    );
    final step = List.generate(actions.length, (index) => index).singleWhere(
      (index) => find.text('Step ${index + 1} of 6').evaluate().isNotEmpty,
    );
    final label = find.text(actions[step]);
    final button = find.ancestor(
      of: label,
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    await waitFor(
      () =>
          button.evaluate().isNotEmpty &&
          tester.widget<ButtonStyleButton>(button).onPressed != null,
      'Onboarding action ${actions[step]} did not become available',
    );
    await tester.ensureVisible(label);
    await tester.tap(label);
    await waitFor(
      () =>
          onboarding.evaluate().isEmpty ||
          find.text('Step ${step + 1} of 6').evaluate().isEmpty,
      'Onboarding step ${step + 1} did not finish',
    );
  }
  await tester.pump();
}
