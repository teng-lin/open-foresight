import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'package:foresight_core/src/graph_labels.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'canonical label order survives metadata edits, reorder, VACUUM and reopen',
    () {
      final root = createTestTempDirectorySync('canonical-labels-');
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}/application.db';
      var store = Store(path);
      final id = store.importText('Title', 'Body', 'text/plain', 'fixture');
      store.labels(id, ['Z', 'A', 'Z']);
      store.putDocumentLabel(
        DocumentLabel(id, 'A', 'automatic', '#123456', 'Evidence'),
      );
      expect(jsonDecode(store.sources.single['labels'] as String), ['Z', 'A']);
      store.labels(id, ['A', 'Z', 'A']);
      final expected = store.graphLabelSet();
      expect(jsonDecode(store.sources.single['labels'] as String), ['A', 'Z']);
      expect(store.documentLabels.first.rationale, 'Evidence');
      store.db.execute('VACUUM');
      expect(store.graphLabelSet(), expected);
      store.close();
      store = Store(path);
      try {
        expect(store.graphLabelSet(), expected);
        expect(jsonDecode(store.sourceSummaries.single['labels'] as String), [
          'A',
          'Z',
        ]);
        expect(
          store
              .rows('PRAGMA table_info(source_details)')
              .map((row) => row['name']),
          isNot(contains('labels')),
        );
        store.db.execute(
          "CREATE TRIGGER fail_reorder BEFORE UPDATE ON document_labels WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'fixture'); END",
        );
        expect(
          () => store.labels(id, ['Z', 'A']),
          throwsA(isA<SqliteException>()),
        );
        expect(store.graphLabelSet(), expected);
      } finally {
        store.close();
      }
    },
  );
}
