import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/google_auth.dart';
import 'package:foresight_core/src/application.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class BundledGoogleAuth extends GoogleAuth {
  BundledGoogleAuth(super.directory, {super.defaultClient});
  int invitations = 0;
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    invitations++;
    throw StateError('Browser sign-in cancelled');
  }
}

class BundledGoogleDomain extends Domain {
  final GoogleAuth auth;
  BundledGoogleDomain(super.store, super.helper, this.auth);
  late final _application = Application(this, auth: auth);
  @override
  Application get application => _application;
}

void main() {
  testWidgets(
    'bundled Google setup goes directly to sign-in from Settings, Calendar and every Drive import',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('google-bundled-ui-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final client = File('${root.path}/bundled-client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
              'client_secret': 'fixture-application',
            },
          }),
        );
      final auth = BundledGoogleAuth(
        Directory('${root.path}/google'),
        defaultClient: client,
      );
      final store = Store('${root.path}/application.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final domain = BundledGoogleDomain(store, helper, auth);
      try {
        await tester.pumpWidget(
          Foresight(domain, deviceLoader: () async => []),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Google sign-in setup required.'),
          findsNothing,
        );
        expect(find.text('Advanced OAuth configuration'), findsOneWidget);
        final connect = find.widgetWithText(FilledButton, 'Connect Google');
        await tester.ensureVisible(connect);
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(auth.invitations, 1);
        expect(find.text('Set up Google Drive and Calendar'), findsNothing);
        await tester.tap(find.text('Meetings').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect Calendar'));
        await tester.pumpAndSettle();
        expect(auth.invitations, 2);
        await tester.tap(find.text('Sources').first);
        await tester.pumpAndSettle();
        for (final label in [
          'Add files from Drive',
          'Add an entire Drive folder',
          'Import last 1 year from Drive',
        ]) {
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await tester.pumpAndSettle();
          final item = find.widgetWithText(PopupMenuItem<String>, label);
          expect(tester.widget<PopupMenuItem<String>>(item).enabled, true);
          await tester.tap(item);
          await tester.pumpAndSettle();
        }
        expect(auth.invitations, 5);
        expect(auth.connected, false);
        expect(store.sources, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await auth.close();
        await helper.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'unconfigured Calendar connection opens actionable setup and cancellation leaves it disconnected',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('google-setup-ui-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
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
