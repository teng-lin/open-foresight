import 'package:open_foresight/shell/workspace_tab.dart';
import '../test_support/core_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:foresight_test_support/test_paths.dart';

import 'package:open_foresight/main.dart';

import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets('another client\'s clear closes the editors that hold its IDs', (
    tester,
  ) async {
    final fixture = RemoteFixture();
    await tester.runAsync(fixture.start);
    addTearDown(() => tester.runAsync(fixture.close));
    fixture.handler = (socket, request) => fixture.reply(socket, request, null);
    await tester.pumpWidget(
      Foresight(fixture.remote, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
    state.update(() {
      state.sourceFeature.noteId = 3;
      state.sourceFeature.noteTitle.text = 'Note 3';
      state.sourceFeature.noteBody.text = 'Body of note 3';
    });
    // The clear commits to the profile before its event arrives.
    fixture.owner.renewWorkspaceEpoch();
    final cleared = fixture.owner.workspaceEpoch;
    fixture.event({...fixture.status, 'workspace_epoch': cleared});
    await pumpUntil(tester, () => state.sourceFeature.noteId == null);
    expect(state.sourceFeature.noteTitle.text, isEmpty);
    expect(state.sourceFeature.noteBody.text, isEmpty);
    // The reset views now edit the new workspace.
    await tester.runAsync(
      () => fixture.remote.command(Operation.notesSave, {
        'id': 1,
        'title': 'New',
        'body': '',
      }),
    );
    expect(
      fixture.requests.last['args'],
      containsPair('workspace_epoch', cleared),
    );
    fixture.remote.close();
    await pumpUntilCompleted(tester, fixture.remote.closed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'an edit dialog opened before a clear cannot change the artifact that reuses its ID',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final before = f.store.meeting('Before');
      f.store.artifact(before, 'summary', 'old summary', 'fixture');
      final row = f.store.rows('SELECT * FROM artifacts').single;
      final editing = f.shell.meetingFeature.editArtifact(
        MeetingArtifact.fromRow(row),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pumpAndSettle();
      final after = f.store.meeting('After');
      f.store.artifact(after, 'summary', 'new summary', 'fixture');
      expect(f.store.rows('SELECT id FROM artifacts').single['id'], row['id']);
      // The views were reset and adopted the new workspace; only the epoch
      // the dialog opened in can stop its save.
      expect(f.connection.workspaceEpoch, f.store.workspaceEpoch);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'stale edit',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('removed when the workspace was cleared'),
        findsOneWidget,
      );
      expect(f.store.rows('SELECT generated,edited FROM artifacts').single, {
        'generated': 'new summary',
        'edited': null,
      });
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await editing;
    },
  );

  const notice = 'Workspace cleared elsewhere; unsaved edits were discarded.';

  testWidgets(
    'a clear elsewhere reports discarded edits, never their text, and only then',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      Future<void> clearElsewhere() async {
        await tester.runAsync(
          () =>
              f.connection.application.call(Operation.workspaceClear.wire, {}),
        );
        await tester.pumpAndSettle();
      }

      f.shell.update(() {
        f.shell.navigate(WorkspaceTab.notes);
        f.shell.sourceFeature.noteTitle.text = 'private unsaved draft';
      });
      await tester.pumpAndSettle();
      await clearElsewhere();
      expect(find.text(notice), findsOneWidget);
      expect(find.textContaining('private unsaved draft'), findsNothing);
      ScaffoldMessenger.of(
        tester.element(find.byType(Workspace)),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      // Nothing unsaved: the views reset without a notice.
      await clearElsewhere();
      expect(f.connection.workspaceEpoch, f.store.workspaceEpoch);
      expect(find.text(notice), findsNothing);
      // This desktop's own clear discards edits on purpose.
      f.shell.update(
        () => f.shell.sourceFeature.noteTitle.text = 'discarded on purpose',
      );
      final clear = f.shell.settingsFeature.clearWorkspace();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete workspace'));
      await tester.pump();
      await tester.runAsync(() async => clear);
      await tester.pumpAndSettle();
      expect(f.shell.sourceFeature.noteTitle.text, isEmpty);
      expect(find.text(notice), findsNothing);
    },
  );

  testWidgets(
    'an edit dialog is not opened while a committed clear awaits its reset',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final meeting = f.store.meeting('Before');
      f.store.artifact(meeting, 'summary', 'old summary', 'fixture');
      final row = f.store.rows('SELECT * FROM artifacts').single;
      // A clear has committed; its event has not reached the views yet.
      f.store.renewWorkspaceEpoch();
      expect(f.connection.workspaceReplaced, isTrue);
      await (f.shell.meetingFeature.editArtifact(MeetingArtifact.fromRow(row)));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(f.shell.error, contains('cleared elsewhere'));
    },
  );

  testWidgets('startup adopts a workspace cleared before the desktop opened', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('startup-epoch-');
    final store = Store('${root.path}/app.db');
    final connection = TestDesktopConnection(
      Application(
        Domain(
          store,
          OfflineHelper('${root.path}/socket', '${root.path}/helper'),
        ),
      ),
    );
    store.renewWorkspaceEpoch();
    expect(connection.workspaceReplaced, isTrue);
    await tester.pumpWidget(
      Foresight(connection, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    expect(connection.workspaceEpoch, store.workspaceEpoch);
    expect(find.text(notice), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a reset also closes the preview, graph selection and question drafts',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final meeting = f.store.meeting('Before');
      f.shell.update(() {
        f.shell.meetingFeature.meetingPreviewId = meeting;
        f.shell.sourceFeature.graphSelectedDocument = 'source';
      });
      f.shell.chatFeature.questionFor(meeting).text = 'question about $meeting';
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pumpAndSettle();
      expect(f.shell.meetingFeature.meetingPreviewId, isNull);
      expect(f.shell.sourceFeature.graphSelectedDocument, isNull);
      expect(f.shell.chatFeature.questionFor(meeting).text, isEmpty);
    },
  );

  testWidgets(
    'a failed clear keeps the meeting notes it was about to discard',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final meeting = f.store.meeting('Kept');
      f.shell.update(() => f.shell.meetingFeature.meetingId = meeting);
      await tester.pumpAndSettle();
      f.connection.failures[Operation.workspaceClear] = StateError(
        'clear failed',
      );
      f.shell.meetingFeature.meetingNoteSaves.schedule(meeting, 'kept draft');
      final clear = f.shell.settingsFeature.clearWorkspace();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete workspace'));
      await tester.pump();
      await tester.runAsync(() async => clear);
      expect(f.shell.error, contains('clear failed'));
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => f.shell.meetingFeature.meetingNoteSaves.flush(),
      );
      await tester.pumpAndSettle();
      expect(
        f.connection.calls.where((call) => call.$1 == Operation.meetingsNotes),
        hasLength(1),
      );
    },
  );
}
