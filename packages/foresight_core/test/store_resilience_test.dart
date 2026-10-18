import 'package:foresight_test_support/test_paths.dart';

import 'package:foresight_core/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test(
    'busy writer preserves revisions and source caches recover after rollback',
    () {
      final root = createTestTempDirectorySync('store-resilience-');
      addTearDown(() => root.deleteSync(recursive: true));
      final writer = Store('${root.path}/application.db');
      final other = Store(writer.path);
      try {
        final id = writer.importText(
          'Original',
          'Original body',
          'text/plain',
          'fixture',
        );
        expect(writer.sourceSummaries.single['title'], 'Original');
        expect(other.sourceSummaries.single['title'], 'Original');
        writer.db.execute('BEGIN IMMEDIATE');
        writer.importText(
          'Uncommitted',
          'Temporary body',
          'text/plain',
          'fixture',
          id: id,
        );
        expect(writer.sourceSummaries.single['title'], 'Uncommitted');
        expect(other.sourceSummaries.single['title'], 'Original');
        expect(
          () => other.importText(
            'Contending',
            'Rejected body',
            'text/plain',
            'fixture',
            id: id,
          ),
          throwsA(
            isA<SqliteException>().having(
              (error) => error.resultCode,
              'SQLITE_BUSY',
              5,
            ),
          ),
        );
        writer.db.execute('ROLLBACK');
        for (final store in [writer, other]) {
          expect(store.sourceSummaries.single['title'], 'Original');
          expect(store.sources.single['revision'], 1);
          expect(store.sources.single['content'], 'Original body');
        }
        // A subsequent committed write must invalidate the first connection's
        // cached metadata, even though it was written through another connection.
        other.importText(
          'Committed',
          'Durable body',
          'text/plain',
          'fixture',
          id: id,
        );
        expect(writer.sourceSummaries.single['title'], 'Committed');
        expect(writer.sources.single['revision'], 2);
        expect(writer.sources.single['content'], 'Durable body');
      } finally {
        if (!writer.db.autocommit) writer.db.execute('ROLLBACK');
        other.close();
        writer.close();
      }
    },
  );
}
