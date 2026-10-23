import '../test_support/platform_fixture.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';

import 'desktop_connection_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/main.dart';

import 'package:open_foresight/features/settings/speech_setup_view.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'package:open_foresight/commands.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'pump_until.dart';

class QuickStartDomain extends CommandFixtureDomain {
  final operations = <String>[];
  bool denyMicrophone = false, failCreate = false, needsSystemSetup = false;
  bool loseCreateReply = false;
  final createKeys = <Object?>[];
  Completer<Map<String, dynamic>>? systemGate;
  Completer<void>? createGate;
  QuickStartDomain(super.store, super.helper);
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    operations.add(operation.wire);
    if (operation == Operation.audioCapabilities)
      return {
        'microphone': denyMicrophone ? 'not_determined' : 'authorized',
        'system_audio_request': needsSystemSetup
            ? 'not_requested'
            : 'completed',
      };
    if (operation == Operation.audioRequestMicrophone)
      return {'granted': false, 'microphone': 'denied'};
    if (operation == Operation.audioRequestSystem)
      return await (systemGate?.future ??
          Future.value({
            'system_audio': 'unknown',
            'system_audio_request': 'completed',
            'permission_verified': false,
            'message': 'Request sent to macOS.',
            'settings_url':
                'x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture',
          }));
    if (operation == Operation.notificationsCapabilities)
      return {'available': false};
    if (operation == Operation.meetingsCreate) {
      createKeys.add(args['idempotency_key']);
      await createGate?.future;
      if (failCreate)
        throw StateError('Meeting creation failed. Please retry.');
      if (loseCreateReply) {
        // The meeting commits, then the connection drops before the reply.
        loseCreateReply = false;
        await super.command(operation, args);
        throw RpcError(
          RpcErrorCode.unavailable,
          'Application service disconnected',
        );
      }
    }
    if (operation == Operation.meetingsStart) return {};
    return super.command(operation, args);
  }
}

/// Exercise the same authenticated-connection gate as the service, without
/// opening devices or running a speech model in a widget test.
class ConsentDesktopConnection extends TestDesktopConnection {
  ConsentDesktopConnection(super.application);
  void Function(Map<String, dynamic>)? events;
  late final gate = AgentAccessGate('fixture-token', (_, event) {
    events?.call(Map<String, dynamic>.from(event));
    return EventDelivery.sent;
  });

  @override
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  ) async {
    this.events = events;
    gate.attach(this, gate.desktopToken, verifiedDesktop: true);
  }

  @override
  Future<void> disableDesktopApprovals() async => gate.detach(this);

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (operation == Operation.meetingsStart ||
        operation == Operation.meetingsResume) {
      await gate.authorize(this, operation.wire, args, current: () => true);
    }
    return super.command(operation, args);
  }
}

