import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/service.dart' show ApplicationService;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class _Retrieval extends RagServiceBase {
  String document = '';
  final queries = <String>[];
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    queries.add(request.query.textQuery);
    return RetrieveResponse(
      chunks: [
        RetrievedChunk(
          documentId: document,
          text: 'Mira owns the draft and sends it on Tuesday.',
          relevanceScore: .9,
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Runtime extends NativeRuntime {
  final prompts = <String>[];
  _Runtime()
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
    prompts.add(prompt);
    yield {
      'type': 'delta',
      'text': '{"status":"insufficient_context","answer":"","citations":[]}',
    };
    yield {'type': 'done', 'status': 'completed'};
  }
}

void main() {
  test(
    'meeting follow-up retrieval and generation use only that conversation history',
    () async {
      final directory = createTestTempDirectorySync('meeting-history-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final retrieval = _Retrieval();
      final server = Server.create(services: [retrieval]);
      final socket = '${directory.path}/helper.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${directory.path}/helper');
      final runtime = _Runtime();
      final domain = Domain(store, helper)..generator = runtime;
      try {
        final first = store.meeting('Alpha');
        final second = store.meeting('Beta');
        retrieval.document = store.importText(
          'Shared source',
          'Mira owns the draft and sends it on Tuesday.',
          'text/plain',
          'fixture',
        );
        store.state(retrieval.document, 'indexed');
        store.answer(
          'What is the general secret?',
          'GENERAL_ONLY',
          'completed',
          [],
          'fixture',
        );
        store.answer(
          'Who owns the draft?',
          'ALPHA_ONLY',
          'completed',
          [],
          'fixture',
          conversation: 'meeting:$first',
        );
        store.answer(
          'What is the other plan?',
          'BETA_ONLY',
          'completed',
          [],
          'fixture',
          conversation: 'meeting:$second',
        );
        await domain
            .askInConversation(
              'What about it?',
              'ignored by meeting scope',
              meetingId: first,
            )
            .drain<void>();
        expect(retrieval.queries.single, contains('Who owns the draft?'));
        expect(retrieval.queries.single, isNot(contains('general secret')));
        expect(retrieval.queries.single, isNot(contains('other plan')));
        expect(runtime.prompts, isNotEmpty);
        expect(runtime.prompts.single, contains('ALPHA_ONLY'));
        expect(runtime.prompts.single, isNot(contains('GENERAL_ONLY')));
        expect(runtime.prompts.single, isNot(contains('BETA_ONLY')));
        final saved = store
            .rows(
              'SELECT answers.*,meeting_id FROM answers JOIN meeting_answers ON answers.id=answer_id',
            )
            .single;
        expect(saved['question'], 'What about it?');
        expect(saved['conversation'], 'meeting:$first');
        expect(saved['meeting_id'], first);
        expect(saved['status'], 'insufficient_context');
        await expectLater(
          domain
              .askInConversation('Invalid meeting', 'desktop', meetingId: 999)
              .drain<void>(),
          throwsStateError,
        );
        expect(
          store.rows('SELECT * FROM answers WHERE question=?', [
            'Invalid meeting',
          ]),
          isEmpty,
        );
      } finally {
        domain.close();
        runtime.close();
        await helper.close();
        await server.shutdown();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'remote streams and command answers retain exact meeting links across clients',
    () async {
      final directory = createTestTempDirectorySync('of-chat-');
      final original = runtimeConfiguration.environment['FORESIGHT_HELPER'];
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final service = await ApplicationService.start(profile);
      RemoteDomain? first, second;
      try {
        first = await RemoteDomain.connect(profile);
        second = await RemoteDomain.connect(profile);
        final alpha =
            (await first.command(Operation.meetingsCreate, {'title': 'Alpha'})
                    as Map)['id']
                as int;
        final beta =
            (await second.command(Operation.meetingsCreate, {'title': 'Beta'})
                    as Map)['id']
                as int;
        await Future.wait([
          first
              .askInConversation('Alpha question', 'desktop', meetingId: alpha)
              .drain<void>(),
          second
              .askInConversation('Beta question', 'desktop', meetingId: beta)
              .drain<void>(),
          first.ask('General question').drain<void>(),
        ]);
        await first.command(Operation.answer, {
          'question': 'Command question',
          'meeting_id': alpha,
        });
        final rows = service.domain.store.rows(
          'SELECT question,conversation,meeting_id FROM answers LEFT JOIN meeting_answers ON answers.id=answer_id ORDER BY answers.id',
        );
        expect(
          rows,
          unorderedEquals([
            {
              'question': 'Alpha question',
              'conversation': 'meeting:$alpha',
              'meeting_id': alpha,
            },
            {
              'question': 'Beta question',
              'conversation': 'meeting:$beta',
              'meeting_id': beta,
            },
            {
              'question': 'General question',
              'conversation': 'desktop',
              'meeting_id': null,
            },
            {
              'question': 'Command question',
              'conversation': 'meeting:$alpha',
              'meeting_id': alpha,
            },
          ]),
        );
        await expectLater(
          first
              .askInConversation('Invalid', 'desktop', meetingId: 999)
              .drain<void>(),
          throwsStateError,
        );
        expect(
          service.domain.store.rows('SELECT * FROM answers'),
          hasLength(4),
        );
      } finally {
        for (final remote in [first, second]) {
          if (remote == null) continue;
          remote.close();
          await remote.client.close();
          await remote.helper.close();
          remote.store.close();
        }
        await service.close();
        if (original == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
        } else {
          runtimeConfiguration.environment['FORESIGHT_HELPER'] = original;
        }
        directory.deleteSync(recursive: true);
      }
    },
  );
}
