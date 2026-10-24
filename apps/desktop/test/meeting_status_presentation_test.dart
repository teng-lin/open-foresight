import 'desktop_fixture_owner.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/generated_content.dart';

import 'controller_fixture.dart';

void main() {
  testWidgets(
    'capture elapsed fallback distinguishes missing time from an explicit zero',
    (tester) async => withDesktopFixtures(tester, () async {
      final f = await ControllerFixture.mount(tester);
      final feature = f.shell.meetingFeature;
      final began = DateTime.now().subtract(const Duration(seconds: 10));
      f.connection.captureState = {
        'active': true,
        'began': began.millisecondsSinceEpoch,
      };
      feature.syncCapture();
      expect(
        feature.recordingElapsed,
        Duration(
          milliseconds:
              (feature.recordingElapsedAt).millisecondsSinceEpoch -
              began.millisecondsSinceEpoch,
        ),
      );
      f.connection.captureState = {
        ...f.connection.captureState,
        'elapsed_ms': 0,
      };
      feature.syncCapture();
      expect(feature.recordingElapsed, Duration.zero);
      f.connection.captureState = {};
      feature.syncCapture();
      expect(feature.recording, isNull);
      expect(feature.recordingElapsed, Duration.zero);
    }),
  );

  testWidgets(
    'missing note preview falls back to accepted notes while explicit empty preview stays empty',
    (tester) async => withDesktopFixtures(tester, () async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Typed notes');
      f.store.artifact(id, 'enhanced_notes', 'Accepted notes', 'fixture');
      f.store.saveMeetingNotes(id, 'Raw notes');
      final feature = f.shell.meetingFeature;
      Future<void> publish(Map<String, Object?> preview) async {
        f.connection.captureState = {
          'note_enhancements': {'$id': preview},
        };
        f.shell.update(() {
          f.shell.navigate(WorkspaceTab.meetings);
          feature.meetingId = id;
          feature.syncCapture();
        });
        await tester.pump();
      }

      await publish({'active': true, 'request_id': 'typed-request'});
      expect(
        tester.widget<GeneratedContent>(find.byType(GeneratedContent)).markdown,
        'Accepted notes',
      );
      await publish({
        'active': true,
        'request_id': 'typed-request',
        'body': '',
      });
      expect(
        tester.widget<GeneratedContent>(find.byType(GeneratedContent)).markdown,
        '',
      );
      await publish({
        'active': true,
        'request_id': 'typed-request',
        'body': 'Current preview',
      });
      expect(
        tester.widget<GeneratedContent>(find.byType(GeneratedContent)).markdown,
        'Current preview',
      );
      await tester.pumpWidget(const SizedBox());
    }),
  );
}
