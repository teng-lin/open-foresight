import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:foresight_core/src/audio_models.dart';
import 'fixtures/durable_speech.dart';

import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class EmbeddingService extends RagServiceBase {
  final texts = <String>[];
  Completer<void>? embeddingGate;
  final embeddingEntered = Completer<void>();
  bool modelUpdateSucceeds = true;
  int modelUpdates = 0;
  int vectorSpace = 1;
  int embeddingFailuresRemaining = 0;

  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async => IndexResponse(success: true);

  @override
  Future<ComputeEmbeddingResponse> computeEmbedding(
    ServiceCall call,
    ComputeEmbeddingRequest request,
  ) async {
    texts.add(request.text);
    if (!embeddingEntered.isCompleted) embeddingEntered.complete();
    if (embeddingFailuresRemaining > 0) {
      embeddingFailuresRemaining--;
      throw const GrpcError.unavailable('Fixture temporary embedding failure');
    }
    final vector = vectorSpace.toDouble();
    await embeddingGate?.future;
    return ComputeEmbeddingResponse(embedding: [vector]);
  }

  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    modelUpdates++;
    if (modelUpdateSucceeds) vectorSpace++;
    return UpdateModelPathsResponse(
      success: modelUpdateSucceeds,
      errorMessage: modelUpdateSucceeds ? '' : 'Fixture model rejected',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class PromptRuntime extends NativeRuntime {
  PromptRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');

  final prompts = <String>[];
  @override
  bool get loaded => true;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready', 'tools': true};
  @override
  void close() {}

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    prompts.add(prompt);
    yield {'type': 'delta', 'text': '- Enhanced plan'};
    yield {'type': 'done', 'status': 'completed'};
  }
}

class ChainRuntime extends PromptRuntime {
  bool finishedFirst = false;
  int calls = 0;
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    final first = calls++ == 0;
    yield* super.generateConversation(
      id,
      prompt,
      maxOutputTokens: maxOutputTokens,
      maxInputTokens: maxInputTokens,
      stopTokenIds: stopTokenIds,
      timeout: timeout,
    );
    if (first) finishedFirst = true;
  }
}

class TranscriptDomain extends AdapterDomain {
  TranscriptDomain(super.store, super.helper, {super.createTimer});

  @override
  Future<void> index(String id, {bool Function()? current}) async {}
}

Future<void> withTranscriptFixture(
  Future<void> Function(
    Directory directory,
    EmbeddingService embeddings,
    TranscriptDomain domain,
    PromptRuntime runtime,
    Application app,
  )
  run,
) async {
  final directory = createTestTempDirectorySync('note-cache-app-');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final socket = '${directory.path}/sock';
  final embeddings = EmbeddingService();
  final server = Server.create(services: [embeddings]);
  final store = Store('${directory.path}/app.db');
  final helper = Helper(
    socket,
    '${directory.path}/helper',
    manageProcess: false,
  );
  final domain = TranscriptDomain(store, helper);
  final runtime = PromptRuntime();
  domain.generator = runtime;
  final app = Application(domain);
  try {
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper.snapshot = control.State(pipeline: 'ready', tokenizerReady: false);
    store.setPreference('liveEnhance', 'false');
    store.setPreference('proactiveAnswers', 'false');
    await run(directory, embeddings, domain, runtime, app);
  } finally {
    await app.close();
    domain.close();
    runtime.close();
    await helper.close();
    store.close();
    await server.shutdown();
    directory.deleteSync(recursive: true);
  }
}

