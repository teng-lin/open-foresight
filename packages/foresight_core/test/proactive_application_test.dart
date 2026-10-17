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
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class _Domain extends Domain {
  _Domain(super.store, super.helper, this.detector);
  final QueryCompletionRuntime detector;
  late final Application _application = Application(
    this,
    queryRuntime: detector,
  );
  @override
  Application get application => _application;
  Completer<void>? indexGate;
  @override
  Future<void> index(String id) async {
    await indexGate?.future;
    store.state(id, 'indexed');
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
  late _Runtime runtime;
  late _Detector detector;
  late _Rag rag;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('proactive-app-');
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
  });
  tearDown(() async {
    await domain.application.close();
    domain.close();
    runtime.close();
    await domain.helper.close();
    await server.shutdown();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'missing dedicated model reports not ready without chat substitution',
    () async {
      final app = Application(domain);
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
      final queue = domain.application.proactive;
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
      final details = await domain.command('meetings.get', {'id': id}) as Map;
      expect(details['questions'], hasLength(1));
      expect(
        (domain.application.captureState['proactive']
            as Map)['pending_meetings'],
        isEmpty,
      );
    },
  );

  test(
    'dedicated detector failure is visible and leaves transcript and processing boundary intact',
    () async {
      final id = store.meeting('Invalid detection');
      final queue = domain.application.proactive;
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
      await domain.command('meetings.retry_detection', {'id': id});
      await queue.process();
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(1));
      await queue.reset();
      await domain.command('workspace.clear');
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_question_cursors'), isEmpty);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  test(
    'closing automatic work stops its queued preparation without cancelling shared indexing',
    () async {
      final id = store.meeting('Delayed indexing');
      final queue = domain.application.proactive;
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
      domain.indexGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
    },
  );

  test(
    'cancellation during retrieval cannot start a later generation or save an orphan answer',
    () async {
      final id = store.meeting('Delayed retrieval');
      final queue = domain.application.proactive;
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
      rag.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(runtime.requests, isEmpty);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      expect(
        store.rows('SELECT state FROM meeting_questions').single['state'],
        'queued',
      );
    },
  );

  for (final interim in [false, true]) {
    test(
      '${interim ? 'Interim' : 'Final'} captured speech automatically schedules detection and a cited answer without a UI request',
      () async {
        final library =
            '${directory.path}/capture.${Platform.isMacOS ? 'dylib' : 'so'}';
        final build = await Process.run('c++', [
          '-std=c++17',
          '-shared',
          '-fPIC',
          'test/fixtures/recording_native_stub.cpp',
          '-o',
          library,
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}');
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
          await domain.command('meetings.start', {'id': id});
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
          if (!interim) await domain.command('meetings.pause', {'id': id});
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while ((interim
                  ? domain.application.provisionalTranscript.values.every(
                      (text) => text.isEmpty,
                    )
                  : store.rows('SELECT * FROM transcript').isEmpty) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          if (interim) {
            expect(store.rows('SELECT * FROM transcript'), isEmpty);
            expect(
              domain.application.provisionalTranscript['microphone'],
              'Mira owns the draft. Who owns the draft? one two three four five',
            );
            // Interim speech has no durable transcript to retrieve yet; supply
            // independently imported context for the existing grounding path.
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
          final queue = domain.application.proactive;
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
          await domain.command('meetings.stop');
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
