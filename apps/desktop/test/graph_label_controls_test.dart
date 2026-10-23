import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'package:open_foresight/features/sources/graph_label_controls.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets('focus loss closes the label editor and retains its draft', (
    tester,
  ) async {
    final controller = TextEditingController();
    final added = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              GraphLabelControls(
                labels: const [],
                controller: controller,
                onAdd: (value) async => added.add(value),
                onRemove: (_) {},
              ),
              const TextField(key: ValueKey('outside-label-editor')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('inspector-label-input')),
      'Planning draft',
    );
    await tester.tap(find.byKey(const ValueKey('outside-label-editor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inspector-label-input')), findsNothing);
    expect(controller.text, 'Planning draft');
    expect(added, isEmpty);
    await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
    await tester.pumpAndSettle();
    expect(find.text('Planning draft'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inspector-cancel-label')));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(added, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inspector editor cancels without writing and submits only to the selected document before propagation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = createTestTempDirectorySync('foresight-inline-label-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = Store('${dir.path}/app.db');
      final a = store.importText(
        'First',
        'Unrelated',
        'text/plain',
        'fixture:a',
      );
      final b = store.importText(
        'Second',
        'Unrelated',
        'text/plain',
        'fixture:b',
      );
      final helper = OfflineHelper('${dir.path}/socket', '${dir.path}/helper');
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(Domain(store, helper))),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      await tester.tap(find.byKey(ValueKey('graph-node-$a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inspector-label-input')),
        'Discard this',
      );
      await tester.tap(find.byKey(const ValueKey('inspector-cancel-label')));
      await tester.pumpAndSettle();
      expect(store.documentLabels, isEmpty);
      expect(state.sourceFeature.graphLabelInput.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inspector-label-input')),
        '  Planning  ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (
        final pollingClock = Stopwatch()..start();
        pollingClock.elapsed < const Duration(seconds: 5) &&
            (state.busy ||
                store.rows('SELECT * FROM document_clusters').isEmpty);
      ) {
        await tester.runAsync(() => Future<void>(() {}));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(state.error, isEmpty);
      expect(store.documentLabels.single.documentId, a);
      expect(store.documentLabels.single.name, 'Planning');
      expect(store.documentLabels.single.source, 'user_defined');
      expect(store.documentLabels.where((r) => r.documentId == b), isEmpty);
      expect(state.sourceFeature.graphLabelInput.text, isEmpty);
      final chip = find.byKey(const ValueKey('inspector-label-Planning'));
      expect(tester.getSize(chip).height, 24);
      expect(
        tester
            .widget<GraphLabelControls>(find.byType(GraphLabelControls))
            .labels
            .single
            .colorHex,
        '#0EBC5F',
      );
      await tester.tap(find.byKey(const ValueKey('inspector-remove-Planning')));
      await tester.pumpAndSettle();
      expect(store.documentLabels, isEmpty);
      expect(
        store.rows('SELECT * FROM document_clusters').length,
        1,
        reason:
            'Per-document remove does not delete the global cluster or propagate',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      dir.deleteSync(recursive: true);
    },
  );
}
