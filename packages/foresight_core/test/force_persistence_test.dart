import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/graph_layout.dart';
import 'package:foresight_core/src/graph_persistence.dart';
import 'package:foresight_core/src/graph_clusters.dart';

void main() {
  test('registered scene does not reuse pre-recovery PCA cache identity', () {
    final dir = Directory.systemTemp.createTempSync('pca-cache-version-');
    final store = Store('${dir.path}/app.db');
    try {
      final a = store.importText('A', 'body', 'text/plain', 'fixture');
      final b = store.importText('B', 'body', 'text/plain', 'fixture');
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime) VALUES(?,?,?,?)',
        ['embedding', '/fixture', 'digest', '/fixture'],
      );
      final old = jsonEncode([
        'force-3d-mac45-normalized-v2',
        'digest',
        'tokenizer',
        'raw',
        'gpu',
        3,
      ]);
      expect(
        store.saveGraphLayout(
          old,
          store.sources,
          {
            a: [1.0, 0.0, 0.0],
            b: [0.0, 1.0, 0.0],
          },
          {a: const GraphPoint(.5, .5, .5), b: const GraphPoint(-.5, -.5, -.5)},
          labelSet: store.graphLabelSet(),
        ),
        true,
      );
      final restored = store.loadRegisteredGraphLayout(
        store.sources,
        labelSet: store.graphLabelSet(),
      );
      expect(restored.complete, false);
      expect(restored.points, isEmpty);
    } finally {
      store.close();
      dir.deleteSync(recursive: true);
    }
  });
  test(
    'force cache restores wider finite coordinates and invalidates only requested label organization',
    () {
      final dir = Directory.systemTemp.createTempSync('force-cache-');
      var store = Store('${dir.path}/app.db');
      final a = store.importText('A', 'body', 'text/plain', 'fixture'),
          b = store.importText('B', 'body', 'text/plain', 'fixture');
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      final identity = jsonEncode([
        graphLayoutAlgorithmVersion,
        'digest',
        'tokenizer',
        'raw',
        'gpu',
        3,
      ]);
      final points = {
        a: const GraphPoint(2.2, 1.3, .7),
        b: const GraphPoint(-2.2, -1.3, -.7),
      };
      final vectors = {
        a: [1.0, 0.0, 0.0],
        b: [0.0, 1.0, 0.0],
      };
      final labels = store.graphLabelSet();
      expect(
        store.saveGraphLayout(
          identity,
          store.sources,
          vectors,
          points,
          labelSet: labels,
          clusters: const [GraphCluster('Group', GraphPoint(100, 50, 30), 140)],
        ),
        true,
      );
      store.close();
      store = Store('${dir.path}/app.db');
      expect(
        store
            .loadGraphLayout(
              identity,
              store.sources,
              3,
              labelSet: store.graphLabelSet(),
            )
            .complete,
        true,
      );
      expect(
        store.loadGraphLayout(identity, store.sources, 3).points[a]!.x,
        2.2,
      );
      expect(
        store.rows('SELECT * FROM document_clusters').single['radius'],
        140,
      );
      store.labels(a, ['Group']);
      store.invalidateGraphOrganization();
      final changed = store.loadGraphLayout(
        identity,
        store.sources,
        3,
        labelSet: store.graphLabelSet(),
      );
      expect(changed.complete, false);
      expect(changed.vectors.length, 2);
      expect(changed.points[a]!.x, 2.2);
      final current = store.graphLabelSet();
      expect(
        store.saveGraphLayout(
          identity,
          store.sources,
          vectors,
          points,
          labelSet: current,
        ),
        true,
      );
      store.labels(a, []);
      store.acknowledgeGraphLabelRemoval();
      expect(
        store
            .loadGraphLayout(
              identity,
              store.sources,
              3,
              labelSet: store.graphLabelSet(),
            )
            .complete,
        true,
      );
      expect(
        store.loadGraphLayout(identity, store.sources, 3).points[a]!.x,
        2.2,
      );
      store.close();
      dir.deleteSync(recursive: true);
    },
  );
  test(
    'cluster write failure rolls back positions, vectors and force signature together',
    () {
      final dir = Directory.systemTemp.createTempSync('force-publish-');
      final store = Store('${dir.path}/app.db');
      final a = store.importText('A', 'body', 'text/plain', 'fixture'),
          b = store.importText('B', 'body', 'text/plain', 'fixture');
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      final identity = jsonEncode([
        graphLayoutAlgorithmVersion,
        'digest',
        'tokenizer',
        'raw',
        'gpu',
        3,
      ]);
      final points = {
            a: const GraphPoint(2, 0, 0),
            b: const GraphPoint(-2, 0, 0),
          },
          vectors = {
            a: [1.0, 0.0, 0.0],
            b: [0.0, 1.0, 0.0],
          };
      final labels = store.graphLabelSet();
      expect(
        store.saveGraphLayout(
          identity,
          store.sources,
          vectors,
          points,
          labelSet: labels,
        ),
        true,
      );
      store.db.execute(
        "CREATE TRIGGER reject_cluster BEFORE INSERT ON document_clusters BEGIN SELECT RAISE(ABORT,'injected cluster failure'); END",
      );
      expect(
        () => store.saveGraphLayout(
          identity,
          store.sources,
          vectors,
          {a: const GraphPoint(3, 0, 0), b: const GraphPoint(-3, 0, 0)},
          labelSet: labels,
          clusters: const [GraphCluster('Group', GraphPoint(0, 0, 0), 90)],
        ),
        throwsA(isA<SqliteException>()),
      );
      final restored = store.loadGraphLayout(
        identity,
        store.sources,
        3,
        labelSet: labels,
      );
      expect(restored.complete, true);
      expect(restored.points[a]!.x, 2);
      store.labels(a, ['Changed']);
      expect(
        store.saveGraphLayout(
          identity,
          store.sources,
          vectors,
          points,
          labelSet: labels,
        ),
        false,
      );
      expect(store.loadGraphLayout(identity, store.sources, 3).points[a]!.x, 2);
      store.close();
      dir.deleteSync(recursive: true);
    },
  );
}
