import 'store_reader_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/background_store.dart';
import 'package:foresight_core/src/store.dart';

void main() {
  test(
    'answers and artifacts share local calendar weeks and generation dates',
    () async {
      final root = createTestTempDirectorySync('output-calendar-');
      final store = Store('${root.path}/application.db');
      try {
        final now = DateTime(2026, 11, 2, 12); // Monday after US DST ends.
        final meeting = store.meeting('Created before generation');
        store.db.execute('UPDATE meeting_details SET created=0');
        void artifact(String text, DateTime? at) {
          store.artifact(meeting, 'summary', text, 'fixture');
          store.db.execute('UPDATE artifacts SET created=? WHERE id=?', [
            at?.millisecondsSinceEpoch,
            store.db.lastInsertRowId,
          ]);
        }

        artifact('current three words', DateTime(2026, 11, 2));
        artifact('previous two', DateTime(2026, 11, 1, 23, 59));
        artifact('oldest', outputWeekStart(now, weeksAgo: 4));
        artifact(
          'too old',
          outputWeekStart(
            now,
            weeksAgo: 4,
          ).subtract(const Duration(milliseconds: 1)),
        );
        artifact('unknown legacy', null);
        artifact('future artifact', now.add(const Duration(milliseconds: 1)));
        store.answer(
          'Question',
          'completed answer',
          'completed',
          [],
          'fixture',
        );
        store.db.execute('UPDATE answers SET created=?', [
          now.millisecondsSinceEpoch,
        ]);
        store.answer('Pending', 'not counted', 'streaming', [], 'fixture');
        store.answer('Future', 'future answer', 'completed', [], 'fixture');
        store.db.execute('UPDATE answers SET created=? WHERE id=?', [
          now.add(const Duration(milliseconds: 1)).millisecondsSinceEpoch,
          store.db.lastInsertRowId,
        ]);
        final stats = await localOutputStats(
          fixtureReader(store),
          nowMs: now.millisecondsSinceEpoch,
        );
        expect(stats.words, 16);
        expect(stats.weekly, [1, 0, 0, 2, 5]);
        expect(stats.weekly, store.weeklyOutputWords(now));
        expect(stats.words, store.localOutputWords);
        final nextWeek = await localOutputStats(
          fixtureReader(store),
          nowMs: DateTime(2026, 11, 9, 12).millisecondsSinceEpoch,
        );
        expect(nextWeek.weekly.last, 0);
        expect(
          nextWeek.weekly[3],
          9,
        ); // Future-dated entries are now in the past.
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
