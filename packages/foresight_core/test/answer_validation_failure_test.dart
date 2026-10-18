import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:convert';
import 'web_answer_test.dart' show ToolRuntime, fixtureSearch;
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class Retrieval extends RagServiceBase {
  late String document;
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      RetrievedChunk(
        documentId: document,
        text: 'Mira leads Atlas.',
        relevanceScore: .9,
      ),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DraftRuntime extends NativeRuntime {
  DraftRuntime(this.raw, this.status)
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final String raw, status;
  @override
  Map<String, dynamic> get effectiveState => {'backend': 'fixture'};
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    yield {'type': 'delta', 'text': raw};
    yield {'type': 'done', 'status': status};
  }
}

class FailedWebRuntime extends ToolRuntime {
  @override
  Stream<Map<String, dynamic>> generateWebAnswer(
    String id,
    String prompt, {
    List<Map<String, dynamic>> messages = const [],
    String systemPrompt = '',
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    yield {'type': 'delta', 'text': 'PARTIAL SECRET ANSWER'};
    yield {'type': 'done', 'status': 'failed'};
  }
}

void main() {
  test('failed web answers discard partial body and local citations', () async {
    final directory = createTestTempDirectorySync('failed-web-answer-');
    final store = Store('${directory.path}/app.db');
    final helper = Helper(
      '/nonexistent.sock',
      '/nonexistent',
      manageProcess: false,
    );
    final runtime = FailedWebRuntime();
    final domain = Domain(store, helper, webSearch: fixtureSearch())
      ..generator = runtime;
    try {
      await domain.askWithWebInConversation('Question', 'fixture').last;
      final row = store.rows('SELECT * FROM answers').single;
      expect(row['status'], 'failed');
      expect(row['body'], 'Answer generation failed. Please retry.');
      expect(jsonDecode(row['citations'] as String), isEmpty);
    } finally {
      await domain.application.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'validated insufficient context remains an owned non-failure result',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'validated-insufficient-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final socket = '${directory.path}/helper.sock';
      final retrieval = Retrieval()
        ..document = store.importText(
          'Atlas',
          'Mira leads Atlas.',
          'text/plain',
          'fixture',
        );
      store.state(retrieval.document, 'indexed');
      final server = Server.create(services: [retrieval]);
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(
        socket,
        '${directory.path}/unused',
        manageProcess: false,
      );
      final runtime = DraftRuntime(
        '{"answer":"Insufficient context","citations":[]}',
        'completed',
      );
      final domain = Domain(store, helper)..generator = runtime;
      try {
        final answer = await domain
            .askInConversation('Who is Unlisted Person90210?', 'fixture')
            .last;
        expect(answer, 'Insufficient context');
        final row = store.rows('SELECT * FROM answers').single;
        expect(row['status'], 'insufficient_context');
        expect(row['body'], 'Insufficient context');
        expect(jsonDecode(row['citations'] as String), isEmpty);
      } finally {
        domain.close();
        runtime.close();
        await helper.close();
        await server.shutdown();
        store.close();
      }
    },
  );

  for (final payload in [
    ('{"answer":"Unverified draft [S1, S9]","citations":["S1"]}', 'completed'),
    ('{"answer":"Unverified draft","citations":[1]}', 'completed'),
    ('{"answer":"Unverified draft","citations":["S1"]}', 'failed'),
    ('{"answer":"Unverified draft","citations":["S1"]}', 'cancelled'),
    (
      '{"answer":"Unverified draft","citations":["S1"]}',
      'insufficient_context',
    ),
  ]) {
    test(
      'unverified local answer never reaches persisted body or citations: $payload',
      () async {
        final directory = createTestTempDirectorySync('answer-validation-');
        addTearDown(() {
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        });
        final store = Store('${directory.path}/app.db');
        final socket = '${directory.path}/helper.sock';
        final retrieval = Retrieval()
          ..document = store.importText(
            'Atlas',
            'Mira leads Atlas.',
            'text/plain',
            'fixture',
          );
        store.state(retrieval.document, 'indexed');
        final server = Server.create(services: [retrieval]);
        await server.serve(
          address: InternetAddress(socket, type: InternetAddressType.unix),
          port: 0,
        );
        final helper = Helper(
          socket,
          '${directory.path}/unused',
          manageProcess: false,
        );
        final runtime = DraftRuntime(payload.$1, payload.$2);
        final domain = Domain(store, helper)..generator = runtime;
        try {
          final visible = <String>[];
          final answer = domain
              .askInConversation('Who leads Atlas?', 'fixture')
              .forEach(visible.add);
          if (payload.$2 == 'completed') {
            await expectLater(answer, throwsFormatException);
          } else {
            await answer;
          }
          expect(visible, contains(contains('Unverified draft')));
          final row = store.rows('SELECT * FROM answers').single;
          expect(
            row['status'],
            ['completed', 'insufficient_context'].contains(payload.$2)
                ? 'failed'
                : payload.$2,
          );
          expect(row['body'], 'Answer generation failed. Please retry.');
          expect(jsonDecode(row['citations'] as String), isEmpty);
        } finally {
          domain.close();
          await helper.close();
          await server.shutdown();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
