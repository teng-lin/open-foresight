import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/background_store.dart';
import 'package:open_foresight/store.dart';

void main() {
  test(
    'background source search finds body text and returns only IDs',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'background-search-',
      );
      final store = Store('${temporary.path}/application.db');
      try {
        final match = store.importText(
          'Planning',
          'Private needle in the body; ÉCOLE',
          'text/plain',
          'fixture',
        );
        store.importText(
          'Unrelated',
          'Different text',
          'text/plain',
          'fixture',
        );
        expect(await searchSourceIds(store.path, 'needle'), {match});
        expect(await searchSourceIds(store.path, 'PLANNING'), {match});
        expect(await searchSourceIds(store.path, 'école'), {match});
        expect(await searchSourceIds(store.path, 'missing'), isEmpty);
        expect(await localOutputWords(store.path), 0);
      } finally {
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
