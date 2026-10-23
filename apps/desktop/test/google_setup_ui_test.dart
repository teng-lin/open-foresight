import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/desktop.dart' show Operation;
import 'desktop_connection_fixture.dart';
import 'pump_until.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/google_auth.dart';
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
}

// The remote decoder owns status. A configure reply must arrive after the
// provider event; a feature must not make that snapshot writable to continue.
class ReadonlyGoogleStatusConnection extends TestDesktopConnection {
  ReadonlyGoogleStatusConnection(super.application);
  bool configuredStatusBeforeReply = false;
  @override
  Map<String, dynamic> get googleStatus => Map.unmodifiable(super.googleStatus);
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    final result = await super.command(operation, args);
    if (operation == Operation.googleConfigure) {
      configuredStatusBeforeReply = googlePresentation.provider == 'granola';
    }
    return result;
  }
}

void main() {
  testWidgets(
    'Granola calendar option configures Calendar only and disables every Drive import',
    (tester) async {
      final root = createTestTempDirectorySync('granola-calendar-ui-');
      final auth = BundledGoogleAuth(Directory('${root.path}/google'));
      final store = Store('${root.path}/application.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final domain = BundledGoogleDomain(store, helper, auth);
      final app = Application(domain, auth: domain.auth);
      final connection = ReadonlyGoogleStatusConnection(app);
      await tester.pumpWidget(
        Foresight(connection, deviceLoader: () async => []),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final connect = find.widgetWithText(
        OutlinedButton,
        'Connect calendar through Granola',
      );
      await tester.ensureVisible(connect);
      await tester.runAsync(() => tester.tap(connect));
      await pumpUntil(tester, () => auth.invitations == 1);
      await tester.pumpAndSettle();
      expect(connection.configuredStatusBeforeReply, true);
      expect(auth.viaGranola, true);
      expect(auth.invitations, 1);
      expect(find.textContaining('Drive is unavailable.'), findsWidgets);
      await tester.tap(find.text('Sources').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      for (final label in [
        'Add files from Drive',
        'Add an entire Drive folder',
        'Import last 1 year from Drive',
      ]) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.widgetWithText(PopupMenuItem<String>, label),
              )
              .enabled,
          false,
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'bundled Google setup goes directly to sign-in from Settings, Calendar and every Drive import',
    (tester) async {
      final root = createTestTempDirectorySync('google-bundled-ui-');
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
      final app = Application(domain, auth: domain.auth);
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Google sign-in setup required.'),
          findsNothing,
        );
        expect(find.text('Advanced OAuth configuration'), findsNothing);
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
    'an unconfigured build reports missing distribution support without a JSON import flow',
    (tester) async {
      final root = createTestTempDirectorySync('google-setup-ui-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/application.db');
      final domain = Domain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
      );
      final app = Application(domain);
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        final connect = find.widgetWithText(FilledButton, 'Connect Google');
        await tester.ensureVisible(connect);
        expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
        expect(
          find.text(
            'Google sign-in is unavailable in this build. Install a distribution with Google sign-in included.',
          ),
          findsOneWidget,
        );
        await tester.tap(connect);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Set up Google Drive and Calendar'), findsNothing);
        expect(find.text('Import client JSON'), findsNothing);
        expect(find.text('Import Desktop client configuration'), findsNothing);
        final dynamic state = tester.state(find.byType(Workspace));
        expect(
          state.error,
          contains('Google sign-in is unavailable in this build.'),
        );
        expect(app.googleAuth.connected, false);
        expect(app.googleAuth.signingIn, false);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    },
  );
}
