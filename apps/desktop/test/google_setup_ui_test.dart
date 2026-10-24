import 'package:foresight_core/desktop.dart' show GoogleAccountPresentation;
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'pump_until.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

class BundledGoogleAuth extends GoogleAuth {
  BundledGoogleAuth(super.directory, {super.defaultClient});
  int invitations = 0;
  final invitationProviders = <bool>[];
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    invitations++;
    invitationProviders.add(viaGranola);
    throw StateError('Browser sign-in cancelled');
  }
}

class SwitchingGoogleAuth extends BundledGoogleAuth {
  SwitchingGoogleAuth(super.directory, {super.defaultClient});
  final saved = ['alex', 'sam'];
  final signedOut = <String>[];
  bool failSignOut = false;

  @override
  bool get configured => true;
  @override
  bool get connected => saved.isNotEmpty;
  @override
  String get account => saved.isEmpty ? '' : saved.first;
  @override
  String get email => connected ? '$account@example.test' : '';
  @override
  List<GoogleAccountPresentation> get accounts => [
    for (final id in saved)
      GoogleAccountPresentation(
        id: id,
        email: '$id@example.test',
        current: id == account,
      ),
  ];

  @override
  Future<void> refreshProfile() async {}

  @override
  Future<Map<String, dynamic>> apiJson(Uri uri) async => {'items': []};

