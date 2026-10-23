import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';

import 'desktop_connection_fixture.dart';
import 'pump_until.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

class NotesRuntime extends NativeRuntime {
  @override
  bool get loaded => true;
  String prompt = '';
  NotesRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    Duration timeout = const Duration(minutes: 5),
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
  }) async* {
    this.prompt = prompt;
    yield {'type': 'delta', 'text': '- Mira will send the draft on Tuesday.'};
    yield {'type': 'done', 'status': 'completed'};
  }
}

void main() {
  testWidgets(
    'meeting workspace preserves notes and offers functional assistant panels',
    (tester) async {
      await (FontLoader(
        'GoogleSans',
      )..addFont(rootBundle.load('assets/fonts/GoogleSans-Medium.ttf'))).load();
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('meeting-workspace-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final id = store.meeting('[New Meeting]');
      store.transcript(
        id,
        'Mira will send the draft on Tuesday. Who sends the draft?',
        true,
        0,
        1000,
        'microphone; captured-sample timeline (gaps excluded)',
      );
      store.transcript(
        id,
        'The remote channel confirms the date.',
        true,
        1100,
        2000,
        'playback; captured-sample timeline (gaps excluded)',
      );
      store.transcript(
        id,
        'Imported background context.',
        true,
        2000,
        3000,
        'imported',
      );
      final helper = OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      final generator = NotesRuntime();
      final domain = Domain(store, helper);
      final app = Application(domain);
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
      );
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      state.update(() => state.meetingFeature.meetingId = id);
      await tester.pumpAndSettle();
      domain.generator = generator;
      expect(find.text('Live enhanced notes'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Live Q&A'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Transcript'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        'Mira draft Tuesday',
      );
      await tester.pump(const Duration(seconds: 31));
      await pumpUntil(
        tester,
        () =>
            generator.prompt.isNotEmpty &&
            (app.captureState['note_enhancements'] as Map).values.every(
              (value) => (value as Map)['active'] != true,
            ),
      );
      await tester.pumpAndSettle();
      expect(
        store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).single['body'],
        'Mira draft Tuesday',
      );
      expect(generator.prompt, contains('Mira draft Tuesday'));
      expect(generator.prompt, contains('<shorthand_notes>'));
      expect(generator.prompt, contains('<relevant_excerpts>'));
      expect(
        generator.prompt,
        contains('Mira will send the draft on Tuesday.'),
      );
      expect(find.text('Mira will send the draft on Tuesday.'), findsOneWidget);
      await tester.tap(find.text('Live Q&A'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Answer this question'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Transcript'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Microphone', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Remote\n', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Unknown\n', findRichText: true),
        findsOneWidget,
      );
      final snapshot =
          await app.call(Operation.meetingsGet.wire, {'id': id}) as Map;
      final transcript = (snapshot['transcript'] as List).cast<Map>();
      expect(transcript.map((t) => t['speaker_id']), [0, 1, null]);
      expect(transcript.map((t) => t['speaker_label']), [
        'Microphone',
        'Remote',
        'Unknown',
      ]);
      expect(transcript.map((t) => t['source']), [
        'microphone; captured-sample timeline (gaps excluded)',
        'playback; captured-sample timeline (gaps excluded)',
        'imported',
      ]);
      await tester.tap(find.byTooltip('Hide assistant'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Open assistant'), findsOneWidget);
      await tester.tap(find.byTooltip('Open assistant'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close assistant'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      final reopened = Store('${directory.path}/app.db');
      expect(
        reopened.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).single['body'],
        'Mira draft Tuesday',
      );
      expect(
        reopened
            .rows("SELECT * FROM artifacts WHERE kind='enhanced_notes'")
            .length,
        1,
      );
      reopened.close();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'transcription workspace adapts to narrow windows and matches wide reference structure',
    (tester) async {
      final fonts = FontLoader('GoogleSans')
        ..addFont(rootBundle.load('assets/fonts/GoogleSans-Regular.ttf'));
      await fonts.load();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('meeting-layout-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final id = store.meeting('[New Meeting]');
      final helper = OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      const boundary = ValueKey('meeting-layout-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: Foresight(
            TestDesktopConnection(Application(Domain(store, helper))),
            deviceLoader: () async => [],
          ),
        ),
      );
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      state.update(() => state.meetingFeature.meetingId = id);
      for (final size in [
        const Size(1952, 1226),
        const Size(1280, 720),
        const Size(800, 700),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Meeting options'), findsNothing);
        expect(find.byTooltip('Full screen'), findsNothing);
        final toggle = tester.getRect(
          find.byKey(const ValueKey('meeting-assistant-toggle')),
        );
        final enhance = tester.getRect(
          find.byKey(const ValueKey('meeting-live-enhance')),
        );
        expect(toggle.left, enhance.right + 8);
        expect(toggle.center.dy, enhance.center.dy);
        if (size.width == 800) {
          expect(find.text('Live Q&A'), findsNothing);
          expect(find.byTooltip('Open assistant'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('meeting-notes-editor')),
            findsOneWidget,
          );
          expect(find.text('Assistant'), findsNothing);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'opening a hidden assistant enlarges the window and retains the selected panel',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('meeting-window-');
      final store = Store('${root.path}/app.db');
      final id = store.meeting('Window resize');
      final requests = <MethodCall>[];
      const channel = MethodChannel('foresight/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        requests.add(call);
        final width = (call.arguments as Map)['width'] as double;
        tester.view.physicalSize = Size(width.ceilToDouble(), 700);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
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
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        state.update(() {
          state.meetingFeature.meetingId = id;
          state.meetingFeature.meetingPanel = 'Transcript';
        });
        await tester.pumpAndSettle();
        final notes = find.byKey(const ValueKey('meeting-notes-editor'));
        await tester.enterText(notes, 'Keep these notes while resizing.');
        await tester.tap(find.byTooltip('Open assistant'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(requests.single.method, 'ensureWidth');
        expect(tester.view.physicalSize.width, greaterThan(800));
        expect(tester.view.physicalSize.height, 700);
        expect(find.byTooltip('Copy full transcript'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Transcript'), findsOneWidget);
        expect(
          tester.widget<TextField>(notes).controller!.text,
          'Keep these notes while resizing.',
        );
        expect(find.byTooltip('Open assistant'), findsNothing);

        // A manual close persists across resizing, and reopening a wide window
        // does not request another native resize.
        await tester.tap(find.byTooltip('Close assistant'));
        tester.view.physicalSize = const Size(1280, 700);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Open assistant'), findsOneWidget);
        await tester.tap(find.byTooltip('Open assistant'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(find.byTooltip('Copy full transcript'), findsOneWidget);
        tester.view.physicalSize = const Size(800, 700);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Open assistant'), findsOneWidget);
        expect(find.byTooltip('Copy full transcript'), findsNothing);
        tester.view.physicalSize = const Size(1280, 700);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Copy full transcript'), findsOneWidget);
        expect(state.meetingFeature.meetingPanel, 'Transcript');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final denied in [false, true]) {
    testWidgets(
      'assistant can still open when window resizing is ${denied ? 'rejected' : 'ignored'}',
      (tester) async {
        tester.view.physicalSize = const Size(640, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final root = createTestTempDirectorySync('meeting-window-fallback-');
        final store = Store('${root.path}/app.db');
        final id = store.meeting('Small display');
        const channel = MethodChannel('foresight/window');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (denied) throw PlatformException(code: 'resize_denied');
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
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
          final state =
              tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
          state.update(() => state.meetingFeature.meetingId = id);
          await tester.pumpAndSettle();
          final notes = find.byKey(const ValueKey('meeting-notes-editor'));
          await tester.enterText(notes, 'Preserve the draft.');
          await tester.tap(find.byTooltip('Open assistant'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Close assistant'), findsOneWidget);
          expect(notes, findsNothing);
          // A compositor can apply a late resize capped below the requested
          // width. Keep the fallback open until the sidecar actually fits.
          tester.view.physicalSize = const Size(720, 700);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Close assistant'), findsOneWidget);
          expect(notes, findsNothing);
          await tester.tap(find.byTooltip('Close assistant'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(notes).controller!.text,
            'Preserve the draft.',
          );
          expect(find.byTooltip('Open assistant'), findsOneWidget);

          await tester.tap(find.byTooltip('Open assistant'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(1280, 700);
          await tester.pumpAndSettle();
          expect(notes, findsOneWidget);
          expect(find.byTooltip('Close assistant'), findsOneWidget);
          tester.view.physicalSize = const Size(640, 700);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Open assistant'), findsOneWidget);
          expect(find.byTooltip('Close assistant'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}
