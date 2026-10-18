import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/src/store.dart';

void main() {
  test(
    'original URI survives edits and reopen, including file punctuation',
    () {
      final temp = Directory.systemTemp.createTempSync('source-uri-');
      var store = Store('${temp.path}/app.db');
      final path = '${temp.path}/notes; final ü.txt';
      final uri = Uri.file(path).toString();
      final id = store.importText(
        'Notes',
        'First',
        'text/plain',
        'fixture',
        sourceUri: uri,
      );
      store.importText(
        'Notes',
        'Edited',
        'text/plain',
        'user edit; fixture',
        id: id,
      );
      store.db.dispose();
      store = Store('${temp.path}/app.db');
      expect(store.sources.single['source_uri'], uri);
      expect(
        Uri.parse(store.sources.single['source_uri'] as String).toFilePath(),
        path,
      );
      expect(store.sources.single['content'], 'Edited');
      expect(store.sources.single['revision'], 2);
      store.db.dispose();
      temp.deleteSync(recursive: true);
    },
  );

  test('legacy URI recovery preserves timestamps, revisions and labels', () {
    final temp = Directory.systemTemp.createTempSync('source-uri-legacy-');
    var store = Store('${temp.path}/app.db');
    final path = '${temp.path}/notes; final ü.txt';
    final file = store.importText(
      'File',
      'Local edit',
      'text/plain',
      'user edit; parser; $path',
    );
    final url = store.importText(
      'URL',
      'Web text',
      'text/plain',
      'url:https://example.test/item?q=a%20b',
    );
    store.db.execute('UPDATE sources SET revision=9');
    store.db.execute(
      "UPDATE source_details SET imported=123,changed=456,labels='[\"Team\"]'",
    );
    store.db.execute('ALTER TABLE source_details DROP COLUMN source_uri');
    store.db.execute('PRAGMA user_version=4');
    store.db.dispose();
    store = Store('${temp.path}/app.db');
    final rows = {for (final row in store.sources) row['id']: row};
    expect(rows[file]!['source_uri'], Uri.file(path).toString());
    expect(rows[url]!['source_uri'], 'https://example.test/item?q=a%20b');
    for (final row in rows.values) {
      expect(row['revision'], 9);
      expect(row['imported'], 123);
      expect(row['changed'], 456);
      expect(row['labels'], '["Team"]');
    }
    expect(rows[file]!['content'], 'Local edit');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    store.db.dispose();
    temp.deleteSync(recursive: true);
  });
}
