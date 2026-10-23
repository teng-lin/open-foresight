import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:open_foresight/main.dart';
import '../test_support/core_fixture.dart';
import 'controller_fixture.dart';
import 'pump_until.dart';
import 'dart:io';
import 'package:open_foresight/commands.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/desktop_visuals.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

void main() {
  testWidgets('one epoch event rebinds every prepared workspace owner', (
    tester,
  ) async {
    late final RemoteFixture fixture;
    fixture = RemoteFixture(
      openStore: (path) {
        final store = Store(path);
        store.setPreference('onboarding.complete', 'true');
        store.setPreference('inactivity', '30');
        store.importText('Before epoch', 'before', 'text/plain', 'fixture');
        fixture.status['workspace_epoch'] = store.workspaceEpoch;
        fixture.status['revision'] = store.dataRevision;
        return store;
      },
    );
    await tester.runAsync(fixture.start);
    final commands = await tester.runAsync(
      () => AppCommands.bind(
        '${fixture.root.path}/commands.sock',
        environment: DesktopEnvironment(run: Process.run),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpUntilCompleted(tester, fixture.remote.closed);
      await tester.runAsync(commands!.close);
      await tester.runAsync(fixture.close);
    });
    fixture.handler = (socket, request) => fixture.reply(socket, request, null);
    await tester.pumpWidget(
      Foresight(
        fixture.remote,
        commands: commands,
        deviceLoader: () async => [],
      ),
    );
    final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
    await pumpUntil(
      tester,
      () =>
          !state.onboardingFeature.active &&
          state.settingsFeature.sourceCount == 1,
    );
    fixture.owner.renewWorkspaceEpoch();
    fixture.owner.importText('After epoch', 'after', 'text/plain', 'fixture');
    fixture.status['workspace_epoch'] = fixture.owner.workspaceEpoch;
    fixture.status['revision'] = fixture.owner.dataRevision;
    fixture.event(fixture.status);
    // No second service event or committing action is needed for recovery.
    await pumpUntil(
      tester,
      () =>
          !state.onboardingFeature.active &&
          state.settingsFeature.sourceCount == 2,
    );
    expect(fixture.remote.workspaceEpoch, fixture.owner.workspaceEpoch);
    state.update(() => state.tab = WorkspaceTab.settings);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DesktopSettingSelect<String>>(
            find.byKey(const Key('inactivity')),
          )
          .value,
      '30',
    );
    state.update(() => state.tab = WorkspaceTab.sources);
    await tester.pumpAndSettle();
    expect(find.text('After epoch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
