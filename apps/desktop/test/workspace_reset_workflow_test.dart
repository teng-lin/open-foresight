import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:open_foresight/main.dart';
import '../test_support/core_fixture.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'a queued meeting-notes save is not sent after another client\'s clear',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final meeting = f.store.meeting('Before');
      f.shell.update(() => f.shell.meetingFeature.meetingId = meeting);
      await tester.pumpAndSettle();
      f.shell.meetingFeature.meetingNoteSaves.schedule(meeting, 'queued draft');
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pump();
      f.store.meeting('After');
      // Past the scheduler's one-second delay.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        f.connection.calls.where((call) => call.$1 == Operation.meetingsNotes),
        isEmpty,
      );
      expect(f.store.meetingNoteRows(meeting), isEmpty);
    },
  );

  testWidgets(
    'a reconnect whose startup status names a new workspace resets the views',
    (tester) async {
      // The startup status names the profile's workspace, as a real one does.
      late final RemoteFixture fixture;
      fixture = RemoteFixture(
        openStore: (path) {
          final store = Store(path);
          fixture.status['workspace_epoch'] = store.workspaceEpoch;
          return store;
        },
      );
      await tester.runAsync(fixture.start);
      addTearDown(() => tester.runAsync(fixture.close));
      fixture.handler = (socket, request) =>
          fixture.reply(socket, request, null);
      await tester.pumpWidget(
        Foresight(fixture.remote, deviceLoader: () async => []),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      state.update(() {
        state.sourceFeature.noteId = 3;
        state.sourceFeature.noteTitle.text = 'Note 3';
      });
      // The workspace is cleared while the desktop is disconnected.
      fixture.owner.renewWorkspaceEpoch();
      fixture.status['workspace_epoch'] = fixture.owner.workspaceEpoch;
      fixture.sockets.last.destroy();
      await pumpUntil(tester, () => state.sourceFeature.noteId == null);
      expect(state.sourceFeature.noteTitle.text, isEmpty);
      fixture.remote.close();
      await pumpUntilCompleted(tester, fixture.remote.closed);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
