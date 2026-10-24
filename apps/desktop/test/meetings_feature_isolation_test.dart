import 'desktop_fixture_owner.dart';
import 'pump_until.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import '../test_support/core_fixture.dart';

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
  int speechPrompts = 0;
  @override
  Future<void> chooseSpeech() async {
    speechPrompts++;
  }

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

class _SpeechConnection extends ControllerConnection {
  _SpeechConnection(super.application);
  _SpeechReader? _speech;
  @override
  _SpeechReader get store => _speech ??= _SpeechReader(super.store);
}

class _SpeechReader implements StoreReader {
  _SpeechReader(this.delegate);
  final StoreReader delegate;
  final reply = Completer<ReadResult<ModelRegistration?>>();
  int reads = 0;
  @override
  String get workspaceEpoch => delegate.workspaceEpoch;
  @override
  String get dataRevision => delegate.dataRevision;
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    if (query.projection != 'model') return delegate.read(query);
    reads++;
    return reply.future.then((result) => result.asType<T>());
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) => delegate.watch(query);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous setup read ${invocation.memberName}',
  );
}

class _BuildGuardConnection extends ControllerConnection {
  _BuildGuardConnection(super.application);
  _BuildGuardReader? _reader;
  @override
  _BuildGuardReader get store => _reader ??= _BuildGuardReader(super.store);
}

class _BuildGuardReader implements StoreReader {
  _BuildGuardReader(this.delegate);
  final StoreReader delegate;
  bool rejectDuringBuild = false;
  int buildAdmissions = 0;
  void _guard() {
    if (rejectDuringBuild &&
        WidgetsBinding.instance.buildOwner!.debugBuilding) {
      buildAdmissions++;
      throw StateError('Persistence access during actual widget building');
    }
  }

  @override
  String get workspaceEpoch {
    _guard();
    return delegate.workspaceEpoch;
  }

  @override
  String get dataRevision {
    _guard();
    return delegate.dataRevision;
  }

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    _guard();
    return delegate.read(query);
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    _guard();
    return delegate.watch(query);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected reader access ${invocation.memberName}');
}

void main() {
  testWidgets(
    'prepared meeting panels render without persistence and retired actions refuse',
    (tester) async => withDesktopFixtures(tester, () async {
      final root = createTestTempDirectorySync('meeting-render-');
      final store = Store('${root.path}/app.db');
      final id = store.meeting('Prepared meeting');
      final connection = _BuildGuardConnection(
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
      controller.meetingId = id;
      controller.start();
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() async {
        await pumpUntilCompleted(tester, controller.dispose());
        connection.close();
        await pumpUntilCompleted(tester, connection.closed);
        await tester.binding.setSurfaceSize(null);
      });
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
      await pumpUntil(tester, () => controller.loadedMeetingNotes == id);
      await tester.pumpAndSettle();
      // Allow setup/read delivery before rejecting every admission made inside
      // actual widget builds, including LayoutBuilder's later build scope.
      connection.store.rejectDuringBuild = true;
      for (final panel in [
        'Summary',
        'Action items',
        'Preparation',
        'Chat',
        'Live Q&A',
      ]) {
        host.update(() => controller.meetingPanel = panel);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: panel);
      }
      expect(connection.store.buildAdmissions, 0);
      final generate = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Generate Summary',
              skipOffstage: false,
            ),
          )
          .onPressed!;
      final originalEpoch = connection.workspaceEpoch;
      await tester.runAsync(
        () => connection.application.call(Operation.workspaceClear.wire, {}),
      );
      expect(
        connection.workspaceEpoch,
        originalEpoch,
        reason: 'The service event has not been adopted by a shell',
      );
      expect(store.workspaceEpoch, isNot(originalEpoch));
      expect(store.meeting('Replacement meeting'), id);
      connection.calls.clear();
      generate();
      await tester.pumpAndSettle();
      expect(connection.calls, isEmpty);
      expect(host.error, isEmpty);
      expect(connection.store.buildAdmissions, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }),
  );

  for (final boundary in ['session', 'selection', 'disposal', 'read failure']) {
    testWidgets(
      'fresh speech readiness respects $boundary before prompting or recording',
      (tester) async => withDesktopFixtures(tester, () async {
        final root = createTestTempDirectorySync('meeting-readiness-');
        final store = Store('${root.path}/app.db');
        final connection = _SpeechConnection(
          Application(
            Domain(
              store,
              OfflineHelper('${root.path}/socket', '${root.path}/helper'),
            ),
          ),
        );
        final host = _Host(connection),
            integration = _Integration(),
            chat = _Chat(),
            settings = _Settings();
        final controller = MeetingsController(
          host: host,
          navigation: host,
          operations: host,
          dialogs: host,
          integrations: integration,
          integrationCommands: integration,
          settings: settings,
          chat: chat,
          chatCommands: chat,
        );
        addTearDown(() async {
          await pumpUntilCompleted(tester, controller.dispose());
          connection.close();
          await pumpUntilCompleted(tester, connection.closed);
        });
        final action = boundary == 'selection'
            ? controller.recordExistingMeeting(1)
            : controller.quickStart();
        expect(connection.store.reads, 1);
        switch (boundary) {
          case 'session':
            connection.replaceClientSessionForTesting();
          case 'selection':
            controller.meetingPreviewId = 2;
          case 'disposal':
            await controller.dispose();
          case 'read failure':
            break;
        }
        connection.store.reply.complete(
          ReadResult(
            freshness: boundary == 'read failure'
                ? ReadFreshness.failed
                : ReadFreshness.current,
            value: null,
            error: boundary == 'read failure'
                ? RpcError(RpcErrorCode.unavailable, 'readiness unavailable')
                : null,
            requestTag: 'held',
            sequence: 0,
          ),
        );
        await action;
        expect(settings.speechPrompts, 0);
        expect(
          connection.calls.where(
            (call) =>
                call.$1 == Operation.meetingsCreate ||
                call.$1 == Operation.meetingsStart,
          ),
          isEmpty,
        );
        expect(
          host.error,
          boundary == 'read failure'
              ? contains('readiness unavailable')
              : isEmpty,
        );
        expect(controller.quickStarting, false);
      }),
    );
  }

  testWidgets(
    'Meetings mounts with explicit ports and settles its owned draft before closing',
    (tester) async => withDesktopFixtures(tester, () async {
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
      controller.setSystemAudioSetupReviewed(true);
      controller.start();
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
      expect(
        controller.systemAudioSetupReviewed,
        true,
        reason:
            'A late initial preference cannot replace the current reviewed choice',
      );
      expect(find.text('Meetings'), findsOneWidget);
      final failure = Completer<void>();
      final action = controller.runAction(() => failure.future);
      controller.meetingPreviewId = id;
      failure.completeError(StateError('retired selection'));
      await action;
      expect(host.error, isEmpty);
      controller.meetingId = id;
      await pumpUntil(tester, () => controller.loadedMeetingNotes == id);
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
    }),
  );
}
