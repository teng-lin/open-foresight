import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class OfflineRevokeAuth extends GoogleAuth {
  OfflineRevokeAuth(super.directory);
  bool signedIn = true;
  @override
  bool get connected => signedIn;
  @override
  Future<void> disconnect() async => throw const SocketException('offline');
  @override
  Future<void> forget() async {
    signedIn = false;
  }
}

void main() {
  testWidgets('acknowledged clear resets editors after status disconnects', (
    tester,
  ) async {
    final fixture = RemoteFixture();
    await tester.runAsync(fixture.start);
    addTearDown(() => tester.runAsync(fixture.close));
    fixture.handler = (socket, request) {
      if (request['method'] == 'workspace.clear') {
        fixture.reply(socket, request, {'cleared': true});
        fixture.rejectStatus = true;
      } else {
        fixture.reply(socket, request, null);
      }
    };
    await tester.pumpWidget(
      Foresight(fixture.remote, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(Workspace));
    state.meetingFeature.noteTitle.text = 'Local title';
    state.meetingFeature.noteBody.text = 'Local body';
    state.meetingFeature.meetingNotesController.text = 'Local meeting notes';
    state.sourceFeature.sourceSearchController.text = 'Local search';
    state.chatFeature.answer = 'Local answer';
    final clear = state.settingsFeature.clearWorkspace() as Future<void>;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete workspace'));
    await tester.pump();
    await tester.runAsync(() async => clear);
    await tester.pumpAndSettle();
    expect(state.meetingFeature.noteTitle.text, isEmpty);
    expect(state.meetingFeature.noteBody.text, isEmpty);
    expect(state.meetingFeature.meetingNotesController.text, isEmpty);
    expect(state.sourceFeature.sourceSearchController.text, isEmpty);
    expect(state.chatFeature.answer, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      fixture.remote.close();
      await fixture.remote.closed;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('offline clear reaches local service and erases sources', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('clear-offline-ui-');
    final store = Store('${root.path}/application.db');
    store.importText('Secret', 'private content', 'text/plain', 'fixture');
    final helper = OfflineHelper('${root.path}/sock', '${root.path}/helper');
    final domain = Domain(store, helper);
    final auth = OfflineRevokeAuth(Directory('${root.path}/google'));
    final app = Application(domain, auth: auth);
    await tester.pumpWidget(
      Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(Workspace));
    final clear = state.settingsFeature.clearWorkspace() as Future<void>;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete workspace'));
    await tester.pumpAndSettle();
    await clear;
    expect(store.sources, isEmpty);
    expect(auth.connected, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
}
