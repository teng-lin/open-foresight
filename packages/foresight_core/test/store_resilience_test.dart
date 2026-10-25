import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';

import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'privacy intent commits with deletion and rolls back with a failed clear',
    () async {
      final root = createTestTempDirectorySync('store-privacy-transaction-');
      final path = '${root.path}/application.db';
      var writer = Store(path);
      try {
        writer.saveNote(null, 'Retained', 'Retained until commit');
        writer.db.execute('BEGIN IMMEDIATE');
        writer.db.execute('DELETE FROM notes');
        writer.markPrivacyMaintenancePending();
        writer.db.execute('ROLLBACK');
        writer.close();
        writer = Store(path);
        expect(writer.privacyMaintenancePending, isFalse);
        expect(writer.notes(), hasLength(1));

        writer.db.execute('BEGIN IMMEDIATE');
        writer.db.execute('DELETE FROM notes');
        writer.markPrivacyMaintenancePending();
        writer.db.execute('COMMIT');
        // Simulate termination after COMMIT but before compactAfterClear runs.
        writer.close();
        final view = Store.readOnly(path);
        expect(view.privacyMaintenancePending, isTrue);
        expect(view.notes(), isEmpty);
        view.close();
        writer = Store(path);
        expect(writer.privacyMaintenancePending, isTrue);
        expect(writer.notes(), isEmpty);
        await eventually(() => !writer.privacyMaintenancePending);
      } finally {
        if (!writer.db.autocommit) writer.db.execute('ROLLBACK');
        writer.close();
      }
    },
  );

  test(
    'deferred privacy maintenance survives close and writable reopen',
    () async {
      final root = createTestTempDirectorySync('store-privacy-reopen-');
      final path = '${root.path}/application.db';
      var writer = Store(path);
      final reader = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        writer.saveNote(null, 'Private', 'Private snapshot');
        reader.execute('BEGIN');
        reader.select('SELECT body FROM notes');
        writer.db.execute('DELETE FROM notes');
        writer.compactAfterClear();
        expect(writer.privacyMaintenancePending, isTrue);
        writer.close();
        writer = Store(path);
        expect(writer.privacyMaintenancePending, isTrue);
        expect(writer.notes(), isEmpty);
        reader.execute('COMMIT');
        await eventually(() => !writer.privacyMaintenancePending);
        expect(writer.notes(), isEmpty);
        expect(
          writer.rows(
            "SELECT 1 FROM preferences WHERE key='internal.privacyMaintenancePending'",
          ),
          isEmpty,
        );
      } finally {
        if (!reader.autocommit) reader.execute('ROLLBACK');
        reader.dispose();
        writer.close();
      }
    },
  );

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
