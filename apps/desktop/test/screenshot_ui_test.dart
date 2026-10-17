import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated/helper_control.pb.dart' as control;
import 'meeting_setup_test.dart' show OfflineHelper;
import '../../../packages/foresight_core/test/fixtures/google_connections.dart'
    show AdapterDomain;

void main() {
  testWidgets('source pause can resume a pending import while the UI is busy', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('foresight-pause-ui-');
    final folder = Directory('${tmp.path}/files')..createSync();
    File('${folder.path}/fixture.txt').writeAsStringSync('A retained import.');
    final store = Store('${tmp.path}/app.db');
    final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
    final domain = AdapterDomain(store, helper);
    await tester.pumpWidget(Foresight(TestDesktopConnection(domain), deviceLoader: () async => []));
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause source imports and indexing'));
    await tester.pumpAndSettle();
    expect(domain.sourcesPaused, true);
    expect(find.text('Paused'), findsOneWidget);
    final dynamic state = tester.state(find.byType(Workspace));
    await tester.runAsync(() async {
      final importing = state.run(() async {
        await state.importFolderPath(folder.path);
      });
      expect(state.busy, true);
      expect(store.sources, isEmpty);
      await tester.tap(find.byTooltip('Resume source imports and indexing'));
      await importing;
    });
    await tester.pumpAndSettle();
    expect(domain.sourcesPaused, false);
    expect(state.busy, false);
    expect(store.sources.single['content'], 'A retained import.');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tmp.deleteSync(recursive: true);
  });

  testWidgets(
    'source search, label editing, graph navigation and settings persist',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('foresight-screens-');
      final path = '${tmp.path}/app.db';
      final store = Store(path);
      final apollo = store.importText(
        'Apollo',
        'Apollo launches in May.',
        'text/plain',
        'fixture',
      );
      final borealis = store.importText(
        'Borealis',
        'Borealis review.',
        'text/plain',
        'fixture',
      );
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(find.text('Knowledge Sources'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Apollo');
      await tester.pumpAndSettle();
      expect(find.text('Borealis'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Edit labels'));
      await tester.tap(find.byTooltip('Edit labels'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Launch, Team');
      await tester.tap(find.text('Save labels'));
      await tester.pumpAndSettle();
      expect(store.sources.first['labels'], '["Launch","Team"]');
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Launch').first);
      await tester.tap(find.text('Launch').first);
      await tester.pumpAndSettle();
      expect(find.text('Borealis'), findsNothing);
      await tester.ensureVisible(find.text('Graph view'));
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      final dynamic graphState = tester.state(find.byType(Workspace));
      final fittedScale =
          graphState.graphTransform.value.getMaxScaleOnAxis() as double;
      for (final id in [apollo, borealis]) {
        final panel = tester.getRect(
          find.byKey(const ValueKey('source-graph-canvas')),
        );
        expect(
          panel.contains(
            tester.getCenter(find.byKey(ValueKey('graph-node-$id'))),
          ),
          true,
          reason:
              'Node $id center=${tester.getCenter(find.byKey(ValueKey('graph-node-$id')))} panel=$panel viewport=${graphState.graphViewportSize} transform=${graphState.graphTransform.value}',
        );
      }
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pumpAndSettle();
      expect(
        graphState.graphTransform.value.getMaxScaleOnAxis(),
        closeTo(fittedScale / 1.3, 1e-8),
      );
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(
        graphState.graphTransform.value.getMaxScaleOnAxis(),
        closeTo(fittedScale, 1e-8),
      );
      graphState.graphTransform.value = graphState.graphTransform.value.clone()
        ..scaleByDouble(1.15, 1.15, 1.15, 1.0);
      await tester.pumpAndSettle();
      expect(
        graphState.graphTransform.value.getMaxScaleOnAxis(),
        closeTo(fittedScale * 1.15, 1e-8),
      );
      for (var i = 0; i < 25; i++) {
        await tester.tap(find.byTooltip('Zoom in'));
        await tester.pumpAndSettle();
      }
      expect(find.text('500%'), findsOneWidget);
      for (var i = 0; i < 25; i++) {
        await tester.tap(find.byTooltip('Zoom out'));
        await tester.pumpAndSettle();
      }
      expect(find.text('2%'), findsOneWidget);
      await tester.tap(find.byTooltip('Fit graph'));
      await tester.pumpAndSettle();
      expect(
        graphState.graphTransform.value.getMaxScaleOnAxis(),
        closeTo(fittedScale, 1e-8),
      );
      await tester.tap(find.byTooltip('Apollo'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('graph-inspector')), findsOneWidget);
      expect(find.text('Apollo · revision 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Concise'));
      await tester.tap(find.text('Concise'));
      await tester.pumpAndSettle();
      expect(store.preference('noteStyle'), 'Concise');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final reopened = Store(path);
      expect(
        reopened.sources.where((s) => s['id'] == apollo).single['labels'],
        '["Launch","Team"]',
      );
      expect(reopened.preference('noteStyle'), 'Concise');
      expect(reopened.sources.first['imported'], greaterThan(0));
      reopened.close();
      await helper.close();
      tmp.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Start transcribing opens speech setup before creating a meeting; cancel preserves selection',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('foresight-quick-start-');
      final store = Store('${tmp.path}/app.db');
      final existing = store.meeting('Existing meeting');
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Existing meeting'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.meetingPreviewId, existing);
      expect(state.meetingId, isNull);
      expect(store.rows('SELECT * FROM meetings').length, 1);
      expect(find.text('Transcription Model'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.busy, false);
      expect(store.rows('SELECT * FROM meetings').length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Ask composer rejects blank input and submits through keyboard or send',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('foresight-composer-');
      final store = Store('${tmp.path}/application.db');
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      final send = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Ask',
      );
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byType(TextField),
        'What is the next milestone?',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(send).onPressed, isNotNull);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        store.rows('SELECT * FROM answers').single['question'],
        'What is the next milestone?',
      );
      expect(
        store.rows('SELECT * FROM answers').single['status'],
        'insufficient_context',
      );
      await tester.enterText(find.byType(TextField), 'Summarize my meeting');
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(store.rows('SELECT * FROM answers').length, 2);
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(find.text('Knowledge Sources'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Source table columns align and Name header sorts without losing grid access',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tmp = Directory.systemTemp.createTempSync(
        'foresight-source-columns-',
      );
      final store = Store('${tmp.path}/application.db');
      store.importText(
        'Apollo',
        'Review Friday.',
        'application/pdf',
        'fixture',
      );
      store.importText('Borealis', 'Review Monday.', 'text/plain', 'fixture');
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      final status = find.byTooltip('Local helper status');
      expect(
        find.descendant(of: status, matching: find.byIcon(Icons.task_alt)),
        findsNothing,
      );
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(find.text('Local helper'), findsOneWidget);
      expect(find.textContaining('Connection: disconnected'), findsOneWidget);
      expect(find.text('Reload models'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      helper.snapshot = control.State(pipeline: 'ready', index: 'ready');
      final dynamic workspace = tester.state(find.byType(Workspace));
      workspace.update(() {});
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: status, matching: find.byIcon(Icons.task_alt)),
        findsOneWidget,
      );
      helper.snapshot!.lastError = 'Embedding adapter exited; reload the model';
      helper.snapshot!.index = 'degraded';
      workspace.update(() {});
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: status, matching: find.byIcon(Icons.task_alt)),
        findsNothing,
      );
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Last error: Embedding adapter exited'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Imported')).dx,
        closeTo(tester.getTopLeft(find.text('Just now').first).dx, .1),
      );
      expect(
        tester.getTopLeft(find.text('Name ↑')).dx,
        closeTo(tester.getTopLeft(find.text('Apollo')).dx, .1),
      );
      await tester.tap(find.text('Name ↑'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Borealis')).dy,
        lessThan(tester.getTopLeft(find.text('Apollo')).dy),
      );
      await tester.tap(find.byTooltip('Grid view'));
      await tester.pumpAndSettle();
      expect(find.text('Apollo'), findsOneWidget);
      expect(find.text('Borealis'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Local file import preserves file modification time and first import time',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('foresight-file-dates-');
      final file = File('${tmp.path}/Apollo.txt')
        ..writeAsStringSync('Review Friday.');
      final originalTime = DateTime.utc(2020, 1, 1);
      file.setLastModifiedSync(originalTime);
      final store = Store('${tmp.path}/application.db');
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(AdapterDomain(store, helper)), deviceLoader: () async => []),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      await tester.runAsync(() async => await state.importFolderPath(tmp.path));
      final initial = store.sources.single;
      expect(initial['changed'], originalTime.millisecondsSinceEpoch);
      expect(
        initial['imported'] as int,
        greaterThan(initial['changed'] as int),
      );
      file.writeAsStringSync('Review Monday.');
      final updatedTime = DateTime.utc(2021, 1, 1);
      file.setLastModifiedSync(updatedTime);
      await tester.runAsync(() async => await state.importFolderPath(tmp.path));
      expect(store.sources.single['id'], initial['id']);
      expect(store.sources.single['revision'], 2);
      expect(store.sources.single['imported'], initial['imported']);
      expect(
        store.sources.single['changed'],
        updatedTime.millisecondsSinceEpoch,
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    },
  );

  for (final size in [const Size(800, 600), const Size(1440, 1000)]) {
    testWidgets('all reference screens fit $size without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tmp = Directory.systemTemp.createTempSync('foresight-layout-');
      final store = Store('${tmp.path}/app.db');
      store.importText('Apollo', 'Plan', 'text/plain', 'fixture');
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      for (final name in ['Meetings', 'Ask', 'Sources', 'Stats', 'Settings']) {
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$name at $size');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    });
  }
  testWidgets(
    'type filters combine with labels/search and survive view switches',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'foresight-type-filter-',
      );
      final store = Store('${root.path}/app.db');
      final pdf = store.importText(
        'Apollo PDF',
        'Launch report',
        'application/pdf',
        'fixture',
      );
      final sheet = store.importText(
        'Apollo sheet',
        'Budget table',
        'text/csv',
        'google-drive:fixture:file',
      );
      store.importText('Borealis text', 'Review', 'text/plain', 'fixture');
      store.labels(pdf, ['Team']);
      store.labels(sheet, ['Team']);
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      store.db.execute('INSERT INTO google_sources VALUES(?,?,?,?,?)', [
        sheet,
        'fixture',
        'file',
        'version',
        'application/vnd.google-apps.spreadsheet',
      ]);
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('PDF: 1'));
      await tester.tap(find.byTooltip('PDF: 1'));
      await tester.pumpAndSettle();
      expect(find.text('Apollo PDF'), findsOneWidget);
      expect(find.text('Apollo sheet'), findsNothing);
      expect(find.text('Borealis text'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Borealis');
      await tester.pumpAndSettle();
      expect(
        find.text('No sources match the current filters.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Team').first);
      await tester.tap(find.text('Team').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Graph view'));
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Apollo PDF'), findsOneWidget);
      expect(find.byTooltip('Apollo sheet'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Spreadsheets: 1'));
      await tester.tap(find.byTooltip('Spreadsheets: 1'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Apollo sheet'), findsOneWidget);
      expect(find.byTooltip('Apollo PDF'), findsOneWidget);
      await tester.ensureVisible(find.text('File list'));
      await tester.tap(find.text('File list'));
      await tester.pumpAndSettle();
      expect(find.text('Apollo sheet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await helper.close();
      root.deleteSync(recursive: true);
    },
  );
}
