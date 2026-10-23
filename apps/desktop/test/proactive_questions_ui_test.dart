import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import '../test_support/core_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    'Live Q&A shows meeting-owned automatic answers, preserves Markdown copy, retries and settings',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('proactive-ui-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final domain = Domain(
        store,
        OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
      );
      final app = Application(domain);
      final id = store.meeting('Automatic fixture');
      final other = store.meeting('Other meeting');
      int seed(int meeting, String question, String state, {String? body}) {
        store.transcript(meeting, question, true, 0, 1000, 'microphone');
        final transcript = store.db.lastInsertRowId;
        int? answer;
        if (body != null) {
          store.answer(
            question,
            body,
            'completed',
            [],
            'fixture',
            conversation: 'meeting:$meeting',
          );
          answer = store.db.lastInsertRowId;
        }
        store.db.execute(
          'INSERT INTO meeting_questions(meeting_id,transcript_id,question,normalized,state,answer_id,error,created) VALUES(?,?,?,?,?,?,?,?)',
          [
            meeting,
            transcript,
            question,
            question,
            state,
            answer,
            state == 'failed' ? 'Fixture generation failure' : '',
            0,
          ],
        );
        return store.db.lastInsertRowId;
      }

      const markdown = '**Mira** owns the draft.';
      seed(id, 'Who owns the draft?', 'completed', body: markdown);
      final failed = seed(id, 'What is next?', 'failed');
      seed(id, 'Who?', 'superseded');
      seed(
        other,
        'Unrelated question?',
        'completed',
        body: 'Other meeting answer',
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
          Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
        );
        final workspace =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        workspace.update(() {
          workspace.meetingFeature.meetingId = id;
          workspace.meetingFeature.meetingPanel = 'Live Q&A';
        });
        await tester.pumpAndSettle();
        expect(find.text('Automatic · Answered'), findsOneWidget);
        expect(find.text('Automatic · Could not answer'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Automatic · Replaced by an updated question'),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        expect(
          find.text('Automatic · Replaced by an updated question'),
          findsOneWidget,
        );
        expect(
          find.text('Other meeting answer', findRichText: true),
          findsNothing,
        );
        await tester.scrollUntilVisible(
          find.byTooltip('Copy automatic answer'),
          -150,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.byTooltip('Copy automatic answer'));
        await tester.pump();
        expect(copied, markdown);
        await tester.tap(find.text('Automatic answers'));
        await tester.pumpAndSettle();
        expect(store.preference('proactiveAnswers'), 'false');
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(
          store.rows('SELECT state FROM meeting_questions WHERE id=?', [
            failed,
          ]).single['state'],
          'queued',
        );
        expect(find.text('Automatic · Waiting'), findsOneWidget);
        await tester.tap(find.text('Automatic answers'));
        await tester.pumpAndSettle();
        expect(store.preference('proactiveAnswers'), 'true');
        for (final width in [800.0, 640.0]) {
          tester.view.physicalSize = Size(width, 850);
          await tester.pumpAndSettle();
          if (find.text('Assistant').evaluate().isNotEmpty) {
            await tester.tap(find.text('Assistant'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }
      } finally {
        await app.close();
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        directory.deleteSync(recursive: true);
      }
    },
  );
}
