import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight/graph_layout.dart';
import 'package:foresight/graph_rendering.dart';
import 'package:foresight/main.dart';
import 'package:foresight/store.dart';
import 'package:foresight/generated/helper_control.pb.dart' as control;
import 'graph_workflow_test.dart' show GraphDomain;
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'selection reveals incoming neighbors, inspector navigation and original links',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync('graph-selection-ui-');
      final store = Store('${temp.path}/app.db');
      final center = store.importText(
        'Center',
        'Center',
        'text/plain',
        'fixture',
        sourceUri: 'https://example.test/original',
      );
      final leaves = [
        for (var i = 0; i < 7; i++)
          store.importText('Leaf $i', 'Leaf', 'text/plain', 'fixture:$i'),
      ];
      final unrelated = store.importText(
        'Unrelated',
        'Separate',
        'text/plain',
        'fixture:unrelated',
      );
      for (final row in store.sources) {
        store.state(row['id'] as String, 'indexed');
      }
      final helper = OfflineHelper(
        '${temp.path}/socket',
        '${temp.path}/helper',
      );
      helper.snapshot = control.State(
        pipeline: 'ready',
        model: control.ModelIdentity(modelDigest: 'fixture', dimensions: 8),
      );
      final domain = GraphDomain(store, helper);
      final opened = <Uri>[];
      await tester.pumpWidget(
        Foresight(
          domain,
          deviceLoader: () async => [],
          sourceLinkOpener: (uri) async {
            opened.add(uri);
          },
        ),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      expect(domain.requests.length, 1);
      domain.requests.single.complete({
        center: [1, ...List.filled(7, 0)],
        for (var i = 0; i < 7; i++)
          leaves[i]: List.generate(
            8,
            (j) => j == 0
                ? .4
                : j == i + 1
                ? math.sqrt(.84)
                : 0,
          ),
        unrelated: [-1, ...List.filled(7, 0)],
      });
      final dynamic state = tester.state(find.byType(Workspace));
      Future<void> waitUntil(bool Function() ready) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(ready(), true);
      }

      await waitUntil(
        () => !state.graphOrganizing && state.graphPoints.length == 9,
      );
      state.update(() {
        state.graphYaw = 0.0;
        state.graphPitch = 0.0;
        state.graphPoints = <String, GraphPoint>{
          center: const GraphPoint(-.8, 0, 0),
          for (var i = 0; i < 7; i++)
            leaves[i]: GraphPoint(.5, (i - 3) * .24, 0),
          unrelated: const GraphPoint(-.8, .9, 0),
        };
      });
      await tester.pumpAndSettle();
      List<GraphEdge> visibleEdges() {
        final dynamic painter = tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('source-graph-links')),
            )
            .painter;
        return (painter.edges as List).cast<GraphEdge>();
      }

      bool dimmed(String id) =>
          (tester
                      .widget<CustomPaint>(
                        find.byKey(ValueKey('graph-node-paint-$id')),
                      )
                      .painter
                  as GraphNodePainter)
              .dimmed;
      expect(state.graphEdges.length, 7);
      expect(visibleEdges(), isEmpty);
      expect(find.byKey(const ValueKey('graph-inspector')), findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('graph-node-$center'))),
      );
      await tester.pump();
      await waitUntil(() => !state.graphRelatedLoading);
      expect(state.graphSelectedDocument, center);
      expect(
        visibleEdges().length,
        7,
        reason: 'Whole incoming pairs augment the six selected results',
      );
      expect(dimmed(unrelated), true);
      for (final id in [center, ...leaves]) {
        expect(dimmed(id), false);
      }
      expect(find.text('40% Match'), findsNWidgets(7));
      expect(
        tester.getSize(find.byKey(const ValueKey('graph-inspector'))).width,
        360,
      );
      expect(find.text('Center · revision 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('graph-inspector-link')));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.test/original')]);
      await tester.ensureVisible(
        find.byKey(ValueKey('graph-related-${leaves.first}')),
      );
      await tester.tap(find.byKey(ValueKey('graph-related-${leaves.first}')));
      await tester.pump();
      await waitUntil(() => !state.graphRelatedLoading);
      expect(state.graphSelectedDocument, leaves.first);
      expect(visibleEdges().length, 1);
      expect(find.byKey(const ValueKey('graph-inspector-link')), findsNothing);
      expect(dimmed(leaves.last), true);
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pumpAndSettle();
      expect(visibleEdges(), isEmpty);
      expect(dimmed(unrelated), false);
      await tester.enterText(find.byType(TextField), 'Unrelated');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('graph-node-$center')), findsOneWidget);
      expect(dimmed(center), true);
      expect(dimmed(unrelated), false);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Resume graph animation'));
      await tester.pump();
      await tester.pump();
      final before = state.graphYaw as double;
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw - before, closeTo(.025, 1e-6));
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('graph-node-$center'))),
      );
      await tester.pump();
      await tester.pump();
      expect(state.graphSelectedDocument, center);
      final selectedYaw = state.graphYaw as double;
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw - selectedYaw, closeTo(.00125, 1e-6));
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('graph-node-${leaves.first}'))),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pump();
      await waitUntil(() => !state.graphRelatedLoading);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(state.graphSelectedDocument, isNull);
      expect(visibleEdges(), isEmpty);
      expect(
        domain.requests.length,
        1,
        reason: 'Selection must use cached vectors',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      temp.deleteSync(recursive: true);
    },
  );
}
