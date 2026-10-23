import 'dart:async';
import 'account_menu_workflow_test.dart' show SignedInAccount;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/google_sign_in_dialog.dart';
import 'controller_fixture.dart';
import 'google_sign_in_workflow_test.dart' show PendingGoogleAuth;
import 'meeting_setup_test.dart' show OfflineHelper;

class _HeldConnection extends ControllerConnection {
  _HeldConnection(super.application);
  final entered = Completer<void>(), release = Completer<void>();
  bool holdSave = false, failInitialize = false, holdPreference = false;
  bool replaceOnResume = false;
  @override
  Future<void> initialize() async {
    if (failInitialize) {
      failInitialize = false;
      throw StateError('First initialization failed');
    }
  }

  @override
  Future<void> resume() async {
    if (replaceOnResume) replaceClientSessionForTesting();
    await super.resume();
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (holdPreference && operation == Operation.preferencesSet) {
      entered.complete();
      await release.future;
      throw StateError('Held preference rejected');
    }
    final result = await super.command(operation, args);
    if (holdSave && operation == Operation.notesSave) {
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  Future<(_HeldConnection, dynamic, Store)> mount(
    WidgetTester tester, {
    bool failInitialize = false,
  }) async {
    final root = createTestTempDirectorySync('desktop71-');
    final store = Store('${root.path}/app.db');
    final connection = _HeldConnection(
      Application(
        Domain(
          store,
          OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        ),
      ),
    )..failInitialize = failInitialize;
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      Foresight(connection, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      if (!connection.release.isCompleted) connection.release.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
    });
    return (connection, tester.state(find.byType(Workspace)), store);
  }

  testWidgets('meeting-list preview Generate sends the preview meeting', (
    tester,
  ) async {
    final (connection, dynamic shell, store) = await mount(tester);
    final id = store.meeting('Preview meeting');
    shell.update(() {
      shell.meetingFeature.meetingPreviewId = id;
      shell.meetingFeature.meetingPreviewTab = 'AI summary';
    });
    await tester.pumpAndSettle();
    expect(shell.meetingFeature.meetingId, isNull);
    await tester.tap(find.byTooltip('Generate Summary'));
    await tester.pumpAndSettle();
    final calls = connection.calls.where(
      (call) => call.$1 == Operation.meetingsGenerate,
    );
    expect(calls, hasLength(1));
    expect(calls.single.$2['id'], id);
  });

  for (final create in [false, true]) {
    for (final target in [
      'different note',
      'new draft',
      'original note reopened',
    ]) {
      testWidgets(
        'slow ${create ? 'create' : 'save'} reply cannot retarget $target',
        (tester) async {
          final (connection, dynamic shell, store) = await mount(tester);
          final first = store.saveNote(null, 'First note', 'First body');
          final second = store.saveNote(null, 'Second note', 'Second body');
          shell.update(() {
            shell.tab = 2;
            shell.meetingFeature.noteId = create ? null : first;
            shell.meetingFeature.noteTitle.text = 'Saved first';
            shell.meetingFeature.noteBody.text = 'Saved body';
          });
          await tester.pumpAndSettle();
          connection.holdSave = true;
          await tester.tap(find.text('Save note'));
          await tester.pump();
          expect(connection.entered.isCompleted, isTrue);
          await tester.tap(find.text('Second note'));
          await tester.pump();
          if (target == 'new draft') {
            await tester.tap(find.text('New note'));
            await tester.pump();
          } else if (target == 'original note reopened') {
            await tester.tap(find.text('Saved first'));
            await tester.pump();
          }
          final expectedId = shell.meetingFeature.noteId;
          final expectedTitle = shell.meetingFeature.noteTitle.text;
          final expectedBaseline = shell.meetingFeature.noteBaseline;
          connection.release.complete();
          await tester.pumpAndSettle();
          expect(shell.meetingFeature.noteId, expectedId);
          if (target == 'different note') expect(expectedId, second);
          expect(shell.meetingFeature.noteTitle.text, expectedTitle);
          expect(shell.meetingFeature.noteBaseline, expectedBaseline);
        },
      );
    }
  }

  testWidgets('successful onboarding retry marks the runtime ready', (
    tester,
  ) async {
    final (connection, dynamic shell, _) = await mount(
      tester,
      failInitialize: true,
    );
    expect(shell.onboardingFeature.ready, isFalse);
    expect(shell.error, contains('First initialization failed'));
    final dynamic view = shell.onboardingFeature.build();
    await view.retryRuntime();
    await tester.pumpAndSettle();
    expect(shell.onboardingFeature.ready, isTrue);
    expect(connection.resumes, 1);
    expect(shell.error, isEmpty);
  });

  testWidgets('onboarding retry becomes ready after reconnecting its client', (
    tester,
  ) async {
    final (connection, dynamic shell, _) = await mount(
      tester,
      failInitialize: true,
    );
    connection.replaceOnResume = true;
    final original = connection.clientSessionGeneration;
    final dynamic view = shell.onboardingFeature.build();
    await view.retryRuntime();
    await tester.pumpAndSettle();
    expect(connection.clientSessionGeneration, isNot(same(original)));
    expect(shell.onboardingFeature.ready, isTrue);
    expect(shell.error, isEmpty);
  });

  for (final key in ['serviceIdleMinutes', 'noteStyle', 'inactivity']) {
    testWidgets('settings callback reports failed $key requests', (
      tester,
    ) async {
      final (connection, dynamic shell, _) = await mount(tester);
      shell.update(() => shell.tab = 6);
      await tester.pumpAndSettle();
      connection.failures[Operation.preferencesSet] = StateError(
        'Preference rejected',
      );
      if (key == 'noteStyle') {
        final widget = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>),
        );
        widget.onSelectionChanged!({'Concise'});
      } else {
        final dynamic widget = tester.widget(find.byKey(Key(key)));
        widget.onChanged('60');
      }
      await tester.pumpAndSettle();
      expect(shell.error, contains('Preference rejected'));
      expect(tester.takeException(), isNull);
    });
  }

  for (final boundary in [
    'current',
    'selection',
    'session',
    'clear',
    'dispose',
  ]) {
    testWidgets('held callback failure respects $boundary ownership', (
      tester,
    ) async {
      final (connection, dynamic shell, store) = await mount(tester);
      shell.update(() => shell.tab = 6);
      await tester.pumpAndSettle();
      connection.holdPreference = true;
      final dynamic control = tester.widget(
        find.byKey(const Key('serviceIdleMinutes')),
      );
      control.onChanged('60');
      await tester.pump();
      expect(connection.entered.isCompleted, isTrue);
      switch (boundary) {
        case 'selection':
          shell.update(() => shell.tab = 3);
        case 'session':
          connection.replaceClientSessionForTesting();
        case 'clear':
          store.renewWorkspaceEpoch();
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      connection.release.complete();
      await tester.pumpAndSettle();
      if (boundary != 'dispose') {
        expect(
          shell.error,
          boundary == 'current'
              ? contains('Held preference rejected')
              : isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in [
    'google refresh',
    'device',
    'meeting style',
    'live enhance',
    'automatic answers',
  ]) {
    testWidgets('$action callback reports request failures', (tester) async {
      final (connection, dynamic shell, store) = await mount(tester);
      final id = store.meeting('Callback meeting');
      connection.account = SignedInAccount(
        createTestTempDirectorySync('account-'),
      );
      shell.update(() {
        shell.tab = action == 'google refresh' || action == 'device' ? 6 : 3;
        if (shell.tab == 3) {
          shell.meetingFeature.meetingId = id;
          shell.meetingFeature.meetingPanel = 'Live Q&A';
        }
      });
      await tester.pumpAndSettle();
      connection.failures[Operation.preferencesSet] = StateError(
        'Callback rejected',
      );
      switch (action) {
        case 'google refresh':
          final dynamic control = tester
              .widgetList(
                find.byWidgetPredicate((widget) {
                  try {
                    return (widget as dynamic).value == '4';
                  } catch (_) {
                    return false;
                  }
                }),
              )
              .first;
          control.onChanged('8');
        case 'device':
          final dynamic control = shell.integrationFeature.deviceChoice(false);
          control.onChanged('auto');
        case 'meeting style':
          final control = tester
              .widgetList<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .firstWhere((widget) => widget.value == 'Standard');
          control.onChanged!('Concise');
        case 'live enhance':
          final control = tester.widget<FilledButton>(
            find.byKey(const ValueKey('meeting-live-enhance')),
          );
          control.onPressed!();
        case 'automatic answers':
          final control = tester
              .widgetList<SwitchListTile>(find.byType(SwitchListTile))
              .firstWhere(
                (widget) => (widget.title as Text).data == 'Automatic answers',
              );
          control.onChanged!(true);
      }
      await tester.pumpAndSettle();
      expect(shell.error, contains('Callback rejected'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Google completion removes its own route beneath another dialog',
    (tester) async {
      final root = createTestTempDirectorySync('signin-route-');
      final auth = PendingGoogleAuth(root);
      late BuildContext home;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              home = context;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );
      final signingIn = showDialog<GoogleSignInOutcome>(
        context: home,
        builder: (_) =>
            GoogleSignInDialog(auth: auth, openBrowser: (_) async {}),
      );
      await tester.pump();
      await tester.pump();
      expect(auth.pending, isNotNull);
      final top = showDialog<void>(
        context: home,
        builder: (_) => const AlertDialog(title: Text('Keep this dialog')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      auth.signedIn = true;
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Keep this dialog'), findsOneWidget);
      expect((await signingIn)!.cancelled, isFalse);
      Navigator.of(home).pop();
      await tester.pumpAndSettle();
      await top;
      expect(find.byType(GoogleSignInDialog), findsNothing);
    },
  );
}
