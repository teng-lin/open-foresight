import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:foresight_core/src/graph_layout.dart';
import 'package:foresight_core/src/graph_persistence.dart';
import 'package:foresight_core/src/store.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'layout and float32 embeddings survive reopen and reject incompatible cache',
    () {
      final temp = createTestTempDirectorySync('graph-persistence-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      var store = Store('${temp.path}/app.db');
      final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture');
      final b = store.importText('Borealis', 'Budget', 'text/plain', 'fixture');
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      final sources = store.sources;
      final points = {
        a: const GraphPoint(.25, .5, -.1),
        b: const GraphPoint(-.25, -.5, .1),
      };
      final vectors = {
        a: [1.0, 0.0, 0.0],
        b: [0.0, 1.0, 0.0],
      };
      expect(store.saveGraphLayout('model-A', sources, vectors, points), true);
      store.close();
      store = Store('${temp.path}/app.db');
      final restored = store.loadGraphLayout(
        'model-A',
        store.sources.reversed.toList(),
        3,
      );
      expect(restored.complete, true);
      expect(restored.points[a]!.x, .25);
      expect(restored.points[a]!.z, -.1);
      expect(restored.vectors[a], [1, 0, 0]);
      final blob =
          store.rows(
                'SELECT embedding FROM graph_documents WHERE document_id=?',
                [a],
              ).single['embedding']
              as Uint8List;
      expect(blob.length, 12);
      expect(ByteData.sublistView(blob).getFloat32(0, Endian.little), 1);
      expect(
        store.loadGraphLayout('model-B', store.sources, 3).points,
        isEmpty,
      );
      expect(
        store.loadGraphLayout('model-A', store.sources, 4).complete,
        false,
      );
      store.db.execute(
        'UPDATE graph_documents SET embedding=? WHERE document_id=?',
        [Uint8List(1), a],
      );
      final corrupt = store.loadGraphLayout('model-A', store.sources, 3);
      expect(corrupt.complete, false);
      expect(corrupt.points.keys, [b]);
      store.close();
      temp.deleteSync(recursive: true);
    },
  );

  test(
    'source edits, deletions and additions invalidate stale publication',
    () {
      final temp = createTestTempDirectorySync('graph-revisions-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final store = Store('${temp.path}/app.db');
      final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture');
      final b = store.importText('Borealis', 'Budget', 'text/plain', 'fixture');
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      final original = store.sources;
      final vectors = {
        a: [1.0, 0.0, 0.0],
        b: [0.0, 1.0, 0.0],
      };
      final points = {
        a: const GraphPoint(1, 0, 0),
        b: const GraphPoint(-1, 0, 0),
      };
      expect(store.saveGraphLayout('model', original, vectors, points), true);
      store.importText('Apollo', 'Changed', 'text/plain', 'fixture', id: a);
      store.state(a, 'indexed');
      expect(store.saveGraphLayout('model', original, vectors, points), false);
      final changed = store.loadGraphLayout('model', store.sources, 3);
      expect(changed.complete, false);
      expect(changed.points.keys, [b]);
      store.tombstone(b);
      expect(store.loadGraphLayout('model', store.sources, 3).points, isEmpty);
      store.close();
      temp.deleteSync(recursive: true);
    },
  );

  test('failed cache publication preserves the previous valid scene', () {
    final temp = createTestTempDirectorySync('graph-atomic-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final store = Store('${temp.path}/app.db');
    final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture');
    final b = store.importText('Borealis', 'Budget', 'text/plain', 'fixture');
    for (final id in [a, b]) {
      store.state(id, 'indexed');
    }
    final points = {
      a: const GraphPoint(1, 0, 0),
      b: const GraphPoint(-1, 0, 0),
    };
    final vectors = {
      a: [1.0, 0.0, 0.0],
      b: [0.0, 1.0, 0.0],
    };
    store.saveGraphLayout('model', store.sources, vectors, points);
    store.db.execute(
      "CREATE TRIGGER reject_graph_write BEFORE INSERT ON graph_documents BEGIN SELECT RAISE(ABORT,'fixture write failure'); END",
    );
    expect(
      () => store.saveGraphLayout('model', store.sources, vectors, points),
      throwsException,
    );
    expect(store.loadGraphLayout('model', store.sources, 3).complete, true);
    expect(
      () => store.saveGraphLayout('model', store.sources, {
        a: [1e100, 0, 0],
        b: [0, 1, 0],
      }, points),
      throwsArgumentError,
    );
    expect(store.loadGraphLayout('model', store.sources, 3).complete, true);
    store.close();
    temp.deleteSync(recursive: true);
  });
}
