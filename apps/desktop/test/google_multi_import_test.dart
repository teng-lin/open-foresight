import 'dart:io';
import 'package:foresight_core/remote.dart' show ConnectedSources;
import 'package:foresight_test_support/test_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'desktop_connection_fixture.dart';
import 'google_picker_workflow_test.dart' show PendingDrive, file;
import 'google_setup_ui_test.dart' show BundledGoogleDomain;
import 'google_sign_in_workflow_test.dart' show PendingGoogleAuth;
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class BatchDrive extends PendingDrive {
  @override
  final Store store;
  bool rejectSecond;
  final imported = <String>[];
  final importedFolders = <String>[];
  BatchDrive(this.store, {required this.rejectSecond});

  @override
  int get lastCompletedRefreshMs => 0;

  @override
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) async => [
    file('First'),
    file('Second'),
    file('Third'),
    {
      ...file('Restricted'),
      'capabilities': {'canDownload': false},
    },
  ];

  @override
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  }) async {
    imported.add(fileId);
    if (rejectSecond && fileId == 'Second') {
      throw StateError('Second: This file cannot be downloaded by the user.');
    }
    final id = store.importText(
      fileId,
      'Document $fileId',
      'text/plain',
      'fixture',
    );
    store.state(id, 'indexed');
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    importedFolders.add(folderId);
    await importDriveFile(folderId);
  }
}

class BatchConnection extends TestDesktopConnection {
  final BatchDrive drive;
  BatchConnection(super.domain, this.drive);
  @override
  ConnectedSources get google => drive;
}

void main() {
  for (final (partial, folder) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      folder
          ? 'Drive folder retry names folders and retries only the failed ID'
          : partial
          ? 'multi-file Drive import keeps successes and names the rejected file'
          : 'multi-file Drive import imports every selected file',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final root = createTestTempDirectorySync('drive-multi-');
        final store = Store('${root.path}/application.db');
        final auth = PendingGoogleAuth(Directory('${root.path}/google'))
          ..signedIn = true;
        final helper = OfflineHelper(
          '${root.path}/socket',
          '${root.path}/helper',
        );
        final domain = BundledGoogleDomain(store, helper, auth);
        final drive = BatchDrive(store, rejectSecond: partial);
        try {
          await tester.pumpWidget(
            Foresight(
              BatchConnection(domain, drive),
              deviceLoader: () async => [],
            ),
          );
          await tester.pumpAndSettle();
          final dynamic state = tester.state(find.byType(Workspace));
          final importing =
              state.run(() async {
                    if (folder) {
                      await state.integrationFeature.importDriveSelection([
                        'First',
                        'Second',
                        'Third',
                      ], folder: true);
                    } else {
                      await state.integrationFeature.chooseDrive();
                    }
                  })
                  as Future<void>;
          if (!folder) {
            await pumpUntil(
              tester,
              () => find.text('Third').evaluate().isNotEmpty,
            );
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              find.text('Download restricted by Google Drive'),
              findsOneWidget,
            );
            final restricted = find.ancestor(
              of: find.text('Restricted'),
              matching: find.byType(ListTile),
            );
            expect(tester.widget<ListTile>(restricted).onTap, isNull);
            await tester.tap(find.text('Restricted'));
            for (final name in ['First', 'Second', 'Third']) {
              await tester.tap(find.text(name));
            }
            await tester.pump();
            await tester.tap(find.text('Import 3 files'));
          }
          await pumpUntil(tester, () => !state.busy);
          await tester.pumpAndSettle();
          await importing;
          expect(drive.imported, ['First', 'Second', 'Third']);
          expect(store.sources, hasLength(partial ? 2 : 3));
          if (partial) {
            expect(
              state.error,
              'Imported 2 of 3 ${folder ? 'folders' : 'files'} from Drive.\n'
              'Could not import:\nSecond: This file cannot be downloaded by the user.',
            );
            drive.rejectSecond = false;
            await tester.tap(
              find.text('Retry failed ${folder ? 'folders' : 'files'}'),
            );
            await pumpUntil(tester, () => !state.busy);
            await tester.pumpAndSettle();
            expect(drive.imported, ['First', 'Second', 'Third', 'Second']);
            expect(
              drive.importedFolders,
              folder ? ['First', 'Second', 'Third', 'Second'] : isEmpty,
            );
            expect(store.sources, hasLength(3));
            expect(state.error, isEmpty);
          } else {
            expect(state.error, isEmpty);
            expect(find.text('Imported 3 files from Drive.'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await auth.close();
          await helper.close();
          if (root.existsSync()) root.deleteSync(recursive: true);
        }
      },
    );
  }
}
