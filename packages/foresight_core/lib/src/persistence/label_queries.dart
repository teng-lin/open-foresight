import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import '../graph_labels.dart';
import 'read_schema_guard.dart';

/// Read-only label projections shared by service and snapshot clients.
class LabelQueries {
  final Database db;
  final int supportedVersion;
  LabelQueries(this.db, {required this.supportedVersion});
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

  String graphLabelSet() => jsonEncode(
    documentLabels
        .map((label) => [label.documentId, label.name, label.source])
        .toList(),
  );
}
