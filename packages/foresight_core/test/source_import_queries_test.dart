import 'dart:typed_data';

import 'package:foresight_core/src/persistence/source_admission_queries.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Store store;
  late SourceAdmissionQueries queries;
  setUp(() {
    store = Store(':memory:');
    queries = SourceAdmissionQueries(store);
    addTearDown(store.close);
  });

  String source(String id, String uri, String provenance, {String? title}) =>
      store.importText(
        title ?? id,
        'original text',
        'text/plain',
        provenance,
        id: id,
        sourceUri: uri,
      );

  test('URI lookup ignores unrelated document bodies and deleted identities', () {
    const uri = 'file:///selected/notes%3B%20final.txt';
    source('wanted', uri, 'fixture');
    source('unrelated', 'file:///elsewhere', 'fixture');
    // An unreadable unrelated body cannot break identity admission. Reading the
    // old all-document facade would try to decode this value as source text.
    store.db.execute('UPDATE sources SET content=? WHERE id=?', [
      Uint8List.fromList([0, 255, 1]),
      'unrelated',
    ]);
    expect(queries.importIdForUri(uri), 'wanted');
    expect(queries.importIdForUri('file:///missing'), isNull);
    store.db.execute("UPDATE sources SET deleted=1 WHERE id='wanted'");
    expect(queries.importIdForUri(uri), isNull);
  });

  test(
    'URL admission preserves edited URL identity and ignores Drive imports',
    () {
      const uri = 'https://example.test/item?q=a%20b';
      source('drive', uri, 'google-drive:account:item', title: 'A');
      source('upper', uri, 'URL:$uri', title: 'B');
      source('substring', uri, 'fixture url:$uri', title: 'C');
      source('edited', uri, 'user edit; url:$uri', title: 'D');
      source('url', uri, 'url:$uri', title: 'E');
      expect(queries.importIdForUri(uri), 'drive');
      expect(queries.importIdForUri(uri, urlOnly: true), 'edited');
      store.db.execute("UPDATE sources SET deleted=1 WHERE id='edited'");
      expect(queries.importIdForUri(uri, urlOnly: true), 'url');
    },
  );

  test('URI lookup treats punctuation and SQL metacharacters literally', () {
    const uri = "file:///a_' OR 1=1--%25.txt";
    source('literal', uri, 'fixture');
    source('other', 'file:///other', 'fixture', title: 'A');
    expect(queries.importIdForUri(uri), 'literal');
    expect(queries.importIdForUri('$uri?changed'), isNull);
  });
}
