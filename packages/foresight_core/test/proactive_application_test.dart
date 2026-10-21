import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class _Domain extends Domain {
  _Domain(super.store, super.helper, this.detector);
  final QueryCompletionRuntime detector;
  Completer<void>? indexGate, indexEntered, indexParked;
  bool productionIndex = false;
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    if (indexEntered != null && !indexEntered!.isCompleted) {
      indexEntered!.complete();
    }
    await indexGate?.future;
    if (productionIndex) {
      await super.index(id, current: current);
    } else {
      store.state(id, 'indexed');
    }
  }

  @override
  Future<void> waitForSourceWork({bool Function()? current}) {
    if (productionIndex &&
        sourcesPaused &&
        indexParked != null &&
        !indexParked!.isCompleted) {
      indexParked!.complete();
    }
    return super.waitForSourceWork(current: current);
  }
}

class _Rag extends RagServiceBase {
  final Store store;
  Completer<void>? gate;
  final entered = Completer<void>();
  _Rag(this.store);
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return RetrieveResponse(
      chunks: [
        for (final source in store.sources.where(
          (row) => request.allowedDocumentIds.contains(row['id']),
        ))
          RetrievedChunk(
            documentId: source['id'] as String,
            text: source['content'] as String,
            relevanceScore: .9,
          ),
      ],
    );
  }

  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async => IndexResponse(success: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Detector implements QueryCompletionRuntime {
  final requests = <String>[];
  final prompts = <String>[];
  String output = ' Who owns the draft?';
  Object? failure;
  @override
  Future<String> complete(String prompt, String requestId) async {
    requests.add(requestId);
    prompts.add(prompt);
    if (failure != null) throw failure!;
    return output;
  }

  @override
  void cancel(String requestId) {}
  @override
  Future<void> close() async {}
}

class _Runtime extends NativeRuntime {
  final requests = <String>[];
  final schemas = <Map<String, dynamic>?>[];
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
    requests.add(id);
    schemas.add(responseSchema);
    yield {
      'type': 'delta',
      'text':
          '{"status":"answered","answer":"Mira owns the draft.","citations":["S1"]}',
    };
    yield {'type': 'done', 'status': 'completed'};
  }
}

