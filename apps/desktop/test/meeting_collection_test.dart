import 'desktop_fixture_owner.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import '../test_support/core_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'cancelled Calendar meetings keep their status and saved transcript badge',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('calendar-status-ui-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/application.db');
      final id = store.meeting('Cancelled review');
      store.transcript(
        id,
        'Saved before cancellation.',
        true,
        0,
        60000,
        'microphone',
      );
      final domain = Domain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
      );
      final app = Application(domain);
      expect(app.google.syncing, false);
      final start = DateTime.now().millisecondsSinceEpoch;
      store.db.execute(
        'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [
          'event',
          'account',
          'primary',
          'google-id',
          id,
          '',
          start,
          start + 1800000,
          'cancelled',
          '{}',
          start,
        ],
      );
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        await tester.pumpAndSettle();
        expect(find.text('Calendar cancelled'), findsOneWidget);
        expect(find.text('Transcript'), findsOneWidget);
        expect(find.text('Cancelled review'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    }),
  );

  testWidgets(
    'meetings group by date, preview saves notes, and narrow previews close and expand',
    (tester) async => withDesktopFixtures(tester, () async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('meeting-collection-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/application.db');
      final first = store.meeting('Product review');
      store.meeting('Planning session');
      store.transcript(
        first,
        'Keep this whole transcript.',
        true,
        0,
        30000,
        'microphone',
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(
              Application(
                Domain(
                  store,
                  OfflineHelper('${root.path}/socket', '${root.path}/helper'),
                ),
              ),
            ),
            deviceLoader: () async => [],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Transcript'), findsOneWidget);
        await tester.tap(find.text('Product review'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('meeting-preview')), findsOneWidget);
        expect(find.text('Planning session'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('meeting-notes-editor')),
          'Preserve my edited notes.',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
            first,
          ]).single['body'],
          'Preserve my edited notes.',
        );
        await tester.tap(find.widgetWithText(TextButton, 'Transcript'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Copy full transcript'), findsOneWidget);
        expect(
          find.byKey(ValueKey('meeting-transcript-$first')),
          findsOneWidget,
        );
        tester.view.physicalSize = const Size(640, 700);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Close meeting preview'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('meeting-preview')), findsNothing);
        await tester.tap(find.text('Product review'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Expand meeting'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('All meetings'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('meeting-notes-editor')),
              )
              .controller!
              .text,
          'Preserve my edited notes.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    }),
  );
}
