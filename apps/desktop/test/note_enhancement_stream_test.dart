import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart' show NativeRuntime;
import 'package:open_foresight/main.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated_content.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class WidgetNoteGenerator extends NativeRuntime {
  @override
  bool get loaded => true;
  WidgetNoteGenerator()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final events = StreamController<Map<String, dynamic>>();
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
    'local editor streams content and cancel restores formatted prior notes',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'note-stream-widget-',
      );
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
      );
      final generator = WidgetNoteGenerator();
      await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() => state.meetingId = id);
      await tester.pumpAndSettle();
      domain.generator = generator;
      late Future<void> work;
      await tester.runAsync(() async {
        work = domain.application.enhanceNotes(id);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
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
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is GeneratedContent &&
              widget.markdown == '- Streamed first',
        ),
        findsOneWidget,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump();
      expect(store.meetingEnhancedNotes(id), '- Streamed first');
      expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('cancel-note-enhancement')));
      await tester.pump();
      expect(
        (domain.application.captureState['note_enhancements']
            as Map)['$id']['cancel_requested'],
        isTrue,
      );
      await tester.runAsync(() async {
        generator.events.add({'type': 'delta', 'text': ' ignored'});
        await work;
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey('cancel-note-enhancement')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is GeneratedContent &&
              widget.markdown == '- Old\n\n💡 Retained',
        ),
        findsOneWidget,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump();
      expect(store.meetingEnhancedNotes(id), '- Old\n\n💡 Retained');
      expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
      await tester.runAsync(() => generator.events.close());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      directory.deleteSync(recursive: true);
    },
  );
}
