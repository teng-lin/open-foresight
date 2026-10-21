import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../graph_labels.dart';
import 'read_schema_guard.dart';

/// One canonical label representation, with durable order shared by all reads.
class LabelStore {
  final Database db;
  final int supportedVersion;
  LabelStore(this.db, {required this.supportedVersion});

  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db
      .select(sql, args)
      .map((row) => Map<String, Object?>.from(row))
      .toList();
  List<DocumentLabel> get documentLabels => readSnapshot(
    db,
    () => _rows(
      'SELECT l.* FROM document_labels l JOIN sources s ON s.id=l.document_id '
      'WHERE s.deleted=0 ORDER BY l.document_id,l.position',
    ).map(DocumentLabel.fromRow).toList(),
    supportedVersion: supportedVersion,
  );

  List<String> names(String id) => readSnapshot(
    db,
    () => _rows(
      'SELECT label_name FROM document_labels WHERE document_id=? ORDER BY position',
      [id],
    ).map((row) => row['label_name'] as String).toList(),
    supportedVersion: supportedVersion,
  );

  List<Map<String, Object?>> sourceRows(String sql) => readSnapshot(db, () {
    final result = _rows(sql);
    final labels = <String, List<String>>{};
    for (final row in _rows(
      'SELECT document_id,label_name FROM document_labels ORDER BY document_id,position',
    )) {
      labels
          .putIfAbsent(row['document_id'] as String, () => [])
          .add(row['label_name'] as String);
    }
    for (final row in result) {
      row['labels'] = jsonEncode(labels[row['id']] ?? const <String>[]);
    }
    return result;
  }, supportedVersion: supportedVersion);

  void _savepoint(String name, void Function() work) {
    db.execute('SAVEPOINT $name');
    try {
      work();
      db.execute('RELEASE $name');
    } catch (_) {
      db.execute('ROLLBACK TO $name');
      db.execute('RELEASE $name');
      rethrow;
    }
  }

  void put(DocumentLabel label) => _savepoint('put_document_label', () {
    final old = _rows(
      'SELECT position FROM document_labels WHERE document_id=? AND label_name=?',
      [label.documentId, label.name],
    ).firstOrNull;
    final position =
        old?['position'] ??
        _rows(
          'SELECT COALESCE(MAX(position)+1,0) AS n FROM document_labels WHERE document_id=?',
          [label.documentId],
        ).single['n'];
    db.execute(
      'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale,position) '
      'VALUES(?,?,?,?,?,?) ON CONFLICT(document_id,label_name) DO UPDATE SET '
      'label_source=excluded.label_source,color_hex=excluded.color_hex,rationale=excluded.rationale',
      [
        label.documentId,
        label.name,
        label.source,
        label.colorHex,
        label.rationale,
        position,
      ],
    );
  });

  void replaceNames(
    String id,
    List<String> requested,
  ) => _savepoint('replace_document_labels', () {
    final names = requested.toSet().toList();
    for (final row in _rows(
      'SELECT label_name FROM document_labels WHERE document_id=?',
      [id],
    )) {
      if (!names.contains(row['label_name'])) {
        db.execute(
          'DELETE FROM document_labels WHERE document_id=? AND label_name=?',
          [id, row['label_name']],
        );
      }
    }
    final records = documentLabels;
    for (var position = 0; position < names.length; position++) {
      final name = names[position];
      if (_rows(
        'SELECT 1 FROM document_labels WHERE document_id=? AND label_name=?',
        [id, name],
      ).isNotEmpty) {
        db.execute(
          'UPDATE document_labels SET position=? WHERE document_id=? AND label_name=?',
          [position, id, name],
        );
      } else {
        final color = allocateGraphLabelColor(name, records);
        db.execute(
          'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale,position) '
          "VALUES(?,?,'user_defined',?,NULL,?)",
          [id, name, color, position],
        );
        records.add(DocumentLabel(id, name, 'user_defined', color));
      }
    }
  });

  String graphLabelSet() => jsonEncode(
    documentLabels
        .map((label) => [label.documentId, label.name, label.source])
        .toList(),
  );
  void invalidateGraphOrganization() =>
      db.execute('DELETE FROM graph_force_state');
  void acknowledgeGraphLabelRemoval() =>
      db.execute('UPDATE graph_force_state SET label_set=?', [graphLabelSet()]);
  void deleteOrganizationLabel(String name) =>
      _savepoint('delete_organization_label', () {
        db.execute('DELETE FROM document_labels WHERE label_name=?', [name]);
        db.execute('DELETE FROM document_clusters WHERE label=?', [name]);
      });

  void saveLabelCluster(
    String label, {
    double x = 0,
    double y = 0,
    double radius = 90,
  }) {
    final existing = _rows(
      'SELECT cluster_id FROM document_clusters WHERE label=?',
      [label],
    );
    if (existing.isNotEmpty) {
      db.execute(
        'UPDATE document_clusters SET center_proj_x=?,center_proj_y=?,radius=? WHERE cluster_id=?',
        [x, y, radius, existing.single['cluster_id']],
      );
    } else {
      db.execute(
        'REPLACE INTO document_clusters(label,summary,centroid_embedding,center_proj_x,center_proj_y,radius) VALUES(?,NULL,NULL,?,?,?)',
        [label, x, y, radius],
      );
    }
  }
}
