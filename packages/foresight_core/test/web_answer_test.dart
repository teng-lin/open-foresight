import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

class LocalRetrieval extends RagServiceBase {
  late String document;
  String text = 'Mira owns the draft and sends it on Tuesday.';
  final encoded = <String>[];
  int Function(String)? tokenCount;
  @override
  Future<EncodeResponse> encode(ServiceCall call, EncodeRequest request) async {
    encoded.add(request.text);
    return EncodeResponse(
      tokens: List.filled(tokenCount?.call(request.text) ?? 1, 7),
    );
  }

  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      RetrievedChunk(documentId: document, text: text, relevanceScore: .9),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ToolRuntime extends NativeRuntime {
  ToolRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  late Future<String> Function(ReferenceToolDispatcher) answer;
  final prompts = <String>[];
  final histories = <List<Map<String, dynamic>>>[];
  int contextLimit = 4096;
  final summaries = <String>[];
  final summaryIds = <String>[];
  final answerIds = <String>[];
  Future<String> Function(String)? summarize;
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int maxOutputTokens = 1024,
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    summaries.add(prompt);
    summaryIds.add(id);
    yield {
      'type': 'delta',
      'text':
          await (summarize?.call(prompt) ??
              Future.value('Important earlier facts')),
    };
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'backend': 'litert-lm-fixture',
    'context_length': contextLimit,
  };
  @override
  Stream<Map<String, dynamic>> generateWithTools(
    String id,
    String prompt, {
    required List<Map<String, dynamic>> tools,
    required ReferenceToolDispatcher dispatcher,
    List<Map<String, dynamic>> messages = const [],
    String systemPrompt = '',
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    prompts.add(prompt);
    answerIds.add(id);
    histories.add(messages);
    expect(systemPrompt, referenceChatInstructions);
    expect(prompt, contains('[Current Date: '));
    expect(prompt, contains('Query: '));
    expect(tools.single['name'], 'google_search');
    final text = await answer(dispatcher);
    yield {
      'type': 'delta',
      'text': text,
      'response': referenceTextMessage('assistant', text),
    };
    yield {'type': 'done', 'status': 'completed'};
  }
}

Map<String, dynamic> searchCall(String query) => {
  'function': {
    'name': 'google_search',
    'arguments': {'query': query},
  },
};

SearchCallbacks fixtureSearch({
  Completer<void>? gate,
  Completer<void>? entered,
}) => SearchCallbacks(
  search: (query) async {
    if (entered != null && !entered.isCompleted) entered.complete();
    await gate?.future;
    return query == 'first'
        ? [
            const WebSearchItem(title: 'A', link: 'https://a', snippet: 'a'),
            const WebSearchItem(title: 'B', link: 'https://b', snippet: 'b'),
          ]
        : [
            const WebSearchItem(title: 'B', link: 'https://b', snippet: 'b2'),
            const WebSearchItem(title: 'C', link: 'https://c', snippet: 'c'),
          ];
  },
  summarize: (_, _) async => '',
);

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late Domain domain;
  late ToolRuntime runtime;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('web-answer-');
    store = Store('${directory.path}/app.db');
    helper = Helper(
      '${directory.path}/unused.sock',
      '${directory.path}/helper',
      manageProcess: false,
    );
    runtime = ToolRuntime();
    domain = Domain(store, helper, webSearch: fixtureSearch())
      ..generator = runtime;
  });
  tearDown(() async {
    domain.close();
    runtime.close();
    await helper.close();
    store.close();
    directory.deleteSync(recursive: true);
  });
  test(
    'web answer works without imported sources and saves remapped cited URLs',
    () async {
      runtime.answer = (dispatcher) async {
        final first = await dispatcher.handle([searchCall('first')]);
        final second = await dispatcher.handle([searchCall('second')]);
        expect(first['content'][0]['text'], contains('[Source:2] title: B'));
        expect(second['content'][0]['text'], contains('[Source:2] title: B'));
        expect(second['content'][0]['text'], contains('[Source:3] title: C'));
        return 'Latest [Source:3], earlier [Source:1,3,999].';
      };
      final text = await domain
          .askWithWebInConversation(
            'Current facts?',
            'desktop',
            requestId: 'web-owned',
          )
          .last;
      expect(text, 'Latest [Source:1], earlier [Source:2, 1].');
      final saved = store.rows('SELECT * FROM answers').single;
      expect(saved['request_id'], 'web-owned');
      expect(saved['status'], 'completed');
      final citations = jsonDecode(saved['citations'] as String) as List;
      expect(citations.map((c) => c['url']), ['https://c', 'https://a']);
      expect(citations.map((c) => c['citation']), ['Source:1', 'Source:2']);
      expect(citations.first['kind'], 'web');
      expect(citations.first['query'], 'second');
      expect(citations.first['excerpt'], 'title: C\nsnippet: c');
    },
  );
  test(
    'enabled search does not force a tool call for a known answer',
    () async {
      runtime.answer = (_) async => 'Known answer [Source:99].';
      expect(
        await domain.askWithWebInConversation('Known fact?', 'desktop').last,
        'Known answer.',
      );
      expect(
        jsonDecode(
          store.rows('SELECT citations FROM answers').single['citations']
              as String,
        ),
        isEmpty,
      );
    },
  );
  test(
    'cancelled search cannot publish an answer or attach it to a meeting',
    () async {
      final gate = Completer<void>(), entered = Completer<void>();
      domain.close();
      domain = Domain(
        store,
        helper,
        webSearch: fixtureSearch(gate: gate, entered: entered),
      )..generator = runtime;
      runtime.answer = (dispatcher) async {
        await dispatcher.handle([searchCall('first')]);
        return 'Late answer [Source:1]';
      };
      final meeting = store.meeting('Meeting');
      var current = true;
      final pending = domain
          .askWithWebInConversation(
            'Current facts?',
            'ignored',
            meetingId: meeting,
            current: () => current,
          )
          .last;
      await entered.future;
      current = false;
      gate.complete();
      await expectLater(pending, throwsStateError);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_answers'), isEmpty);
    },
  );
  test(
    'service forwards web mode and pins each saved answer to the requesting meeting',
    () async {
      final profile = ProfilePaths(
        '${directory.path}/service-data',
        '${directory.path}/service-run',
      );
      final service = await ApplicationService.start(
        profile,
        webSearch: fixtureSearch(),
      );
      final serviceRuntime = ToolRuntime();
      serviceRuntime.answer = (dispatcher) async {
        await dispatcher.handle([searchCall('first')]);
        return 'Answer [Source:1].';
      };
      service.domain.generator = serviceRuntime;
      RemoteDomain? client;
      try {
        client = await RemoteDomain.connect(profile);
        expect(client.webSearchAvailable, isTrue);
        final id =
            (await client.command('meetings.create', {
                      'title': 'Remote meeting',
                    })
                    as Map)['id']
                as int;
        expect(
          await client
              .askWithWebInConversation('Current?', 'desktop', meetingId: id)
              .last,
          'Answer [Source:1].',
        );
        final saved = service.domain.store.rows('SELECT * FROM answers').single;
        expect(saved['conversation'], 'meeting:$id');
        expect(
          service.domain.store.rows(
            'SELECT answer_id FROM meeting_answers WHERE meeting_id=?',
            [id],
          ).single['answer_id'],
          saved['id'],
        );
        expect(
          (jsonDecode(saved['citations'] as String) as List).single['url'],
          'https://a',
        );
      } finally {
        client?.close();
        await service.close();
      }
    },
  );
  test('personal and web citations retain local revision navigation', () async {
    final retrieval = LocalRetrieval();
    retrieval.document = store.importText(
      'Local note',
      'Mira owns the draft and sends it on Tuesday.',
      'text/plain',
      'web answer fixture',
      sourceUri: 'note://local',
    );
    store.state(retrieval.document, 'indexed');
    final server = Server.create(services: [retrieval]);
    await server.serve(
      address: InternetAddress(
        '${directory.path}/unused.sock',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
    try {
      runtime.answer = (dispatcher) async {
        expect(runtime.prompts.last, contains('[Source:1] Local note'));
        final result = await dispatcher.handle([searchCall('first')]);
        expect(result['content'][0]['text'], contains('[Source:2] title: A'));
        return 'Web [Source:3], local [Source:1].';
      };
      expect(
        await domain
            .askWithWebInConversation('Who owns the draft?', 'desktop')
            .last,
        'Web [Source:1], local [Source:2].',
      );
      final citations =
          jsonDecode(
                store.rows('SELECT citations FROM answers').single['citations']
                    as String,
              )
              as List;
      expect(citations.first['url'], 'https://b');
      expect(citations.last['document_id'], retrieval.document);
      expect(
        domain.citationCurrent(Map<String, Object?>.from(citations.last)),
        isTrue,
      );
    } finally {
      await server.shutdown();
    }
  });
  test(
    'web response aligns numbers against retrieved local context before history',
    () async {
      final retrieval = LocalRetrieval()
        ..text = 'There are 12 widgets. The invoice total is 87.';
      retrieval.document = store.importText(
        'Invoice',
        retrieval.text,
        'text/plain',
        'number repair fixture',
      );
      store.state(retrieval.document, 'indexed');
      final server = Server.create(services: [retrieval]);
      await server.serve(
        address: InternetAddress(
          '${directory.path}/unused.sock',
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      try {
        runtime.answer = (_) async =>
            'There are 123 widgets. The invoice total is 876 [Source:1].';
        expect(
          await domain
              .askWithWebInConversation('What are the figures?', 'numbers')
              .last,
          'There are 12 widgets. The invoice total is 87 [Source:1].',
        );
        final saved = store.rows('SELECT model_response FROM answers').single;
        expect(
          jsonDecode(saved['model_response'] as String),
          referenceTextMessage(
            'assistant',
            'There are 12 widgets. The invoice total is 87 [Source:1].',
          ),
        );
      } finally {
        await server.shutdown();
      }
    },
  );
  test(
    'web response repairs dates before display and structured history replay',
    () async {
      runtime.answer = (dispatcher) async {
        await dispatcher.handle([searchCall('first')]);
        return 'May11,202026 at 10:000 AM [Source:2].';
      };
      expect(
        await domain.askWithWebInConversation('When?', 'time-repair').last,
        'May 11, 2026 at 10:00 AM [Source:1].',
      );
      final row = store.rows('SELECT * FROM answers').single;
      expect(
        jsonDecode(row['model_response'] as String),
        referenceTextMessage(
          'assistant',
          'May 11, 2026 at 10:00 AM [Source:2].',
        ),
      );
      runtime.answer = (_) async => 'Next answer';
      await domain.askWithWebInConversation('Again?', 'time-repair').last;
      expect(
        runtime.histories.last.last,
        referenceTextMessage(
          'assistant',
          'May 11, 2026 at 10:00 AM [Source:2].',
        ),
      );
    },
  );
  test(
    'web history replays plain queries and pre-renumbered structured responses',
    () async {
      runtime.answer = (dispatcher) async {
        await dispatcher.handle([searchCall('first')]);
        return 'Second result [Source:2].';
      };
      await domain
          .askWithWebInConversation('First question', 'history')
          .toList();
      final first = store.rows('SELECT * FROM answers').single;
      expect(first['body'], 'Second result [Source:1].');
      expect(
        jsonDecode(first['model_response'] as String),
        referenceTextMessage('assistant', 'Second result [Source:2].'),
      );
      runtime.answer = (_) async => 'Follow-up answer';
      await domain
          .askWithWebInConversation('Follow-up question', 'history')
          .toList();
      expect(runtime.histories.last, [
        referenceTextMessage('user', 'First question'),
        referenceTextMessage('assistant', 'Second result [Source:2].'),
      ]);
      expect(runtime.prompts.last, isNot(contains('Conversation:')));
      expect(runtime.prompts.last, isNot(contains('First question')));
      await domain
          .askWithWebInConversation('Another conversation', 'separate')
          .toList();
      expect(runtime.histories.last, isEmpty);
    },
  );

  test(
    'legacy completed answers become full structured text and failed answers stay out',
    () async {
      final longBody = 'Legacy answer ' * 200;
      store.answer(
        'Old question',
        longBody,
        'completed',
        [],
        'legacy',
        conversation: 'history',
      );
      store.answer(
        'Failed question',
        'Partial answer',
        'failed',
        [],
        'legacy',
        conversation: 'history',
      );
      runtime.answer = (_) async => 'New answer';
      await domain
          .askWithWebInConversation('Next question', 'history')
          .toList();
      expect(runtime.histories.last, [
        referenceTextMessage('user', 'Old question'),
        referenceTextMessage('assistant', longBody),
      ]);
    },
  );
  void seedMemory() {
    for (var i = 0; i < 8; i++) {
      store.answer(
        'Old question $i',
        'Fact $i',
        'completed',
        [],
        'legacy',
        conversation: 'history',
      );
    }
  }

  test(
    'web history exceeds four answers and checkpoints survive Domain recreation',
    () async {
      seedMemory();
      runtime.answer = (_) async => 'New answer';
      await domain.askWithWebInConversation('Next?', 'history').toList();
      expect(runtime.histories.last, hasLength(16));
      expect(runtime.summaries, isEmpty);
      domain.close();
      domain = Domain(store, helper, webSearch: fixtureSearch())
        ..generator = runtime;
      await domain.askWithWebInConversation('Another?', 'history').toList();
      expect(runtime.histories.last, hasLength(18));
      expect(
        referenceHistoryText(runtime.histories.last.first),
        'Old question 0',
      );
    },
  );

  test(
    'web memory compresses the oldest half and commits a memo with the answer',
    () async {
      seedMemory();
      runtime.contextLimit = 100;
      runtime.answer = (_) async => 'New answer';
      await domain
          .askWithWebInConversation('Next?', 'history', requestId: 'same-owner')
          .toList();
      expect(runtime.summaries, hasLength(1));
      expect(runtime.summaries.single, startsWith(referenceMemoryInstructions));
      expect(runtime.summaries.single, contains('Old question 3'));
      expect(runtime.summaries.single, isNot(contains('Old question 4')));
      expect(runtime.summaryIds, ['same-owner']);
      expect(runtime.answerIds, ['same-owner']);
      expect(
        referenceHistoryText(runtime.histories.last.first),
        startsWith(referenceMemoryPrefix),
      );
      final checkpoint = store.rows('SELECT * FROM conversation_memory').single;
      final messages = List<Map<String, dynamic>>.from(
        jsonDecode(checkpoint['messages'] as String) as List,
      );
      expect(
        referenceHistoryText(messages.first),
        contains('Important earlier facts'),
      );
      expect(referenceHistoryText(messages[messages.length - 2]), 'Next?');
      expect(store.rows('SELECT * FROM answers'), hasLength(9));
      expect(
        checkpoint['through_answer_id'],
        store.rows('SELECT max(id) AS id FROM answers').single['id'],
      );
    },
  );

  test(
    'failed compression uses FIFO and cancelled compression saves no checkpoint or answer',
    () async {
      seedMemory();
      runtime.contextLimit = 100;
      runtime.summarize = (_) async => throw StateError('Unavailable');
      runtime.answer = (_) async => 'Recovered answer';
      await domain.askWithWebInConversation('Next?', 'history').toList();
      expect(runtime.histories.last.length, lessThan(16));
      expect(
        referenceHistoryText(runtime.histories.last.first),
        isNot(startsWith(referenceMemoryPrefix)),
      );
      final before = store.rows('SELECT * FROM conversation_memory').single;
      final count = store.rows('SELECT * FROM answers').length;
      var current = true;
      runtime.contextLimit = 30;
      runtime.summarize = (_) async {
        current = false;
        return 'Late memo';
      };
      await expectLater(
        domain
            .askWithWebInConversation(
              'Next again?',
              'history',
              current: () => current,
            )
            .toList(),
        throwsStateError,
      );
      expect(store.rows('SELECT * FROM answers'), hasLength(count));
      expect(store.rows('SELECT * FROM conversation_memory').single, before);
    },
  );
  test(
    'memory checkpoint retains completed turns that arrive during generation',
    () async {
      runtime.answer = (_) async {
        store.answer(
          'Intervening query',
          'Intervening answer',
          'completed',
          [],
          'other client',
          conversation: 'history',
        );
        store.answer(
          'Unrelated query',
          'Unrelated answer',
          'completed',
          [],
          'other client',
          conversation: 'separate',
        );
        return 'Own answer';
      };
      await domain.askWithWebInConversation('Own query', 'history').toList();
      final saved =
          jsonDecode(
                store
                        .rows(
                          "SELECT messages FROM conversation_memory WHERE conversation='history'",
                        )
                        .single['messages']
                    as String,
              )
              as List;
      expect(saved, [
        referenceTextMessage('user', 'Intervening query'),
        referenceTextMessage('assistant', 'Intervening answer'),
        referenceTextMessage('user', 'Own query'),
        referenceTextMessage('assistant', 'Own answer'),
      ]);
    },
  );
  test(
    'checkpoint writes keep the exact meeting answer ID and roll back with failed linking',
    () async {
      for (var i = 0; i < 3; i++)
        store.answer('Old $i', 'Body', 'completed', [], 'legacy');
      final meeting = store.meeting('Checkpoint fixture');
      runtime.answer = (_) async => 'Meeting answer';
      await domain
          .askWithWebInConversation('Question', 'ignored', meetingId: meeting)
          .toList();
      final answerId = store
          .rows('SELECT max(id) AS id FROM answers')
          .single['id'];
      expect(answerId, 4);
      expect(
        store.rows('SELECT answer_id FROM meeting_answers').single['answer_id'],
        answerId,
      );
      expect(
        store
            .rows('SELECT through_answer_id FROM conversation_memory')
            .single['through_answer_id'],
        answerId,
      );
      final before = store.rows('SELECT * FROM conversation_memory').single;
      store.db.execute(
        "CREATE TRIGGER reject_memory_link BEFORE INSERT ON meeting_answers BEGIN SELECT RAISE(ABORT,'controlled fixture'); END",
      );
      await expectLater(
        domain
            .askWithWebInConversation(
              'Rejected question',
              'ignored',
              meetingId: meeting,
            )
            .toList(),
        throwsA(isA<SqliteException>()),
      );
      expect(store.rows('SELECT * FROM answers'), hasLength(4));
      expect(store.rows('SELECT * FROM conversation_memory').single, before);
      expect(store.rows('SELECT * FROM meeting_answers'), hasLength(1));
    },
  );
  test(
    'ready helper tokenizes non-Latin history and cached counts avoid re-encoding',
    () async {
      final tokenizer = LocalRetrieval()
        ..tokenCount = (text) => text.contains('字') ? text.runes.length : 1;
      final server = Server.create(services: [tokenizer]);
      await server.serve(
        address: InternetAddress(helper.socket, type: InternetAddressType.unix),
        port: 0,
      );
      helper.snapshot = control.State(tokenizerReady: true);
      for (var i = 0; i < 6; i++)
        store.answer(
          'Old question $i',
          '字' * 40,
          'completed',
          [],
          'legacy',
          conversation: 'history',
        );
      runtime.contextLimit = 100;
      runtime.answer = (_) async => 'New answer';
      try {
        await domain.askWithWebInConversation('Next?', 'history').toList();
        expect(runtime.summaries, hasLength(1));
        expect(tokenizer.encoded, contains('字' * 40));
        expect(tokenizer.encoded, contains('Next?'));
        expect(
          tokenizer.encoded.any(
            (text) => text.startsWith(referenceMemoryPrefix),
          ),
          isTrue,
        );
        final first = store
            .rows(
              "SELECT token_counts FROM conversation_memory WHERE conversation='history'",
            )
            .single;
        expect(jsonDecode(first['token_counts'] as String), [1, 40, 1, 1]);
        tokenizer.encoded.clear();
        await domain.askWithWebInConversation('Again?', 'history').toList();
        expect(tokenizer.encoded, hasLength(3));
        expect(tokenizer.encoded, isNot(contains('字' * 40)));
        expect(runtime.summaries, hasLength(1));
        helper.snapshot = control.State(tokenizerReady: false);
        runtime.contextLimit = 4096;
        tokenizer.encoded.clear();
        await domain.askWithWebInConversation('Fallback?', 'history').toList();
        expect(tokenizer.encoded, isEmpty);
        final weights =
            jsonDecode(
                  store
                          .rows(
                            "SELECT token_counts FROM conversation_memory WHERE conversation='history'",
                          )
                          .single['token_counts']
                      as String,
                )
                as List;
        expect(weights.take(6), [1, 40, 1, 1, 1, 1]);
      } finally {
        await server.shutdown();
      }
    },
  );
}
