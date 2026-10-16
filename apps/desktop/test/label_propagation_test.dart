import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/graph_labels.dart';
import 'package:foresight_linux/graph_layout.dart';
import 'package:foresight_linux/label_propagation.dart';

DocumentLabel seed(String id, [String name = 'Alpha']) =>
    DocumentLabel(id, name, 'user_defined', '#0EBC5F');
List<double> angle(double cosine) => [cosine, math.sqrt(1 - cosine * cosine)];
void main() {
  test(
    'title substring and original-case heading rules produce lexical anchors',
    () {
      final p = planLabelPropagation(
        'Alpha',
        [
          const LabelDocument('title', '', title: 'ALPHA planning'),
          const LabelDocument('heading', '# alpha planning'),
          const LabelDocument('case', '# ALPHA planning'),
          const LabelDocument('unrelated', 'Unrelated body'),
        ],
        [],
        {},
        [],
      );
      expect(p.assigned, {'title', 'heading'});
      expect(p.writes.map((w) => w.source), ['user_defined', 'user_defined']);
      expect(p.writes.first.rationale, 'Title exact match for "Alpha"');
      expect(p.writes.last.rationale, 'Heading exact match for "Alpha"');
    },
  );
  test('keyword relevance requires four original-case occurrences', () {
    final docs = [
      const LabelDocument('four', 'alpha alpha alpha alpha'),
      const LabelDocument('three', 'alpha alpha alpha'),
      const LabelDocument('upper', 'ALPHA ALPHA ALPHA ALPHA'),
      for (var i = 0; i < 20; i++)
        LabelDocument('background$i', List.filled(100, 'other').join(' ')),
    ];
    final p = planLabelPropagation('Alpha', docs, [], {}, []);
    expect(p.assigned, {'four'});
    expect(p.writes.single.rationale, 'High keyword relevance for "Alpha"');
  });
  test(
    'edge pass has fixed anchors but community discovers one further hop',
    () {
      final p = planLabelPropagation(
        'Alpha',
        [
          for (final id in ['a', 'b', 'c', 'd']) LabelDocument(id, ''),
        ],
        [seed('a')],
        {
          for (final id in ['a', 'b', 'c', 'd']) id: [1, 0],
        },
        [
          const GraphEdge('a', 'b', .8),
          const GraphEdge('b', 'c', .8),
          const GraphEdge('c', 'd', .8),
        ],
      );
      expect(p.assigned, {'a', 'b', 'c'});
      expect(p.writes.map((w) => w.source), [
        'propagated',
        'propagated_community',
      ]);
    },
  );
  test('edge cutoff is inclusive and first unordered duplicate wins', () {
    final records = [for (var i = 0; i < 5; i++) seed('a$i')];
    final p = planLabelPropagation(
      'Alpha',
      [],
      records,
      {
        'a0': [1, 0],
        'equal': angle(.70),
        'low': angle(.70),
        'duplicate': angle(.70),
      },
      [
        const GraphEdge('a0', 'equal', .65),
        const GraphEdge('a0', 'low', .649),
        const GraphEdge('a0', 'duplicate', .5),
        const GraphEdge('duplicate', 'a0', .99),
      ],
    );
    expect(p.writes.map((w) => w.documentId), ['equal']);
  });
  test('edge propagation is not capped at five assignments', () {
    final p = planLabelPropagation(
      'Alpha',
      [],
      [seed('a')],
      {},
      [for (var i = 0; i < 7; i++) GraphEdge('a', 'b$i', .8)],
    );
    expect(p.assigned.length, 8);
    expect(p.writes.every((w) => w.source == 'propagated'), true);
  });
  test('community ranks adjacent candidates and stops at five total', () {
    final p = planLabelPropagation(
      'Alpha',
      [],
      [seed('a')],
      {},
      [
        for (var i = 0; i < 7; i++) GraphEdge('a', 'b$i', .64 - .01 * i),
        const GraphEdge('x', 'unconnected', 1),
      ],
    );
    expect(p.assigned, {'a', 'b0', 'b1', 'b2', 'b3'});
    expect(p.writes.every((w) => w.source == 'propagated_community'), true);
  });
  test(
    'existing label equality is exact and no anchor gives no assignments',
    () {
      final p = planLabelPropagation(
        'alpha',
        [const LabelDocument('a', 'unrelated')],
        [seed('a')],
        {},
        [const GraphEdge('a', 'b', 1)],
      );
      expect(p.assigned, isEmpty);
      expect(p.writes, isEmpty);
    },
  );
}
