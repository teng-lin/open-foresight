import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart' as rag;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  final executable = Platform.environment['FORESIGHT_TEST_HELPER'];
  test(
    'application incremental producer survives real helper restart/reset and publishes parent citations',
    () async {
      final root = createTestTempDirectorySync('app-native-');
      final permissions = await Process.run('/bin/chmod', ['700', root.path]);
      expect(
        permissions.exitCode,
        0,
        reason: '${permissions.stdout}\n${permissions.stderr}',
      );
      final socket = '${root.path}/h.sock', storage = '${root.path}/helper';
      Store? store;
      Helper? helper;
      Domain? domain;
      Application? app;
      Process? child;
      final logs = <Future<String>>[];
      Future<void> stopApp() async {
        await app?.close();
        domain?.close();
        await domain?.drain();
        await helper?.close();
        store?.close();
        app = null;
        domain = null;
        helper = null;
        store = null;
      }

      Future<void> stopHelper() async {
        final process = child;
        if (process == null) return;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        child = null;
      }

      addTearDown(() async {
        await stopApp();
        await stopHelper();
        for (final log in logs) {
          final output = await log;
          if (output.isNotEmpty) print(output);
        }
      });
      Future<void> startHelper() async {
        final process = await Process.start(executable!, [
          socket,
          storage,
          '--allow-test-models',
        ]);
        child = process;
        logs.add(process.stdout.transform(utf8.decoder).join());
        logs.add(process.stderr.transform(utf8.decoder).join());
      }

      Future<void> startApp() async {
        final database = Store('${root.path}/application.db');
        store = database;
        final transport = Helper(socket, storage, manageProcess: false);
        helper = transport;
        await eventually(() async {
          try {
            return (await transport.client.ping(
              rag.PingRequest(),
              options: CallOptions(timeout: const Duration(milliseconds: 200)),
            )).success;
          } catch (_) {
            return false;
          }
        }, timeout: const Duration(seconds: 10));
        final configured = await transport.client.updateModelPaths(
          rag.UpdateModelPathsRequest(
            embeddingModelPath: 'test://deterministic',
          ),
        );
        expect(configured.success, true, reason: configured.errorMessage);
        transport.snapshot = await control.HelperControlClient(
          transport.channel,
        ).getState(control.Empty());
        domain = Domain(database, transport);
        app = Application(domain!);
      }

      Future<List<rag.RetrievedChunk>> search(String id) async =>
          (await helper!.client.retrieveContext(
            rag.RetrieveRequest(
              query: rag.Query(textQuery: 'speech'),
              minSimilarityScore: -1,
              maxResults: 100,
              allowedDocumentIds: [id],
            ),
          )).chunks;
      await startHelper();
      await startApp();
      final meeting = store!.meeting('Native incremental capture'),
          id = 'meeting-1';
      expect(meeting, 1);
      for (var i = 0; i < 8; i++) {
        store!.transcript(
          meeting,
          'speech segment $i',
          true,
          i * 10,
          i * 10 + 10,
          'microphone',
        );
        await app!.indexMeeting(meeting);
      }
      var chunks = await search(id);
      expect(chunks, hasLength(8));
      expect(chunks.every((chunk) => chunk.documentId == id), true);
      expect(
        chunks.map((chunk) => chunk.text).join('\n'),
        contains('speech segment 7'),
      );
      final sourceRevision = store!.sourceQueries.source(id)!.revision;
      store!.db.execute(
        "UPDATE transcript SET text='edited speech' WHERE id=(SELECT min(id) FROM transcript)",
      );
      store!.db.execute(
        'DELETE FROM transcript WHERE id=(SELECT max(id) FROM transcript)',
      );
      await app!.indexMeeting(meeting);
      chunks = await search(id);
      expect(chunks, hasLength(7));
      expect(
        chunks.map((chunk) => chunk.text).join('\n'),
        allOf(
          contains('edited speech'),
          isNot(contains('speech segment 0')),
          isNot(contains('speech segment 7')),
        ),
      );
      expect(
        store!.sourceQueries.source(id)!.revision,
        greaterThan(sourceRevision),
      );
      await stopApp();
      await stopHelper();
      await startHelper();
      await startApp();
      await app!.recoverMeetingIndexes();
      expect(app!.meetingIndexWork['transcript_rows_read'], 0);
      expect(await search(id), hasLength(7));
      // Independently lost helper state must be discovered by startup replay,
      // despite a successful app-side revision from before the loss.
      expect(
        (await helper!.client.deleteDocument(
          rag.DeleteRequest(documentId: id),
        )).success,
        true,
      );
      await app!.recoverMeetingIndexes();
      expect(await search(id), hasLength(7));
      expect(app!.meetingIndexWork['transcript_rows_read'], 0);
      store!.db.execute('DELETE FROM transcript WHERE meeting_id=?', [meeting]);
      await app!.recoverMeetingIndexes();
      expect(await search(id), isEmpty);
      expect(store!.sourceQueries.source(id)!.content, '');
      expect(store!.sourceQueries.source(id)!.state, 'indexed');
      await domain!.delete(id);
      expect(await search(id), isEmpty);
      await app!.recoverMeetingIndexes();
      expect(store!.sourceQueries.source(id), isNull);
      expect(await search(id), isEmpty);
    },
    skip: executable == null || executable.isEmpty
        ? 'Requires FORESIGHT_TEST_HELPER from a freshly built repository-root test-helper target'
        : false,
  );
}
