import 'package:open_foresight/shell/workspace_tab.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'source edits persist a revision, retain identity, index and survive service rejection',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.importText(
        'Editable source',
        'original',
        'text/plain',
        'fixture',
      );
      final dynamic source = f.shell.sourceFeature;
      final opening =
          source.source(f.store.sourceSummaries.single) as Future<void>;
      await tester.pumpAndSettle();
      expect(find.text('original'), findsOneWidget);
      await tester.tap(find.text('Edit source'));
      await tester.pumpAndSettle();
      await opening;
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'edited content',
      );
      f.connection.failures[Operation.sourcesImport] = StateError(
        'service unavailable',
      );
      await tester.tap(find.text('Save and index'));
      await tester.pumpAndSettle();
      expect(find.textContaining('service unavailable'), findsOneWidget);
      expect(f.store.sourceById(id).single['content'], 'original');
      expect(f.connection.indexed, isEmpty);
      f.connection.failures.clear();
      await tester.tap(find.text('Save and index'));
      await tester.pumpAndSettle();
      expect(f.store.sourceById(id).single['content'], 'edited content');
      expect(f.store.sourceById(id).single['revision'], 2);
      expect(f.connection.indexed, [id]);
      expect(find.byType(AlertDialog), findsNothing);
      await source.source({'id': 'already-deleted'});
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  testWidgets(
    'file and reviewed folder pickers import selections while cancellation is a no-op',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final dynamic source = f.shell.sourceFeature;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final messenger = tester.binding.defaultBinaryMessenger;
      String? selected;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'openFile'
            ? (selected == null ? null : [selected])
            : selected,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final op in [
        Operation.sourcesImportFile,
        Operation.sourcesImportDirectory,
        Operation.sourcesRefresh,
        Operation.sourcesImportUrl,
      ]) {
        f.connection.replies[op] = {};
      }
      await source.import();
      await source.importFolder();
      expect(
        f.connection.calls.where(
          (c) =>
              c.$1 == Operation.sourcesImportFile ||
              c.$1 == Operation.sourcesImportDirectory,
        ),
        isEmpty,
      );
      selected = '${f.root.path}/notes.txt';
      File(selected).writeAsStringSync('Synthetic source import fixture.');
      await source.import();
      expect(f.connection.calls.last.$2, {'path': selected});
      selected = f.root.path;
      final callsBeforeFolder = f.connection.calls.length;
      final folder = source.importFolder() as Future<void>;
      await pumpUntil(
        tester,
        () => find.text('Import selected (1)').evaluate().isNotEmpty,
      );
      expect(find.text('Review folder import'), findsOneWidget);
      expect(f.connection.calls, hasLength(callsBeforeFolder));
      await tester.tap(find.text('Import selected (1)'));
      await tester.pumpAndSettle();
      await folder;
      expect(f.connection.calls, hasLength(callsBeforeFolder + 1));
      expect(f.connection.calls.last.$1, Operation.sourcesImportFile);
      expect(f.connection.calls.last.$2, {
        'path': File('${f.root.path}/notes.txt').resolveSymbolicLinksSync(),
      });
      expect(
        f.connection.calls.where(
          (c) => c.$1 == Operation.sourcesImportDirectory,
        ),
        isEmpty,
      );
      await source.refreshSources();
      expect(f.connection.calls.last.$1, Operation.sourcesRefresh);
      await source.importSourceUrl('https://example.test/document');
      expect(f.connection.calls.last.$2, {
        'url': 'https://example.test/document',
      });
      final dialog = source.importUrl() as Future<void>;
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'http://127.0.0.1/fixture',
      );
      final checkbox = find.byType(CheckboxListTile);
      if (checkbox.evaluate().isNotEmpty) {
        await tester.tap(checkbox);
        await tester.pump();
      }
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await dialog;
      expect(f.connection.calls.last.$1, Operation.sourcesImportUrl);
      expect(f.connection.calls.last.$2['url'], 'http://127.0.0.1/fixture');
    },
  );
  testWidgets('editable notes create, reopen and update through the service', (
    tester,
  ) async {
    final f = await ControllerFixture.mount(tester);
    f.shell.update(() => f.shell.navigate(WorkspaceTab.notes));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Saved note');
    await tester.enterText(fields.at(1), 'First body');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    final id = f.shell.meetingFeature.noteId as int;
    expect(f.store.noteBody(id), 'First body');
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved note'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'First body',
    );
    await tester.enterText(fields.at(1), 'Revised body');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(f.store.noteBody(id), 'Revised body');
  });
}
