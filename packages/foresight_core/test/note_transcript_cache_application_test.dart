import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/domain.dart';
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

class TranscriptDomain extends Domain {
  TranscriptDomain(super.store, super.helper);

  @override
  Future<void> index(String id) async {}
}

Future<void> withTranscriptFixture(
  Future<void> Function(
    Directory directory,
    EmbeddingService embeddings,
    TranscriptDomain domain,
    PromptRuntime runtime,
  )
  run,
) async {
  final directory = Directory.systemTemp.createTempSync('note-cache-app-');
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
  try {
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper.snapshot = control.State(pipeline: 'ready', tokenizerReady: false);
    store.setPreference('liveEnhance', 'false');
    store.setPreference('proactiveAnswers', 'false');
    await run(directory, embeddings, domain, runtime);
  } finally {
    await domain.application.close();
    domain.close();
    runtime.close();
    await helper.close();
    store.close();
    await server.shutdown();
    directory.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'a temporary embedding error does not permanently poison note enhancement',
    () async {
      await withTranscriptFixture((
        directory,
        embeddings,
        domain,
        runtime,
      ) async {
        final store = domain.store;
        final id = store.meeting('Retry embedding');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        embeddings.embeddingFailuresRemaining = 1;
        await expectLater(
          domain.application.enhanceNotes(id),
          throwsA(isA<GrpcError>()),
        );
        expect(runtime.prompts, isEmpty);
        expect(store.rows('SELECT * FROM artifacts'), isEmpty);
        await domain.application.enhanceNotes(id);
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
        ) async {
          final store = domain.store;
          final id = store.meeting('Saved meeting');
          store.saveMeetingNotes(id, 'Raw note');
          store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
          await domain.application.enhanceNotes(id);
          final model = File('${directory.path}/embedding.litertlm');
          model.writeAsStringSync('ABI fixture model');
          final change = domain.command('models.embedding', {
            'path': model.path,
            if (!registrySucceeds) 'digest': 'incorrect-digest',
          });
          if (registrySucceeds) {
            await change;
          } else {
            await expectLater(change, throwsStateError);
          }
          expect(embeddings.modelUpdates, 1);
          await domain.application.enhanceNotes(id);
          expect(
            embeddings.texts.where((text) => text == 'Saved evidence'),
            hasLength(2),
          );

          embeddings.modelUpdateSucceeds = false;
          await expectLater(
            domain.command('models.embedding', {'path': model.path}),
            throwsStateError,
          );
          await domain.application.enhanceNotes(id);
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
      ) async {
        final store = domain.store;
        final id = store.meeting('Waiting enhancement');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        final gate = Completer<void>();
        embeddings.embeddingGate = gate;
        final enhancement = domain.application.enhanceNotes(id);
        try {
          await embeddings.embeddingEntered.future;
          expect(runtime.generating, isFalse);
          expect(runtime.prompts, isEmpty);
          for (final method in ['models.embedding', 'models.generation']) {
            await expectLater(
              domain.command(method, {'path': '/unused'}),
              throwsStateError,
            );
          }
          expect(embeddings.modelUpdates, 0);
        } finally {
          gate.complete();
          await enhancement;
        }
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
      ) async {
        final store = domain.store;
        final id = store.meeting('Cancelled preparation');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(id, 'Saved evidence', true, 0, 20, 'imported');
        store.artifact(id, 'enhanced_notes', '- Prior accepted', 'fixture');
        final gate = Completer<void>();
        embeddings.embeddingGate = gate;
        final enhancement = domain.application.enhanceNotes(id);
        try {
          await embeddings.embeddingEntered.future;
          final states =
              domain.application.captureState['note_enhancements'] as Map;
          final state = states['$id'] as Map;
          expect(
            await domain.command('meetings.cancel_enhance', {
              'id': id,
              'request_id': state['request_id'],
            }),
            isTrue,
          );
          expect(runtime.prompts, isEmpty);
        } finally {
          gate.complete();
          await enhancement;
        }
        expect(runtime.prompts, isEmpty);
        expect(store.meetingEnhancedNotes(id), '- Prior accepted');
        expect(store.rows('SELECT * FROM artifacts'), hasLength(1));
        await domain.application.enhanceNotes(id);
        expect(runtime.prompts, hasLength(1));
        expect(
          embeddings.texts.where((text) => text == 'Saved evidence'),
          hasLength(1),
        );
        expect(
          embeddings.texts.where((text) => text == 'Raw note'),
          hasLength(2),
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
      ) async {
        final library =
            '${directory.path}/recording.${Platform.isMacOS ? "dylib" : "so"}';
        final build = await Process.run('c++', [
          '-std=c++17',
          '-shared',
          '-fPIC',
          'test/fixtures/recording_native_stub.cpp',
          '-o',
          library,
        ]);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
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
        try {
          await domain.application.startRecording(id);
          await embeddings.embeddingEntered.future;
          // This is the actual final-transcript callback installed by Application.
          domain.application.recording!.transcript(
            'Second evidence',
            20,
            40,
            'playback',
          );
          await domain.application.enhanceNotes(id, isLive: true);
          expect(embeddings.texts.first, 'Microphone: First evidence');
          expect(
            embeddings.texts,
            contains('Microphone: First evidence\nRemote: Second evidence'),
          );
          expect(
            runtime.prompts.single,
            contains('Microphone: First evidence\nRemote: Second evidence'),
          );
          await domain.application.stopRecording();
          await domain.application.enhanceNotes(id);
          expect(
            embeddings.texts,
            contains('First evidence\n\nSecond evidence'),
          );
        } finally {
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
      final directory = Directory.systemTemp.createTempSync('note-cache-app-');
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
        await domain.application.enhanceNotes(id);
        expect(runtime.prompts, hasLength(1));
        expect(runtime.prompts.first, contains('Original evidence'));
        expect(runtime.prompts.first, isNot(contains('Novel evidence')));
        expect(embeddings.texts, ['Original evidence', 'Raw note']);

        await domain.command('meetings.transcript', {
          'id': id,
          'text': 'Novel evidence',
        });
        await domain.application.enhanceNotes(id);
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
        await domain.application.close();
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
