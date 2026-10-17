import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'fixtures/google_connections.dart';

class OperationsRag extends RagServiceBase {
  RetrieveRequest? query;
  bool reject = false;
  Completer<void>? entered, release;
  Completer<void>? retrievalEntered, retrievalRelease;
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    query = request;
    retrievalEntered?.complete();
    await retrievalRelease?.future;
    return RetrieveResponse(
      chunks: [
        for (final id in request.allowedDocumentIds)
          RetrievedChunk(
            documentId: id,
            text: 'Passage $id',
            relevanceScore: .9,
          ),
      ],
    );
  }

  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    entered?.complete();
    await release?.future;
    return UpdateModelPathsResponse(
      success: !reject,
      errorMessage: reject ? 'corrupt bundle' : '',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OperationsDomain extends AdapterDomain {
  final deleted = <String>[];
  bool rejectIndex = false;
  @override
  Future<void> index(String id) async {
    if (rejectIndex) throw StateError('index worker disconnected');
    await super.index(id);
  }

  OperationsDomain(super.store, super.helper);
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    await super.delete(id);
  }

  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    yield '$question [$conversation:${meetingId ?? 0}]';
  }

  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    yield 'web: $question [$conversation:${meetingId ?? 0}]';
  }

  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async => {
    for (final source in sources) source['id'] as String: [1, 0, 0],
  };
}

class ArtifactGenerator extends NativeRuntime {
  List<Map<String, dynamic>> events = [
    {'type': 'delta', 'text': 'Grounded'},
    {'type': 'delta', 'text': ' summary'},
    {'type': 'done', 'status': 'completed'},
  ];
  final prompts = <String>[];
  final requestIds = <String>[];
  Completer<void>? entered, release;
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready'};
  ArtifactGenerator()
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
    requestIds.add(id);
    entered?.complete();
    await release?.future;
    yield* Stream.fromIterable(events);
  }
}

