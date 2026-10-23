import 'pump_until.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/meetings/meetings_controller.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class _Host
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceDialogs {
  _Host(this.connection);
  @override
  final ControllerConnection connection;
  @override
  late BuildContext context;
  @override
  bool mounted = true;
  @override
  final environment = const DesktopEnvironment();
  @override
  WorkspaceTab selectedTab = WorkspaceTab.meetings;
  @override
  bool busy = false;
  @override
  String error = '';
  StateSetter rebuild = (action) => action();
  @override
  void update(VoidCallback action) {
    if (mounted) rebuild(action);
  }

  @override
  void navigate(WorkspaceTab value) => selectedTab = value;
  @override
  void setError(String value) => error = value;
  @override
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      error = '$failure';
    }
  }

  @override
  void reportAsyncError(Object failure) => error = '$failure';
  @override
  bool rowsAreCurrent() => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Integration implements IntegrationActivity, IntegrationCommands {
  @override
  GooglePresentation get googlePresentation =>
      GooglePresentation.fromWire(const {});
  @override
  bool get googleSyncing => false;
  @override
  int get lastCompletedRefreshMilliseconds => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Settings implements SettingsCommands {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Chat implements ChatActivity, ChatCommands {
  @override
  bool get asking => false;
  @override
  double get answerFontSize => 14;
  @override
  Widget chat({int? meetingScope, bool compact = false}) =>
      const Text('Owned Chat port');
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  testWidgets(
    'Meetings mounts with explicit ports and settles its owned draft before closing',
    (tester) async {
      final root = createTestTempDirectorySync('meetings-feature-');
      final store = Store('${root.path}/app.db');
      final id = store.meeting('Standalone meeting');
      final connection = ControllerConnection(
        Application(
          Domain(
            store,
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          ),
        ),
      );
      final host = _Host(connection),
          integration = _Integration(),
          chat = _Chat();
      final controller = MeetingsController(
        host: host,
        navigation: host,
        operations: host,
        dialogs: host,
        integrations: integration,
        integrationCommands: integration,
        settings: _Settings(),
        chat: chat,
        chatCommands: chat,
      );
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: MeetingsView(controller));
            },
          ),
        ),
      );
      addTearDown(() async {
        await pumpUntilCompleted(tester, controller.dispose());
        connection.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpAndSettle();
      expect(find.text('Standalone meeting'), findsOneWidget);
      expect(find.text('Meetings'), findsOneWidget);
      final failure = Completer<void>();
      final action = controller.runAction(() => failure.future);
      controller.meetingPreviewId = id;
      failure.completeError(StateError('retired selection'));
      await action;
      expect(host.error, isEmpty);
      controller.meetingId = id;
      controller.loadMeetingNotes(id);
      controller.meetingNotesController.text = 'Draft owned by Meetings';
      controller.scheduleMeetingNotesSave();
      expect(controller.hasPendingNoteSave, true);
      final closing = controller.dispose();
      await pumpUntilCompleted(tester, closing);
      expect(
        store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).single['body'],
        'Draft owned by Meetings',
      );
      expect(
        connection.calls.where((call) => call.$1 == Operation.meetingsNotes),
        hasLength(1),
      );
      expect(controller.mounted, false);
      connection.close();
      await pumpUntilCompleted(tester, connection.closed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
