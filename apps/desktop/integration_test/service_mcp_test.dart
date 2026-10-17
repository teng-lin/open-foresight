import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/remote.dart' show RemoteDomain;
import 'package:foresight_test_support/observed_expectations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_foresight/main.dart' as app;

final observed = ObservedExpectations();

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  observed.expect('wait-ready', ready(), true);
  observed.expect('framework-exception', tester.takeException(), isNull);
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

Future<void> closeDesktop(WidgetTester tester, dynamic workspace) async {
  final client = (workspace.d as RemoteDomain).client;
  final commands = workspace.integrationFeature.commands;
  await tester.pumpWidget(const SizedBox.shrink());
  await waitFor(
    tester,
    () => client.isClosed && (commands == null || commands.isClosed == true),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'desktop and MCP share content, capture, and service across desktop restart',
    (tester) async {
      await app.main();
      await waitFor(
        tester,
        () => find.byType(app.Workspace).evaluate().isNotEmpty,
      );
      dynamic workspace = tester.state(find.byType(app.Workspace));
      await waitFor(
        tester,
        () =>
            workspace.d.generator?.effectiveState['state'] == 'ready' &&
            workspace.d.helper.snapshot?.pipeline == 'ready',
      );
      // A ready snapshot may precede the current restore transaction finishing.
      await workspace.d.resume();
      final initial = await workspace.d.command('status') as Map;
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
        mcpStatus['structuredContent']['result']['pid'],
        initial['pid'],
      );
      final created = await mcp.tool('create_meeting', {
        'title': 'Shared MCP planning',
      });
      final id = created['structuredContent']['result']['id'] as int;
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
      await waitFor(
        tester,
        () => workspace.d.store
            .rows("SELECT * FROM notes WHERE title='MCP note'")
            .isNotEmpty,
      );
      observed.expect(
        'mcp_changes_visible',
        workspace.d.store
            .rows("SELECT * FROM notes WHERE title='MCP note'")
            .isNotEmpty,
        true,
      );
      final starting = mcp.tool('start_recording', {'id': id});
      await waitFor(
        tester,
        () => find.text('Allow once').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      await starting;
      await waitFor(
        tester,
        () =>
            workspace.meetingFeature.recording != null &&
            workspace.meetingFeature.recording.sampleCounts.length == 2,
      );
      await waitFor(
        tester,
        () => workspace.meetingFeature.recording.sampleCounts.every(
          (int n) => n > 0,
        ),
      );
      await mcp.close();
      observed.expect(
        'recording_survived_mcp_close',
        (await workspace.d.command('status') as Map)['capture']['active'],
        true,
      );
      // Closing the desktop removes its visible indicator and must stop capture.
      await closeDesktop(tester, workspace);
      await app.main();
      await waitFor(
        tester,
        () => find.byType(app.Workspace).evaluate().isNotEmpty,
      );
      workspace = tester.state(find.byType(app.Workspace));
      await waitFor(tester, () => workspace.meetingFeature.recording == null);
      // Final transcription persists independently of desktop startup. Wait for this
      // client's restore/reconciliation to finish before requesting generation.
      await workspace.d.resume();
      observed.expect(
        'recording_stopped_when_desktop_indicator_closed',
        (await workspace.d.command('status') as Map)['capture']['active'],
        false,
      );
      observed.expect(
        'desktop_restart_preserved_owner',
        (await workspace.d.command('status') as Map)['pid'],
        initial['pid'],
      );
      await workspace.meetingFeature.stopRecording();
      await waitFor(tester, () => workspace.meetingFeature.recording == null);
      final meeting =
          await workspace.d.command('meetings.get', {'id': id}) as Map;
      observed.expect(
        'transcript_persisted',
        (meeting['transcript'] as List).where(
          (dynamic t) =>
              t['final'] == 1 && (t['text'] as String).contains('Mira'),
        ),
        isNotEmpty,
      );
      await workspace.d.command('meetings.generate', {
        'id': id,
        'kind': 'summary',
      });
      final content =
          await workspace.d.command('meetings.get', {'id': id}) as Map;
      observed.expect(
        'artifact_persisted',
        (content['artifacts'] as List).single['generated'],
        contains('Mira'),
      );
      observed.expect(
        'desktop_database_read_only',
        () => workspace.d.store.saveNote(null, 'forbidden', ''),
        throwsA(anything),
      );
      final report = Platform.environment['FORESIGHT_SERVICE_UI_REPORT'];
      if (report != null)
        File(report).writeAsStringSync(jsonEncode(observed.toJson()));
      await closeDesktop(tester, workspace);
    },
  );
}