  @override
  Future<void> signOutAccount(String id) async {
    if (failSignOut) throw StateError('Could not sign out');
    signedOut.add(id);
    saved.remove(id);
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
  testWidgets('failed Granola sign-in can recover through the Google button', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('granola-recovery-ui-');
    final client = File('${root.path}/bundled-client.json')
      ..writeAsStringSync(
        jsonEncode({
          'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
        }),
      );
    final auth = BundledGoogleAuth(
      Directory('${root.path}/google'),
      defaultClient: client,
    );
    final domain = BundledGoogleDomain(
      Store('${root.path}/app.db'),
      OfflineHelper('${root.path}/socket', '${root.path}/helper'),
      auth,
    );
    await tester.pumpWidget(
      Foresight(
        ReadonlyGoogleStatusConnection(Application(domain, auth: auth)),
        deviceLoader: () async => [],
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Google Drive and Calendar'), findsOneWidget);
    expect(find.text('Calendar through Granola'), findsOneWidget);
    final granola = find.widgetWithText(
      OutlinedButton,
      'Connect calendar through Granola',
    );
    await tester.ensureVisible(granola);
    await tester.runAsync(() => tester.tap(granola));
    await pumpUntil(tester, () => auth.invitations == 1);
    await tester.pumpAndSettle();
    expect(auth.viaGranola, true);
    final google = find.widgetWithText(FilledButton, 'Connect Google');
    await tester.ensureVisible(google);
    await tester.runAsync(() => tester.tap(google));
    await pumpUntil(tester, () => auth.invitations == 2);
    await tester.pumpAndSettle();
    expect(auth.invitationProviders, [true, false]);
    expect(auth.viaGranola, false);
    expect(auth.client!.id, 'fixture.apps.googleusercontent.com');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'connected Granola users can cancel or confirm switching to Google',
    (tester) async {
      final root = createTestTempDirectorySync('google-switch-ui-');
      final client = File('${root.path}/bundled.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
          }),
        );
      final auth = SwitchingGoogleAuth(
        Directory('${root.path}/google'),
        defaultClient: client,
      );
      auth.saved.clear();
      await tester.runAsync(auth.configureGranola);
      auth.saved.addAll(['alex', 'sam']);
      final domain = BundledGoogleDomain(
        Store('${root.path}/app.db'),
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        auth,
      );
      await tester.pumpWidget(
        Foresight(
          ReadonlyGoogleStatusConnection(Application(domain, auth: auth)),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final google = find.widgetWithText(FilledButton, 'Connect Google');
      expect(find.text('Disconnect calendar'), findsOneWidget);
      expect(find.text('Connect calendar through Granola'), findsNothing);
      await tester.ensureVisible(google);
      await tester.runAsync(() => tester.tap(google));
      await pumpUntil(
        tester,
        () => find.text('Switch connection to Google?').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Switch connection to Google?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpUntil(
        tester,
        () =>
            !(tester.state(find.byType(Workspace)) as WorkspaceTestAccess).busy,
      );
      await tester.pumpAndSettle();
      expect(auth.saved, ['alex', 'sam']);
      expect(auth.viaGranola, true);
      await tester.runAsync(() => tester.tap(google));
      await pumpUntil(
        tester,
        () => find.text('Switch connection to Google?').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => tester.tap(find.text('Sign out and switch')));
      await pumpUntil(tester, () => auth.invitations == 1);
      await tester.pumpAndSettle();
      expect(auth.signedOut, ['alex', 'sam']);
      expect(auth.invitationProviders, [false]);
      expect(auth.viaGranola, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final invalidClient in [null, '{private-client-material']) {
    testWidgets(
      'missing or invalid direct Google setup preserves connected Granola accounts ($invalidClient)',
      (tester) async {
        final root = createTestTempDirectorySync('granola-preflight-ui-');
        final auth = SwitchingGoogleAuth(Directory('${root.path}/google'));
        auth.saved.clear();
        await tester.runAsync(auth.configureGranola);
        auth.saved.addAll(['alex', 'sam']);
        if (invalidClient != null) {
          File(
            '${auth.directory.path}/google-client.json',
          ).writeAsStringSync(invalidClient);
        }
        final configuration = File('${auth.directory.path}/client.json');
        final before = configuration.readAsBytesSync();
        final domain = BundledGoogleDomain(
          Store('${root.path}/app.db'),
          OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          auth,
        );
        await tester.pumpWidget(
          Foresight(
            ReadonlyGoogleStatusConnection(Application(domain, auth: auth)),
            deviceLoader: () async => [],
          ),
        );
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        final google = find.widgetWithText(FilledButton, 'Connect Google');
        await tester.ensureVisible(google);
        await tester.runAsync(() => tester.tap(google));
        final workspace =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        await pumpUntil(tester, () => !workspace.busy);
        await tester.pumpAndSettle();
        expect(auth.saved, ['alex', 'sam']);
        expect(auth.signedOut, isEmpty);
        expect(auth.connected, true);
        expect(auth.viaGranola, true);
        expect(auth.invitations, 0);
        expect(configuration.readAsBytesSync(), before);
        expect(find.text('Switch connection to Google?'), findsNothing);
        expect(
          workspace.error,
          contains(
            invalidClient == null
                ? 'Google sign-in is unavailable in this build.'
                : 'Google client setup could not be loaded.',
          ),
        );
        expect(workspace.error, isNot(contains('private-client-material')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a stale switch confirmation cannot sign out a replacement session',
    (tester) async {
      final root = createTestTempDirectorySync('granola-stale-ui-');
      final auth = SwitchingGoogleAuth(Directory('${root.path}/google'));
      final domain = BundledGoogleDomain(
        Store('${root.path}/app.db'),
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        auth,
      );
      final connection = ReadonlyGoogleStatusConnection(
        Application(domain, auth: auth),
      );
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Switch calendar connection to Granola?'),
        findsOneWidget,
      );
      connection.replaceClientSessionForTesting();
      await tester.runAsync(() => tester.tap(find.text('Sign out and switch')));
      final workspace =
          tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      await pumpUntil(tester, () => !workspace.busy);
      await tester.pumpAndSettle();
      expect(auth.saved, ['alex', 'sam']);
      expect(auth.signedOut, isEmpty);
      expect(auth.viaGranola, false);
      expect(auth.invitations, 0);
      expect(connection.configuredStatusBeforeReply, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final failSignOut in [false, true]) {
    testWidgets(
      'connected Google users can cancel or confirm a Granola switch (sign-out failure: $failSignOut)',
      (tester) async {
        final root = createTestTempDirectorySync('granola-switch-ui-');
        final auth = SwitchingGoogleAuth(Directory('${root.path}/google'))
          ..failSignOut = failSignOut;
        final store = Store('${root.path}/application.db');
        final helper = OfflineHelper(
          '${root.path}/socket',
          '${root.path}/helper',
        );
        final domain = BundledGoogleDomain(store, helper, auth);
        final connection = ReadonlyGoogleStatusConnection(
          Application(domain, auth: auth),
        );
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
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text('Switch calendar connection to Granola?'),
          findsOneWidget,
        );
        expect(find.textContaining('stops Drive sync'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await pumpUntil(
          tester,
          () => !(tester.state(find.byType(Workspace)) as WorkspaceTestAccess)
              .busy,
        );
        await tester.pumpAndSettle();
        expect(auth.saved, ['alex', 'sam']);
        expect(auth.signedOut, isEmpty);
        expect(auth.viaGranola, false);
        expect(auth.invitations, 0);

        await tester.runAsync(() => tester.tap(connect));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
          () => tester.tap(find.text('Sign out and switch')),
        );
        final workspace =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        await pumpUntil(tester, () => !workspace.busy);
        await tester.pumpAndSettle();
        if (failSignOut) {
          expect(auth.saved, ['alex', 'sam']);
          expect(auth.viaGranola, false);
          expect(auth.invitations, 0);
          final state =
              tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
          expect(state.error, contains('Could not sign out'));
        } else {
          await pumpUntil(tester, () => auth.invitations == 1);
          await tester.pumpAndSettle();
          expect(auth.signedOut, ['alex', 'sam']);
          expect(auth.saved, isEmpty);
          expect(auth.viaGranola, true);
          expect(connection.configuredStatusBeforeReply, true);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
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
