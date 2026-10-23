import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Read access to recoverable pre-replacement snapshots. Writes are captured by
/// schema-owned triggers, so every writer shares the same atomic history.
final class ContentHistory {
  ContentHistory(this.db);
  final Database db;

  static const entities = {
    'notes',
    'meeting_notes',
    'artifacts',
    'meeting_tasks',
    'sources',
  };

  List<Map<String, Object?>> revisions(String entity, Object id) {
    if (!entities.contains(entity)) throw ArgumentError.value(entity, 'entity');
    return [
      for (final row in db.select(
        'SELECT id,snapshot,created FROM content_revisions WHERE entity=? AND entity_id=? ORDER BY id DESC',
        [entity, '$id'],
      ))
        {
          'id': row['id'],
          'created': row['created'],
          'snapshot': jsonDecode(row['snapshot'] as String),
        },
    ];
  }

  List<Map<String, Object?>> row(String entity, Object id) {
    if (!entities.contains(entity)) throw ArgumentError.value(entity, 'entity');
    final column = entity == 'meeting_notes' ? 'meeting_id' : 'id';
    return [
      for (final row in db.select('SELECT * FROM $entity WHERE $column=?', [
        id,
      ]))
        Map<String, Object?>.from(row),
    ];
  }

  List<Map<String, Object?>> meetingArtifacts(int id, String kind) => [
    for (final row in db.select(
      'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id',
      [id, kind],
    ))
      Map<String, Object?>.from(row),
  ];
}
