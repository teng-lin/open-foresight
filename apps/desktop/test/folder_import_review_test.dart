import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/store.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

void main() {
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
            TestDesktopConnection(Domain(store, helper)),
            deviceLoader: () async => [],
          ),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        final work =
            state.run(() async {
                  await state.sourceFeature.reviewFolderImport(files.path);
                })
                as Future<void>;
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
