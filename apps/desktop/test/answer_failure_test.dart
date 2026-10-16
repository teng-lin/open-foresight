import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/helper.dart';
import 'package:open_foresight/native.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated/rag_service.pbgrpc.dart';
import 'domain_lifecycle_test.dart' show DelayedIndexService;

class AnswerService extends DelayedIndexService {
  final String id;
  AnswerService(this.id);
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      RetrievedChunk(
        documentId: id,
        text: 'Mira Shah leads the Atlas laboratory.',
        relevanceScore: .8,
      ),
    ],
  );
}

class FailedAnswerRuntime extends NativeRuntime {
  FailedAnswerRuntime() : super('libc.so.6');
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    yield {
      'type': 'delta',
      'text': '{"status":"insufficient_context","answer":"Insufficient',
    };
    yield {
      'type': 'error',
      'message': 'Generation runner exited with status 1',
    };
    yield {'type': 'done', 'status': 'failed'};
  }
}

void main() {
  test(
    'failed generation replaces provisional insufficient text with an error',
    () async {
      final tmp = Directory.systemTemp.createTempSync('answer-failure-');
      final store = Store('${tmp.path}/app.db');
      final id = store.importText(
        'Atlas',
        'Mira Shah leads the Atlas laboratory.',
        'text/plain',
        'fixture',
      );
      store.state(id, 'indexed');
      final socket = '${tmp.path}/helper.sock';
      final server = Server.create(services: [AnswerService(id)]);
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${tmp.path}/helper');
      final domain = Domain(store, helper)..generator = FailedAnswerRuntime();
      try {
        final answer = (await domain.ask('Who is Mira Shah?').toList()).last;
        expect(answer, startsWith('Answer generation failed:'));
        expect(answer, isNot(contains('Insufficient')));
        expect(
          store.rows('SELECT status FROM answers').single['status'],
          'failed',
        );
      } finally {
        domain.close();
        domain.generator?.close();
        await helper.close();
        await server.shutdown();
        store.close();
        tmp.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isLinux,
  );
}
