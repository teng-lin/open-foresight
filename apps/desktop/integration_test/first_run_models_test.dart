import 'dart:convert';
import 'package:foresight_test_support/macos_integration_runtime.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/main.dart' as app;
import 'package:open_foresight/features/settings/gemma_setup_view.dart';

import '../test_support/current_read.dart';
// These helpers launch/close app.main and speak the real MCP protocol. This
// journey deliberately never calls the setup-skipping finishOnboarding helper.
import 'service_mcp_test.dart' show startDesktop, closeDesktop, waitFor, Mcp;

Future<Map<String, dynamic>> fixtureRequest(String path, {String? mode}) async {
  final origin = Uri.parse(
    Platform.environment['FORESIGHT_FIRST_RUN_LOOPBACK']!,
  );
  if (origin.scheme != 'http' || origin.host != '127.0.0.1')
    throw StateError('Loopback fixture required');
  final client = HttpClient();
  try {
    final request = mode == null
        ? await client.getUrl(origin.resolve(path))
        : await client.postUrl(origin.resolve(path));
    if (mode != null) {
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode({'mode': mode}));
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

List<Map<String, dynamic>> requestRecords(Map<String, dynamic> state) =>
    (state['requests'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    prepareMacosIntegrationRuntime(registerTearDown: addTearDown);
  });
  testWidgets(
    'fresh compiled setup survives interruption, rejects bad bytes and adopts indexed models',
    (tester) async {
      expect(const bool.fromEnvironment('FORESIGHT_ENABLE_TEST_HOOKS'), true);
      final report = <String, Object>{
        'real_models': 'not_run',
        'real_gpu': 'not_run',
      };
      final reportFile = File(
        Platform.environment['FORESIGHT_FIRST_RUN_REPORT']!,
      );
      app.WorkspaceTestAccess? workspace;
      Mcp? mcp;
      IOSink? mcpLog;
      String visibleText() => find
          .byType(Text)
          .evaluate()
          .map((element) => (element.widget as Text).data)
          .whereType<String>()
          .join('\n');
      try {
        await startDesktop(tester);
        workspace =
            tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
        Future<List<ModelRegistration>> models() =>
            currentRead(workspace!.d.store, StoreReadQueries.models());
        expect(await models(), isEmpty);
        report['fresh'] = true;
        await waitFor(
          tester,
          () => find.text('Start Foresight').evaluate().isNotEmpty,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Start Foresight'));
        await waitFor(
          tester,
          () => find.byType(GemmaSetupDialog).evaluate().isNotEmpty,
        );
        await waitFor(
          tester,
          () =>
              find
                  .widgetWithText(FilledButton, 'Download models')
                  .evaluate()
                  .isNotEmpty &&
              tester
                      .widget<FilledButton>(
                        find.widgetWithText(FilledButton, 'Download models'),
                      )
                      .onPressed !=
                  null,
        );
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Download models'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Download models'));
        await waitFor(
          tester,
          () => find
              .text('Fixture embedding (not a model) terms')
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Accept and download'),
        );
        await waitFor(tester, () {
          if (find
              .widgetWithText(FilledButton, 'Retry')
              .evaluate()
              .isNotEmpty) {
            fail(
              'Fixture setup refused before generation consent: ${visibleText()}',
            );
          }
          return find
              .text('Fixture generation (not a model) terms')
              .evaluate()
              .isNotEmpty;
        });
        expect((await models()).map((model) => model.kind), ['embedding']);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Accept and download'),
        );
        await waitFor(tester, () async {
          final state = await fixtureRequest('/state');
          return requestRecords(state).any(
            (request) =>
                request['kind'] == 'generation' &&
                request['mode'] == 'hold' &&
                request['sent'] == 4096,
          );
        });
        expect((await models()).map((model) => model.kind), ['embedding']);
        report['partial'] = true;
        // The service owns transfer independently of the desktop. Interrupt
        // the actual HTTP body, then let its normal bounded retries settle.
        await fixtureRequest('/control', mode: 'interrupt');
        await waitFor(
          tester,
          () =>
              find.widgetWithText(FilledButton, 'Retry').evaluate().isNotEmpty,
        );
        expect((await models()).map((model) => model.kind), ['embedding']);
        report['interrupted'] = true;
        await closeDesktop(tester, workspace);
        workspace = null;
        report['desktop_closed'] = true;
        await fixtureRequest('/control', mode: 'corrupt');

        await startDesktop(tester);
        workspace =
            tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
        await waitFor(
          tester,
          () => find.byType(GemmaSetupDialog).evaluate().isNotEmpty,
        );
        expect((await models()).map((model) => model.kind), ['embedding']);
        report['restarted'] = true;
        await waitFor(
          tester,
          () =>
              find
                  .widgetWithText(FilledButton, 'Continue')
                  .evaluate()
                  .isNotEmpty &&
              tester
                      .widget<FilledButton>(
                        find.widgetWithText(FilledButton, 'Continue'),
                      )
                      .onPressed !=
                  null,
        );
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await waitFor(
          tester,
          () =>
              find.widgetWithText(FilledButton, 'Retry').evaluate().isNotEmpty,
        );
        expect(
          find.text(
            'Model download failed size or hash verification. Retry the download.',
          ),
          findsWidgets,
        );
        expect((await models()).map((model) => model.kind), ['embedding']);
        report['checksum_rejected'] = true;
        await fixtureRequest('/control', mode: 'good');
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Retry'));
        await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
        await waitFor(
          tester,
          () async =>
              (await models()).any((model) => model.kind == 'generation'),
        );
        report['retried'] = true;
        final before = await fixtureRequest('/state');
        final requestCount = (before['requests'] as List).length;
        await closeDesktop(tester, workspace);
        workspace = null;
        await startDesktop(tester);
        workspace =
            tester.state(find.byType(app.Workspace)) as app.WorkspaceTestAccess;
        await waitFor(tester, () async => (await models()).length == 2);
        expect((await models()).map((model) => model.kind).toSet(), {
          'embedding',
          'generation',
        });
        final after = await fixtureRequest('/state');
        expect((after['requests'] as List).length, requestCount);
        expect(
          requestRecords(
            after,
          ).where((request) => request['kind'] == 'embedding'),
          hasLength(1),
        );
        report['adopted'] = true;
        final sourceId = Platform.environment['FORESIGHT_FIRST_RUN_SOURCE_ID'];
        await waitFor(
          tester,
          () async =>
              (await currentRead(
                workspace!.d.store,
                StoreReadQueries.sources(),
              )).any(
                (source) => source.id == sourceId && source.state == 'indexed',
              ),
        );
        report['indexed'] = true;
        final status = await workspace.d.command(Operation.status) as Map;
        mcp = Mcp(
          await Process.start(
            Platform.environment['FORESIGHT_MCP_EXECUTABLE']!,
            const [],
          ),
        );
        mcpLog = File(
          '${reportFile.parent.path}/first-run-mcp.stderr',
        ).openWrite();
        mcp.process.stderr.listen(mcpLog.add);
        await mcp.initialize();
        final mcpStatus = await mcp.tool('get_status');
        expect(
          ((mcpStatus['structuredContent'] as Map)['result'] as Map)['pid'],
          status['pid'],
        );
        report['same_service_mcp'] = true;
      } catch (error) {
        report['visible_text'] = visibleText();
        report['failure'] = error.toString();
        rethrow;
      } finally {
        reportFile.writeAsStringSync(jsonEncode(report));
        if (mcp != null) await mcp.close();
        await mcpLog?.close();
        if (workspace != null) await closeDesktop(tester, workspace);
      }
    },
  );
}
