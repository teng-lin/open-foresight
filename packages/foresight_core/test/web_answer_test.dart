import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class LocalRetrieval extends RagServiceBase {
  late String document;
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      RetrievedChunk(
        documentId: document,
        text: 'Mira owns the draft and sends it on Tuesday.',
        relevanceScore: .9,
      ),
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
  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'backend': 'litert-lm-fixture',
  };
  @override
  Stream<Map<String, dynamic>> generateWithTools(
    String id,
    String prompt, {
    required List<Map<String, dynamic>> tools,
    required ReferenceToolDispatcher dispatcher,
    String systemPrompt = '',
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    prompts.add(prompt);
    expect(tools.single['name'], 'google_search');
    yield {'type': 'delta', 'text': await answer(dispatcher)};
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
        return 'Answer [Source:1]';
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
          'Answer [Source:1]',
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
}
