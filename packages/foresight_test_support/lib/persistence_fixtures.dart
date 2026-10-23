import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

/// Explicitly reconstruct the pre17 label shape before a test lowers user_version.
/// Production never downgrades a profile. Historical migration bodies retain
/// their original five-column writes; this fixture keeps that schema boundary.
void legacyLabelFixture(Database db) {
  // A version-1/8/16 fixture cannot keep schema-18 tables or triggers. Retain
  // the original content while reconstructing that actual historical shape.
  for (final table in [
    'notes',
    'meeting_notes',
    'artifacts',
    'meeting_tasks',
    'sources',
  ]) {
    db.execute('DROP TRIGGER IF EXISTS ${table}_retain_revision');
    db.execute('DROP TRIGGER IF EXISTS ${table}_erase_revisions');
  }
  db.execute('DROP TRIGGER IF EXISTS sources_erase_deleted_revisions');
  db.execute('DROP TABLE IF EXISTS content_revisions');
  final columns = db
      .select('PRAGMA table_info(document_labels)')
      .map((r) => r['name'])
      .toSet();
  if (!columns.contains('position')) return;
  db.execute(
    "ALTER TABLE source_details ADD COLUMN labels TEXT NOT NULL DEFAULT '[]'",
  );
  for (final row in db.select('SELECT source_id FROM source_details')) {
    final labels = db
        .select(
          'SELECT label_name FROM document_labels WHERE document_id=? ORDER BY position',
          [row['source_id']],
        )
        .map((r) => r['label_name'])
        .toList();
    db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
      jsonEncode(labels),
      row['source_id'],
    ]);
  }
  db.execute('ALTER TABLE document_labels DROP COLUMN position');
}
