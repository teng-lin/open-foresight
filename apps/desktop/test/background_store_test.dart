import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/background_store.dart';
import 'package:open_foresight/store.dart';

void main() {
  test(
    'background output stats ignore empty and surrounding whitespace',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'background-words-',
      );
      final store = Store('${temporary.path}/application.db');
      try {
        for (final body in ['', ' \t ', '  one\ntwo  ']) {
          store.answer('Question', body, 'completed', [], 'fixture');
        }
        store.answer('Pending', 'not counted', 'streaming', [], 'fixture');
        final meeting = store.meeting('Fixture');
        store.artifact(meeting, 'summary', ' three\t four five ', 'fixture');
        store.artifact(meeting, 'questions', '', 'fixture');
        store.artifact(meeting, 'actions', ' \n ', 'fixture');
        final stats = await localOutputStats(store.path);
        expect(stats.words, 5);
        expect(stats.weekly, [0, 0, 0, 0, 2]);
      } finally {
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
  );

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
