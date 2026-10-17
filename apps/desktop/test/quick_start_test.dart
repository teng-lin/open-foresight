import 'desktop_connection_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/speech_setup_view.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class QuickStartDomain extends CommandFixtureDomain {
  final operations = <String>[];
  bool denyMicrophone = false, failCreate = false, needsSystemSetup = false;
  Completer<Map<String, dynamic>>? systemGate;
  Completer<void>? createGate;
  QuickStartDomain(super.store, super.helper);
  @override
  Future<Object?> command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    operations.add(method);
    if (method == 'audio.capabilities')
      return {
        'microphone': denyMicrophone ? 'not_determined' : 'authorized',
        'system_audio_request': needsSystemSetup
            ? 'not_requested'
            : 'completed',
      };
    if (method == 'audio.request_microphone')
      return {'granted': false, 'microphone': 'denied'};
    if (method == 'audio.request_system')
      return await (systemGate?.future ??
          Future.value({
            'system_audio': 'unknown',
            'system_audio_request': 'completed',
            'permission_verified': false,
            'message': 'Request sent to macOS.',
            'settings_url':
                'x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture',
          }));
    if (method == 'notifications.capabilities') return {'available': false};
    if (method == 'meetings.create') {
      await createGate?.future;
      if (failCreate)
        throw StateError('Meeting creation failed. Please retry.');
    }
    if (method == 'meetings.start') return {};
    return super.command(method, args);
  }
}

void main() {
  late Directory directory;
  late Store store;
  late QuickStartDomain domain;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('quick-start-ui-');
    store = Store('${directory.path}/app.db');
    domain = QuickStartDomain(
      store,
      OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));
  Future<void> registerSpeech() async {
    final model = File('${directory.path}/speech.bin')
      ..writeAsStringSync('control flow fixture');
    final runner = File('${directory.path}/speech-runner')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('/bin/chmod', ['700', runner.path]);
    await store.register('speech', model.path, runner.path);
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(Foresight(TestDesktopConnection(domain), deviceLoader: () async => []));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

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
      final dynamic state = tester.state(find.byType(Workspace));
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
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.busy, false);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );

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
      final dynamic state = tester.state(find.byType(Workspace));
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
      final dynamic state = tester.state(find.byType(Workspace));
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
      await tester.pumpAndSettle();
      expect(find.text('Allow system audio recording'), findsOneWidget);
      expect(find.textContaining('System Audio Recording Only'), findsWidgets);
      expect(domain.operations, isNot(contains('audio.request_system')));
      await tester.tap(find.text('Request access'));
      await tester.pump();
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
      final dynamic state = tester.state(find.byType(Workspace));
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
      await tester.tap(find.text('Request access'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.captureCapabilities['microphone'], 'authorized');
      expect(state.captureCapabilities['system_audio_request'], 'completed');
      expect(state.captureCapabilities['permission_verified'], false);
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
