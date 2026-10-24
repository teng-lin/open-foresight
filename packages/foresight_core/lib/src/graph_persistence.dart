import 'persistence/graph_queries.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'graph_layout.dart';
import 'graph_clusters.dart';
import 'store.dart';

import 'graph_view_data.dart';
export 'graph_view_data.dart';

extension GraphPersistence on Store {
  StoredGraphLayout loadRegisteredGraphLayout(
    List<Map<String, Object?>> sources, {
    String? labelSet,
  }) => GraphQueries(db).loadRegisteredGraphLayout(sources, labelSet: labelSet);
  StoredGraphLayout loadGraphLayout(
    String identity,
    List<Map<String, Object?>> sources,
    int dimensions, {
    String? labelSet,
  }) => GraphQueries(
    db,
  ).loadGraphLayout(identity, sources, dimensions, labelSet: labelSet);

  bool saveGraphLayout(
    String identity,
    List<Map<String, Object?>> sources,
    Map<String, List<double>> vectors,
    Map<String, GraphPoint> points, {
    String? labelSet,
    List<GraphCluster> clusters = const [],
  }) {
    if (sources.length < 2 || points.length != sources.length) return false;
    var forceIdentity = false;
    try {
      final parts = jsonDecode(identity);
      forceIdentity =
          parts is List && parts.firstOrNull == graphLayoutAlgorithmVersion;
    } on FormatException {
      /* Existing generic cache callers retain PCA limits. */
    }
    final blobs = <String, Uint8List>{};
    int? dimensions;
    for (final source in sources) {
      final id = source['id'] as String;
      final point = points[id];
      final vector = vectors[id];
      if (forceIdentity && vector == null && source['state'] != 'indexed') {
        if (point == null ||
            [point.x, point.y, point.z].any((v) => !v.isFinite)) {
          throw ArgumentError('Invalid graph coordinates');
        }
        blobs[id] = Uint8List(0);
        continue;
      }
      if (point == null ||
          vector == null ||
          vector.length < 3 ||
          vector.length > 8192 ||
          (dimensions != null && dimensions != vector.length) ||
          [point.x, point.y, point.z].any(
            (value) => !value.isFinite || (!forceIdentity && value.abs() > 1.1),
          ) ||
          vector.any((value) => !value.isFinite)) {
        throw ArgumentError('Invalid graph coordinates or embedding');
      }
      dimensions = vector.length;
      final bytes = ByteData(vector.length * 4);
      for (var i = 0; i < vector.length; i++) {
        bytes.setFloat32(i * 4, vector[i], Endian.little);
        if (!bytes.getFloat32(i * 4, Endian.little).isFinite) {
          throw ArgumentError('Graph embedding exceeds float32 range');
        }
      }
      blobs[id] = bytes.buffer.asUint8List();
    }
    final documentSet = graphDocumentSet(sources);
    db.execute('BEGIN');
    try {
      final current = forceIdentity
          ? graphSceneSources(this.sources, vectors)
          : this.sources.where((s) => s['state'] == 'indexed').toList();
      if (graphDocumentSet(current) != documentSet ||
          current
              .where((s) => s['state'] == 'indexed')
              .any((s) => !vectors.containsKey(s['id'])) ||
          (labelSet != null && graphLabelSet() != labelSet)) {
        db.execute('ROLLBACK');
        return false;
      }
      // One active model scene; publish its positions and vectors atomically.
      db.execute('DELETE FROM graph_force_state');
      db.execute('DELETE FROM graph_documents');
      db.execute('DELETE FROM graph_layouts');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final source in sources) {
        final id = source['id'] as String;
        final point = points[id]!;
        db.execute('INSERT INTO graph_documents VALUES(?,?,?,?,?,?,?,?)', [
          identity,
          id,
          source['revision'],
          blobs[id],
          point.x,
          point.y,
          point.z,
          now,
        ]);
      }
      db.execute('INSERT INTO graph_layouts VALUES(?,?)', [
        identity,
        documentSet,
      ]);
      if (labelSet != null) {
        db.execute(
          'INSERT INTO graph_force_state(model_identity,label_set) VALUES(?,?)',
          [identity, labelSet],
        );
      }
      for (final cluster in clusters) {
        saveLabelCluster(
          cluster.label,
          x: cluster.center.x,
          y: cluster.center.y,
          radius: cluster.radius,
        );
      }
      db.execute('COMMIT');
      return true;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
