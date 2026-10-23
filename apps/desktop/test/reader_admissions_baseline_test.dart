import 'package:open_foresight/shell/workspace_tab.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/commands.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/onboarding/onboarding_view.dart';
import '../test_support/reader_admissions.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'store_reader_fixture.dart';
import 'pump_until.dart';

final _measurements = <String, Object?>{};

Future<void> _measure(
  WidgetTester tester,
  String label,
  WorkspaceTestAccess shell,
  OfflineHelper helper,
  ReaderAdmissions admissions,
) async {
  final before = admissions.snapshot();
  var notifications = 0;
  var widgetBuilds = 0;
  final oldCallback = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    oldCallback?.call(element, builtOnce);
    widgetBuilds++;
  };
  void changed() => notifications++;
  shell.serviceUiRevision.addListener(changed);
  try {
    for (var i = 0; i < 20; i++) helper.changed?.call();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(notifications, 1, reason: '$label coalesces coarse service events');
    expect(widgetBuilds, greaterThan(0));
    final after = admissions.snapshot();
    // Status-only events retain prepared queries; count worker admissions
    // separately from metadata reads and widget publications.
    for (final boundary in ['read', 'watch', 'worker']) {
      expect(after[boundary], before[boundary], reason: '$label $boundary');
    }
    _measurements[label] = {
      'before': before,
      'after': after,
      'service_ui_notifications': notifications,
      'widget_builds': widgetBuilds,
    };
    final report = Platform.environment['FORESIGHT_DESKTOP_READ_BASELINE'];
    if (report != null) {
      File(report).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(_measurements)}\n',
      );
    }
  } finally {
    shell.serviceUiRevision.removeListener(changed);
    debugOnRebuildDirtyWidget = oldCallback;
  }
}

void main() {
  testWidgets(
    'typed read admissions, service notifications and widget builds are measured separately',
    (tester) async {
      final root = createTestTempDirectorySync('reader-baseline-');
      final store = Store('${root.path}/app.db');
      store.importText(
        'Planning source',
        'Source body',
        'text/plain',
        'fixture',
      );
      store.meeting('Planning meeting');
      store.answer('Question', 'one two three', 'completed', [], 'fixture');
      final admissions = ReaderAdmissions();
      fixtureReader(store, admissions: admissions);
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final connection = TestDesktopConnection(
        Application(Domain(store, helper)),
      );
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        Foresight(connection, deviceLoader: () async => []),
      );
      await tester.pumpAndSettle();
      final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      for (final (label, tab) in [
        ('Sources', WorkspaceTab.sources),
        ('Chat', WorkspaceTab.chat),
        ('Meetings', WorkspaceTab.meetings),
        ('Stats', WorkspaceTab.stats),
        ('Settings', WorkspaceTab.settings),
        // Integrations' account/device controls currently share Settings' root.
        // Models is setup, not an independent Integrations screen.
        ('Integrations', WorkspaceTab.settings),
      ]) {
        final beforeSourceProjections =
            admissions.synchronous['sourceSummaries'] ?? 0;
        shell.navigate(tab);
        await tester.pumpAndSettle();
        if (label == 'Integrations') {
          expect(find.text('Connected services'), findsOneWidget);
          expect(find.text('Refresh audio devices'), findsOneWidget);
        }
        await _measure(tester, label, shell, helper, admissions);
        if (label == 'Sources') {
          expect(
            admissions.synchronous['sourceSummaries'] ?? 0,
            beforeSourceProjections,
            reason: 'Sources rebuilds use prepared snapshots',
          );
          expect(admissions.watches['sources'], 1);
        }
      }
      // Retain the frozen pre-migration JSON; this test records current
      // typed admissions without equating raw-row spies with SQLite work.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      var closed = false;
      unawaited(
        connection.closed.then<void>((_) {
          closed = true;
        }),
      );
      await pumpUntil(tester, () => closed);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Onboarding library admissions and rebuilds are measured', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('onboard-baseline-');
    final store = Store('${root.path}/app.db');
    store.setPreference('onboarding.step', '5');
    store.importText('Planning source', 'Source body', 'text/plain', 'fixture');
    final admissions = ReaderAdmissions();
    fixtureReader(store, admissions: admissions);
    final helper = OfflineHelper('${root.path}/socket', '${root.path}/helper');
    final connection = TestDesktopConnection(
      Application(Domain(store, helper)),
    );
    final commands = await tester.runAsync(
      () => AppCommands.bind(
        '${root.path}/cmd',
        environment: DesktopEnvironment(
          run: (_, _) async => ProcessResult(1, 0, '', ''),
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Foresight(connection, commands: commands, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingView), findsOneWidget);
    expect(find.text('Documents added (1)'), findsOneWidget);
    final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
    await _measure(tester, 'Onboarding', shell, helper, admissions);
    expect(admissions.synchronous['sourceSummaries'] ?? 0, 0);
    expect(admissions.watches['sources'], greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    var closed = false;
    unawaited(connection.closed.then<void>((_) => closed = true));
    await pumpUntil(tester, () => closed && commands!.isClosed);
    expect(tester.takeException(), isNull);
  });
}
