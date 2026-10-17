import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/graph_persistence.dart';
import 'package:foresight_core/src/graph_layout.dart';
import 'package:foresight_core/src/force_layout.dart';

void main() {
  test(
    'scene admits missing-vector text and excludes blank names and placeholders',
    () async {
      final sources = <Map<String, Object?>>[
        {'id': 'a', 'title': 'Indexed', 'content': '', 'state': 'indexed'},
        {'id': 'b', 'title': 'Pending', 'content': 'text', 'state': 'idle'},
        {'id': 'c', 'title': 'Blank', 'content': ' \n ', 'state': 'failed'},
        {'id': 'd', 'title': '  ', 'content': 'text', 'state': 'indexed'},
      ];
      final vectors = {
        'a': [1.0, 2.0, 3.0],
        'd': [1.0, 2.0, 3.0],
      };
      final scope = graphSceneSources(sources, vectors);
      expect(scope.map((s) => s['id']).toList(), ['a', 'b']);
      final scene = await organizeForceGraphSceneInBackground(
        vectors,
        {},
        [],
        {},
        documents: scope.map((s) => s['id'] as String).toList(),
      );
      expect(scene.points.keys.toList(), ['a', 'b']);
      expect(
        scene.points.values.every(
          (p) => [p.x, p.y, p.z].every((v) => v.isFinite),
        ),
        true,
      );
      expect(vectors.containsKey('b'), false);
    },
  );
  test(
    'missing-vector positions reopen honestly and index promotion invalidates cache',
    () {
      final dir = Directory.systemTemp.createTempSync('graph-scene-cache-');
      var store = Store('${dir.path}/app.db');
      final a = store.importText('Indexed', 'text', 'text/plain', 'fixture:a');
      final b = store.importText('Pending', 'text', 'text/plain', 'fixture:b');
      store.state(a, 'indexed');
      final identity = jsonEncode([
        graphLayoutAlgorithmVersion,
        'digest',
        'tokenizer',
        'raw',
        'gpu',
        3,
      ]);
      final vectors = {
        a: [1.0, 0.0, 0.0],
      };
      final points = {
        a: const GraphPoint(1, 2, 3),
        b: const GraphPoint(-1, -2, -3),
      };
      try {
        expect(
          store.saveGraphLayout(
            identity,
            store.sources,
            vectors,
            points,
            labelSet: store.graphLabelSet(),
          ),
          true,
        );
        expect(
          store.rows(
                'SELECT embedding FROM graph_documents WHERE document_id=?',
                [b],
              ).single['embedding']
              as Uint8List,
          isEmpty,
        );
        store.close();
        store = Store('${dir.path}/app.db');
        final restored = store.loadGraphLayout(
          identity,
          store.sources,
          3,
          labelSet: store.graphLabelSet(),
        );
        expect(restored.complete, true);
        expect(restored.points.keys.toSet(), {a, b});
        expect(restored.points[b]!.x, -1);
        expect(restored.vectors.keys.toList(), [a]);
        store.state(b, 'indexed');
        expect(
          store.loadGraphLayout(identity, store.sources, 3).complete,
          false,
        );
        expect(
          () => store.saveGraphLayout(identity, store.sources, vectors, points),
          throwsArgumentError,
        );
      } finally {
        store.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
}
