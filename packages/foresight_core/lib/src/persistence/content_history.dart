import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'read_schema_guard.dart';

/// Read access to recoverable pre-replacement snapshots. Writes are captured by
/// schema-owned triggers, so every writer shares the same atomic history.
final class ContentHistory {
  ContentHistory(this.db, {required this.supportedVersion});
  final Database db;
  final int supportedVersion;

  List<Map<String, Object?>> _rows(String sql, List<Object?> args) =>
      readSnapshot(
        db,
        () => [
          for (final row in db.select(sql, args))
            Map<String, Object?>.from(row),
        ],
        supportedVersion: supportedVersion,
      );

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
      for (final row in _rows(
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
      for (final row in _rows('SELECT * FROM $entity WHERE $column=?', [id]))
        Map<String, Object?>.from(row),
    ];
  }

  List<Map<String, Object?>> meetingArtifacts(int id, String kind) => [
    for (final row in _rows(
      'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id',
      [id, kind],
    ))
      Map<String, Object?>.from(row),
  ];

  /// Editing the newest enhanced artifact also replaces its live Note draft.
  /// Include that state using the same latest-artifact rule as MeetingStore.
  List<Map<String, Object?>> artifactEdit(int id) {
    final artifact = row('artifacts', id);
    if (artifact.isEmpty || artifact.single['kind'] != 'enhanced_notes') {
      return artifact;
    }
    final meeting = artifact.single['meeting_id'] as int;
    final latest = meetingArtifacts(meeting, 'enhanced_notes').last;
    return [
      ...artifact,
      if (latest['id'] == id) ...row('meeting_notes', meeting),
    ];
  }
}
