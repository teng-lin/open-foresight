import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/graph_label_controls.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'inspector editor cancels without writing and submits only to the selected document before propagation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync(
        'foresight-inline-label-',
      );
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
        Foresight(Domain(store, helper), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
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
      expect(state.graphLabelInput.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('inspector-add-label')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inspector-label-input')),
        '  Planning  ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (
        var i = 0;
        i < 100 &&
            (state.busy ||
                store.rows('SELECT * FROM document_clusters').isEmpty);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(state.error, isEmpty);
      expect(store.documentLabels.single.documentId, a);
      expect(store.documentLabels.single.name, 'Planning');
      expect(store.documentLabels.single.source, 'user_defined');
      expect(store.documentLabels.where((r) => r.documentId == b), isEmpty);
      expect(state.graphLabelInput.text, isEmpty);
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
