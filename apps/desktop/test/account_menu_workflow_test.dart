import 'package:foresight_core/src/application.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:open_foresight/google_sign_in_dialog.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'desktop_connection_fixture.dart';
import 'google_setup_ui_test.dart' show BundledGoogleDomain;
import 'meeting_setup_test.dart' show OfflineHelper;

class SignedInAccount extends GoogleAuth {
  SignedInAccount(super.directory);
  final saved = ['alex'];
  String selected = 'alex';
  int disconnects = 0;
  @override
  bool get connected => saved.isNotEmpty;
  @override
  String get account => connected ? selected : '';
  @override
  String get email => connected ? '$selected@example.test' : '';
  @override
  String get displayName =>
      connected ? (selected == 'alex' ? 'Alex Example' : 'Sam Example') : '';
  @override
  String get photoUrl => '';
  @override
  List<Map<String, Object?>> get accounts => [
    for (final id in saved)
      {
        'id': id,
        'email': '$id@example.test',
        'displayName': id == 'alex' ? 'Alex Example' : 'Sam Example',
        'photoUrl': '',
        'current': id == selected,
      },
  ];
  @override
  Future<void> refreshProfile() async {}
  @override
  Future<void> signOutAccount(String id) async {
    disconnects++;
    saved.remove(id);
    if (id == selected) selected = saved.isEmpty ? '' : saved.first;
  }

  @override
  Future<void> switchAccount(String id) async {
    expect(saved, contains(id));
    selected = id;
  }

  @override
  Future<Map<String, dynamic>> apiJson(Uri uri) async => {'items': []};
}

class PendingAdditionalAccount extends SignedInAccount {
  PendingAdditionalAccount(super.directory);
  final pending = Completer<void>();
  int invitations = 0;
  @override
  Future<void> addAccount(Future<void> Function(Uri) openBrowser) async {
    invitations++;
    await openBrowser(Uri.parse('https://accounts.example.test/authorize'));
    await pending.future;
  }

  @override
  void cancelSignIn() {
    if (!pending.isCompleted) pending.completeError(StateError('Cancelled'));
  }
}

void main() {
  testWidgets('cancelling Add another account retains the existing login', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('add-account-');
    final auth = PendingAdditionalAccount(root);
    GoogleSignInOutcome? outcome;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                outcome = await showDialog<GoogleSignInOutcome>(
                  context: context,
                  builder: (_) => GoogleSignInDialog(
                    auth: auth,
                    addAccount: true,
                    openBrowser: (_) async {},
                  ),
                );
              },
              child: const Text('Add another account'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add another account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(auth.invitations, 1);
      expect(auth.account, 'alex');
      await tester.tap(find.text('Cancel sign-in'));
      await tester.pumpAndSettle();
      expect(outcome?.cancelled, true);
      expect(outcome?.error, isNull);
      expect(auth.connected, true);
      expect(auth.account, 'alex');
      expect(auth.saved, ['alex']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.close();
      root.deleteSync(recursive: true);
    }
  });
  testWidgets(
    'switching accounts shares notes and individual sign-out keeps the other account',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('shared-accounts-');
      final auth = SignedInAccount(Directory('${root.path}/google'))
        ..saved.add('sam');
      final store = Store('${root.path}/application.db');
      store.saveNote(null, 'Shared knowledge', 'Visible for both accounts');
      final domain = BundledGoogleDomain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        auth,
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(domain, auth: auth)),
            deviceLoader: () async => [],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Google account: alex@example.test'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('sam@example.test'));
        await tester.pumpAndSettle();
        expect(auth.account, 'sam');
        expect(
          find.byTooltip('Google account: sam@example.test'),
          findsOneWidget,
        );
        expect(
          store.rows('SELECT title FROM notes').single['title'],
          'Shared knowledge',
        );
        await tester.tap(find.byTooltip('Google account: sam@example.test'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Sign out of alex@example.test'));
        await tester.pumpAndSettle();
        expect(auth.account, 'sam');
        expect(auth.saved, ['sam']);
        expect(
          find.byTooltip('Google account: sam@example.test'),
          findsOneWidget,
        );
        expect(
          store.rows('SELECT title FROM notes').single['title'],
          'Shared knowledge',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'sidebar reflects signed-in identity and signs out without deleting notes',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('account-menu-');
      final auth = SignedInAccount(Directory('${root.path}/google'));
      final store = Store('${root.path}/application.db');
      store.saveNote(null, 'Saved local note', 'Keep this after sign-out');
      final domain = BundledGoogleDomain(
        store,
        OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        auth,
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(domain, auth: auth)),
            deviceLoader: () async => [],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Google account: alex@example.test'));
        await tester.pumpAndSettle();
        expect(find.text('Alex Example'), findsOneWidget);
        expect(find.text('alex@example.test'), findsOneWidget);
        await tester.tap(find.byTooltip('Sign out of alex@example.test'));
        await tester.pumpAndSettle();
        expect(auth.disconnects, 1);
        expect(find.byTooltip('Sign in with Google'), findsOneWidget);
        expect(
          find.byTooltip('Google account: alex@example.test'),
          findsNothing,
        );
        expect(
          store.rows('SELECT title FROM notes').single['title'],
          'Saved local note',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    },
  );
}
