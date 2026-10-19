import 'dart:io';
import 'dart:convert';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/conversation_answer.dart';
import 'package:foresight_core/src/model_gate.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class _Retrieval extends RagServiceBase {
  String? document;
  String text = 'Mira leads Atlas.';
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      if (document != null)
        RetrievedChunk(documentId: document, text: text, relevanceScore: .9),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Busy implements ModelGate {
  @override
  bool get modelBusy => true;
}

class _Generator extends NativeRuntime {
  _Generator()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  Map<String, dynamic>? schema;
  bool fail = false;
  @override
  Map<String, dynamic> get effectiveState => {'backend': 'litert-lm-fixture'};
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    schema = responseSchema;
    if (fail) {
      yield {'type': 'error', 'message': 'worker disappeared'};
      yield {'type': 'done', 'status': 'failed'};
    } else {
      yield {
        'type': 'delta',
        'text': '{"answer":"Mira leads Atlas. [S1]","citations":["S1"]}',
      };
      yield {'type': 'done', 'status': 'completed'};
    }
  }
}

void main() {
  late Store store;
  late Domain domain;
  late _Retrieval retrieval;
  setUp(() async {
    final root = createTestTempDirectorySync('ar-');
    store = Store('${root.path}/app.db');
    addTearDown(store.close);
    retrieval = _Retrieval();
    final server = Server.create(services: [retrieval]);
    await server.serve(
      address: InternetAddress(
        '${root.path}/helper.sock',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
    addTearDown(server.shutdown);
    final helper = Helper(
      '${root.path}/helper.sock',
      root.path,
      manageProcess: false,
    );
    addTearDown(helper.close);
    domain = Domain(store, helper);
    addTearDown(domain.close);
  });

  void source(String title, String content) {
    retrieval.document = store.importText(
      title,
      content,
      'text/plain',
      'fixture',
    );
    store.state(retrieval.document!, 'indexed');
  }

  test(
    'missing meeting and busy model reject answers before persistence',
    () async {
      await expectLater(
        domain.askInConversation('Question', 'chat', meetingId: 999).toList(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.notFound),
        ),
      );
      domain.modelGate = _Busy();
      await expectLater(
        domain.askInConversation('Question', 'chat').toList(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect(store.rows('SELECT * FROM answers'), isEmpty);
    },
  );

  test(
    'no relevant excerpts persists a recoverable insufficient-context result',
    () async {
      source('Unrelated', 'Bananas and oranges.');
      retrieval.document = null;
      final answer = await domain
          .askInConversation('Who leads Atlas?', 'chat')
          .last;
      expect(answer, contains('no current source excerpts'));
      expect(
        store.rows('SELECT status FROM answers').single['status'],
        'insufficient_context',
      );
      source('Atlas', 'Mira leads Atlas.');
      await expectLater(
        domain.askInConversation('Who leads Atlas?', 'chat').toList(),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
      expect(store.rows('SELECT * FROM answers'), hasLength(1));
    },
  );

  test(
    'source procedure answers persist every step without a generation worker',
    () async {
      final guide =
          '# How to Write a Target Product Profile\n\n'
          '${List.generate(10, (i) => '## Step ${i + 1} — Task ${i + 1}\n${'Relevant instructions and expected output. ' * 15}\n').join('\n')}';
      source('How to Write a Target Product Profile', guide);
      final meeting = store.meeting('Planning');
      final answer = await domain
          .askInConversation(
            'How to write a Target Product Profile. I need step by step instruction',
            'chat',
            meetingId: meeting,
          )
          .last;
      for (var step = 1; step <= 10; step++) {
        expect(answer, contains('Step $step — Task $step'));
      }
      final row = store.rows('SELECT * FROM answers').single;
      expect(row['model'], 'source-guide');
      expect(row['status'], 'completed');
      expect(
        store.rows('SELECT * FROM meeting_answers').single['meeting_id'],
        meeting,
      );
      expect(jsonDecode(row['citations'] as String), hasLength(1));
    },
  );

  test('complete examples retain evidence boundaries and all citations', () async {
    String example(String name, String value) =>
        '## $name\nA published example with its evidence limitations.\n'
        '### Targets\n| Attribute | Minimum | Preferred |\n|---|---|---|\n'
        '| Duration | $value | 2 weeks |\n| Safety | Comparable | Better |\n'
        '${'Evidence boundaries and intended population remain part of the example. ' * 5}\n';
    source(
      'ABC Examples.md',
      '# ABC Examples\n${example('1. Alpha', '12–24 months')}${example('2. Beta', '2019')}',
    );
    final answer = await domain
        .askInConversation('Show me two examples of ABC in detail', 'examples')
        .last;
    expect(answer, contains('12–24 months'));
    expect(answer, contains('2019'));
    final row = store.rows('SELECT * FROM answers').single;
    expect(row['model'], 'source-examples');
    expect(jsonDecode(row['citations'] as String), hasLength(2));
  });

  test(
    'local grounding carries current evidence and failure cannot persist a draft',
    () async {
      source('Atlas', 'Mira leads Atlas.');
      final runtime = _Generator();
      addTearDown(runtime.close);
      domain.generator = runtime;
      await domain.askInConversation('Who leads Atlas?', 'chat').last;
      await domain.askInConversation('And who leads it?', 'chat').last;
      final grounded = runtime.schema!['x-foresight-grounded-request'] as Map;
      expect(grounded['previous_question'], 'Who leads Atlas?');
      expect((grounded['sources'] as List).single['excerpt'], contains('Mira'));
      runtime.fail = true;
      final visible = await domain
          .askInConversation('Who leads Atlas?', 'chat')
          .toList();
      expect(visible, contains('Answer generation failed: worker disappeared'));
      final failed = store
          .rows('SELECT * FROM answers ORDER BY id DESC LIMIT 1')
          .single;
      expect(failed['body'], 'Answer generation failed. Please retry.');
      expect(failed['status'], 'failed');
      expect(jsonDecode(failed['citations'] as String), isEmpty);
      final cancelled = ConversationAnswer(
        domain,
        'Cancelled',
        'chat',
        current: () => false,
      );
      expect(
        () => cancelled.saveAnswer(
          'Cancelled',
          'late',
          'completed',
          [],
          '',
          conversation: 'chat',
        ),
        throwsA(isA<RpcError>()),
      );
      expect(store.rows('SELECT * FROM answers'), hasLength(3));
    },
  );
}
