import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/application.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/google_auth.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
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
  testWidgets('offline clear reaches local service and erases sources', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('clear-offline-ui-');
    final store = Store('${root.path}/application.db');
    store.importText('Secret', 'private content', 'text/plain', 'fixture');
    final helper = OfflineHelper('${root.path}/sock', '${root.path}/helper');
    final domain = Domain(store, helper);
    final auth = OfflineRevokeAuth(Directory('${root.path}/google'));
    Application(domain, auth: auth);
    await tester.pumpWidget(
      Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
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