void main() {
  late Directory directory;
  late Store store;
  late QuickStartDomain domain;
  setUp(() {
    directory = createTestTempDirectorySync('quick-start-ui-');
    store = Store('${directory.path}/app.db');
    domain = QuickStartDomain(
      store,
      OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
    );
  });
  setUp(() {
    addTearDown(() => directory.deleteSync(recursive: true));
  });
  Future<void> registerSpeech() async {
    final model = File('${directory.path}/speech.bin')
      ..writeAsStringSync('control flow fixture');
    final runner = File('${directory.path}/speech-runner')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('/bin/chmod', ['700', runner.path]);
    await store.register('speech', model.path, runner.path);
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      Foresight(
        TestDesktopConnection(Application(domain)),
        deviceLoader: () async => [],
        environment: DesktopEnvironment(
          capabilities: testHostPlatformCapabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('commands socket quick meeting waits for visible confirmation', (
    tester,
  ) async {
    await tester.runAsync(registerSpeech);
    store.setPreference('onboarding.complete', 'true');
    final commands = await tester.runAsync(
      () => AppCommands.bind(
        '${directory.path}/commands.sock',
        environment: DesktopEnvironment(run: Process.run),
      ),
    );
    await tester.pumpWidget(
      Foresight(
        TestDesktopConnection(Application(domain)),
        commands: commands,
        deviceLoader: () async => [],
        environment: DesktopEnvironment(
          capabilities: testHostPlatformCapabilities,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(() => AppCommands.forward(commands!.path)),
      true,
    );
    await pumpUntil(
      tester,
      () => find
          .text('Start microphone and system audio recording?')
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Start microphone and system audio recording?'),
      findsOneWidget,
    );
    expect(domain.operations, isNot(contains('meetings.create')));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(domain.operations, isNot(contains('meetings.start')));
    expect(
      await tester.runAsync(() => AppCommands.forward(commands!.path)),
      true,
    );
    await pumpUntil(
      tester,
      () => find
          .text('Start microphone and system audio recording?')
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start recording'));
    await pumpUntil(tester, () => domain.operations.contains('meetings.start'));
    await tester.pumpAndSettle();
    expect(domain.operations, contains('meetings.create'));
    expect(domain.operations, contains('meetings.start'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => eventually(() => commands!.isClosed));
  });

  Future<void> dispose(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets(
    'direct Start transcribing authorizes once without a second dialog',
    (tester) async {
      await tester.runAsync(registerSpeech);
      final connection = ConsentDesktopConnection(Application(domain));
      await tester.pumpWidget(
        Foresight(
          connection,
          deviceLoader: () async => [],
          environment: DesktopEnvironment(
            capabilities: testHostPlatformCapabilities,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(
        find.text('Allow microphone and system audio recording?'),
        findsNothing,
      );
      expect(
        domain.operations.where((method) => method == 'meetings.start'),
        hasLength(1),
      );
      expect(store.rows('SELECT id FROM meetings'), hasLength(1));
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );

  testWidgets(
    'missing speech setup opens immediately, repeated start does not stack dialogs, cancel creates nothing',
    (tester) async {
      await show(tester);
      final start = tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Start transcribing'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed!;
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechSetupDialog), findsOneWidget);
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      start();
      expect(find.byType(SpeechSetupDialog), findsOneWidget);
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.busy, false);
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      expect(domain.operations, isNot(contains('meetings.start')));
      await dispose(tester);
    },
  );

  testWidgets(
    'completing speech setup continues once into meeting creation and recording',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechSetupDialog), findsOneWidget);
      // Complete the setup registration using tiny control-flow fixtures; no
      // model download or inference is represented by this widget test.
      await tester.runAsync(registerSpeech);
      Navigator.of(tester.element(find.byType(SpeechSetupDialog))).pop();
      await tester.pumpAndSettle();
      expect(
        domain.operations
            .where((operation) => operation == 'meetings.create')
            .length,
        1,
      );
      expect(
        domain.operations
            .where((operation) => operation == 'meetings.start')
            .length,
        1,
      );
      expect(store.rows('SELECT * FROM meetings').length, 1);
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(state.busy, false);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );

  testWidgets(
    'Start transcribing in a meeting records that meeting without creating another',
    (tester) async {
      await tester.runAsync(registerSpeech);
      final meeting = store.meeting('Existing meeting');
      await show(tester);
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      state.update(() => state.meetingFeature.meetingId = meeting);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(domain.operations, isNot(contains('meetings.create')));
      expect(
        domain.operations.where((method) => method == 'meetings.start'),
        hasLength(1),
      );
      expect(store.rows('SELECT id FROM meetings').single['id'], meeting);
      expect(state.meetingFeature.meetingId, meeting);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );

  testWidgets(
    'Start transcribing again after a lost create reply records one meeting',
    (tester) async {
      await tester.runAsync(registerSpeech);
      domain.loseCreateReply = true;
      await show(tester);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(state.error, contains('disconnected'));
      expect(domain.operations, isNot(contains('meetings.start')));
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      final meeting = store.rows('SELECT id FROM meetings').single['id'];
      expect(state.meetingFeature.meetingId, meeting);
      expect(
        domain.operations.where((method) => method == 'meetings.start'),
        hasLength(1),
      );
      expect(domain.createKeys, hasLength(2));
      expect(domain.createKeys.toSet(), hasLength(1));
      expect(domain.createKeys.first, isA<String>());
      await dispose(tester);
    },
  );

  // The OS access prompt can stay open while the meeting goes away.
  for (final (closedBy, message) in [
    (
      'a workspace clear',
      'Recording did not start: the workspace was cleared while recording '
          'access was requested.',
    ),
    (
      'closing the meeting',
      'Recording did not start: the meeting was closed while recording '
          'access was requested.',
    ),
  ]) {
    testWidgets(
      '$closedBy during the recording access check stops without recording',
      (tester) async {
        await tester.runAsync(registerSpeech);
        final meeting = store.meeting('Existing meeting');
        await show(tester);
        final state =
            tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
        // As the Start button does; it stops at the access check.
        final started = state.meetingFeature.recordExistingMeeting(meeting);
        expect(state.meetingFeature.meetingId, meeting);
        if (closedBy == 'a workspace clear') {
          // Another client clears the workspace; this desktop resets.
          store.renewWorkspaceEpoch();
          state.serviceChanged();
        } else {
          state.update(() => state.meetingFeature.meetingId = null);
        }
        await tester.pumpAndSettle();
        await started;
        expect(state.error, message);
        expect(domain.operations, isNot(contains('meetings.start')));
        expect(state.busy, false);
        expect(tester.takeException(), isNull);
        await dispose(tester);
      },
    );
  }

  testWidgets(
    'creation failure is visible and a pending creation ignores reentry',
    (tester) async {
      await tester.runAsync(registerSpeech);
      domain.failCreate = true;
      domain.createGate = Completer<void>();
      await show(tester);
      final start = tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Start transcribing'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed!;
      await tester.tap(find.text('Start transcribing'));
      await tester.pump();
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      start();
      expect(
        domain.operations
            .where((operation) => operation == 'meetings.create')
            .length,
        1,
      );
      domain.createGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Meeting creation failed. Please retry.'),
        findsOneWidget,
      );
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      expect(state.busy, false);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );

  testWidgets(
    'existing meeting recording checks Mac permissions and cancel preserves the meeting',
    (tester) async {
      await tester.runAsync(registerSpeech);
      final meeting = store.meeting('Existing meeting');
      domain.denyMicrophone = true;
      await show(tester);
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start').first);
      // The operation remains busy while the permission dialog is open.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Allow recording access'), findsOneWidget);
      expect(domain.operations, isNot(contains('meetings.start')));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.rows('SELECT id FROM meetings').single['id'], meeting);
      expect(domain.operations, isNot(contains('meetings.start')));
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(state.busy, false);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'Mac microphone denial is actionable and leaves no empty meeting',
    (tester) async {
      await tester.runAsync(registerSpeech);
      domain.denyMicrophone = true;
      await show(tester);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();
      expect(find.text('Allow recording access'), findsOneWidget);
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Allow microphone'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Microphone access was denied'),
        findsOneWidget,
      );
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      expect(domain.operations, isNot(contains('meetings.start')));
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
    skip: !Platform.isMacOS,
  );
  testWidgets(
    'Mac system audio request is explicit, pending setup can cancel without a meeting',
    (tester) async {
      await tester.runAsync(registerSpeech);
      domain.needsSystemSetup = true;
      domain.systemGate = Completer<Map<String, dynamic>>();
      await show(tester);
      await tester.tap(find.text('Start transcribing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Allow system audio recording'), findsOneWidget);
      expect(find.textContaining('System Audio Recording Only'), findsWidgets);
      expect(domain.operations, contains('audio.request_system'));
      expect(find.text('Request access'), findsNothing);
      expect(
        find.text('Waiting for the macOS audio access request…'),
        findsOneWidget,
      );
      expect(
        domain.operations
            .where((operation) => operation == 'audio.request_system')
            .length,
        1,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(state.busy, false);
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      domain.systemGate!.complete({
        'system_audio': 'pending',
        'system_audio_request': 'requesting',
        'permission_verified': false,
      });
      await tester.pumpAndSettle();
      expect(domain.operations, isNot(contains('meetings.start')));
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'Mac system audio unknown after a completed request permits explicit continuation',
    (tester) async {
      await tester.runAsync(registerSpeech);
      domain.needsSystemSetup = true;
      await show(tester);
      await tester.tap(find.text('Start transcribing'));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
      expect(
        state.integrationFeature.captureCapabilities.microphone,
        'authorized',
      );
      expect(
        state.integrationFeature.captureCapabilities.systemAudioRequest,
        'completed',
      );
      expect(
        state.integrationFeature.captureCapabilities.permissionVerified,
        false,
      );
      expect(find.text('Open System Settings'), findsOneWidget);
      expect(store.rows('SELECT * FROM meetings'), isEmpty);
      await tester.tap(find.text('Continue recording'));
      await tester.pumpAndSettle();
      expect(
        domain.operations
            .where((operation) => operation == 'meetings.create')
            .length,
        1,
      );
      expect(
        domain.operations
            .where((operation) => operation == 'meetings.start')
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
    skip: !Platform.isMacOS,
  );
}
