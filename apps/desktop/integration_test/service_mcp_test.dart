import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_foresight/main.dart' as app;

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), true);
  expect(tester.takeException(), isNull);
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
        expect(value['error'], isNull);
        return Map<String, dynamic>.from(value['result'] as Map);
      }
    }
    throw StateError('MCP disconnected');
  }

  Future<Map> tool(String name, [Map<String, dynamic> args = const {}]) async {
    final result = await call('tools/call', {'name': name, 'arguments': args});
    expect(result['isError'], isNot(true));
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
    expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
    await responses.cancel();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'desktop and MCP share content, capture, and service across desktop restart',
    (tester) async {
      await app.main();
      await tester.pump();
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
      await mcp.tool('start_recording', {'id': id});
      await waitFor(
        tester,
        () =>
            workspace.recording != null &&
            workspace.recording.sampleCounts.length == 2,
      );
      await waitFor(
        tester,
        () => workspace.recording.sampleCounts.every((int n) => n > 0),
      );
      await mcp.close();
      expect(
        (await workspace.d.command('status') as Map)['capture']['active'],
        true,
      );
      // Destroy the actual Flutter state. Service-owned capture must continue.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      await app.main();
      await tester.pump();
      workspace = tester.state(find.byType(app.Workspace));
      await waitFor(tester, () => workspace.recording != null);
      expect(
        (await workspace.d.command('status') as Map)['pid'],
        initial['pid'],
      );
      await workspace.stopRecording();
      await waitFor(tester, () => workspace.recording == null);
      final meeting =
          await workspace.d.command('meetings.get', {'id': id}) as Map;
      expect(
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
      expect(
        (content['artifacts'] as List).single['generated'],
        contains('Mira'),
      );
      expect(
        () => workspace.d.store.saveNote(null, 'forbidden', ''),
        throwsA(anything),
      );
      final report = Platform.environment['FORESIGHT_SERVICE_UI_REPORT'];
      if (report != null)
        File(report).writeAsStringSync(
          jsonEncode({
            'desktop_and_mcp_same_owner': true,
            'mcp_changes_visible': true,
            'recording_survived_both_clients_disconnecting': true,
            'desktop_restart_preserved_owner': true,
            'transcript_and_artifact_persisted': true,
            'desktop_database_read_only': true,
          }),
        );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