void main() {
  bootstrapSqlSupportFixture();
  test(
    'a chained live enhancement never exposes a zero producer count between producers',
    () async {
      final directory = createTestTempDirectorySync('chained-enhance-');
      final socket = '${directory.path}/h.sock';
      final embeddings = EmbeddingService()..embeddingGate = Completer<void>();
      final server = Server.create(services: [embeddings]);
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        socket,
        '${directory.path}/helper',
        manageProcess: false,
      )..snapshot = control.State(pipeline: 'ready');
      final runtime = ChainRuntime();
      late TranscriptDomain domain;
      late Application app;
      var observedChain = false;
      domain = TranscriptDomain(
        store,
        helper,
        createTimer: (duration, callback) {
          if (runtime.finishedFirst && runtime.calls == 1) {
            observedChain = true;
            expect(app.activeEnhancements, greaterThan(0));
          }
          return Timer(duration, callback);
        },
      )..generator = runtime;
      app = Application(domain);
      addTearDown(() async {
        if (!embeddings.embeddingGate!.isCompleted) {
          embeddings.embeddingGate!.complete();
        }
        await app.close();
        domain.close();
        await helper.close();
        await server.shutdown();
        store.close();
      });
      store.setPreference('liveEnhance', 'true');
      store.setPreference('proactiveAnswers', 'false');
      final first = store.meeting('First'), second = store.meeting('Second');
      for (final id in [first, second]) {
        store.saveMeetingNotes(id, '- Draft shorthand');
        store.transcript(
          id,
          'Saved evidence for the draft.',
          true,
          0,
          20,
          'imported',
        );
      }
      final work = app.enhanceNotes(first, isLive: true);
      await embeddings.embeddingEntered.future;
      await app.enhanceNotes(
        second,
        isLive: true,
        deferWhenBusy: true,
        targetBulletIndices: {0},
      );
      embeddings.embeddingGate!.complete();
      await work;
      await eventually(() => app.activeEnhancements == 0);
      expect(runtime.calls, 2);
      expect(observedChain, true);
      expect(app.backgroundBusy, false);
    },
  );

  test(
    'saved structured transcript records reach enhancement as readable text',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
        app,
      ) async {
        final id = domain.store.meeting('Structured saved record');
        domain.store.saveMeetingNotes(id, 'Raw note');
        domain.store.transcript(
          id,
          '[{"segment_title":"Planning","turns":[{"speaker":"Ada","text":"Ship it"}]}]',
          true,
          0,
          20,
          'imported',
        );
        domain.store.transcript(
          id,
          '  Plain evidence  ',
          true,
          20,
          40,
          'imported',
        );
        await app.enhanceNotes(id);
        expect(
          embeddings.texts.first,
          '--- [Planning] ---\nAda: Ship it\n\nPlain evidence',
        );
        expect(runtime.prompts.single, contains('Ada: Ship it'));
        expect(runtime.prompts.single, isNot(contains('segment_title')));
      });
    },
  );

  test(
    'a temporary embedding error does not permanently poison note enhancement',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
        app,
      ) async {
        final store = domain.store;
        final id = store.meeting('Retry embedding');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        embeddings.embeddingFailuresRemaining = 1;
        await expectLater(app.enhanceNotes(id), throwsA(isA<GrpcError>()));
        expect(runtime.prompts, isEmpty);
        expect(store.rows('SELECT * FROM artifacts'), isEmpty);
        await app.enhanceNotes(id);
        expect(runtime.prompts, hasLength(1));
        expect(embeddings.texts, [
          'Saved evidence',
          'Saved evidence',
          'Raw note',
        ]);
        expect(store.meetingEnhancedNotes(id), '- Enhanced plan');
      });
    },
  );

  for (final registrySucceeds in [true, false]) {
    test(
      'successful helper model change invalidates vectors even when '
      'registry persistence ${registrySucceeds ? "succeeds" : "fails"}',
      () async {
        await withTranscriptFixture((
          directory,
          embeddings,
          domain,
          runtime,
          app,
        ) async {
          final store = domain.store;
          final id = store.meeting('Saved meeting');
          store.saveMeetingNotes(id, 'Raw note');
          store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
          await app.enhanceNotes(id);
          final model = File('${directory.path}/embedding.litertlm');
          model.writeAsStringSync('ABI fixture model');
          final change = app.call(Operation.modelsEmbedding.wire, {
            'path': model.path,
            if (!registrySucceeds) 'digest': 'incorrect-digest',
          });
          if (registrySucceeds) {
            await change;
          } else {
            await expectLater(change, throwsStateError);
          }
          expect(embeddings.modelUpdates, 1);
          await app.enhanceNotes(id);
          expect(
            embeddings.texts.where((text) => text == 'Saved evidence'),
            hasLength(2),
          );

          embeddings.modelUpdateSucceeds = false;
          await expectLater(
            app.call(Operation.modelsEmbedding.wire, {'path': model.path}),
            throwsStateError,
          );
          await app.enhanceNotes(id);
          expect(
            embeddings.texts.where((text) => text == 'Saved evidence'),
            hasLength(2),
          );
        });
      },
    );
  }

  test(
    'model configuration cannot race note preparation before native generation',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
        app,
      ) async {
        final store = domain.store;
        final id = store.meeting('Waiting enhancement');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        final gate = Completer<void>();
        embeddings.embeddingGate = gate;
        final enhancement = app.enhanceNotes(id);
        try {
          await embeddings.embeddingEntered.future;
          expect(runtime.generating, isFalse);
          expect(app.activeEnhancements, 1);
          expect(app.transcriptComputing, 1);
          expect(app.backgroundBusy, true);
          expect(runtime.prompts, isEmpty);
          for (final method in [
            Operation.modelsEmbedding,
            Operation.modelsGeneration,
          ]) {
            await expectLater(
              app.call(method.wire, {
                'path': '/unused',
                if (method == Operation.modelsGeneration) 'runtime': '/unused',
              }),
              throwsA(
                isA<RpcError>().having(
                  (error) => error.code,
                  'code',
                  RpcErrorCode.busy,
                ),
              ),
            );
          }
          expect(embeddings.modelUpdates, 0);
        } finally {
          gate.complete();
          await enhancement;
        }
        expect(app.activeEnhancements, 0);
        expect(app.transcriptComputing, 0);
        expect(app.backgroundBusy, false);
        expect(runtime.prompts, hasLength(1));
      });
    },
  );

  test(
    'cancellation during embedding restores prior notes and retains valid cache',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
        app,
      ) async {
        final store = domain.store;
        final id = store.meeting('Cancelled preparation');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        store.artifact(id, 'enhanced_notes', '- Prior accepted', 'fixture');
        final gate = Completer<void>();
        embeddings.embeddingGate = gate;
        final enhancement = app.enhanceNotes(id);
        try {
          await embeddings.embeddingEntered.future;
          final states = app.captureState['note_enhancements'] as Map;
          final state = states['$id'] as Map;
          expect(
            await app.call(Operation.meetingsCancelEnhance.wire, {
              'id': id,
              'request_id': state['request_id'],
            }),
            isTrue,
          );
          expect(runtime.prompts, isEmpty);
          await enhancement.timeout(const Duration(seconds: 2));
          expect(store.meetingEnhancedNotes(id), '- Prior accepted');
        } finally {
          gate.complete();
          await enhancement;
        }
        expect(runtime.prompts, isEmpty);
        expect(store.meetingEnhancedNotes(id), '- Prior accepted');
        expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
        await app.enhanceNotes(id);
        expect(runtime.prompts, hasLength(1));
        expect(
          embeddings.texts.where((text) => text == 'Saved evidence'),
          hasLength(1),
        );
        expect(
          embeddings.texts.where((text) => text == 'Raw note'),
          hasLength(1),
        );
        expect(store.meetingEnhancedNotes(id), '- Enhanced plan');
      });
    },
  );

  test(
    'capture loads and appends live embeddings with original channel labels',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
        app,
      ) async {
        final library =
            '${directory.path}/recording.${Platform.isMacOS ? "dylib" : "so"}';
        await buildCachedNativeFixture(
          source: 'test/fixtures/recording_native_stub.cpp',
          output: library,
        );
        final previous = runtimeConfiguration.environment['FORESIGHT_NATIVE'];
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
        final store = domain.store;
        final model = File('${directory.path}/speech.model')
          ..writeAsStringSync('ABI fixture');
        store.db.execute(
          "INSERT INTO models(kind,path,digest,runtime,backend) VALUES('speech',?,'fixture','/usr/bin/true','llama_cpp')",
          [model.path],
        );
        final id = store.meeting('Live meeting');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'First evidence', true, 0, 20, 'microphone');
        final capture = DurableSpeechFixture(
          app,
          store,
          DynamicLibrary.open(library),
          text: 'Second evidence',
        );
        try {
          await app.startRecording(id);
          await embeddings.embeddingEntered.future;
          // Real saved-WAV segmentation and ASR commit reach Application's
          // durable notification; no direct transcript callback is injected.
          capture.voice(AudioSource.playback);
          await eventually(
            () => store
                .rows("SELECT 1 FROM transcript WHERE text='Second evidence'")
                .isNotEmpty,
          );
          await app.enhanceNotes(id, isLive: true);
          expect(embeddings.texts.first, 'Microphone: First evidence');
          expect(
            embeddings.texts,
            contains('Microphone: First evidence\nRemote: Second evidence'),
          );
          expect(
            runtime.prompts.single,
            contains('Microphone: First evidence\nRemote: Second evidence'),
          );
          await app.stopRecording();
          await app.enhanceNotes(id);
          expect(
            embeddings.texts,
            contains('First evidence\n\nSecond evidence'),
          );
        } finally {
          await capture.close();
          if (previous == null) {
            runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
          } else {
            runtimeConfiguration.environment['FORESIGHT_NATIVE'] = previous;
          }
        }
      });
    },
  );

  test(
    'saved transcript append refreshes complete embedded grounding cache',
    () async {
      final directory = createTestTempDirectorySync('note-cache-app-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final socket = '${directory.path}/sock';
      final embeddings = EmbeddingService();
      final server = Server.create(services: [embeddings]);
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        socket,
        '${directory.path}/helper',
        manageProcess: false,
      );
      final domain = TranscriptDomain(store, helper);
      final runtime = PromptRuntime();
      domain.generator = runtime;
      final app = Application(domain);
      try {
        await server.serve(
          address: InternetAddress(socket, type: InternetAddressType.unix),
          port: 0,
        );
        helper.snapshot = control.State(
          pipeline: 'ready',
          tokenizerReady: false,
        );
        store.setPreference('liveEnhance', 'false');
        final id = store.meeting('Saved meeting');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Original evidence', true, 0, 20, 'imported');
        await app.enhanceNotes(id);
        expect(runtime.prompts, hasLength(1));
        expect(runtime.prompts.first, contains('Original evidence'));
        expect(runtime.prompts.first, isNot(contains('Novel evidence')));
        expect(embeddings.texts, ['Original evidence', 'Raw note']);

        await app.call(Operation.meetingsTranscript.wire, {
          'id': id,
          'text': 'Novel evidence',
        });
        await app.enhanceNotes(id);
        expect(runtime.prompts, hasLength(2));
        expect(runtime.prompts.last, contains('Original evidence'));
        expect(runtime.prompts.last, contains('Novel evidence'));
        expect(
          embeddings.texts.where((text) => text.contains('Novel evidence')),
          hasLength(1),
        );
        expect(
          embeddings.texts.where((text) => text == 'Raw note'),
          hasLength(2),
        );
        expect(store.meetingEnhancedNotes(id), '- Enhanced plan');
      } finally {
        await app.close();
        domain.close();
        runtime.close();
        await helper.close();
        store.close();
        await server.shutdown();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
