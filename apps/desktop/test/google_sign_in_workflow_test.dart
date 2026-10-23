import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'pump_until.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:open_foresight/features/integrations/google_sign_in_dialog.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/remote.dart' show RpcError, RpcErrorCode;
import 'google_setup_ui_test.dart' show BundledGoogleDomain;
import 'meeting_setup_test.dart' show OfflineHelper;

class PendingGoogleAuth extends GoogleAuth {
  PendingGoogleAuth(super.directory, {super.defaultClient});
  Completer<void>? pending;
  int invitations = 0;
  int calendarQueries = 0;
  bool signedIn = false;
  bool inviteBrowser = false;
  @override
  bool get connected => signedIn;
  @override
  bool get signingIn => pending != null;
  @override
  Future<Map<String, dynamic>> apiJson(Uri uri) async {
    expectSync(uri.path, contains('/calendars/'));
    calendarQueries++;
    return {'items': []};
  }

  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    invitations++;
    final operation = Completer<void>();
    pending = operation;
    try {
      if (inviteBrowser)
        await openBrowser(Uri.parse('https://accounts.example.test/authorize'));
      await operation.future;
    } finally {
      pending = null;
    }
  }

  @override
  void cancelSignIn() {
    if (pending?.isCompleted == false) {
      pending!.completeError(StateError('Google sign-in cancelled'));
    }
  }
}

