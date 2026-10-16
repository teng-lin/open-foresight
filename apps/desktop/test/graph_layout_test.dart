import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/graph_layout.dart';

void main() {
  test('PCA recovers distinct covariance axes and ignores translation', () {
    final vectors = <String, List<double>>{
      'x+': [4, 0, 0],
      'x-': [-4, 0, 0],
      'y+': [0, 2, 0],
      'y-': [0, -2, 0],
      'z+': [0, 0, 1],
      'z-': [0, 0, -1],
    };
    final result = semanticGraphLayout(vectors);
    expect(result['x+']!.x.abs(), closeTo(1, 1e-6));
    expect(result['x+']!.y.abs(), lessThan(1e-6));
    expect(result['y+']!.y.abs(), closeTo(1, 1e-6));
    expect(result['z+']!.z.abs(), closeTo(.5, 1e-6));
    final translated = semanticGraphLayout(
      vectors.map((id, v) => MapEntry(id, [v[0] + 11, v[1] - 7, v[2] + 3])),
    );
    for (final id in vectors.keys) {
      expect(translated[id]!.x, closeTo(result[id]!.x, 1e-6));
      expect(translated[id]!.y, closeTo(result[id]!.y, 1e-6));
      expect(translated[id]!.z, closeTo(result[id]!.z, 1e-6));
    }
  });
  test('dominant semantic axis is independent of insertion order', () {
    final vectors = <String, List<double>>{
      'apollo': [1, .001, .002],
      'launch': [1, -.001, -.002],
      'finance': [-1, .001, .002],
      'budget': [-1, -.001, -.002],
    };
    final result = semanticGraphLayout(vectors);
    double distance(String a, String b) => math.sqrt(
      math.pow(result[a]!.x - result[b]!.x, 2) +
          math.pow(result[a]!.y - result[b]!.y, 2) +
          math.pow(result[a]!.z - result[b]!.z, 2),
    );
    // PCA should keep the dominant semantic separation. Linux viewport
    // normalization magnifies the tiny secondary direction, so compare X here.
    expect((result['apollo']!.x - result['launch']!.x).abs(), lessThan(.01));
    expect(distance('apollo', 'finance'), greaterThan(1.9));
    final reordered = semanticGraphLayout(
      Map.fromEntries(vectors.entries.toList().reversed),
    );
    for (final id in vectors.keys) {
      expect(reordered[id]!.x, closeTo(result[id]!.x, 1e-6));
      expect(reordered[id]!.y, closeTo(result[id]!.y, 1e-6));
    }
  });
  test('ineligible and nonfinite embeddings leave PCA empty', () {
    for (final input in <Map<String, List<double>>>[
      {},
      {
        'a': [1, 2, 3],
      },
      {
        'a': [1, 2],
        'b': [2, 3],
      },
      {
        'a': [double.nan, 2, 3],
        'b': [1, 2, 3],
      },
    ]) {
      expect(semanticGraphLayout(input), isEmpty);
    }
    final sphere = uniformGraphLayout(['a', 'b', 'c', 'd', 'e']);
    for (final p in sphere.values) {
      expect(p.x * p.x + p.y * p.y + p.z * p.z, closeTo(1, 1e-10));
      final projected = projectGraphPoint(p);
      expect(projected.x.isFinite && projected.y.isFinite, true);
    }
    expect(uniformGraphLayout([]), isEmpty);
  });
  test(
    'zero variance keeps origins and missing-vector ring instead of sphere',
    () {
      final result = initialGraphLayout(
        ['a', 'b', 'missing'],
        {
          'a': [1, 2, 3],
          'b': [1, 2, 3],
        },
      );
      for (final id in ['a', 'b']) {
        expect([result[id]!.x, result[id]!.y, result[id]!.z], [0, 0, 0]);
      }
      expect(
        [result['missing']!.x, result['missing']!.y, result['missing']!.z],
        [276, 0, 0],
      );
      final singleton = initialGraphLayout(['only'], {});
      expect(
        [singleton['only']!.x, singleton['only']!.y, singleton['only']!.z],
        [0, 240, 0],
      );
    },
  );
  test('short vector leaves absent centered dimensions zero', () {
    final result = pcaGraphLayout(
      ['long', 'short'],
      {
        'long': [0, 0, 6],
        'short': [0, 0],
      },
    );
    expect(result['long']!.x, closeTo(240, 1e-9));
    expect(
      [result['short']!.x, result['short']!.y, result['short']!.z],
      [0, 0, 0],
    );
    expect(
      pcaGraphLayout(
        ['short', 'long'],
        {
          'long': [0, 0, 6],
          'short': [0, 0],
        },
      ),
      isEmpty,
    ); // The first eligible dimension controls eligibility.
  });
  test('repeated document IDs contribute repeatedly before keyed output', () {
    final result = pcaGraphLayout(
      ['a', 'a', 'b'],
      {
        'a': [4, 0, 0],
        'b': [0, 0, 0],
      },
    );
    expect(result.keys.toList(), ['a', 'b']);
    expect(result['a']!.x, closeTo(120, 1e-9));
    expect(result['b']!.x, closeTo(-240, 1e-9));
  });
  test(
    'low covariance norm retains seed and tiny projections stay unscaled',
    () {
      final result = pcaGraphLayout(
        ['a', 'b'],
        {
          'a': [1e-7, 0, 0],
          'b': [-1e-7, 0, 0],
        },
      );
      final seedNorm = math.sqrt(
        [1, 2, 3].fold(0.0, (sum, j) => sum + math.pow(math.sin(j), 2)),
      );
      expect(result['a']!.x, closeTo(1e-7 * math.sin(1) / seedNorm, 1e-20));
      expect(result['b']!.x, closeTo(-result['a']!.x, 1e-20));
    },
  );
  test('projection rotates axes and applies depth perspective', () {
    final turned = projectGraphPoint(
      const GraphPoint(1, 0, 0),
      yaw: math.pi / 2,
    );
    expect(turned.x, closeTo(0, 1e-10));
    expect(turned.z, closeTo(1, 1e-10));
    final pitched = projectGraphPoint(
      const GraphPoint(0, 1, 0),
      pitch: math.pi / 2,
    );
    expect(pitched.y, closeTo(0, 1e-10));
    expect(pitched.z, closeTo(1, 1e-10));
    expect(projectGraphPoint(const GraphPoint(1, 0, 1)).x, closeTo(.75, 1e-10));
    expect(
      () => projectGraphPoint(const GraphPoint(1, 0, -3)),
      throwsArgumentError,
    );
  });
}
