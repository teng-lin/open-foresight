import 'desktop_fixture_owner.dart';
import 'dart:async';
import '../test_support/core_fixture.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';

import 'package:open_foresight/generated_content.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'note_enhancement_stream_test.dart' show WidgetNoteGenerator;

void main() {
  testWidgets(
    'completed enhancement replaces the visible draft without navigation',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('enhance-complete-');
      final time = FakeAsync();
      final store = Store('${root.path}/application.db');
      store.setPreference('liveEnhance', 'false');
      final id = store.meeting('Synthetic Juniper');
      store.saveMeetingNotes(id, 'Juniper owner Mira; launch Nov 7');
      store.transcript(
        id,
        'Mira Chen owns Project Juniper. Launch: 7 November 2026.',
        true,
        0,
        1000,
        'imported',
      );
      final helper = OfflineHelper(
        '${root.path}/socket',
        '${root.path}/helper',
      );
      final domain = Domain(
        store,
        helper,
        clock: time.getClock(DateTime(2026)),
        createTimer: (duration, callback) =>
            time.run((_) => Timer(duration, callback)),
      );
      final app = Application(domain);
      final generator = WidgetNoteGenerator();
      try {
        await tester.pumpWidget(
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        state.update(() => state.meetingFeature.meetingId = id);
        await tester.pumpAndSettle();
        domain.generator = generator;
        late Future<void> work;
        await tester.runAsync(() async {
          work = app.enhanceNotes(id);
        });
        await waitForUi(tester, () => generator.entered.isCompleted);
        await tester.runAsync(() async {
          generator.events.add({
            'type': 'delta',
            'text': '- Juniper owner: Mira Chen; launch: 7 November 2026.',
          });
        });
        await waitForUi(
          tester,
          () => find
              .byWidgetPredicate(
                (w) =>
                    w is GeneratedContent && w.markdown.contains('Mira Chen'),
              )
              .evaluate()
              .isNotEmpty,
        );
        await tester.runAsync(() async {
          generator.events.add({'type': 'done', 'status': 'completed'});
        });
        await waitForUi(tester, () => !state.meetingFeature.meetingEnhancing);
        await tester.runAsync(() => work);
        expect(store.meetingEnhancedNotes(id), contains('7 November 2026'));
        expect(store.enhancedNoteArtifacts(id), hasLength(1));
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is GeneratedContent &&
                w.markdown == store.meetingEnhancedNotes(id),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('cancel-note-enhancement')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() => generator.events.close());
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        root.deleteSync(recursive: true);
      }
    }),
  );
}

Future<void> waitForUi(WidgetTester tester, bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>(() {}));
  }
  expect(ready(), isTrue);
  await tester.pump();
}
