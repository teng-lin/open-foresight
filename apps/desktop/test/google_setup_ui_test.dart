import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'unconfigured Calendar connection opens actionable setup and cancellation leaves it disconnected',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('google-setup-ui-');
      final store = Store('${root.path}/application.db');
      final domain = Domain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
      );
      try {
        await tester.pumpWidget(
          Foresight(domain, deviceLoader: () async => []),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        final connect = find.widgetWithText(FilledButton, 'Connect Google');
        await tester.ensureVisible(connect);
        expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
        expect(
          find.text(
            'Google sign-in setup required. Choose Connect Google to get started.',
          ),
          findsOneWidget,
        );
        await tester.tap(connect);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Set up Google Drive and Calendar'), findsOneWidget);
        expect(find.textContaining('Google Calendar API'), findsOneWidget);
        expect(find.text('Import client JSON'), findsOneWidget);
        tester.view.physicalSize = const Size(640, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(AlertDialog)).height,
          lessThanOrEqualTo(400),
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(domain.application.googleAuth.connected, false);
        expect(domain.application.googleAuth.signingIn, false);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    },
  );
}