void main() {
  late Directory directory;
  late Store store;
  late Server server;
  late _Domain domain;
  late Application app;
  late _Runtime runtime;
  late _Detector detector;
  late _Rag rag;
  setUp(() async {
    directory = createTestTempDirectorySync('proactive-app-');
    store = Store('${directory.path}/app.db');
    final socket = '${directory.path}/helper.sock';
    rag = _Rag(store);
    server = Server.create(services: [rag]);
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    runtime = _Runtime();
    detector = _Detector();
    domain = _Domain(
      store,
      Helper(socket, '${directory.path}/helper'),
      detector,
    )..generator = runtime;
    app = Application(domain, queryRuntime: detector);
  });
  setUp(() {
    addTearDown(() async {
      await app.close();
      domain.close();
      runtime.close();
      await domain.helper.close();
      await server.shutdown();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'missing dedicated model reports not ready without chat substitution',
    () async {
      await app.close();
      app = Application(domain);
      try {
        final id = store.meeting('Detector unavailable');
        final queue = app.proactive;
        queue.begin(id);
        store.transcript(
          id,
          'Who owns the draft?',
          true,
          0,
          1000,
          'microphone',
        );
        queue.notify(id);
        await queue.process();
        expect(
          queue.errors[id],
          contains('Dedicated question detector is not ready'),
        );
        expect(runtime.requests, isEmpty);
        expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
        expect(
          store
              .rows('SELECT transcript_id FROM meeting_question_cursors')
              .single['transcript_id'],
          0,
        );
      } finally {
        await app.close();
      }
    },
  );

  test(
    'service pipeline detects, indexes, grounds, cites and links an automatic answer by request ownership',
    () async {
      final id = store.meeting('Automatic meeting');
      final queue = app.proactive;
      queue.begin(id);
      store.transcript(
        id,
        'Mira owns the draft. Who owns the draft?',
        true,
        0,
        1000,
        'microphone',
      );
      queue.notify(id);
      await queue.process();
      await queue.process();
      await queue.process();
      expect(queue.errors, isEmpty);
      final question = store.rows('SELECT * FROM meeting_questions').single;
      expect(question['state'], 'completed');
      final answer = store.rows('SELECT * FROM answers').single;
      expect(answer['id'], question['answer_id']);
      expect(answer['body'], 'Mira owns the draft. [S1]');
      expect(answer['conversation'], 'meeting:$id');
      expect(answer['request_id'], runtime.requests.last);
      expect(runtime.requests, hasLength(1));
      expect(detector.requests.single, startsWith('proactive-detect-'));
      expect(detector.prompts.single, startsWith(' <ctrl1>'));
      expect(runtime.requests.last, startsWith('proactive-answer-'));
      expect(runtime.schemas.first?['required'], isNot(contains('questions')));
      expect(store.rows('SELECT * FROM meeting_answers').single, {
        'meeting_id': id,
        'answer_id': answer['id'],
      });
      expect(store.sources.single['id'], 'meeting-$id');
      final details =
          await app.call(Operation.meetingsGet.wire, {'id': id}) as Map;
      expect(details['questions'], hasLength(1));
      expect(
        (app.captureState['proactive'] as Map)['pending_meetings'],
        isEmpty,
      );
    },
  );

  test(
    'dedicated detector failure is visible and leaves transcript and processing boundary intact',
    () async {
      final id = store.meeting('Invalid detection');
      final queue = app.proactive;
      queue.begin(id);
      store.transcript(id, 'Who owns the draft?', true, 0, 1000, 'microphone');
      queue.notify(id);
      detector.failure = StateError('Dedicated detector failed');
      await queue.process();
      expect(queue.errors[id], contains('Dedicated detector failed'));
      expect(runtime.requests, isEmpty);
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'Who owns the draft?',
      );
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
      detector.failure = null;
      await app.call(Operation.meetingsRetryDetection.wire, {'id': id});
      await queue.process();
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(1));
      await queue.reset();
      await app.call(Operation.workspaceClear.wire, const {});
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_question_cursors'), isEmpty);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  test(
    'closing automatic work stops its queued preparation without cancelling shared indexing',
    () async {
      final id = store.meeting('Delayed indexing');
      final queue = app.proactive;
      queue.begin(id);
      store.transcript(
        id,
        'Mira owns the draft. Who owns the draft?',
        true,
        0,
        1000,
        'microphone',
      );
      queue.notify(id);
      await queue.process();
      domain.indexGate = Completer<void>();
      final answer = queue.process();
      await queue.close().timeout(const Duration(seconds: 2));
      await answer;
      expect(runtime.requests, isEmpty);
      expect(
        store.rows('SELECT state FROM meeting_questions').single['state'],
        'queued',
      );
      expect(domain.indexGate!.isCompleted, false);
      expect(app.proactiveWork, 0);
      expect(app.backgroundBusy, false);
      domain.indexGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
    },
  );

  test(
    'cancellation during retrieval cannot start a later generation or save an orphan answer',
    () async {
      final id = store.meeting('Delayed retrieval');
      final queue = app.proactive;
      queue.begin(id);
      store.transcript(
        id,
        'Mira owns the draft. Who owns the draft?',
        true,
        0,
        1000,
        'microphone',
      );
      queue.notify(id);
      await queue.process();
      rag.gate = Completer<void>();
      final work = queue.process();
      await rag.entered.future.timeout(const Duration(seconds: 2));
      await queue.close().timeout(const Duration(seconds: 2));
      await work;
      expect(runtime.requests, isEmpty);
      expect(queue.running, false);
      expect(app.proactiveWork, 1);
      expect(app.backgroundBusy, true);
      rag.gate!.complete();
      await eventually(() => app.proactiveWork == 0);
      expect(app.backgroundBusy, false);
      await Future<void>(() {});
      expect(runtime.requests, isEmpty);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      expect(
        store.rows('SELECT state FROM meeting_questions').single['state'],
        'queued',
      );
    },
  );

  for (final cancelCaller in [false, true]) {
    test(
      'model configuration yields retrieval and preserves queued answer (cancel caller: $cancelCaller)',
      () async {
        final id = store.meeting('Model configuration during retrieval');
        final queue = app.proactive;
        queue.begin(id);
        store.transcript(
          id,
          'Mira owns the draft. Who owns the draft?',
          true,
          0,
          1000,
          'microphone',
        );
        queue.notify(id);
        await queue.process();
        rag.gate = Completer<void>();
        final work = queue.process();
        await rag.entered.future.timeout(const Duration(seconds: 2));
        var current = true;
        final configure = app.call(
          Operation.modelsAcquireQuery.wire,
          {},
          current: () => current,
        );
        if (cancelCaller) current = false;
        // No download is authorized in this fixture. Even a denied model
        // request must leave the interrupted automatic answer retryable.
        await expectLater(
          configure,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              cancelCaller ? RpcErrorCode.cancelled : RpcErrorCode.denied,
            ),
          ),
        );
        await work;
        expect(queue.running, false);
        expect(queue.errors, isEmpty);
        expect(store.meetingQuestions(id).single['state'], 'queued');
        expect(runtime.requests, isEmpty);
        rag.gate!.complete();
        await eventually(() => app.proactiveWork == 0);
        await queue.process();
        expect(store.meetingQuestions(id).single['state'], 'completed');
        expect(runtime.requests, hasLength(1));
      },
    );
  }

  test(
    'cancelled proactive preparation leaves a real paused shared index durable and not busy',
    () async {
      final id = store.meeting('Paused preparation');
      final queue = app.proactive;
      queue.begin(id);
      store.transcript(
        id,
        'Mira owns the draft. Who owns the draft?',
        true,
        0,
        1000,
        'microphone',
      );
      queue.notify(id);
      await queue.process();
      domain.productionIndex = true;
      domain.indexEntered = Completer<void>();
      domain.indexParked = Completer<void>();
      domain.indexGate = Completer<void>();
      final work = queue.process();
      await domain.indexEntered!.future;
      domain.pauseSources();
      domain.indexGate!.complete();
      await domain.indexParked!.future;
      await queue.close();
      await work;
      expect(queue.running, false);
      expect(app.proactiveWork, 0);
      expect(domain.mutating, 0);
      expect(app.backgroundBusy, false);
      expect(store.sources.single['state'], 'pending');
      expect(domain.cancellationWatchCount, 0);
      domain.resumeSources();
      await eventually(() => store.sources.single['state'] == 'indexed');
      expect(app.backgroundBusy, false);
    },
  );

  for (final interim in [false, true]) {
    test(
      '${interim ? 'Interim' : 'Final'} captured speech automatically schedules detection and a cited answer without a UI request',
      () async {
        final library =
            '${directory.path}/capture.${Platform.isMacOS ? 'dylib' : 'so'}';
        await buildCachedNativeFixture(
          source: 'test/fixtures/recording_native_stub.cpp',
          output: library,
        );
        final fixture = DynamicLibrary.open(library);
        final transcript = jsonEncode({
          'type': 'transcript',
          'text': interim
              ? 'Mira owns the draft. Who owns the draft? one two three four five'
              : 'Mira owns the draft. Who owns the draft?',
        }).toNativeUtf8();
        fixture.lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fixture_speech_event')(transcript);
        calloc.free(transcript);
        final prior = runtimeConfiguration.environment['FORESIGHT_NATIVE'];
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
        try {
          final model = File('${directory.path}/speech-fixture')
            ..writeAsStringSync('Fixture');
          await store.register('speech', model.path, '/usr/bin/true');
          final id = store.meeting('Capture fixture');
          await app.call(Operation.meetingsStart.wire, {'id': id});
          final bytes = ByteData(interim ? 12000 : 4000);
          final event = jsonEncode({
            'type': 'pcm',
            'sampleRate': 1000,
            'volume': .02,
            'data': base64Encode(bytes.buffer.asUint8List()),
          }).toNativeUtf8();
          expect(
            fixture.lookupFunction<
              Int32 Function(Int32, Pointer<Utf8>),
              int Function(int, Pointer<Utf8>)
            >('fixture_emit')(0, event),
            1,
          );
          calloc.free(event);
          if (!interim) {
            await app.call(Operation.meetingsPause.wire, {'id': id});
          }
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while ((interim
                  ? app.provisionalTranscript.values.every(
                      (text) => text.isEmpty,
                    )
                  : store.rows('SELECT * FROM transcript').isEmpty) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          if (interim) {
            expect(store.rows('SELECT * FROM transcript'), isEmpty);
            expect(
              app.provisionalTranscript['microphone'],
              'Mira owns the draft. Who owns the draft? one two three four five',
            );
            // Interim speech has no durable transcript to retrieve yet; supply
            // independently imported context under an explicit workspace scope.
            store.setPreference('proactiveScope.$id', 'workspace');
            store.importText(
              'Ownership',
              'Mira owns the draft.',
              'text/plain',
              'fixture',
            );
            for (final source in store.sources) {
              store.state(source['id'] as String, 'indexed');
            }
          } else {
            expect(
              store.rows('SELECT text FROM transcript').single['text'],
              'Mira owns the draft. Who owns the draft?',
            );
          }
          final queue = app.proactive;
          // The capture callback, not this test, called notify().
          await queue.process();
          await queue.process();
          await queue.process();
          expect(queue.errors, isEmpty);
          expect(
            store.rows('SELECT state FROM meeting_questions').single['state'],
            'completed',
          );
          expect(
            store.rows('SELECT body FROM answers').single['body'],
            'Mira owns the draft. [S1]',
          );
          await app.call(Operation.meetingsStop.wire, const {});
        } finally {
          if (prior == null) {
            runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
          } else {
            runtimeConfiguration.environment['FORESIGHT_NATIVE'] = prior;
          }
        }
      },
    );
  }
}
