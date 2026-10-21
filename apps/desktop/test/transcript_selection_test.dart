import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'whole transcript selects and copies every saved segment, including offscreen text',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('transcript-selection-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/application.db');
      final meeting = store.meeting('Selection fixture');
      final other = store.meeting('Other meeting');
      final segments = List.generate(
        80,
        (i) => 'Segment $i: 中文 and English, preserved exactly.',
      );
      for (var i = 0; i < segments.length; i++) {
        store.transcript(
          meeting,
          segments[i],
          true,
          i * 1000,
          (i + 1) * 1000,
          i.isEven ? 'microphone' : 'playback',
        );
      }
      store.transcript(
        other,
        'Other meeting must not be copied',
        true,
        0,
        1000,
        'microphone',
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(
              Application(
                Domain(
                  store,
                  OfflineHelper('${root.path}/socket', '${root.path}/helper'),
                ),
              ),
            ),
            deviceLoader: () async => [],
          ),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        state.update(() {
          state.meetingFeature.meetingId = meeting;
          state.meetingFeature.meetingPanel = 'Transcript';
        });
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy full transcript'));
        await tester.pump();
        expect(copied, segments.join('\n\n'));
        final transcript = find.byKey(ValueKey('meeting-transcript-$meeting'));
        final editable = find.descendant(
          of: transcript,
          matching: find.byType(EditableText),
        );
        final field = tester.widget<EditableText>(editable);
        field.focusNode.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(field.controller.selection.start, 0);
        expect(field.controller.selection.end, field.controller.text.length);
        expect(field.controller.text, contains(segments.last));
        expect(
          field.controller.text,
          isNot(contains('Other meeting must not be copied')),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        root.deleteSync(recursive: true);
      }
    },
  );
}
