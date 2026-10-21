import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'package:foresight_core/src/application.dart';
import 'pump_until.dart';
import 'dart:async';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart' show NativeRuntime;
import 'package:open_foresight/main.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/store.dart';
import 'package:open_foresight/generated_content.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class WidgetNoteGenerator extends NativeRuntime {
  @override
  bool get loaded => true;
  WidgetNoteGenerator()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  // Ownership transfers to the transport or test teardown.
  // ignore: close_sinks
  final events = StreamController<Map<String, dynamic>>();
  final entered = Completer<void>();
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    var text = '';
    entered.complete();
    await for (final event in events.stream) {
      if (event['type'] == 'delta') {
        text += event['text'] as String;
        yield {'type': 'preview', 'text': text};
      } else if (event['type'] == 'done') {
        yield {'type': 'delta', 'text': text};
        yield event;
        break;
      } else {
        yield event;
      }
    }
  }
}

void main() {
  testWidgets(
    'local editor streams content and cancel restores the exact previous notes',
    (tester) async {
      final directory = createTestTempDirectorySync('note-stream-widget-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final time = FakeAsync();
      final store = Store('${directory.path}/app.db');
      store.setPreference('liveEnhance', 'false');
      final id = store.meeting('Meeting');
      store.saveMeetingNotes(id, 'Raw notes');
      store.transcript(id, 'Transcript evidence', true, 0, 10, 'imported');
      store.artifact(
        id,
        'enhanced_notes',
        '# Heading\n- Old\n💡 Retained\n# Potential Important Topics Not In Notes\n- Excluded',
        'fixture',
      );
      final domain = Domain(
        store,
        OfflineHelper('${directory.path}/sock', '${directory.path}/helper'),
        clock: time.getClock(DateTime.utc(2026)),
        createTimer: (duration, callback) =>
            time.run((_) => Timer(duration, callback)),
      );
      final app = Application(domain);
      final generator = WidgetNoteGenerator();
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
      );
      final dynamic state = tester.state(find.byType(Workspace));
      Future<void> waitForUi(bool Function() ready) async {
        final elapsed = Stopwatch()..start();
        while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
          await tester.runAsync(() => Future<void>(() {}));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          ready(),
          isTrue,
          reason: 'Throttled service state must reach the visible editor',
        );
      }

      state.update(() => state.meetingFeature.meetingId = id);
      await tester.pumpAndSettle();
      domain.generator = generator;
      late Future<void> work;
      await tester.runAsync(() async {
        work = app.enhanceNotes(id);
      });
      await pumpUntil(tester, () => generator.entered.isCompleted);
      await waitForUi(
        () => find
            .byKey(const ValueKey('cancel-note-enhancement'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('cancel-note-enhancement')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is GeneratedContent && widget.markdown == '- Old',
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        generator.events.add({'type': 'delta', 'text': '- Streamed first'});
      });
      await waitForUi(
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is GeneratedContent &&
                  widget.markdown == '- Streamed first',
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is GeneratedContent &&
              widget.markdown == '- Streamed first',
        ),
        findsOneWidget,
      );
      time.elapse(const Duration(seconds: 1));
      await tester.pump();
      expect(store.meetingEnhancedNotes(id), '- Streamed first');
      expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
      final cancel = find.byKey(const ValueKey('cancel-note-enhancement'));
      await tester.ensureVisible(cancel);
      await tester.pump();
      await tester.tap(cancel);
      await tester.pump();
      expect(
        (app.captureState['note_enhancements']
            as Map)['$id']['cancel_requested'],
        isTrue,
      );
      await tester.runAsync(() async {
        generator.events.add({'type': 'delta', 'text': ' ignored'});
      });
      await waitForUi(
        () => find
            .byKey(const ValueKey('cancel-note-enhancement'))
            .evaluate()
            .isEmpty,
      );
      await tester.runAsync(() => work);
      expect(
        find.byKey(const ValueKey('cancel-note-enhancement')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is GeneratedContent &&
              widget.markdown ==
                  '# Heading\n- Old\n💡 Retained\n# Potential Important Topics Not In Notes\n- Excluded',
        ),
        findsOneWidget,
      );
      time.elapse(const Duration(seconds: 1));
      await tester.pump();
      expect(
        store.meetingEnhancedNotes(id),
        '# Heading\n- Old\n💡 Retained\n# Potential Important Topics Not In Notes\n- Excluded',
      );
      expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
      await tester.runAsync(() => generator.events.close());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
