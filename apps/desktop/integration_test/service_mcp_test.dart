import 'package:foresight_test_support/macos_integration_runtime.dart';
import '../test_support/core_fixture.dart';
import 'dart:async';
import 'package:foresight_core/remote.dart' show RemoteDomain;
import '../test_support/current_read.dart';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/desktop.dart' show StoreReader, StoreReadQueries;
import 'package:foresight_test_support/observed_expectations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_foresight/main.dart' as app;
import '../test_support/onboarding.dart';
import 'package:open_foresight/features/onboarding/onboarding_view.dart';

final observed = ObservedExpectations();

Future<void> waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() ready, {
  DateTime? deadline,
}) async {
  deadline ??= DateTime.now().add(const Duration(seconds: 30));
  var settled = await currentReadCondition(ready, deadline: deadline);
  while (!settled && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    settled = await currentReadCondition(ready, deadline: deadline);
  }
  observed.expect('wait-ready', settled, true);
  observed.expect('framework-exception', tester.takeException(), isNull);
}

Future<void> startDesktop(WidgetTester tester) async {
  await app.main();
  final startupDeadline = DateTime.now().add(const Duration(seconds: 30));
  await waitFor(
    tester,
    () =>
        find.byType(app.Workspace).evaluate().isNotEmpty ||
        find.text('Open Foresight could not start').evaluate().isNotEmpty,
    deadline: startupDeadline,
  );
  if (find.byType(app.Workspace).evaluate().isEmpty) {
    final details = find.byType(SelectableText);
    fail(
      'Desktop startup failed: ${details.evaluate().isEmpty ? 'unknown' : tester.widget<SelectableText>(details).data}',
    );
  }
  // Workspace can mount while its asynchronous onboarding preferences load.
  // Wait for the actual first screen before deciding whether to advance it.
  await waitFor(
    tester,
    () =>
        find.byType(OnboardingView).evaluate().isNotEmpty ||
        find.text('Meetings').evaluate().isNotEmpty,
    deadline: startupDeadline,
  );
}

class Mcp {
  final Process process;
  final StreamIterator<Map<String, dynamic>> responses;
  int next = 0;
  Mcp(this.process)
    : responses = StreamIterator(
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((v) => jsonDecode(v) as Map<String, dynamic>),
      );
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++next;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    await process.stdin.flush();
    while (await responses.moveNext()) {
      final value = responses.current;
      if (value['id'] == id) {
        observed.expect('mcp-envelope', value['error'], isNull);
        return Map<String, dynamic>.from(value['result'] as Map);
      }
    }
    throw StateError('MCP disconnected');
  }

  Future<Map> tool(String name, [Map<String, dynamic> args = const {}]) async {
    final result = await call('tools/call', {'name': name, 'arguments': args});
    observed.expect('mcp-tool-success', result['isError'], isNot(true));
    return result;
  }

  Future<void> initialize() async {
    await call('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': {},
      'clientInfo': {'name': 'native-desktop-test', 'version': '1'},
    });
    process.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );
  }

  Future<void> close() async {
    await process.stdin.close();
    observed.expect(
      'mcp-clean-exit',
      await process.exitCode.timeout(const Duration(seconds: 5)),
      0,
    );
    await responses.cancel();
  }
}

