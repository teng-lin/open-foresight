import 'package:foresight_core/src/application.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/helper.dart';
import 'package:open_foresight/native.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated/rag_service.pbgrpc.dart';
import '../../../packages/foresight_core/test/fixtures/delayed_index_service.dart'
    show DelayedIndexService;

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
  FailedAnswerRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
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
      final tmp = Directory('/tmp').createTempSync('answer-failure-');
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
        expect(answer, 'Answer generation failed. Please retry.');
        expect(answer, isNot(contains('Insufficient')));
        final saved = store.rows('SELECT * FROM answers').single;
        expect(saved['status'], 'failed');
        expect(saved['body'], answer);
        expect(saved['body'], isNot(contains('Insufficient')));
        expect(jsonDecode(saved['citations'] as String), isEmpty);
      } finally {
        domain.close();
        domain.generator?.close();
        await helper.close();
        await server.shutdown();
        store.close();
        tmp.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );
}
