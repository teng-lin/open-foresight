import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/graph_labels.dart';
import 'package:open_foresight/generated/helper_control.pb.dart' as control;
import 'graph_workflow_test.dart' show GraphDomain;
import 'meeting_setup_test.dart' show OfflineHelper;

class RestoringGraphDomain extends GraphDomain {
  final requestedIds = <List<String>>[];
  RestoringGraphDomain(super.store, super.helper);
  @override
  Future<void> resume() async {}
  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) {
    requestedIds.add(sources.map((source) => source['id'] as String).toList());
    return super.graphEmbeddings(sources);
  }
}

void main() {
  testWidgets(
    'label removal and deletion survive restart with restored coordinates and only missing vectors requested',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final temp = Directory.systemTemp.createTempSync('graph-restoration-ui-');
      var store = Store('${temp.path}/app.db');
      final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture:a');
      final b = store.importText(
        'Borealis',
        'Budget',
        'text/plain',
        'fixture:b',
      );
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      store.putDocumentLabel(
        DocumentLabel(a, 'Planning', 'user_defined', '#0EBC5F'),
      );
      store.putDocumentLabel(
        DocumentLabel(
          b,
          'Planning',
          'propagated',
          '#0EBC5F',
          'Fixture rationale',
        ),
      );
      RestoringGraphDomain domain(String instance, String path) {
        final helper = OfflineHelper(
          '${temp.path}/socket',
          '${temp.path}/helper',
        );
        helper.snapshot = control.State(
          pipeline: 'ready',
          instanceId: instance,
          model: control.ModelIdentity(
            modelDigest: 'fixture',
            tokenizerDigest: 'tokenizer',
            preprocessing: 'fixture',
            backend: 'fixture',
            dimensions: 3,
            path: path,
          ),
        );
        return RestoringGraphDomain(store, helper);
      }

      Future<void> showGraph(RestoringGraphDomain d) async {
        await tester.pumpWidget(Foresight(TestDesktopConnection(d), deviceLoader: () async => []));
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Graph view'));
        await tester.pumpAndSettle();
      }

      Future<void> waitForPoints(int count) async {
        for (var i = 0; i < 100; i++) {
          final dynamic state = tester.state(find.byType(Workspace));
          if (!state.sourceFeature.graphOrganizing && state.sourceFeature.graphPoints.length == count)
            return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        fail('Graph layout did not finish');
      }

      final first = domain('original-process', '/original-model-location');
      await showGraph(first);
      expect(first.requests.length, 1);
      first.requests.single.complete({
        a: [1, 0, 0],
        b: [.8, .6, 0],
      });
      await waitForPoints(2);
      final dynamic firstState = tester.state(find.byType(Workspace));
      expect(firstState.graphEdges.length, 1);
      expect(store.rows('SELECT * FROM graph_documents').length, 2);
      final beforeLabelChanges = store.rows(
        'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents ORDER BY document_id',
      );
      await tester.tap(find.byKey(ValueKey('graph-node-$a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inspector-remove-Planning')));
      await tester.pumpAndSettle();
      expect(store.documentLabels.single.documentId, b);
      expect(store.documentLabels.single.rationale, 'Fixture rationale');
      expect(store.documentLabels.single.source, 'propagated');
      expect(store.documentLabels.single.colorHex, '#0EBC5F');
      expect(store.rows('SELECT * FROM document_clusters'), isNotEmpty);
      // Per-document removal keeps the global cluster. Confirming the global
      // deletion then removes it without reorganizing the saved coordinates.
      final chip = find.widgetWithText(FilterChip, 'Planning');
      await tester.tap(
        find.descendant(of: chip, matching: find.byType(Icon)).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.documentLabels.single.documentId, b);
      await tester.tap(
        find.descendant(of: chip, matching: find.byType(Icon)).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store.documentLabels, isEmpty);
      expect(store.rows('SELECT * FROM document_clusters'), isEmpty);
      expect(
        store.rows(
          'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents ORDER BY document_id',
        ),
        beforeLabelChanges,
      );
      expect(first.requests.length, 1);
      store.db.execute('UPDATE graph_documents SET proj_x=proj_x*0.75');
      final expected = {
        for (final row in store.rows(
          'SELECT document_id,proj_x FROM graph_documents',
        ))
          row['document_id']: row['proj_x'],
      };
      await tester.pumpWidget(const SizedBox.shrink());
      store = Store('${temp.path}/app.db');
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
        ['embedding', '/moved-model-location', 'fixture', '', 'fixture'],
      );
      expect(store.documentLabels, isEmpty);
      expect(store.rows('SELECT * FROM document_clusters'), isEmpty);
      // Process and file location changed, but the model's content identity did not.
      final second = domain('fresh-process', '/moved-model-location');
      final ready = second.helper.snapshot;
      second.helper.snapshot = control.State(pipeline: 'failed');
      await showGraph(second);
      await waitForPoints(2);
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.sourceFeature.graphOrganizing, false);
      expect(second.requests, isEmpty);
      expect(state.sourceFeature.graphPoints.length, 2);
      expect(state.sourceFeature.graphEdges.length, 1);
      expect(state.sourceFeature.graphEdges.single.similarity, closeTo(.8, 1e-6));
      for (final entry in expected.entries) {
        expect(state.sourceFeature.graphPoints[entry.key].x, entry.value);
      }
      // Cached rendering works without a live engine; readiness still validates
      // the backend/preprocessing identity before any new organization.
      second.helper.snapshot = ready;
      state.update(() {});
      await tester.pumpAndSettle();
      await waitForPoints(2);
      expect(second.requests, isEmpty);
      final c = store.importText(
        'Comet',
        'Astronomy',
        'text/plain',
        'fixture:c',
      );
      store.state(c, 'indexed');
      state.update(() {});
      await tester.pumpAndSettle();
      expect(second.requestedIds.single, [c]);
      expect(state.sourceFeature.graphPoints[a].x, expected[a]);
      second.requests.single.complete({
        c: [0, 0, 1],
      });
      await waitForPoints(3);
      expect(state.sourceFeature.graphEdges.length, 1);
      expect(store.rows('SELECT * FROM graph_documents').length, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      temp.deleteSync(recursive: true);
    },
  );
}
