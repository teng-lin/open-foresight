import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/settings/output_statistics.dart';
import 'package:open_foresight/features/sources/background_store.dart';
import 'package:foresight_core/src/store.dart';

void main() {
  test(
    'background output stats ignore empty and surrounding whitespace',
    () async {
      final temporary = createTestTempDirectorySync('background-words-');
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
        final stats = await localOutputStats(fixtureReader(store));
        expect(stats.words, 5);
        expect(stats.weekly, [0, 0, 0, 0, 5]);
      } finally {
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
  );

  test(
    'background source search finds body text and returns only IDs',
    () async {
      final temporary = createTestTempDirectorySync('background-search-');
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
        expect(await searchSourceIds(fixtureReader(store), 'needle'), {match});
        expect(await searchSourceIds(fixtureReader(store), 'PLANNING'), {
          match,
        });
        expect(await searchSourceIds(fixtureReader(store), 'école'), {match});
        expect(await searchSourceIds(fixtureReader(store), 'missing'), isEmpty);
        expect(await localOutputWords(fixtureReader(store)), 0);
      } finally {
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
