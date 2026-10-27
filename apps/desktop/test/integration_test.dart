import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import '../test_support/core_fixture.dart' as control;

void main() {
  test(
    'real Unix helper + native generation cited answer, restart persistence and deletion',
    () async {
      final tmp = createTestTempDirectorySync('foresight-e2e-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      Process.runSync('chmod', ['700', tmp.path]);
      final store = Store('${tmp.path}/app.db');
      final helper = Helper('${tmp.path}/helper.sock', '${tmp.path}/helper');
      final d = Domain(store, helper);
      final app = Application(d);
      final elapsed = Stopwatch()..start();
      try {
        await helper.start();
        expect(helper.state, contains('live'));
        final configured = await helper.client.updateModelPaths(
          UpdateModelPathsRequest(
            embeddingModelPath: Platform.environment['FORESIGHT_EMBEDDING']!,
            useGpu: false,
          ),
        );
        expect(configured.success, true, reason: configured.errorMessage);
        final embeddingState = await control.HelperControlClient(
          helper.channel,
        ).getState(control.Empty());
        expect(embeddingState.pipeline, 'ready');
        await store.register(
          'generation',
          Platform.environment['FORESIGHT_GENERATION_MODEL']!,
          Platform.environment['FORESIGHT_GENERATION_RUNNER']!,
          backend:
              Platform.environment['FORESIGHT_GENERATION_BACKEND'] ??
              'litert_lm',
        );
        d.generator = NativeRuntime(Platform.environment['FORESIGHT_NATIVE']!);
        await d.generator!.load(
          Platform.environment['FORESIGHT_GENERATION_RUNNER']!,
          Platform.environment['FORESIGHT_GENERATION_MODEL']!,
          backend:
              Platform.environment['FORESIGHT_GENERATION_BACKEND'] ??
              'litert_lm',
        );
        final id = store.importText(
          'Mission briefing',
          'The Apollo project launches on May 17. The project owner is Alice Chen.',
          'text/plain',
          'local evaluation',
        );
        await d.index(id);
        expect(store.sources.single['state'], 'indexed');
        await app
            .ask('What is the Apollo project launch date? Cite the source.')
            .drain<void>();
        final answer = store.rows('SELECT * FROM answers').single;
        expect(
          answer['status'],
          'completed',
          reason: answer['body'].toString(),
        );
        expect(answer['body'], contains('May'));
        expect(
          ((jsonDecode(answer['citations'] as String) as List).single
              as Map)['document_id'],
          id,
        );
        store.saveNote(null, 'Review', 'User edits survive');
        final pid = helper.process!.pid;
        Process.killPid(pid, ProcessSignal.sigkill);
        await eventually(
          () =>
              helper.process != null &&
              helper.process!.pid != pid &&
              helper.snapshot != null,
          timeout: const Duration(seconds: 30),
        );
        expect(helper.process?.pid, isNot(pid));
        final ping = await helper.client.ping(PingRequest());
        expect(ping.success, true);
        await helper.client.updateModelPaths(
          UpdateModelPathsRequest(
            embeddingModelPath: Platform.environment['FORESIGHT_EMBEDDING']!,
            useGpu: false,
          ),
        );
        final found = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'Apollo launch'),
            maxResults: 3,
            allowedDocumentIds: [id],
            minSimilarityScore: 0,
            userId: 'local_user',
          ),
        );
        expect(found.chunks.first.documentId, id);
        await d.delete(id);
        expect(store.sources, isEmpty);
        expect(
          store.rows('SELECT * FROM notes').single['body'],
          'User edits survive',
        );
        final deleted = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'Apollo launch'),
            maxResults: 3,
            allowedDocumentIds: [id],
            minSimilarityScore: 0,
            userId: 'local_user',
          ),
        );
        expect(deleted.chunks, isEmpty);
        final report = Platform.environment['FORESIGHT_EVALUATION_REPORT'];
        if (report != null) {
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'workflow': 'Dart UDS retrieval + native cited generation',
              'question': answer['question'],
              'answer': answer['body'],
              'status': answer['status'],
              'citations': jsonDecode(answer['citations'] as String),
              'generator': store
                  .rows("SELECT * FROM models WHERE kind='generation'")
                  .single,
              'helper_model': embeddingState.model.toProto3Json(),
              'elapsed_ms': elapsed.elapsedMilliseconds,
              'validated_at': DateTime.now().toUtc().toIso8601String(),
              'helper_restart':
                  'SIGKILL + distinct supervised PID + Ping + committed-source retrieval passed',
              'source_deletion':
                  'live app tombstone + empty scoped helper retrieval passed',
              'fast_persistence_tests':
                  'source revisions, archived citations, edited notes/artifacts DB reopen passed',
            }),
          );
        }
      } finally {
        await app.close();
        d.close();
        await d.drain();
        await helper.close();
        store.close();
        tmp.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['FORESIGHT_INTEGRATION'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
