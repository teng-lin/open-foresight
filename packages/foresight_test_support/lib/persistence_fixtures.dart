import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

/// Explicitly reconstruct the pre17 label shape before a test lowers user_version.
/// Production never downgrades a profile. Historical migration bodies retain
/// their original five-column writes; this fixture keeps that schema boundary.
void legacyLabelFixture(Database db) {
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
