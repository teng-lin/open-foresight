import 'package:sqlite3/sqlite3.dart';

/// Preserve pre-migration read-only compatibility. This is evaluated inside the
/// caller's schema snapshot, so a reader sees an upgrade on its next read.
Map<String, Object?> materializeSource(Database db, Map<String, Object?> row) {
  if (row['generated'] != 1 || row['id'] == null) return row;
  if (db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type='view' AND name='source_contents'",
      )
      .isEmpty) {
    return row;
  }
  final body = db.select('SELECT content FROM source_contents WHERE id=?', [
    row['id'],
  ]);
  return body.isEmpty ? row : {...row, 'content': body.single['content']};
}
