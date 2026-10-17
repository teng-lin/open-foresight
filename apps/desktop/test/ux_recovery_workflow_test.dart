import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class RecoveryDomain extends Domain {
  RecoveryDomain(super.store, super.helper);
  final failures = <String>{};
  final calls = <String, int>{};
  Completer<void>? gate;
  String? gatedMethod;
  void count(String method) =>
      calls.update(method, (n) => n + 1, ifAbsent: () => 1);
  @override
  Future<Object?> command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    count(method);
    if (method == gatedMethod) await gate!.future;
    if (failures.contains(method)) throw StateError('Write unavailable');
    if (method == 'sources.import_file') {
      final path = args['path'] as String;
      count(path);
      if (failures.contains(path)) throw StateError('File unavailable');
      return {
        'id': store.importText(path, 'Imported text', 'text/plain', path),
      };
    }
    if (method == 'sources.import_url') {
      return {
        'id': store.importText(
          args['url'] as String,
          'Page',
          'text/plain',
          'fixture',
        ),
      };
    }
    return super.command(method, args);
  }

  @override
  Future<void> index(String id) async => store.state(id, 'indexed');
  @override
  Future<void> delete(String id) async {
    count('delete');
    if (failures.contains('delete')) throw StateError('Delete unavailable');
    store.tombstone(id);
  }
}

Future<void> withWorkspace(
  WidgetTester tester,
  Future<void> Function(Store, RecoveryDomain, dynamic) body,
) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final root = Directory.systemTemp.createTempSync('ux-recovery-');
  final store = Store('${root.path}/app.db');
  final helper = OfflineHelper('${root.path}/socket', '${root.path}/helper');
  final domain = RecoveryDomain(store, helper);
  try {
    await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
    await tester.pumpAndSettle();
    await body(store, domain, tester.state(find.byType(Workspace)));
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await helper.close();
    root.deleteSync(recursive: true);
  }
}

Finder dialogInput() => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

