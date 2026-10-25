import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import '../graph_layout.dart';
import '../graph_view_data.dart';

class GraphQueries {
  final Database db;
  GraphQueries(this.db);
  List<Map<String, Object?>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db
      .select(sql, args)
      .map((row) => Map<String, Object?>.from(row))
      .toList();
  StoredGraphLayout loadRegisteredGraphLayout(
    List<Map<String, Object?>> sources, {
    String? labelSet,
  }) {
    final registered = rows("SELECT digest FROM models WHERE kind='embedding'");
    if (registered.isNotEmpty) {
      for (final row in rows('SELECT model_identity FROM graph_layouts')) {
        final identity = row['model_identity'] as String;
        try {
          final parts = jsonDecode(identity);
          if (parts is List &&
              parts.length == 6 &&
              parts[0] == graphLayoutAlgorithmVersion &&
              parts[1] == registered.single['digest'] &&
              parts[5] is int) {
            return loadGraphLayout(
              identity,
              sources,
              parts[5] as int,
              labelSet: labelSet,
            );
          }
        } on FormatException {
          // A malformed cached identity cannot select a model.
        }
      }
    }
    return const StoredGraphLayout({}, {}, false);
  }

  StoredGraphLayout loadGraphLayout(
    String identity,
    List<Map<String, Object?>> sources,
    int dimensions, {
    String? labelSet,
  }) {
    var forceIdentity = false;
    try {
      final parts = jsonDecode(identity);
      forceIdentity =
          parts is List && parts.firstOrNull == graphLayoutAlgorithmVersion;
    } on FormatException {
      /* Legacy generic identities retain PCA bounds. */
    }
    final points = <String, GraphPoint>{};
    final vectors = <String, List<double>>{};
    if (dimensions < 3 || dimensions > 8192) {
      return StoredGraphLayout(points, vectors, false);
    }
    final current = {
      for (final source in sources) source['id']: source['revision'],
    };
    for (final row in rows(
      'SELECT g.* FROM graph_documents g JOIN sources s ON s.id=g.document_id '
      'WHERE g.model_identity=? AND s.deleted=0 '
      'AND s.revision=g.source_revision',
      [identity],
    )) {
      final id = row['document_id'] as String;
      if (current[id] != row['source_revision']) continue;
      final blob = row['embedding'];
      if (blob is! Uint8List ||
          (blob.length != dimensions * 4 && !(forceIdentity && blob.isEmpty))) {
        continue;
      }
      final data = ByteData.sublistView(blob);
      final vector = List.generate(
        blob.length ~/ 4,
        (i) => data.getFloat32(i * 4, Endian.little),
      );
      final coordinates = [row['proj_x'], row['proj_y'], row['proj_z']];
      if (vector.any((value) => !value.isFinite) ||
          coordinates.any(
            (value) =>
                value is! num ||
                !value.isFinite ||
                (!forceIdentity && value.abs() > 1.1),
          )) {
        continue;
      }
      if (vector.isNotEmpty) vectors[id] = vector;
      points[id] = GraphPoint(
        (coordinates[0] as num).toDouble(),
        (coordinates[1] as num).toDouble(),
        (coordinates[2] as num).toDouble(),
      );
    }
    final saved = rows(
      'SELECT document_set FROM graph_layouts WHERE model_identity=?',
      [identity],
    );
    final forceState = rows(
      'SELECT label_set FROM graph_force_state WHERE model_identity=?',
      [identity],
    );
    final scope = forceIdentity ? graphSceneSources(sources, vectors) : sources;
    final complete =
        scope.length >= 2 &&
        points.length == scope.length &&
        sources
            .where((s) => s['state'] == 'indexed')
            .every((s) => vectors.containsKey(s['id'])) &&
        saved.isNotEmpty &&
        saved.single['document_set'] == graphDocumentSet(scope) &&
        (labelSet == null ||
            (forceState.isNotEmpty &&
                forceState.single['label_set'] == labelSet));
    return StoredGraphLayout(points, vectors, complete, identity: identity);
  }
}
