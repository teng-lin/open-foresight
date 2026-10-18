import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'package:foresight_core/foresight_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('legacy label repair runs once and tolerates malformed JSON', () {
    final directory = createTestTempDirectorySync('label-repair-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/app.db';
    var store = Store(path);
    final id = store.importText('Legacy', 'body', 'text/plain', 'fixture');
    store.labels(id, ['Keep me']);
    store.close();
    final legacy = sqlite3.open(path);
    legacy.execute('PRAGMA user_version=1');
    legacy.execute(
      "UPDATE source_details SET labels='broken' WHERE source_id=?",
      [id],
    );
    legacy.dispose();
    store = Store(path);
    expect(
      store.db.select('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    expect(store.documentLabels.single.name, 'Keep me');
    expect(jsonDecode(store.sources.single['labels'] as String), ['Keep me']);
    store.db.execute(
      "CREATE TRIGGER no_reconciliation BEFORE UPDATE OF labels ON source_details BEGIN SELECT RAISE(FAIL,'labels must not reconcile on reopen'); END",
    );
    store.close();
    store = Store(path);
    try {
      expect(store.documentLabels.single.name, 'Keep me');
    } finally {
      store.close();
    }
  });
}
