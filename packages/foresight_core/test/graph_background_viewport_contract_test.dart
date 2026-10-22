import 'dart:math' as math;

import 'package:foresight_core/src/graph_clusters.dart';
import 'package:foresight_core/src/graph_labels.dart';
import 'package:foresight_core/src/graph_layout.dart';
import 'package:foresight_core/src/label_propagation.dart';
import 'package:test/test.dart';

List<Object> edgeValue(GraphEdge edge) => [
  edge.source,
  edge.target,
  edge.similarity,
];

void main() {
  test(
    'background graph workers preserve semantic layout and selected incidence',
    () async {
      final vectors = <String, List<double>>{
        'launch': [1, 0, 0],
        'orbit': [.9, .1, 0],
        'unrelated': [-1, 0, 0],
      };
      final edges = await graphEdgesInBackground(vectors);
      expect(edges.map(edgeValue), semanticGraphEdges(vectors).map(edgeValue));
      expect(edges.map((e) => {e.source, e.target}), [
        {'launch', 'orbit'},
      ]);
      final selected = await selectedGraphEdgesInBackground('orbit', vectors, [
        ...edges,
        const GraphEdge('unrelated', 'elsewhere', .99),
        const GraphEdge('orbit', 'launch', .1),
      ]);
      expect(selected, hasLength(1));
      expect(
        {selected.single.source, selected.single.target},
        {'launch', 'orbit'},
      );
      expect(selected.single.similarity, greaterThan(.9));
      final scene = await organizeGraphSceneInBackground(vectors);
      expect(scene.edges.map(edgeValue), edges.map(edgeValue));
      final expected = semanticGraphLayout(vectors);
      expect(scene.points.keys.toSet(), vectors.keys.toSet());
      for (final id in vectors.keys) {
        final actual = scene.points[id]!;
        final reference = expected[id]!;
        expect(
          [actual.x, actual.y, actual.z],
          [reference.x, reference.y, reference.z],
        );
        expect(
          actual.x.isFinite && actual.y.isFinite && actual.z.isFinite,
          isTrue,
        );
      }
      expect(vectors['launch'], [1, 0, 0]);
      expect(await graphEdgesInBackground({}), isEmpty);
    },
  );

  test('camera keeps empty and degenerate scenes centered and bounds zoom', () {
    for (final points in <List<GraphPoint>>[
      [],
      [const GraphPoint(4, 8, 1)],
      [const GraphPoint(4, 8, 1), const GraphPoint(4, 12, 2)],
    ]) {
      final camera = fitGraphCamera(points, 800, 600);
      expect(camera.scale, 1);
      expect(camera.x + graphSceneOrigin, 400);
      expect(camera.y + graphSceneOrigin, 300);
    }
    for (final extent in [.0001, 1e9]) {
      final camera = fitGraphCamera(
        [GraphPoint(-extent, -extent, 0), GraphPoint(extent, extent, 0)],
        800,
        600,
      );
      expect(camera.scale, extent < 1 ? 5 : .015);
      expect(camera.x + graphSceneOrigin * camera.scale, closeTo(400, 1e-9));
      expect(camera.y + graphSceneOrigin * camera.scale, closeTo(300, 1e-9));
    }
  });

  test(
    'depth styling distinguishes dimmed nodes and rejects invalid camera distances',
    () {
      for (final depth in [-1000.0, 0.0, 1000.0]) {
        final fill = graphNodeFillOpacity(depth);
        final outline = graphNodeOutlineOpacity(depth);
        expect(fill, inInclusiveRange(0, 1));
        expect(outline, greaterThan(fill));
        expect(graphNodeFillOpacity(depth, dimmed: true), lessThan(fill));
        expect(graphNodeOutlineOpacity(depth, dimmed: true), lessThan(outline));
      }
      expect(
        graphNodeFillOpacity(-1000),
        greaterThan(graphNodeFillOpacity(1000)),
      );
      for (final distance in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () =>
              projectGraphPoint(const GraphPoint(0, 0, 0), distance: distance),
          throwsArgumentError,
        );
      }
      final rotated = projectGraphPoint(
        const GraphPoint(1, 0, 0),
        yaw: math.pi / 2,
      );
      expect(rotated.x, closeTo(0, 1e-12));
      expect(rotated.z, closeTo(1, 1e-12));
    },
  );

  test(
    'world rotation preserves radius and agrees with perspective composition',
    () {
      const point = GraphPoint(3, 4, 12);
      final rotated = rotateGraphPoint(point, yaw: .7, pitch: -.3);
      expect(
        rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z,
        closeTo(169, 1e-10),
      );
      final composed = projectGraphPoint(rotated, distance: 20);
      final direct = projectGraphPoint(
        point,
        yaw: .7,
        pitch: -.3,
        distance: 20,
      );
      expect(composed.x, closeTo(direct.x, 1e-12));
      expect(composed.y, closeTo(direct.y, 1e-12));
      expect(composed.z, closeTo(direct.z, 1e-12));
    },
  );

  test(
    'legacy two-dimensional clusters retain geometry and reserve label colors',
    () {
      final cluster = GraphCluster.fromRow({
        'label': 'Launch',
        'center_proj_x': 1,
        'center_proj_y': -.5,
        'radius': 20,
      });
      final center = graphWorldPoint(cluster.center);
      expect(cluster.label, 'Launch');
      expect([center.x, center.y, center.z], [240, -120, 0]);
      expect(cluster.radius, 20);
      final free = allocateGraphLabelColor(
        'Orbit',
        [],
        clusterColors: [null, graphLabelPalette.first.toLowerCase()],
      );
      expect(free, graphLabelPalette[1]);
      final saturated = allocateGraphLabelColor(
        'Orbit',
        [],
        clusterColors: graphLabelPalette,
      );
      expect(graphLabelPalette, contains(saturated));
      expect(
        allocateGraphLabelColor('Orbit', [], clusterColors: graphLabelPalette),
        saturated,
      );
    },
  );

  test(
    'background propagation honors an attached anchor outside loaded documents',
    () async {
      final result = await planLabelPropagationInBackground(
        'Launch',
        [const LabelDocument('candidate', 'Related material')],
        [
          const DocumentLabel(
            'external-anchor',
            'Launch',
            'user_attached',
            '#123456',
          ),
        ],
        {
          'external-anchor': [1, 0, 0],
          'candidate': [1, .1, 0],
        },
        [const GraphEdge('external-anchor', 'candidate', .9)],
      );
      expect(result.assigned, {'external-anchor', 'candidate'});
      expect(result.writes, hasLength(1));
      final write = result.writes.single;
      expect(
        [write.documentId, write.name, write.source, write.colorHex],
        ['candidate', 'Launch', 'propagated', '#123456'],
      );
      expect(write.rationale, contains('core seed'));
    },
  );
}