void main() {
  late Directory root;
  late OperationsDomain domain;
  late Application app;
  late OperationsRag rag;
  late Server server;
  late GoogleFixture google;
  late GoogleAuth auth;
  setUp(() async {
    root = Directory('/tmp').createTempSync('of-operations-');
    rag = OperationsRag();
    server = Server.create(services: [rag]);
    final socket = '${root.path}/rag.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    domain = OperationsDomain(
      Store('${root.path}/app.db'),
      Helper(socket, '${root.path}/helper', manageProcess: false),
    );
    domain.store.setPreference('liveEnhance', 'false');
    google = GoogleFixture();
    await google.start();
    auth = GoogleAuth(
      Directory('${root.path}/google'),
      endpoints: google.endpoints,
    );
    app = Application(domain, auth: auth);
  });
  tearDown(() async {
    await app.close();
    domain.close();
    domain.generator?.close();
    await domain.helper.close();
    domain.store.close();
    await server.shutdown();
    await google.close();
    root.deleteSync(recursive: true);
  });

  Future<Map> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => (await app.call(method, args)) as Map;
  Future<void> connectGoogle() async {
    final config = File('${root.path}/client.json')
      ..writeAsStringSync(
        jsonEncode({
          'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
        }),
      );
    await app.call('google.configure', {'path': config.path});
    final iterator = StreamIterator(app.signIn('owner'));
    expect(await iterator.moveNext(), isTrue);
    final invitation = (iterator.current as Map)['authorization_url'] as String;
    await google.consent(Uri.parse(invitation));
    expect(await iterator.moveNext(), isTrue);
    expect((iterator.current as Map)['connected'], isTrue);
    expect(await iterator.moveNext(), isFalse);
    await iterator.cancel();
  }

  test(
    'import, revision, search and deletion retain source scope and metadata',
    () async {
      final imported = await call('sources.import', {
        'title': 'Apollo',
        'text': 'First',
        'sourceUri': 'fixture:apollo',
      });
      final id = imported['id'] as String;
      final hidden = await call('sources.import', {
        'title': 'Pending',
        'text': 'Pending',
        'index': false,
      });
      var source = await call('sources.get', {'id': id});
      expect(source['revision'], 1);
      expect(source['state'], 'indexed');
      await app.call('sources.import', {
        'id': id,
        'title': 'Apollo v2',
        'text': 'Second',
      });
      source = await call('sources.get', {'id': id});
      expect(source['revision'], 2);
      expect((await app.call('sources.list', {}) as List), hasLength(2));
      final found =
          await app.call('sources.search', {'query': 'Apollo', 'limit': 1})
              as List;
      expect(found.single['id'], id);
      expect(found.single['revision'], 2);
      expect(rag.query!.allowedDocumentIds, [id]);
      expect(rag.query!.query.textQuery, 'Apollo');
      expect(rag.query!.maxResults, 1);
      for (final limit in [0, 101]) {
        await expectLater(
          app.call('sources.search', {'query': 'q', 'limit': limit}),
          throwsArgumentError,
        );
      }
      await app.call('sources.index', {'id': hidden['id']});
      await app.call('sources.delete', {'id': id});
      await expectLater(
        app.call('sources.get', {'id': id}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.notFound,
          ),
        ),
      );
      await app.call('sources.delete', {'id': hidden['id']});
      expect(await app.call('sources.search', {'query': 'q'}), isEmpty);
    },
  );

  test(
    'meeting, note and answer operations preserve ownership and user edits',
    () async {
      final id =
          (await call('meetings.create', {'title': 'Planning'}))['id'] as int;
      final note = await call('notes.save', {
        'title': 'Personal',
        'body': 'v1',
      });
      await app.call('notes.save', {
        'id': note['id'],
        'title': 'Personal',
        'body': 'v2',
      });
      expect((await app.call('notes.list', {}) as List).single['body'], 'v2');
      expect(
        (await app.call('meetings.list', {}) as List).single['title'],
        'Planning',
      );
      await app.call('meetings.notes', {
        'id': id,
        'body': '- Original',
        'last_manual_edit': 123,
      });
      await app.call('meetings.transcript', {
        'id': id,
        'text': 'Apollo ships Friday',
        'source': 'microphone',
        'start': 20,
        'end': 100,
      });
      await app.call('meetings.index', {'id': id});
      final view = await call('meetings.get', {'id': id});
      expect((view['notes'] as List).single['body'], '- Original');
      expect((view['transcript'] as List).single['speaker_id'], 0);
      expect(domain.store.sources.single['id'], 'meeting-$id');
      expect(
        domain.store.sources.single['revision'],
        1,
        reason: 'Unchanged indexed transcripts are not rewritten',
      );
      for (final web in [false, true]) {
        final result = await call('answer', {
          'question': 'When?',
          'conversation': 'meeting:$id',
          'meeting_id': id,
          'web_search': web,
        });
        expect(result['text'], contains('When? [meeting:$id:$id]'));
        expect((result['text'] as String).startsWith('web:'), web);
      }
      domain.store.answer('Question', 'Answer', 'completed', [], 'fixture');
      final answer = domain.store.db.lastInsertRowId;
      await app.call('meetings.link_answer', {'id': id, 'answer': answer});
      expect(
        domain.store.rows('SELECT * FROM meeting_answers').single['meeting_id'],
        id,
      );
      await app.call('meetings.retry_detection', {'id': id});
      await app.call('meetings.cancel_enhance', {
        'id': id,
        'request_id': 'missing',
      });
      await expectLater(
        app.call('meetings.get', {'id': 999}),
        throwsStateError,
      );
      await expectLater(
        app.call('unsupported', {}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.notFound,
          ),
        ),
      );
      await expectLater(
        app.call('notes.save', {}, current: () => false),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
    },
  );

  test(
    'artifact generation accepts only final transcript and never saves failed output',
    () async {
      final id = domain.store.meeting('Planning');
      final generator = ArtifactGenerator();
      domain.generator = generator;
      await expectLater(app.generateMeeting(id, 'summary'), throwsStateError);
      await expectLater(
        app.generateMeeting(id, 'unknown'),
        throwsArgumentError,
      );
      domain.store.transcript(id, 'interim secret', false, 0, 10, 'microphone');
      domain.store.transcript(id, 'Ship Friday', true, 10, 30, 'microphone');
      domain.store.setPreference('noteStyle', 'Concise');
      for (final kind in ['summary', 'actions', 'action_items', 'questions']) {
        await app.call('meetings.generate', {'id': id, 'kind': kind});
      }
      expect(
        generator.prompts.every(
          (p) =>
              p.contains('Ship Friday') &&
              !p.contains('interim secret') &&
              p.contains('brief phrases'),
        ),
        isTrue,
      );
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(4));
      final artifact = domain.store.rows('SELECT * FROM artifacts').first;
      await app.call('artifacts.edit', {
        'id': artifact['id'],
        'text': 'User edit',
      });
      expect(
        domain.store.rows('SELECT * FROM artifacts').first['edited'],
        'User edit',
      );
      generator.events = [
        {'type': 'error', 'message': 'model disconnected'},
        {'type': 'done', 'status': 'failed'},
      ];
      await expectLater(
        app.generateMeeting(id, 'summary'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'failure',
            contains('model disconnected'),
          ),
        ),
      );
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(4));
      domain.generator = null;
      await expectLater(app.generateMeeting(id, 'summary'), throwsStateError);
    },
  );

  test(
    'URL imports normalize HTML, preserve source identity, and reject unusable responses',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var content =
          '<style>private</style><script>secret</script><p>Apollo&nbsp;&amp; Friday &lt;yes&gt;</p>';
      server.listen((request) async {
        final mode = request.uri.path;
        request.response.headers.contentType = mode == '/binary'
            ? ContentType.binary
            : ContentType.html;
        if (mode == '/missing') request.response.statusCode = 404;
        request.response.write(
          mode == '/empty'
              ? '<script>only script</script>'
              : mode == '/large'
              ? 'x' * (5 * 1024 * 1024 + 1)
              : content,
        );
        await request.response.close().catchError((Object _) {});
      });
      addTearDown(() => server.close(force: true));
      String url(String path) => 'http://127.0.0.1:${server.port}$path';
      final id = await app.importUrl(url('/page'), allowPrivateNetwork: true);
      expect(domain.store.sources.single['content'], 'Apollo & Friday <yes>');
      content = '<p>Updated</p>';
      expect(await app.importUrl(url('/page'), allowPrivateNetwork: true), id);
      expect(domain.store.sources.single['revision'], 2);
      for (final path in ['/missing', '/binary', '/empty', '/large']) {
        await expectLater(
          app.importUrl(url(path), allowPrivateNetwork: true),
          throwsStateError,
        );
      }
      for (final invalid in ['file:///private', 'https:', 'garbage']) {
        await expectLater(app.importUrl(invalid), throwsStateError);
      }
      await expectLater(
        app.importUrl(
          url('/cancel'),
          current: () => false,
          allowPrivateNetwork: true,
        ),
        throwsStateError,
      );
      expect(domain.store.sources, hasLength(1));
      await app.call('sources.refresh', {'allow_private_network': true});
      expect(domain.store.sources.single['revision'], 3);
    },
  );

  test(
    'directory imports keep successful files, aggregate failures and honor cancellation',
    () async {
      final directory = Directory('${root.path}/documents')..createSync();
      final file = File('${directory.path}/note.md')
        ..writeAsStringSync('first');
      File('${directory.path}/ignore.png').writeAsStringSync('unsupported');
      final first = (await call('sources.import_file', {
        'path': file.path,
      }))['id'];
      file.writeAsStringSync('second');
      await app.call('sources.import_directory', {'path': directory.path});
      expect(domain.store.sources.single['id'], first);
      expect(domain.store.sources.single['revision'], 2);
      File('${directory.path}/bad.txt').writeAsBytesSync([255]);
      await expectLater(
        app.importDirectory(directory.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'failure',
            allOf(contains('Imported 1 files'), contains('bad.txt')),
          ),
        ),
      );
      await expectLater(
        app.importDirectory(directory.path, current: () => false),
        throwsStateError,
      );
      file.deleteSync();
      await expectLater(
        app.reimport(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'failure',
            contains('missing'),
          ),
        ),
      );
      await expectLater(app.reimport(current: () => false), throwsStateError);
    },
  );

  test(
    'model configuration serializes changes, preserves rejected registrations and clears busy state',
    () async {
      final model = File('${root.path}/embedding.litertlm')
        ..writeAsStringSync('fixture');
      rag.entered = Completer<void>();
      rag.release = Completer<void>();
      final pending = app.call('models.embedding', {
        'path': model.path,
        'gpu': true,
      });
      await rag.entered!.future;
      expect(app.modelBusy, isTrue);
      await expectLater(
        app.call('models.register', {'kind': 'speech', 'path': model.path}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.busy,
          ),
        ),
      );
      rag.release!.complete();
      await pending;
      expect(
        domain.store.model('embedding')!['backend'],
        'litert_lm_embedding_gpu',
      );
      rag.entered = null;
      rag.release = null;
      rag.reject = true;
      await expectLater(
        app.call('models.embedding', {'path': '${root.path}/bad.litertlm'}),
        throwsStateError,
      );
      expect(app.modelBusy, isFalse);
      expect(domain.store.model('embedding')!['path'], model.absolute.path);
      await app.call('models.register', {'kind': 'speech', 'path': model.path});
      expect(domain.store.model('speech'), isNotNull);
      await app.call('models.cancel_query_acquisition', {});
    },
  );

  test(
    'Google operations use the authenticated adapter and preserve calendar provenance',
    () async {
      await connectGoogle();
      expect((await call('google.status'))['connected'], isTrue);
      final files =
          await app.call('google.drive_files', {
                'parent': 'folder',
                'query': 'Apollo',
                'modifiedAfter': '2020-01-01T00:00:00Z',
              })
              as List;
      expect(files, isNotEmpty);
      await app.call('google.import_file', {'id': 'doc'});
      await app.call('google.import_folder', {'id': 'folder'});
      await app.call('google.import_year', {});
      await app.call('google.calendar', {});
      final meeting = domain.store.rows('SELECT * FROM meetings').single['id'];
      await app.call('google.attachments', {'id': meeting});
      await app.call('google.refresh', {});
      await app.maintainGoogle();
      expect(
        domain.store.sources.any(
          (s) => s['source_uri'] == 'https://drive.example.test/doc',
        ),
        isTrue,
      );
      await app.call('google.cancel_sign_in', {});
      await app.call('google.disconnect', {});
      expect((await call('google.status'))['connected'], isFalse);
    },
  );

  test(
    'label and graph operations keep organization scoped to current sources',
    () async {
      final id = domain.store.importText(
        'Apollo',
        'body',
        'text/plain',
        'fixture',
      );
      final second = domain.store.importText(
        'Borealis',
        'body',
        'text/plain',
        'fixture',
      );
      domain.store.state(id, 'indexed');
      domain.store.state(second, 'indexed');
      await app.call('labels.put', {
        'id': id,
        'name': 'Planning',
        'source': 'user_defined',
        'color': '#123456',
        'rationale': 'fixture',
      });
      await app.call('labels.set', {
        'id': id,
        'labels': ['Planning', 'Other'],
      });
      await app.call('labels.cluster', {'name': 'Planning'});
      final embeddings =
          await app.call('graph.embeddings', {'sources': domain.store.sources})
              as Map;
      expect(embeddings[id], [1, 0, 0]);
      final saved = await app.call('graph.save', {
        'identity': 'model',
        'sources': domain.store.sources,
        'vectors': embeddings,
        'points': {
          id: [.1, .2, .3],
          second: [-.1, -.2, -.3],
        },
        'labelSet': domain.store.graphLabelSet(),
        'clusters': [],
      });
      expect(saved, isTrue);
      await app.call('graph.invalidate', {});
      await app.call('graph.acknowledge', {});
      await app.call('labels.delete', {'name': 'Other'});
      expect(domain.store.documentLabels.map((l) => l.name), ['Planning']);
      await app.call('preferences.set', {
        'key': 'proactiveAnswers',
        'value': 'false',
      });
      await app.call('sources.pause', {});
      expect(domain.sourcesPaused, isTrue);
      await app.call('sources.resume', {});
      expect(domain.sourcesPaused, isFalse);
      final state = await call('status');
      expect(state['pid'], pid);
      expect(state['models_busy'], isFalse);
      await app.close();
      await expectLater(app.call('status', {}), throwsStateError);
    },
  );
  test(
    'paused meeting indexing reports failures and retry keeps the transcript revision',
    () async {
      final id = domain.store.meeting('Retry');
      domain.store.transcript(id, 'Final evidence', true, 0, 10, 'microphone');
      domain.pauseSources();
      domain.rejectIndex = true;
      await app.indexMeeting(id);
      await Future<void>.delayed(Duration.zero);
      expect(app.recordingState, contains('index worker disconnected'));
      expect(domain.store.sources.single['revision'], 1);
      domain.rejectIndex = false;
      domain.resumeSources();
      await app.indexMeeting(id);
      expect(domain.store.sources.single['revision'], 1);
      expect(domain.store.sources.single['state'], 'indexed');
      final empty = domain.store.meeting('No transcript');
      await app.indexMeeting(empty);
      expect(domain.store.sources, hasLength(1));
    },
  );

  test(
    'speech setup validates a real probe subprocess and model operations reject invalid query assets',
    () async {
      final model = File('${root.path}/speech.bin')
        ..writeAsStringSync('fixture');
      final runner = File('${root.path}/speech-runner')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      expect(
        (await Process.run('/bin/chmod', ['700', runner.path])).exitCode,
        0,
      );
      final digest = sha256.convert(model.readAsBytesSync()).toString();
      await app.call('models.speech', {
        'path': model.path,
        'runtime': runner.path,
        'digest': digest,
      });
      expect(domain.store.model('speech')!['digest'], digest);
      for (final backend in ['unsupported', 'legacy_query_cpu']) {
        await expectLater(
          app.call('models.register', {
            'kind': 'query-detection',
            'path': model.path,
            'backend': backend,
          }),
          throwsStateError,
        );
        expect(app.modelBusy, isFalse);
      }
      expect(domain.store.model('query-detection'), isNull);
    },
  );

  test(
    'enhanced artifact edits preserve originals and separate latest from historical drafts',
    () async {
      final id = domain.store.meeting('Edited');
      await app.call('meetings.notes', {
        'id': id,
        'body': '- Original shorthand',
      });
      domain.store.artifact(
        id,
        'enhanced_notes',
        '- Expanded original',
        'fixture',
      );
      final historical = domain.store.db.lastInsertRowId;
      domain.store.artifact(
        id,
        'enhanced_notes',
        '- Latest expanded original',
        'fixture',
      );
      final latest = domain.store.db.lastInsertRowId;
      await app.call('artifacts.edit', {
        'id': latest,
        'text': '- User edited latest',
        'last_manual_edit': 123,
      });
      await app.call('artifacts.edit', {
        'id': historical,
        'text': '- User edited history',
      });
      final view = await call('meetings.get', {'id': id});
      expect(
        (view['artifacts'] as List).last['generated'],
        '- Latest expanded original',
      );
      expect(
        (view['artifacts'] as List).last['edited'],
        '- User edited latest',
      );
      expect((view['notes'] as List).single['body'], '- Original shorthand');
    },
  );
  for (final kind in ['summary', 'actions', 'action_items', 'questions']) {
    test(
      'cancelled $kind generation retains request identity and saves no artifact',
      () async {
        final meeting = domain.store.meeting('Cancellation');
        domain.store.transcript(
          meeting,
          'Meeting facts',
          true,
          0,
          1,
          'imported',
        );
        final generator = ArtifactGenerator()
          ..entered = Completer<void>()
          ..release = Completer<void>();
        domain.generator = generator;
        var current = true;
        final pending = expectLater(
          app.call('meetings.generate', {
            'id': meeting,
            'kind': kind,
            'requestId': 'cancel-$kind',
          }, current: () => current),
          throwsStateError,
        );
        await generator.entered!.future;
        expect(generator.requestIds, ['cancel-$kind']);
        current = false;
        generator.release!.complete();
        await pending;
        expect(domain.store.rows('SELECT * FROM artifacts'), isEmpty);
      },
    );
  }

  test(
    'search drops changed and deleted revisions while retaining valid results',
    () async {
      final ids = [
        for (final title in ['changed', 'deleted', 'stable'])
          domain.store.importText(title, 'Old passage', 'text/plain', 'test'),
      ];
      for (final id in ids) domain.store.state(id, 'indexed');
      rag.retrievalEntered = Completer<void>();
      rag.retrievalRelease = Completer<void>();
      final pending = app.call('sources.search', {'query': 'Old passage'});
      await rag.retrievalEntered!.future;
      domain.store.importText(
        'changed v2',
        'New passage',
        'text/plain',
        'test',
        id: ids.first,
      );
      domain.store.state(ids.first, 'indexed');
      domain.store.tombstone(ids[1]);
      rag.retrievalRelease!.complete();
      final results = await pending as List;
      expect(results, hasLength(1));
      expect(results.single['id'], ids.last);
      expect(results.single['revision'], 1);
    },
  );

  test(
    'refresh retains a locally edited file source and its revision',
    () async {
      final file = File('${root.path}/private.txt')
        ..writeAsStringSync('Original');
      final id = await app.importFile(file.path);
      final source = domain.store.sources.single;
      domain.store.importText(
        'Private',
        'My local edit',
        'text/plain',
        "user edit; ${source['provenance']}",
        id: id,
      );
      file.writeAsStringSync('External replacement');
      await app.reimport();
      final refreshed = domain.store.sources.single;
      expect(refreshed['content'], 'My local edit');
      expect(refreshed['revision'], 2);
    },
  );

  test('refresh cannot overwrite an edit made during URL retrieval', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${http.port}/page';
    http.listen((request) async {
      entered.complete();
      await release.future;
      request.response.headers.contentType = ContentType.text;
      request.response.write('External replacement');
      await request.response.close();
    });
    final id = domain.store.importText(
      'Page',
      'Original',
      'text/plain',
      'url:$url',
    );
    try {
      final pending = expectLater(
        app.reimport(allowPrivateNetwork: true),
        throwsStateError,
      );
      await entered.future;
      domain.store.importText(
        'Page',
        'My concurrent edit',
        'text/plain',
        'user edit; url:$url',
        id: id,
      );
      release.complete();
      await pending;
      final refreshed = domain.store.sources.single;
      expect(refreshed['content'], 'My concurrent edit');
      expect(refreshed['revision'], 2);
    } finally {
      if (!release.isCompleted) release.complete();
      await http.close(force: true);
    }
  });
}
