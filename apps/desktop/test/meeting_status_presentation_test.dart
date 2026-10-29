import 'desktop_fixture_owner.dart';
import 'package:open_foresight/features/meetings/recording_view.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/generated_content.dart';

import 'controller_fixture.dart';

void main() {
  testWidgets(
    'terminal recording status remains visible across tabs and clears on next capture',
    (tester) async => withDesktopFixtures(tester, () async {
      final f = await ControllerFixture.mount(tester);
      const message =
          'Capture interrupted: audio storage or capture failed. Saved audio is retained.';
      Future<void> publish(Map<String, dynamic> capture) async {
        f.connection.captureState = capture;
        f.shell.update(() => f.shell.meetingFeature.syncCapture());
        await tester.pump();
      }

      await publish({'active': false, 'state': message, 'error': message});
      expect(find.text(message), findsOneWidget);
      final notice = find.byType(RecordingStatusNotice);
      final colors = Theme.of(tester.element(notice)).colorScheme;
      Material noticeMaterial() => tester.widget<Material>(
        find.descendant(of: notice, matching: find.byType(Material)),
      );
      expect(noticeMaterial().color, colors.error);
      expect(
        tester
            .widget<SelectableText>(
              find.descendant(
                of: notice,
                matching: find.byType(SelectableText),
              ),
            )
            .style
            ?.color,
        colors.onError,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(
        tester.getRect(notice).bottom,
        tester.binding.renderViews.single.size.height,
      );
      f.shell.update(() => f.shell.navigate(WorkspaceTab.settings));
      await tester.pump();
      expect(find.text(message), findsOneWidget);
      expect(
        tester.getRect(notice).bottom,
        tester.binding.renderViews.single.size.height,
      );
      await publish({'active': true, 'state': 'Recording'});
      expect(find.text(message), findsNothing);
      expect(
        find.descendant(
          of: find.byType(RecordingStatusNotice),
          matching: find.text('Recording'),
        ),
        findsNothing,
      );
      await publish({
        'active': false,
        'state': 'Recording stopped after 15 minutes without audio.',
      });
      expect(
        find.text('Recording stopped after 15 minutes without audio.'),
        findsOneWidget,
      );
      expect(noticeMaterial().color, colors.surfaceContainerHigh);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      await publish({});
      expect(find.text('idle'), findsNothing);
    }),
  );

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