void main() {
  for (final rpc in [false, true]) {
    testWidgets(
      'Granola return paste hides codes, permits retry and completes the pending login (${rpc ? 'RPC' : 'local'})',
      (tester) async {
        final root = createTestTempDirectorySync('granola-return-ui-');
        final auth = PendingGoogleAuth(Directory('${root.path}/google'))
          ..inviteBrowser = true;
        addTearDown(auth.close);
        var submissions = 0;
        GoogleSignInOutcome? outcome;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    outcome = await showDialog<GoogleSignInOutcome>(
                      context: context,
                      builder: (_) => GoogleSignInDialog(
                        auth: auth,
                        openBrowser: (_) async {},
                        calendarThroughGranola: true,
                        completeSignIn: (url) async {
                          submissions++;
                          expect(
                            url,
                            'granola://login-complete?code=private-fixture',
                          );
                          if (submissions == 1)
                            throw rpc
                                ? RpcError(
                                    RpcErrorCode.invalidArgument,
                                    GranolaReturnFailure.wrongAttempt.message,
                                  )
                                : StateError(
                                    GranolaReturnFailure.wrongAttempt.message,
                                  );
                          if (submissions == 2)
                            throw rpc
                                ? RpcError(
                                    RpcErrorCode.internal,
                                    'Do not echo private-fixture',
                                  )
                                : StateError('Do not echo private-fixture');
                          auth.signedIn = true;
                          auth.pending!.complete();
                        },
                      ),
                    );
                  },
                  child: const Text('Connect fixture'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Connect fixture'));
        await tester.pump();
        await tester.pump();
        final field = find.byType(TextField);
        expect(tester.widget<TextField>(field).obscureText, true);
        await tester.enterText(
          field,
          'granola://login-complete?code=private-fixture',
        );
        await tester.tap(find.text('Complete sign-in with return URL'));
        await tester.pump();
        expect(
          find.text(GranolaReturnFailure.wrongAttempt.message),
          findsOneWidget,
        );
        await tester.tap(find.text('Complete sign-in with return URL'));
        await tester.pump();
        expect(
          find.textContaining('The return link was not accepted.'),
          findsOneWidget,
        );
        expect(find.text('Do not echo private-fixture'), findsNothing);
        expect(auth.signingIn, true);
        await tester.tap(find.text('Complete sign-in with return URL'));
        await tester.pumpAndSettle();
        expect(submissions, 3);
        expect(outcome, isNotNull);
        expect(outcome!.error, null);
        expect(find.byType(GoogleSignInDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'Google sign-in can be cancelled and retried from every entry point',
    (tester) async {
      var activations = 0;
      const windowChannel = MethodChannel('foresight/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async {
          if (call.method == 'activate') activations++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('google-sign-in-ux-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final client = File('${root.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': 'fixture.apps.googleusercontent.com',
              'client_secret': 'fixture',
            },
          }),
        );
      final auth = PendingGoogleAuth(
        Directory('${root.path}/google'),
        defaultClient: client,
      );
      final store = Store('${root.path}/app.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final Domain domain = BundledGoogleDomain(store, helper, auth);
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(domain, auth: auth)),
            deviceLoader: () async => [],
          ),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        Future<void> cancel({bool keyboard = false}) async {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Cancel sign-in'), findsOneWidget);
          expect(auth.signingIn, true);
          if (keyboard) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.tap(find.text('Cancel sign-in'));
          }
          await tester.pumpAndSettle();
          expect(auth.connected, false);
          expect(auth.signingIn, false);
          expect(find.byType(AlertDialog), findsNothing);
          expect(state.error, isEmpty);
          expect(
            state.integrationFeature.googleState,
            'Google sign-in cancelled.',
          );
          expect(state.busy, false);
          expect(store.sources, isEmpty);
        }

        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        final connect = find.widgetWithText(FilledButton, 'Connect Google');
        await tester.ensureVisible(connect);
        await tester.tap(connect);
        await cancel(keyboard: true);
        await tester.tap(find.text('Meetings').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect Calendar'));
        await cancel();
        await tester.tap(find.text('Sources').first);
        await tester.pumpAndSettle();
        for (final title in [
          'Add files from Drive',
          'Add an entire Drive folder',
          'Import last 1 year from Drive',
        ]) {
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(PopupMenuItem<String>, title));
          await cancel();
        }
        expect(auth.invitations, 5);
        // Calendar sync stores meeting metadata and needs no embedding model.
        final connecting =
            state.run(state.integrationFeature.connectGoogle) as Future<void>;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        auth.signedIn = true;
        auth.pending!.complete();
        await pumpUntil(tester, () => !state.busy);
        await connecting;
        expect(auth.connected, true);
        expect(state.error, isEmpty);
        expect(activations, 1);
        expect(
          state.integrationFeature.googleState,
          startsWith('Connected as '),
        );
        expect(auth.calendarQueries, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await auth.close();
        await helper.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('browser failure closes sign-in with its actual error', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('google-browser-error-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final auth = PendingGoogleAuth(root)..inviteBrowser = true;
    GoogleSignInOutcome? outcome;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  outcome = await showDialog<GoogleSignInOutcome>(
                    context: context,
                    builder: (_) => GoogleSignInDialog(
                      auth: auth,
                      openBrowser: (_) async =>
                          throw StateError('Browser unavailable'),
                    ),
                  ),
              child: const Text('Connect'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(outcome!.cancelled, false);
      expect(outcome!.error.toString(), contains('Browser unavailable'));
      expect(find.byType(GoogleSignInDialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.close();
      root.deleteSync(recursive: true);
    }
  });
  testWidgets(
    'successful browser consent closes the progress dialog in a short window',
    (tester) async {
      tester.view.physicalSize = const Size(640, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('google-consent-success-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final auth = PendingGoogleAuth(root)..inviteBrowser = true;
      GoogleSignInOutcome? outcome;
      Uri? invitation;
      var returnedToApp = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    outcome = await showDialog<GoogleSignInOutcome>(
                      context: context,
                      builder: (_) => GoogleSignInDialog(
                        auth: auth,
                        openBrowser: (uri) async => invitation = uri,
                        returnToApp: () async {
                          returnedToApp = true;
                        },
                      ),
                    ),
                child: const Text('Connect'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Connect'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(invitation!.host, 'accounts.example.test');
        expect(
          find.text(
            'Complete Google sign-in in your browser. If Open Foresight does not reopen, return to the app manually.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        auth.signedIn = true;
        auth.pending!.complete();
        await tester.pumpAndSettle();
        expect(outcome!.cancelled, false);
        expect(outcome!.error, isNull);
        expect(auth.connected, true);
        expect(returnedToApp, true);
        expect(find.byType(GoogleSignInDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await auth.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
