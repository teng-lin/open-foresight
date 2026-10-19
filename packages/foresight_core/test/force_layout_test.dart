import 'package:test/test.dart';
import 'package:foresight_core/src/force_layout.dart';
import 'package:foresight_core/src/graph_layout.dart';

void main() {
  test(
    'overlapping groups and stale duplicate edges preserve deterministic geometry',
    () {
      final points = {
        'a': const GraphPoint(-10, 0, 2),
        'b': const GraphPoint(10, 0, 2),
        'shared': const GraphPoint(0, 10, 2),
        'unlabelled': const GraphPoint(0, 5, 2),
      };
      final labels = {
        'a': ['Left'],
        'b': ['Right'],
        'shared': ['Left', 'Right'],
      };
      final edges = [const GraphEdge('a', 'b', .8)];
      final clean = forceLabelLayout(points, edges, labels, ['Left', 'Right']);
      final duplicated = forceLabelLayout(
        points,
        [
          ...edges,
          const GraphEdge('b', 'a', .8),
          const GraphEdge('missing', 'a', .5),
        ],
        labels,
        ['Left', 'Right'],
      );
      for (final id in points.keys) {
        final point = clean.points[id]!;
        expect(
          [point.x, point.y, point.z].every((value) => value.isFinite),
          isTrue,
        );
        expect(duplicated.points[id]!.x, point.x);
        expect(duplicated.points[id]!.y, point.y);
        expect(duplicated.points[id]!.z, point.z);
      }
      for (final cluster in clean.clusters) {
        final members = points.keys
            .where((id) => labels[id]?.contains(cluster.label) == true)
            .toList();
        expect(
          cluster.center.x,
          closeTo(
            members.map((id) => clean.points[id]!.x).reduce((a, b) => a + b) /
                members.length,
            1e-9,
          ),
        );
        expect(cluster.radius, greaterThanOrEqualTo(50));
      }
      expect(
        points['a']!.x,
        -10,
        reason: 'Organization must not mutate persisted input points',
      );
    },
  );

  test(
    'disjoint label groups separate even when seeded into the same region',
    () {
      final initial = {
        'a': const GraphPoint(-5, 0, 1),
        'b': const GraphPoint(5, 0, 1),
        'c': const GraphPoint(0, 5, 1),
        'd': const GraphPoint(0, -5, 1),
      };
      final result = forceLabelLayout(
        initial,
        [],
        {
          'a': ['Alpha'],
          'b': ['Alpha'],
          'c': ['Beta'],
          'd': ['Beta'],
        },
        ['Alpha', 'Beta'],
      );
      final first = result.clusters.first.center,
          second = result.clusters.last.center;
      final distanceSquared =
          (first.x - second.x) * (first.x - second.x) +
          (first.y - second.y) * (first.y - second.y) +
          (first.z - second.z) * (first.z - second.z);
      expect(distanceSquared, greaterThan(10000));
    },
  );
  test(
    'force organization handles singleton and zero-variance PCA seeds',
    () async {
      for (final vectors in <Map<String, List<double>>>[
        {
          'a': [1, 2, 3],
        },
        {
          'a': [1, 2, 3],
          'b': [1, 2, 3],
        },
      ]) {
        final scene = await organizeForceGraphSceneInBackground(
          vectors,
          {},
          [],
          {},
        );
        expect(scene.points.keys.toSet(), vectors.keys.toSet());
        for (final point in scene.points.values) {
          expect([point.x, point.y, point.z].every((x) => x.isFinite), true);
        }
      }
    },
  );
  test(
    'recovered seeded sequence agrees with retained IEEE-derived values',
    () {
      final random = ForceRandom42();
      expect(random.nextDouble(), .15092545597797424);
      expect(random.nextDouble(), .6041479725361217);
      expect(random.nextDouble(), .6616810157870647);
    },
  );
  test(
    'origin and flat-plane initialization consume seeded draws in key order',
    () {
      final r = forceLabelLayout(
        {'a': const GraphPoint(0, 0, 0), 'b': const GraphPoint(10, 5, 0)},
        [],
        {},
        [],
        iterations: 0,
      );
      expect(r.points['a']!.x, (.15092545597797424 - .5) * 50);
      expect(r.points['a']!.y, (.6041479725361217 - .5) * 50);
      expect(r.points['a']!.z, (.6616810157870647 - .5) * 50);
      expect(r.points['b']!.x, 10);
      expect(r.points['b']!.y, 5);
      expect(r.points['b']!.z, isNot(0));
    },
  );
  test(
    'repulsion conserves pair center and collision correction reaches 82',
    () {
      final r = forceLabelLayout(
        {'a': const GraphPoint(-20, 0, 5), 'b': const GraphPoint(20, 0, 5)},
        [],
        {},
        [],
        iterations: 1,
      );
      expect(r.points['a']!.x, closeTo(-41, 1e-10));
      expect(r.points['b']!.x, closeTo(41, 1e-10));
      expect(r.points['a']!.z, 5);
      expect(r.points['b']!.z, 5);
    },
  );
  test('isolated label attraction uses blended target and output geometry', () {
    const start = GraphPoint(100, 0, 10);
    final target = forceLabelTarget('Planning');
    final r = forceLabelLayout(
      {'a': start},
      [],
      {
        'a': ['Planning'],
      },
      ['Planning', 'Unused'],
      iterations: 1,
    );
    expect(
      r.points['a']!.x,
      closeTo(start.x + .0195 * (target.x - start.x), 1e-10),
    );
    expect(r.clusters.first.center.x, r.points['a']!.x);
    expect(r.clusters.first.radius, 90);
    expect(r.clusters.last.center.x, 0);
    expect(r.clusters.last.radius, 90);
    expect(forceLabelTarget(' planning ').x, target.x);
  });
  test(
    'radius deduplicates distances, rejects jumps and obeys 90..160 limits',
    () {
      expect(forceLabelRadius([]), 90);
      expect(forceLabelRadius([10, 10, 10, 20, 500]), 90);
      expect(forceLabelRadius([100, 110, 120, 130]), 155);
      expect(forceLabelRadius([300, 400, 500]), 160);
    },
  );
  test(
    'output radius uses final 3D member distances plus 50 and preserves request order',
    () {
      final r = forceLabelLayout(
        {'a': const GraphPoint(-100, 0, 5), 'b': const GraphPoint(100, 0, 5)},
        [],
        {
          'a': ['Both'],
          'b': ['Both'],
        },
        ['Unused', 'Both'],
        iterations: 0,
      );
      expect(r.clusters.map((c) => c.label), ['Unused', 'Both']);
      expect(r.clusters.last.center.x, 0);
      expect(r.clusters.last.center.z, 5);
      expect(r.clusters.last.radius, 150);
    },
  );
}
