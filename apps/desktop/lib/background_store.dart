import 'dart:isolate';
import 'store.dart';

/// Only the database path and query cross isolate boundaries. Keeping the
/// closure outside widget methods avoids retaining a State/BuildContext.
Future<Set<String>> searchSourceIds(String path, String query) => Isolate.run(
  () {
    final reader = Store.readOnly(path);
    try {
      final normalized = query.toLowerCase();
      // SQLite's built-in lower() folds ASCII only. Preserve the desktop's
      // Unicode matching semantics while reading bodies on this worker isolate.
      return reader
          .rows('SELECT id,title,content FROM sources WHERE deleted=0')
          .where(
            (row) => '${row['title']} ${row['content']}'.toLowerCase().contains(
              normalized,
            ),
          )
          .map((row) => row['id'] as String)
          .toSet();
    } finally {
      reader.close();
    }
  },
);

Future<int> localOutputWords(String path) => Isolate.run(() {
  final reader = Store.readOnly(path);
  try {
    return [
      ...reader.rows(
        "SELECT body AS text FROM answers WHERE status='completed'",
      ),
      ...reader.rows('SELECT generated AS text FROM artifacts'),
    ].fold<int>(
      0,
      (count, row) =>
          count + (row['text'] as String).split(RegExp(r'\s+')).length,
    );
  } finally {
    reader.close();
  }
});
