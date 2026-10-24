import 'desktop_fixture_owner.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'global shortcut failure is visible in the workspace',
    (tester) async => withDesktopFixtures(tester, () async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = createTestTempDirectorySync('shortcut-failure-ui-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final store = Store('${temp.path}/app.db');
      final domain = Domain(
        store,
        OfflineHelper('${temp.path}/helper.sock', temp.path),
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(domain)),
          deviceLoader: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      final workspace =
          tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      workspace.integrationFeature.reportShortcutFailure(
        StateError('Microphone unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Global shortcut failed:'), findsWidgets);
      expect(find.textContaining('Microphone unavailable'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      temp.deleteSync(recursive: true);
    }),
  );
}
