import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/native.dart';
import 'package:open_foresight/store.dart';
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
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'meeting-workspace-',
      );
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
      await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() => state.meetingId = id);
      await tester.pumpAndSettle();
      domain.generator = generator;
      expect(find.text('Live enhanced notes'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Live Q&A'), findsOneWidget);
      expect(find.text('Summary'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        'Mira draft Tuesday',
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
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
      await tester.tap(find.byTooltip('More meeting panels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transcript'));
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
      final snapshot = await domain.command('meetings.get', {'id': id}) as Map;
      final transcript = snapshot['transcript'] as List;
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
      await tester.tap(find.byTooltip('Close assistant'));
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
      final directory = Directory.systemTemp.createTempSync('meeting-layout-');
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
          child: Foresight(Domain(store, helper), deviceLoader: () async => []),
        ),
      );
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() => state.meetingId = id);
      for (final size in [
        const Size(1952, 1226),
        const Size(1280, 720),
        const Size(800, 700),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size.width == 800) {
          await tester.tap(find.text('Assistant'));
          await tester.pumpAndSettle();
          expect(find.text('Live Q&A'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      directory.deleteSync(recursive: true);
    },
  );
}
