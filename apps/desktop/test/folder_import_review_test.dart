import '../test_support/core_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';

import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

void main() {
  testWidgets('folder picker completion after disposal opens no review', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final picked = Completer<String?>();
    var requested = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDirectoryPath');
      requested = true;
      return picked.future;
    });
    final root = createTestTempDirectorySync('folder-disposed-');
    final helper = OfflineHelper('${root.path}/socket', '${root.path}/helper');
    try {
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(
            Application(Domain(Store('${root.path}/app.db'), helper)),
          ),
          deviceLoader: () async => [],
        ),
      );
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      final work = state.sourceFeature.importFolder();
      await tester.pump();
      expect(requested, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      picked.complete(root.path);
      await tester.pump();
      await work;
      expect(find.text('Review folder import'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await helper.close();
      root.deleteSync(recursive: true);
    }
  });
  for (final cancel in [true, false]) {
    testWidgets('folder review imports only checked files, cancel=$cancel', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('folder-review-');
      final files = Directory('${root.path}/files')..createSync();
      for (final name in ['Juniper.txt', 'Cedar.md']) {
        File(
          '${files.path}/$name',
        ).writeAsStringSync('Synthetic fixture for $name');
      }
      File('${files.path}/unsupported.bin').writeAsStringSync('Not imported');
      final store = Store('${root.path}/application.db');
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(Application(Domain(store, helper))),
            deviceLoader: () async => [],
          ),
        );
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        final work = state.run(() async {
          await state.sourceFeature.reviewFolderImport(files.path);
        });
        await pumpUntil(
          tester,
          () => find.text('Import selected (2)').evaluate().isNotEmpty,
        );
        expect(find.text('Review folder import'), findsOneWidget);
        expect(store.sources, isEmpty);
        expect(find.text('unsupported.bin'), findsNothing);
        if (cancel) {
          await tester.tap(find.text('Cancel').last);
        } else {
          await tester.tap(find.text('Cedar.md'));
          await tester.pump();
          await tester.tap(find.text('Import selected (1)'));
        }
        await pumpUntil(tester, () => !state.busy);
        await tester.pumpAndSettle();
        await work;
        expect(store.sources, hasLength(cancel ? 0 : 1));
        if (!cancel) expect(store.sources.single['title'], 'Juniper.txt');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        root.deleteSync(recursive: true);
      }
    });
  }
}
