import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import '../test_support/reader_admissions.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'store_reader_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'typed read admissions, service notifications and widget builds are measured separately',
    (tester) async {
      final root = createTestTempDirectorySync('reader-baseline-');
      final store = Store('${root.path}/app.db');
      store.importText(
        'Planning source',
        'Source body',
        'text/plain',
        'fixture',
      );
      store.meeting('Planning meeting');
      store.answer('Question', 'one two three', 'completed', [], 'fixture');
      final admissions = ReaderAdmissions();
      fixtureReader(store, admissions: admissions);
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final connection = TestDesktopConnection(
        Application(Domain(store, helper)),
      );
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        Foresight(connection, deviceLoader: () async => []),
      );
      await tester.pumpAndSettle();
      final dynamic shell = tester.state(find.byType(Workspace));
      final measurements = <String, Object?>{};
      for (final (label, tab) in [
        ('Sources', 0),
        ('Chat', 1),
        ('Meetings', 3),
        ('Stats', 5),
      ]) {
        shell.update(() => shell.tab = tab);
        await tester.pumpAndSettle();
        final before = admissions.snapshot();
        var notifications = 0;
        var widgetBuilds = 0;
        final oldCallback = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          oldCallback?.call(element, builtOnce);
          widgetBuilds++;
        };
        void changed() => notifications++;
        shell.serviceUiRevision.addListener(changed);
        try {
          for (var i = 0; i < 20; i++) helper.changed?.call();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          expect(
            notifications,
            1,
            reason: '$label coalesces coarse service events',
          );
          expect(widgetBuilds, greaterThan(0));
          measurements[label] = {
            'before': before,
            'after': admissions.snapshot(),
            'service_ui_notifications': notifications,
            'widget_builds': widgetBuilds,
          };
        } finally {
          shell.serviceUiRevision.removeListener(changed);
          debugOnRebuildDirtyWidget = oldCallback;
        }
      }
      expect(admissions.synchronous['sourceSummaries'], greaterThan(0));
      // This baseline deliberately records existing synchronous projections. It
      // must not equate a Store.rows spy with absent SQLite work.
      final report = Platform.environment['FORESIGHT_DESKTOP_READ_BASELINE'];
      if (report != null)
        File(report).writeAsStringSync(jsonEncode(measurements));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      var closed = false;
      unawaited(
        connection.closed.then<void>((_) {
          closed = true;
        }),
      );
      await pumpUntil(tester, () => closed);
      expect(tester.takeException(), isNull);
    },
  );
}
