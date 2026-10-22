import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class BodyReadCountingStore extends Store {
  int outputBodyReads = 0;
  BodyReadCountingStore(super.path);
  @override
  List<Map<String, Object?>> rows(String sql, [List<Object?> args = const []]) {
    final query = sql.toLowerCase();
    if ((query.contains('from answers') && query.contains('body')) ||
        (query.contains('from artifacts') && query.contains('generated'))) {
      outputBodyReads++;
    }
    return super.rows(sql, args);
  }
}

void main() {
  testWidgets(
    'visible Stats caches background word aggregates across service events',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temporary = createTestTempDirectorySync('stats-background-');
      final store = BodyReadCountingStore('${temporary.path}/application.db');
      store.answer('Question', 'one two three', 'completed', [], 'fixture');
      final helper = OfflineHelper(
        '${temporary.path}/helper.sock',
        '${temporary.path}/helper',
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(Domain(store, helper))),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Stats').first);
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      Future<void> waitForCount(int expected) async {
        for (
          final elapsed = Stopwatch()..start();
          elapsed.elapsed < const Duration(seconds: 5) &&
              state.settingsFeature.localOutputCount != expected;
        ) {
          await tester.runAsync(() => Future<void>(() {}));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(state.settingsFeature.localOutputCount, expected);
      }

      await waitForCount(3);
      await tester.pumpAndSettle();
      expect(state.settingsFeature.localOutputWeekly, [0, 0, 0, 0, 3]);
      expect(store.outputBodyReads, 0);
      final cachedWeeks = state.settingsFeature.localOutputWeekly;
      for (var i = 0; i < 20; i++) {
        helper.changed?.call();
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(
        identical(state.settingsFeature.localOutputWeekly, cachedWeeks),
        true,
      );
      expect(store.outputBodyReads, 0);
      store.db.execute("UPDATE answers SET body='one two three four'");
      helper.changed?.call();
      await tester.pump(const Duration(milliseconds: 100));
      await waitForCount(4);
      expect(state.settingsFeature.localOutputWeekly, [0, 0, 0, 0, 4]);
      expect(store.outputBodyReads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      temporary.deleteSync(recursive: true);
    },
  );
}