Future<void> closeDesktop(
  WidgetTester tester,
  app.WorkspaceTestAccess workspace,
) async {
  final connection = workspace.d as RemoteDomain;
  final client = connection.client;
  final saves = workspace.meetingFeature.meetingNoteSaves;
  final commands = workspace.integrationFeature.commands;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() async {
    try {
      await saves.close().timeout(const Duration(seconds: 30));
    } finally {
      connection.close();
      await connection.closed.timeout(const Duration(seconds: 30));
    }
  });
  await waitFor(
    tester,
    () => client.isClosed && (commands == null || commands.isClosed == true),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    prepareMacosIntegrationRuntime(registerTearDown: addTearDown);
  });
  testWidgets(
    'desktop and MCP share content, capture, and service across desktop restart',
    (tester) async {
      await startDesktop(tester);
      await finishOnboarding(tester);
      app.WorkspaceTestAccess workspace =
          tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
      await waitFor(
        tester,
        () =>
            workspace.d.generator?.effectiveState['state'] == 'ready' &&
            workspace.d.helper.snapshot?.pipeline == 'ready',
      );
      // A ready snapshot may precede the current restore transaction finishing.
      await workspace.d.resume();
      final initial = await workspace.d.command(Operation.status) as Map;
      final mcp = Mcp(
        await Process.start(
          Platform.environment['FORESIGHT_MCP_EXECUTABLE']!,
          const [],
        ),
      );
      unawaited(mcp.process.stderr.drain<void>());
      await mcp.initialize();
      final mcpStatus = await mcp.tool('get_status');
      observed.expect(
        'desktop_and_mcp_same_owner',
        ((mcpStatus['structuredContent'] as Map)['result'] as Map)['pid'],
        initial['pid'],
      );
      final created = await mcp.tool('create_meeting', {
        'title': 'Shared MCP planning',
      });
      final id =
          ((created['structuredContent'] as Map)['result'] as Map)['id'] as int;
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () => find.text('Shared MCP planning').evaluate().isNotEmpty,
      );
      await mcp.tool('save_note', {
        'title': 'MCP note',
        'body': 'Visible through the desktop reader',
      });
      final StoreReader reader = workspace.d.store;
      Future<bool> mcpNoteVisible() async => (await currentRead(
        reader,
        StoreReadQueries.notes(),
      )).any((note) => note.title == 'MCP note');
      await waitFor(tester, mcpNoteVisible);
      observed.expect('mcp_changes_visible', await mcpNoteVisible(), true);
      workspace.update(() => workspace.meetingFeature.meetingId = id);
      await waitFor(
        tester,
        () => find.byTooltip('Rename meeting').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Rename meeting'));
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, 'Renamed shared planning');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () => find.text('Renamed shared planning').evaluate().isNotEmpty,
      );
      final renamed =
          await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
      observed.expect(
        'meeting_rename_persisted',
        (renamed['meeting'] as Map)['title'],
        'Renamed shared planning',
      );

      // Exercise denial through the visible desktop and the real MCP/service
      // boundary before allowing a fresh request. A previous denial must not
      // create capture handles, transcripts, or an implicit future grant.
      final denied = mcp.call('tools/call', {
        'name': 'start_recording',
        'arguments': {'id': id},
      });
      await waitFor(tester, () => find.text('Deny').evaluate().isNotEmpty);
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      observed.expect(
        'recording_denial_reported',
        (await denied)['isError'],
        true,
      );
      observed.expect(
        'recording_denial_left_capture_inactive',
        ((await workspace.d.command(Operation.status) as Map)['capture']
            as Map)['active'],
        false,
      );
      final afterDenial =
          await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
      observed.expect(
        'recording_denial_left_no_transcript',
        afterDenial['transcript'] as List,
        isEmpty,
      );
      final starting = mcp.tool('start_recording', {'id': id});
      await waitFor(
        tester,
        () => find.text('Allow once').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      await starting;
      observed.expect(
        'recording_retry_required_fresh_approval',
        find.text('Allow once').evaluate(),
        isEmpty,
      );
      await waitFor(
        tester,
        () =>
            workspace.meetingFeature.recording != null &&
            workspace.meetingFeature.recording!.sampleCounts.length == 2,
      );
      await waitFor(
        tester,
        () => workspace.meetingFeature.recording!.sampleCounts.every(
          (int n) => n > 0,
        ),
      );
      await mcp.close();
      observed.expect(
        'recording_survived_mcp_close',
        ((await workspace.d.command(Operation.status) as Map)['capture']
            as Map)['active'],
        true,
      );
      // Closing the desktop removes its visible indicator and must stop capture.
      await closeDesktop(tester, workspace);
      await startDesktop(tester);
      workspace =
          tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
      await waitFor(tester, () => workspace.meetingFeature.recording == null);
      // Final transcription persists independently of desktop startup. Wait for this
      // client's restore/reconciliation to finish before requesting generation.
      await workspace.d.resume();
      observed.expect(
        'recording_stopped_when_desktop_indicator_closed',
        ((await workspace.d.command(Operation.status) as Map)['capture']
            as Map)['active'],
        false,
      );
      observed.expect(
        'desktop_restart_preserved_owner',
        (await workspace.d.command(Operation.status) as Map)['pid'],
        initial['pid'],
      );
      await workspace.meetingFeature.stopRecording();
      await waitFor(tester, () => workspace.meetingFeature.recording == null);
      final meeting =
          await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
      observed.expect(
        'transcript_persisted',
        (meeting['transcript'] as List).where(
          (t) =>
              (t as Map)['final'] == 1 &&
              ((t)['text'] as String).contains('Mira'),
        ),
        isNotEmpty,
      );
      await workspace.d.command(Operation.meetingsGenerate, {
        'id': id,
        'kind': 'summary',
      });
      final content =
          await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
      observed.expect(
        'artifact_persisted',
        ((content['artifacts'] as List).single as Map)['generated'],
        contains('Mira'),
      );
      observed.expect(
        'desktop_database_read_only',
        // The public reader has no writer capability; exercise the actual
        // connected facade, without granting it an inspection/write escape.
        // Deliberately attack the runtime read-only facade with a missing writer.
        // ignore: avoid_dynamic_calls
        () => (workspace.d.store as dynamic).saveNote(null, 'forbidden', ''),
        throwsA(isA<NoSuchMethodError>()),
      );
      // Desktop restart opens the collection. Select this meeting again so
      // capture failure is checked in its actual retained-audio panel.
      workspace.update(() => workspace.meetingFeature.meetingId = id);
      await waitFor(
        tester,
        () => find.byTooltip('Rename meeting').evaluate().isNotEmpty,
      );
      // The Python driver owns this executable. Simulate an OS capture denial
      // across the real native/service boundary without touching host devices.
      final env = Platform.environment;
      final capture = File(env['FORESIGHT_CAPTURE_RUNTIME']!);
      expect(
        capture.parent.path,
        '${Directory(env['FORESIGHT_DATA']!).parent.path}/fixtures',
      );
      final originalCapture = capture.readAsBytesSync();
      final savedTranscript = List<Map<String, dynamic>>.from(
        content['transcript'] as List,
      );
      final savedIds = savedTranscript.map((row) => row['id']).toSet();
      try {
        capture.writeAsStringSync(
          '#!/bin/sh\nprintf "Permission denied by capture fixture\\n" >&2\nexit 1\n',
        );
        await workspace.d.command(Operation.meetingsStart, {'id': id});
        const captureWarning =
            'Capture interrupted: audio storage or capture failed. Saved audio is retained.';
        const visibleWarning =
            'Recording stopped unexpectedly. Your saved audio is still shown here.';
        final denialDeadline = DateTime.now().add(const Duration(seconds: 30));
        await waitFor(
          tester,
          () =>
              workspace.meetingFeature.recordingState == captureWarning &&
              workspace.meetingFeature.recording == null,
          deadline: denialDeadline,
        );
        expect(workspace.meetingFeature.recordingState, captureWarning);
        await waitFor(
          tester,
          () => find.text(visibleWarning).evaluate().isNotEmpty,
          deadline: denialDeadline,
        );
        final failedStatus = await workspace.d.command(Operation.status) as Map;
        final readArgs = {
          'meeting_id': id,
          'workspace_epoch': failedStatus['workspace_epoch'],
        };
        final failedAudio =
            await workspace.d.command(Operation.recordingsRead, readArgs)
                as Map;
        observed.expect(
          'capture_denial_reached_desktop',
          {
            'warning': workspace.meetingFeature.recordingState,
            'active': (failedStatus['capture'] as Map)['active'],
            'capture_active':
                (failedStatus['capture'] as Map)['capture_active'],
            'persisted_warning':
                (failedAudio['meeting'] as Map)['captureError'],
          },
          {
            'warning': captureWarning,
            'active': false,
            'capture_active': false,
            'persisted_warning': captureWarning,
          },
        );
        // Durable capture has already joined and retired the failed owner.
        // Stop is idempotent after that automatic fence; healthy capture below
        // still exercises the visible Stop control.
        final interrupted =
            await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
        expect((interrupted['meeting'] as Map)['state'], 'interrupted');
        await workspace.d.command(Operation.meetingsStop);
        await tester.pump();
        expect(workspace.meetingFeature.recording, isNull);
        final afterStopAudio =
            await workspace.d.command(Operation.recordingsRead, readArgs)
                as Map;
        expect(
          (afterStopAudio['meeting'] as Map)['captureError'],
          captureWarning,
        );
        expect(find.text(visibleWarning), findsWidgets);
        final failed =
            await workspace.d.command(Operation.meetingsGet, {'id': id}) as Map;
        observed.expect(
          'capture_denial_persisted_interruption',
          (failed['meeting'] as Map)['state'],
          'interrupted',
        );
        observed.expect(
          'capture_denial_preserved_transcript',
          (failed['transcript'] as List)
              .where((row) => savedIds.contains((row as Map)['id']))
              .toList(),
          savedTranscript,
        );
      } finally {
        capture.writeAsBytesSync(originalCapture);
      }
      await workspace.d.command(Operation.meetingsStart, {'id': id});
      await waitFor(
        tester,
        () =>
            workspace.meetingFeature.recording != null &&
            workspace.meetingFeature.recording!.sampleCounts.length == 2 &&
            workspace.meetingFeature.recording!.sampleCounts.every(
              (int n) => n > 0,
            ),
      );
      observed.expect(
        'capture_recovered_after_permission_fixture_restored',
        workspace.meetingFeature.recording!.sampleCounts.every(
          (int n) => n > 0,
        ),
        true,
      );
      await tester.tap(find.byTooltip('Stop recording'));
      await waitFor(tester, () => workspace.meetingFeature.recording == null);
      final report = Platform.environment['FORESIGHT_SERVICE_UI_REPORT'];
      if (report != null)
        File(report).writeAsStringSync(jsonEncode(observed.toJson()));
      await closeDesktop(tester, workspace);
    },
  );
}
