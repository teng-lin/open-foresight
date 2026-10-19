import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/app_theme.dart';
import 'package:open_foresight/onboarding_view.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    int initial = 0,
    Future<void> Function(int)? save,
    Future<void> Function()? complete,
    Future<bool> Function()? connect,
    bool ready = true,
    String runtimeError = '',
    Future<void> Function()? retry,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: foresightTheme(),
        home: OnboardingView(
          initialStep: initial,
          runtimeReady: ready,
          runtimeError: runtimeError,
          retryRuntime: retry ?? () async {},
          saveStep: save ?? (_) async {},
          complete: complete ?? () async {},
          generation: (done) => TextButton(
            onPressed: done,
            child: const Text('Install Gemma fixture'),
          ),
          transcription: (done) => TextButton(
            onPressed: done,
            child: const Text('Install Whisper fixture'),
          ),
          permissions: (_) => const Text('Permission actions'),
          imports: (_) => const Text('Import actions'),
          library: (_) => const Text('Actual imported documents'),
          connectGoogle: connect ?? () async => true,
          googleConnected: false,
          googleEmail: '',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'right information card is vertically centered in a wide window',
    (tester) async {
      await show(tester);
      final logo = tester.widget<Image>(
        find.descendant(
          of: find.byType(ForesightBrand),
          matching: find.byType(Image),
        ),
      );
      expect(
        (logo.image as AssetImage).assetName,
        'assets/images/open-foresight-logo.png',
      );
      final card = tester.getRect(
        find.byKey(const ValueKey('onboarding-information-card')),
      );
      expect(card.center.dy, closeTo(500, 1));
      expect(card.center.dx, closeTo(960, 1));
      expect(card.top, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('welcome fits the normal onboarding window without scrolling', (
    tester,
  ) async {
    await show(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(Scaffold));
    final button = tester.getRect(find.text('Start Foresight'));
    final notice = tester.getRect(
      find.textContaining('Setup downloads the models you choose.'),
    );
    expect(button.top, greaterThanOrEqualTo(viewport.top));
    expect(notice.bottom, lessThan(viewport.bottom));
    final left = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(left.position.maxScrollExtent, 0);
    expect(find.text('Open Foresight'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'welcome, model installers, permissions, skipped sign-in and document completion persist in sequence',
    (tester) async {
      final steps = <int>[];
      var complete = false;
      await show(
        tester,
        save: (step) async => steps.add(step),
        complete: () async => complete = true,
      );
      await tester.tap(find.text('Start Foresight'));
      await tester.pumpAndSettle();
      expect(find.text('Install Gemma fixture'), findsOneWidget);
      await tester.tap(find.text('Install Gemma fixture'));
      await tester.pumpAndSettle();
      expect(find.text('Install Whisper fixture'), findsOneWidget);
      await tester.tap(find.text('Install Whisper fixture'));
      await tester.pumpAndSettle();
      expect(find.text('Permission actions'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Import actions'), findsOneWidget);
      expect(find.text('Actual imported documents'), findsOneWidget);
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(steps, [1, 2, 3, 4, 5]);
      expect(complete, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resumed step and back navigation save progress; failures keep the current page',
    (tester) async {
      var fail = true;
      final steps = <int>[];
      await show(
        tester,
        initial: 2,
        save: (step) async {
          if (fail) throw StateError('Could not save setup progress');
          steps.add(step);
        },
      );
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not save setup progress'),
        findsOneWidget,
      );
      expect(find.text('Install Whisper fixture'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Install Gemma fixture'), findsOneWidget);
      expect(steps, [1]);
    },
  );

  testWidgets(
    'Google explanation precedes OAuth; cancel and incomplete sign-in stay on page',
    (tester) async {
      var calls = 0;
      var connected = false;
      final steps = <int>[];
      await show(
        tester,
        initial: 4,
        save: (step) async => steps.add(step),
        connect: () async {
          calls++;
          return connected;
        },
      );
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Connect your Google account'), findsOneWidget);
      expect(calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Continue to Google'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(steps, isEmpty);
      connected = true;
      await tester.tap(find.text('Sign in with Google'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Continue to Google'));
      await tester.pumpAndSettle();
      expect(steps, [5]);
      expect(find.text('Add documents manually'), findsOneWidget);
    },
  );

  testWidgets('saving locks navigation and completion failure can be retried', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    await show(
      tester,
      initial: 5,
      complete: () async {
        calls++;
        if (calls == 1) {
          await gate.future;
          throw StateError('Service disconnected');
        }
      },
    );
    await tester.tap(find.text('Get started'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('Back'),
              matching: find.byWidgetPredicate((w) => w is TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Get started'),
          )
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Service disconnected'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('runtime failure offers retry without constructing installers', (
    tester,
  ) async {
    var retries = 0;
    await show(
      tester,
      initial: 1,
      ready: false,
      runtimeError: 'Helper unavailable',
      retry: () async {
        retries++;
      },
    );
    expect(find.text('Install Gemma fixture'), findsNothing);
    await tester.tap(find.text('Retry connection'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 6'), findsOneWidget);
  });

  testWidgets(
    'compact window and large text retain imports and library without overflow',
    (tester) async {
      await show(tester, initial: 5);
      await tester.binding.setSurfaceSize(const Size(600, 600));
      final viewContext = tester.element(find.byType(OnboardingView));
      final existing = MediaQuery.of(viewContext);
      await tester.pumpWidget(
        MediaQuery(
          data: existing.copyWith(textScaler: TextScaler.linear(1.8)),
          child: MaterialApp(
            theme: foresightTheme(),
            home: OnboardingView(
              initialStep: 5,
              runtimeReady: true,
              retryRuntime: () async {},
              saveStep: (_) async {},
              complete: () async {},
              generation: (_) => const SizedBox(),
              transcription: (_) => const SizedBox(),
              permissions: (_) => const SizedBox(),
              imports: (_) => const Text('Import actions'),
              library: (_) => const Text('Actual imported documents'),
              connectGoogle: () async => false,
              googleConnected: false,
              googleEmail: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Actual imported documents'));
      expect(tester.takeException(), isNull);
    },
  );
}