void main() {
  testWidgets(
    'source editor preserves a failed write and retries the same draft',
    (tester) async {
      await withWorkspace(tester, (store, domain, state) async {
        store.importText('Source', 'Original', 'text/plain', 'fixture');
        tester.view.physicalSize = const Size(640, 400);
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        state.editSource(store.sources.single);
        await tester.pumpAndSettle();
        await tester.enterText(dialogInput(), 'Retained source draft');
        domain.failures.add('sources.import');
        domain.pauseSources();
        await tester.tap(find.text('Save and index'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Keep paused'));
        await tester.pumpAndSettle();
        expect(domain.calls['sources.import'], isNull);
        expect(domain.sourcesPaused, true);
        expect(
          tester.widget<TextField>(dialogInput()).controller!.text,
          'Retained source draft',
        );
        await tester.tap(find.text('Save and index'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Resume and continue'));
        await tester.pumpAndSettle();
        expect(domain.sourcesPaused, false);
        expect(find.text('Write unavailable'), findsOneWidget);
        expect(
          tester.widget<TextField>(dialogInput()).controller!.text,
          'Retained source draft',
        );
        expect(store.sources.single['content'], 'Original');
        domain.failures.clear();
        await tester.tap(find.text('Save and index'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(store.sources.single['content'], 'Retained source draft');
      });
    },
  );

  testWidgets(
    'artifact save blocks duplicates, retains failed text and supports retry',
    (tester) async {
      await withWorkspace(tester, (store, domain, state) async {
        final meeting = store.meeting('Review');
        store.artifact(meeting, 'summary', 'Original generation', 'fixture');
        state.editArtifact(store.rows('SELECT * FROM artifacts').single);
        await tester.pumpAndSettle();
        await tester.enterText(dialogInput(), 'Retained artifact draft');
        domain.gatedMethod = 'artifacts.edit';
        domain.gate = Completer<void>();
        domain.failures.add('artifacts.edit');
        await tester.tap(find.text('Save edit'));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Save edit'))
              .onPressed,
          isNull,
        );
        expect(tester.widget<TextField>(dialogInput()).enabled, false);
        await tester.tap(find.text('Save edit'));
        expect(domain.calls['artifacts.edit'], 1);
        domain.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Write unavailable'), findsOneWidget);
        expect(
          tester.widget<TextField>(dialogInput()).controller!.text,
          'Retained artifact draft',
        );
        expect(store.rows('SELECT generated,edited FROM artifacts').single, {
          'generated': 'Original generation',
          'edited': null,
        });
        domain.failures.clear();
        domain.gatedMethod = null;
        await tester.tap(find.text('Save edit'));
        await tester.pumpAndSettle();
        expect(store.rows('SELECT generated,edited FROM artifacts').single, {
          'generated': 'Original generation',
          'edited': 'Retained artifact draft',
        });
        expect(find.byType(AlertDialog), findsNothing);
      });
    },
  );

  testWidgets('URL validates and Enter retries without losing its address', (
    tester,
  ) async {
    await withWorkspace(tester, (store, domain, state) async {
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(PopupMenuItem<String>, 'Add from URL'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(dialogInput(), 'file:///private/file');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Enter a valid http or https URL.'), findsOneWidget);
      expect(domain.calls['sources.import_url'], isNull);
      await tester.enterText(dialogInput(), 'https://example.test/page');
      domain.failures.add('sources.import_url');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Write unavailable'), findsOneWidget);
      expect(
        tester.widget<TextField>(dialogInput()).controller!.text,
        'https://example.test/page',
      );
      domain.failures.clear();
      await tester.showKeyboard(dialogInput());
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(store.sources.single['title'], 'https://example.test/page');
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets(
    'blank label has actionable validation and cancellation writes nothing',
    (tester) async {
      await withWorkspace(tester, (store, domain, state) async {
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add label'));
        await tester.pumpAndSettle();
        await tester.enterText(dialogInput(), '   ');
        await tester.tap(find.text('Create & Auto-Assign'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a label name.'), findsOneWidget);
        expect(store.documentLabels, isEmpty);
        expect(store.rows('SELECT * FROM document_clusters'), isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });
    },
  );

  testWidgets('batch retries only failed files and reports eventual success', (
    tester,
  ) async {
    await withWorkspace(tester, (store, domain, state) async {
      domain.failures.add('/fixture/failed.txt');
      final importing = state.importFiles([
        '/fixture/good.txt',
        '/fixture/failed.txt',
      ]);
      await tester.pumpAndSettle();
      expect(find.text('1 of 2 imports completed.'), findsOneWidget);
      expect(
        find.textContaining('failed.txt: File unavailable'),
        findsOneWidget,
      );
      domain.failures.clear();
      domain.gatedMethod = 'sources.import_file';
      domain.gate = Completer<void>();
      await tester.tap(find.text('Retry failed imports'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Retry failed imports'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Retry failed imports'));
      domain.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('2 of 2 imports completed.'), findsOneWidget);
      expect(domain.calls['/fixture/good.txt'], 1);
      expect(domain.calls['/fixture/failed.txt'], 2);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await importing;
      expect(store.sources, hasLength(2));
    });
  });

  testWidgets(
    'list and grid deletions require confirmation; failed delete can retry',
    (tester) async {
      await withWorkspace(tester, (store, domain, state) async {
        store.importText(
          'Keep until confirmed',
          'Text',
          'text/plain',
          'fixture',
        );
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Delete source'));
        await tester.pumpAndSettle();
        expect(store.sources, hasLength(1));
        expect(domain.calls['delete'], isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(store.sources, hasLength(1));
        await tester.tap(find.byTooltip('Grid view'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Delete source'));
        await tester.pumpAndSettle();
        domain.failures.add('delete');
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete unavailable'), findsOneWidget);
        domain.failures.clear();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(store.sources, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
      });
    },
  );
}
