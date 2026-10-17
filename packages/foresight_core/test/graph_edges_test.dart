import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:foresight_core/src/graph_layout.dart';

void main() {
  test(
    'selected results precede whole edges and only incident pairs remain',
    () {
      final result = selectedGraphEdges(
        'chosen',
        {
          'chosen': [1, 0],
          'neighbor': [.8, .6],
        },
        [
          const GraphEdge('chosen', 'neighbor', .3),
          const GraphEdge('incoming', 'chosen', .4),
          const GraphEdge('unrelated', 'neighbor', .9),
        ],
      );
      expect(result.length, 2);
      expect(result.first.source, 'chosen');
      expect(result.first.target, 'neighbor');
      expect(result.first.similarity, closeTo(.8, 1e-12));
      expect(result.last.source, 'chosen');
      expect(result.last.target, 'incoming');
    },
  );

  test(
    'whole incoming edges can add visible neighbors beyond selected six',
    () {
      final vectors = <String, List<double>>{
        'center': [1, ...List.filled(7, 0)],
        for (var i = 0; i < 7; i++)
          'leaf:$i': List.generate(
            8,
            (j) => j == 0
                ? .4
                : j == i + 1
                ? math.sqrt(.84)
                : 0,
          ),
      };
      expect(selectedGraphNeighbors('center', vectors).length, 6);
      expect(
        selectedGraphEdges(
          'center',
          vectors,
          semanticGraphEdges(vectors),
        ).length,
        7,
      );
    },
  );
  test('cosine handles scale, negative values and ineligible vectors', () {
    expect(graphCosine([3, 0], [8, 0]), 1);
    expect(graphCosine([3, 0], [-8, 0]), -1);
    expect(graphCosine([1, 0], [0, 1]), 0);
    expect(graphCosine([], []), 0);
    expect(graphCosine([0, 0], [1, 0]), 0);
    expect(graphCosine([1], [1, 2]), 0);
  });

  test(
    'cutoff is inclusive and rejects lower scores, NaN and empty vectors',
    () {
      final vectors = <String, List<double>>{
        'selected': [1, 0],
        'boundary': [.2, math.sqrt(.96)],
        'below': [.199999, math.sqrt(1 - .199999 * .199999)],
        'negative': [-1, 0],
        'zero': [0, 0],
        'empty': [],
        'mismatched': [1],
        'nan': [double.nan, 1],
      };
      expect(graphCosine(vectors['selected']!, vectors['boundary']!), .2);
      expect(
        selectedGraphNeighbors('selected', vectors).map((n) => n.document),
        ['boundary'],
      );
      expect(selectedGraphNeighbors('missing', vectors), isEmpty);
    },
  );

  test('top two is per document; inbound selections can exceed degree two', () {
    final vectors = <String, List<double>>{
      'z:center': [1, 0, 0, 0, 0],
      for (var i = 0; i < 4; i++)
        'leaf:$i': List.generate(
          5,
          (j) => j == 0
              ? .4
              : j == i + 1
              ? math.sqrt(.84)
              : 0,
        ),
    };
    final edges = semanticGraphEdges(vectors);
    expect(edges.length, 4);
    expect(edges.map((e) => (e.source, e.target)).toSet().length, 4);
    for (final edge in edges) {
      expect(edge.source.startsWith('leaf:'), true);
      expect(edge.target, 'z:center');
      expect(edge.similarity, closeTo(.4, 1e-12));
    }
  });

  test(
    'qualifying cross-group pairs are omitted when both endpoints have two closer peers',
    () {
      final vectors = <String, List<double>>{
        for (var i = 0; i < 6; i++)
          'doc:$i': [
            math.cos(i < 3 ? i * .01 : .5 + (i - 3) * .01),
            math.sin(i < 3 ? i * .01 : .5 + (i - 3) * .01),
          ],
      };
      expect(
        graphCosine(vectors['doc:0']!, vectors['doc:5']!),
        greaterThan(.2),
      );
      final edges = semanticGraphEdges(vectors);
      expect(edges.length, 6);
      expect(edges.map((e) => (e.source, e.target)).toSet(), {
        ('doc:0', 'doc:1'),
        ('doc:0', 'doc:2'),
        ('doc:1', 'doc:2'),
        ('doc:3', 'doc:4'),
        ('doc:3', 'doc:5'),
        ('doc:4', 'doc:5'),
      });
    },
  );

  test(
    'selected neighbors take six in descending order without an ID tie key',
    () {
      final vectors = <String, List<double>>{
        'selected': [1, 0],
        'z-first-tie': [.9, math.sqrt(.19)],
        'a-second-tie': [.9, math.sqrt(.19)],
        for (var i = 0; i < 6; i++)
          'score:$i': [.8 - i * .1, math.sqrt(1 - math.pow(.8 - i * .1, 2))],
      };
      final neighbors = selectedGraphNeighbors('selected', vectors);
      expect(neighbors.map((n) => n.document), [
        'z-first-tie',
        'a-second-tie',
        'score:0',
        'score:1',
        'score:2',
        'score:3',
      ]);
      expect(semanticGraphEdges({}), isEmpty);
      expect(
        semanticGraphEdges({
          'only': [1, 0],
        }),
        isEmpty,
      );
    },
  );
}
