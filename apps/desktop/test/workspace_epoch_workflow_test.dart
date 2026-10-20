import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:open_foresight/main.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';

void main() {
  testWidgets('another client\'s clear closes the editors that hold its IDs', (
    tester,
  ) async {
    final fixture = RemoteFixture();
    fixture.status['workspace_epoch'] = 'before-clear';
    await tester.runAsync(fixture.start);
    addTearDown(() => tester.runAsync(fixture.close));
    fixture.handler = (socket, request) => fixture.reply(socket, request, null);
    await tester.pumpWidget(
      Foresight(fixture.remote, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(Workspace));
    state.update(() {
      state.meetingFeature.noteId = 3;
      state.meetingFeature.noteTitle.text = 'Note 3';
      state.meetingFeature.noteBody.text = 'Body of note 3';
    });
    fixture.event({...fixture.status, 'workspace_epoch': 'after-clear'});
    await pumpUntil(tester, () => state.meetingFeature.noteId == null);
    expect(state.meetingFeature.noteTitle.text, isEmpty);
    expect(state.meetingFeature.noteBody.text, isEmpty);
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
      containsPair('workspace_epoch', 'after-clear'),
    );
    await tester.runAsync(fixture.remote.helper.close);
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
      final editing = f.shell.meetingFeature.editArtifact(row) as Future<void>;
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => f.connection.application.call(Operation.workspaceClear.wire, {}),
      );
      await tester.pumpAndSettle();
      final after = f.store.meeting('After');
      f.store.artifact(after, 'summary', 'new summary', 'fixture');
      expect(f.store.rows('SELECT id FROM artifacts').single['id'], row['id']);
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
}
