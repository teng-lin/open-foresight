import 'dart:convert';
import 'source_contents.dart';

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

  static const maximumRevisions = 20;
  static const maximumBytes = 32 * 1024 * 1024;
  static const maximumAge = Duration(days: 90);

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
        'SELECT id,snapshot,created FROM content_revisions WHERE entity=? AND entity_id=? AND created>=? ORDER BY id DESC',
        [
          entity,
          '$id',
          DateTime.now().subtract(maximumAge).millisecondsSinceEpoch,
        ],
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
    return readSnapshot(
      db,
      () => [
        for (final row in _rows('SELECT * FROM $entity WHERE $column=?', [id]))
          entity == 'sources'
              ? materializeSource(db, Map<String, Object?>.from(row))
              : Map<String, Object?>.from(row),
      ],
      supportedVersion: supportedVersion,
    );
  }

  List<Map<String, Object?>> meetingArtifacts(int id, String kind) => [
    for (final row in _rows(
      'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id',
      [id, kind],
    ))
      Map<String, Object?>.from(row),
  ];

  /// Only title ownership participates in rename consent; live transcription
  /// and capture state must not invalidate an otherwise unchanged name.
  List<Map<String, Object?>> meetingTitle(int id) => _rows(
    'SELECT id,title,title_manually_edited FROM meetings WHERE id=?',
    [id],
  );

  /// The attribution a correction or reset is about to replace; an approval
  /// is bound to exactly this row.
  List<Map<String, Object?>> attribution(int transcriptId) => _rows(
    'SELECT transcript_id,participant_id,display_name,state,method,manual,revision FROM transcript_attributions WHERE transcript_id=?',
    [transcriptId],
  );

  /// The participant name a rename is about to replace.
  List<Map<String, Object?>> participant(int id) => _rows(
    'SELECT id,display_name,name_manual,rename_count FROM meeting_participants WHERE id=?',
    [id],
  );

  static const derivedKinds = {
    'summary',
    'actions',
    'preparation',
    'enhanced_notes',
  };

  /// Stable derived sources are independently editable. Bind consent to their
  /// content, excluding background indexing state and already-deleted content.
  List<Map<String, Object?>> meetingSource(int meeting, String kind) =>
      derivedKinds.contains(kind)
      ? _rows(
          'SELECT id,title,content,mime,revision,deleted,provenance,locally_edited FROM sources WHERE id=? AND deleted=0',
          ['meeting-$kind-$meeting'],
        )
      : [];

  List<Map<String, Object?>> meetingReplacement(int meeting, String kind) => [
    ...meetingArtifacts(meeting, kind),
    if (kind == 'enhanced_notes')
      ...row(
        'meeting_notes',
        meeting,
      ).where((row) => row['enhanced_body'] != null),
    if (kind == 'actions')
      ..._rows('SELECT * FROM meeting_tasks WHERE meeting_id=? ORDER BY id', [
        meeting,
      ]),
    ...meetingSource(meeting, kind),
  ];

  /// Latest-artifact edits also replace a stable source and, for enhanced
  /// notes, the live draft. Historical edits replace only their artifact row.
  List<Map<String, Object?>> artifactEdit(int id) {
    final artifact = row('artifacts', id);
    if (artifact.isEmpty) return artifact;
    final kind = artifact.single['kind'] as String;
    final meeting = artifact.single['meeting_id'] as int;
    final latest = meetingArtifacts(meeting, kind).last;
    if (latest['id'] != id) return artifact;
    return [
      ...artifact,
      if (kind == 'enhanced_notes') ...row('meeting_notes', meeting),
      ...meetingSource(meeting, kind),
    ];
  }

  List<Map<String, Object?>> taskEdit(int id) {
    final task = row('meeting_tasks', id);
    if (task.isEmpty) return task;
    final meeting = task.single['meeting_id'] as int;
    final artifact = meetingArtifacts(meeting, 'actions').lastOrNull;
    return [
      ...task,
      if (artifact != null) ...artifactEdit(artifact['id'] as int),
    ];
  }
}
