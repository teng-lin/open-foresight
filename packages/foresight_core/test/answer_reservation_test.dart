import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/application_services/answer_coordinator.dart';
import 'package:foresight_core/src/application_services/capture_activity.dart';
import 'package:foresight_core/src/application_services/generation_coordinator.dart';
import 'package:foresight_core/src/application_services/note_enhancement_coordinator.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/meeting_queries.dart';
import 'package:foresight_core/src/proactive_questions.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class _HeldRetrieval extends RagServiceBase {
  final entered = Completer<void>(), release = Completer<void>();
  late String document;
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    entered.complete();
    await release.future;
    return RetrieveResponse(
      chunks: [
        RetrievedChunk(
          documentId: document,
          text: 'Mira leads the Atlas project.',
          relevanceScore: .9,
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Cancellation is acknowledged while native cleanup remains held. A peer
/// cannot borrow this interval even when NativeRuntime.generating is false.
class _HeldRuntime extends NativeRuntime {
  _HeldRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>(), release = Completer<void>();
  final cancellations = <String?>[];
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {
    'backend': 'fixture',
    'context_length': 4096,
  };
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    entered.complete();
    await release.future;
    yield {
      'type': 'delta',
      'text': '{"answer":"Mira leads Atlas. [S1]","citations":["S1"]}',
    };
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  bool cancel({String? requestId}) {
    cancellations.add(requestId);
    return true;
  }
}

Matcher rpc(RpcErrorCode code) =>
    throwsA(isA<RpcError>().having((error) => error.code, 'code', code));

void main() {
  bootstrapSqlSupportFixture();
  for (final mode in ['cancel', 'clear', 'close']) {
    test('answer owns retrieval and native cleanup through $mode', () async {
      final root = createTestTempDirectorySync('answer-owner-');
      final store = Store('${root.path}/application.db');
      final retrieval = _HeldRetrieval();
      retrieval.document = store.importText(
        'Atlas project',
        'Mira leads the Atlas project.',
        'text/plain',
        'fixture',
      );
      store.state(retrieval.document, 'indexed');
      final server = Server.create(services: [retrieval]);
      final socket = '${root.path}/helper.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, root.path, manageProcess: false);
      final domain = Domain(store, helper);
      final runtime = _HeldRuntime();
      domain.generator = runtime;
      final generation = GenerationCoordinator(
        restoring: () => false,
        generating: () => runtime.generating,
        recording: () => false,
        closed: () => domain.closed,
        yieldAutomatic: () async {},
      );
      domain.modelGate = generation;
      final proactive = ProactiveQuestions(
        store: store,
        detect: (_, _) async => [],
        answer: (_, _, _) async => 0,
        busy: () => generation.busy,
        cancel: (_) {},
        changed: () {},
      );
      final notes = NoteEnhancementCoordinator(
        domain: domain,
        generation: generation,
        proactive: proactive,
        meetings: MeetingQueries(
          store.db,
          supportedVersion: Store.schemaVersion,
        ),
        capture: CaptureActivity(),
        changed: () {},
        indexSource: (_) {},
        modelDigest: () => 'fixture',
      );
      final answers = AnswerCoordinator(
        domain: domain,
        proactive: proactive,
        notes: notes,
        generation: generation,
        profileId: () => 'fixture-profile',
      );
      addTearDown(() async {
        if (!retrieval.release.isCompleted) retrieval.release.complete();
        if (!runtime.release.isCompleted) runtime.release.complete();
        await generation.close();
        await notes.close();
        await proactive.close();
        domain.close();
        runtime.close();
        await helper.close();
        await server.shutdown();
        store.close();
      });
      final meeting = store.meeting('Original');
      final work = answers
          .ask('Who leads Atlas?', 'desktop', requestId: 'owned')
          .toList();
      final failed = expectLater(work, rpc(RpcErrorCode.cancelled));
      await retrieval.entered.future;
      expect(generation.generationReserved, isTrue);
      expect(generation.configure, rpc(RpcErrorCode.busy));
      await expectLater(
        answers.ask('Peer', 'desktop', requestId: 'peer').toList(),
        rpc(RpcErrorCode.busy),
      );
      expect(runtime.cancellations, isEmpty);
      retrieval.release.complete();
      await runtime.entered.future;
      expect(generation.generationReserved, isTrue);
      Future<void>? closing;
      var closed = false;
      if (mode == 'close') {
        closing = generation.close().then((_) => closed = true);
      } else {
        generation.cancel();
        if (mode == 'clear') {
          domain.invalidateWorkspace();
          WorkspacePersistence(store).clearLocalData(
            store.sources.map((row) => row['id'] as String).toList(),
          );
          expect(store.meeting('Replacement'), meeting);
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(runtime.cancellations, ['owned']);
      expect(generation.generationReserved, isTrue);
      expect(closed, isFalse);
      if (mode != 'close') {
        expect(generation.configure, rpc(RpcErrorCode.busy));
        await expectLater(
          answers.ask('Peer', 'desktop', requestId: 'peer').toList(),
          rpc(RpcErrorCode.busy),
        );
      }
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      runtime.release.complete();
      await failed;
      await closing;
      expect(generation.generationReserved, isFalse);
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      if (mode == 'close') expect(closed, isTrue);
    });
  }
}
