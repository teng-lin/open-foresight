import 'package:open_foresight/shell/workspace_tab.dart';
import '../test_support/core_fixture.dart';
import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_foresight/main.dart';
import 'package:open_foresight/model_setup.dart';

import 'package:open_foresight/features/settings/speech_setup_view.dart';
import '../test_support/meeting_panel.dart';

class OfflineHelper extends Helper {
  OfflineHelper(super.socket, super.storage);
  @override
  Future<void> start() async {
    state = 'disconnected';
  }
}

void main() {
  testWidgets('summary labels artifacts from older meeting revisions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = createTestTempDirectorySync('stale-summary-ui-');
    final store = Store('${root.path}/application.db');
    final id = store.meeting('Meeting');
    store.artifact(id, 'summary', 'Earlier summary', 'fixture');
    store.transcript(id, 'New transcript', true, 0, 100, 'imported');
    final helper = OfflineHelper('${root.path}/sock', '${root.path}/helper');
    await tester.pumpWidget(
      Foresight(
        TestDesktopConnection(Application(Domain(store, helper))),
        deviceLoader: () async => [],
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
    state.update(() {
      state.navigate(WorkspaceTab.meetings);
      state.meetingFeature.meetingId = id;
      state.meetingFeature.meetingPanel = 'Summary';
    });
    await tester.pumpAndSettle();
    expect(find.text('Out of date — regenerate'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets(
    'meeting workflow opens summary and targets its scoped chat input',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('meeting-panels-');
      final store = Store('${directory.path}/app.db');
      final helper = OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(Domain(store, helper))),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();
      final workspace =
          tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      final meeting = workspace.meetingFeature.meetingId as int;
      expect(find.text('Summary'), findsNothing);
      await selectMeetingPanel(tester, 'Summary');
      expect(find.byTooltip('Generate Summary'), findsOneWidget);
      await selectMeetingPanel(tester, 'Chat');
      final chat = find.byKey(ValueKey('chat-input:meeting:$meeting'));
      await tester.enterText(chat, 'Question about the meeting');
      expect(
        tester.widget<TextField>(chat).controller!.text,
        'Question about the meeting',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('meeting-notes-editor')),
            )
            .controller!
            .text,
        isEmpty,
      );
      store.answer(
        'Question about the meeting',
        List.filled(
          30,
          'A detailed answer about the recorded meeting.',
        ).join('\n\n'),
        'completed',
        [
          {
            'citation': 'S1',
            'document_id': 'archived-meeting-source',
            'revision': 1,
            'excerpt': 'Recorded source excerpt',
          },
        ],
        'fixture',
        conversation: 'meeting:$meeting',
      );
      store.db.execute(
        'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
        [meeting, store.db.lastInsertRowId],
      );
      helper.changed?.call();
      workspace.update(() {});
      await tester.pumpAndSettle();
      expect(find.text('[S1] source revision 1').hitTestable(), findsNothing);
      await openMeetingCitation(tester, meeting, 1);
      expect(
        find.text('Archived citation: source changed or deleted'),
        findsOneWidget,
      );
      expect(find.text('Recorded source excerpt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'meeting recording requires setup and opens speech setup instead of throwing',
    (tester) async {
      final directory = createTestTempDirectorySync('meeting-setup-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final helper = OfflineHelper(
        '${directory.path}/helper.sock',
        '${directory.path}/helper',
      );
      await tester.pumpWidget(
        Foresight(
          TestDesktopConnection(Application(Domain(store, helper))),
          deviceLoader: () async => [],
        ),
      );
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New meeting'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Meeting options'), findsNothing);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechSetupDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.text('Set up a speech model and runner before recording.'),
        findsOneWidget,
      );
      expect(find.textContaining('Bad state'), findsNothing);
      await tester.tap(find.text('Set up speech'));
      await tester.pumpAndSettle();
      final choice = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(choice.value, 'speech');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      directory.deleteSync(recursive: true);
    },
  );

  test(
    'registered missing runner is reported as incomplete speech setup',
    () async {
      final directory = createTestTempDirectorySync('meeting-model-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final model = File('${directory.path}/speech.model')
        ..writeAsStringSync('control flow fixture');
      await store.register(
        'speech',
        model.path,
        '${directory.path}/missing-runner',
      );
      expect(
        speechSetupProblem(fixtureReader(store)),
        contains('runner is missing'),
      );
      store.close();
      directory.deleteSync(recursive: true);
    },
  );
}
