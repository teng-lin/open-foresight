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

class LocalOutputStats {
  final int words;
  final List<int> weekly;
  LocalOutputStats(this.words, this.weekly);
}

Future<LocalOutputStats> localOutputStats(String path, {int? nowMs}) =>
    Isolate.run(() {
      final reader = Store.readOnly(path);
      try {
        final now = nowMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(nowMs);
        return LocalOutputStats(
          reader.localOutputWords,
          reader.weeklyOutputWords(now),
        );
      } finally {
        reader.close();
      }
    });

Future<int> localOutputWords(String path) async =>
    (await localOutputStats(path)).words;
