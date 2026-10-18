import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class RecoveryRag extends RagServiceBase {
  void Function()? duringEmbedding;
  @override
  Future<ComputeEmbeddingResponse> computeEmbedding(
    ServiceCall call,
    ComputeEmbeddingRequest request,
  ) async {
    duringEmbedding?.call();
    return ComputeEmbeddingResponse(embedding: [1 / 3, .5, -1]);
  }

  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async =>
      PingResponse(version: 'fixture');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecoveryControl extends control.HelperControlServiceBase {
  control.State value = control.State(
    pipeline: 'ready',
    tokenizerReady: true,
    model: control.ModelIdentity(
      path: '/model.litertlm',
      modelDigest: 'digest',
      backend: 'litert-lm-embedding-cpu',
    ),
  );
  int loading = 0;
  bool reject = false, failWatch = false;
  @override
  Future<control.State> getState(
    ServiceCall call,
    control.Empty request,
  ) async {
    if (reject) throw GrpcError.unavailable('helper disconnected');
    return loading-- > 0 ? control.State(pipeline: 'loading') : value;
  }

  @override
  Stream<control.State> watchState(
    ServiceCall call,
    control.WatchRequest request,
  ) async* {
    if (failWatch) throw GrpcError.unavailable('watch disconnected');
    yield value;
  }
}

void main() {
  late Directory root;
  late Store store;
  late Helper helper;
  late Domain domain;
  late RecoveryRag rag;
  late RecoveryControl controlService;
  late Server server;
  setUp(() async {
    root = shortTestTempRoot.createTempSync('of-recovery-');
    store = Store('${root.path}/app.db');
    rag = RecoveryRag();
    controlService = RecoveryControl();
    server = Server.create(services: [rag, controlService]);
    final path = '${root.path}/helper.sock';
    await server.serve(
      address: InternetAddress(path, type: InternetAddressType.unix),
      port: 0,
    );
    helper = Helper(path, '${root.path}/helper', manageProcess: false);
    domain = Domain(store, helper);
  });
  tearDown(() async {
    domain.close();
    await helper.close();
    await server.shutdown();
    store.close();
    root.deleteSync(recursive: true);
  });

  test(
    'graph embeddings reject unavailable, paused, stale-model and disposed results',
    () async {
      final a = store.importText('A', 'first', 'text/plain', 'fixture');
      final b = store.importText('B', 'second', 'text/plain', 'fixture');
      expect(await domain.graphEmbeddings(store.sources), isEmpty);
      helper.snapshot = controlService.value.deepCopy();
      final embeddings = await domain.graphEmbeddings(store.sources);
      expect(embeddings.keys.toSet(), {a, b});
      expect(embeddings[a]![0], closeTo(1 / 3, 1e-7));
      domain.pauseSources();
      expect(await domain.graphEmbeddings(store.sources), isEmpty);
      domain.resumeSources();
      rag.duringEmbedding = () =>
          helper.snapshot!.model.modelDigest = 'changed';
      expect(await domain.graphEmbeddings(store.sources), isEmpty);
      rag.duringEmbedding = domain.pauseSources;
      expect(await domain.graphEmbeddings(store.sources), isEmpty);
      domain.resumeSources();
      rag.duringEmbedding = domain.close;
      await expectLater(
        domain.graphEmbeddings(store.sources),
        throwsStateError,
      );
    },
  );

  test(
    'model reuse requires matching tokenizer, digest, path and backend and waits for a rebuild',
    () async {
      expect(
        await helper.hasActiveModel('/model.litertlm', 'digest', false),
        isTrue,
      );
      for (final mutate in <void Function(control.State)>[
        (state) => state.tokenizerReady = false,
        (state) => state.lastError = 'failed',
        (state) => state.model.path = '/other',
        (state) => state.model.modelDigest = 'other',
        (state) => state.model.backend = 'litert-lm-embedding-gpu',
      ]) {
        final before = controlService.value.deepCopy();
        mutate(controlService.value);
        expect(
          await helper.hasActiveModel('/model.litertlm', 'digest', false),
          isFalse,
        );
        controlService.value = before;
      }
      controlService.loading = 1;
      expect(
        await helper.hasActiveModel('/model.litertlm', 'digest', false),
        isTrue,
      );
      controlService.value.model.backend = 'litert-lm-embedding-gpu';
      expect(
        await helper.hasActiveModel('/model.litertlm', 'digest', true),
        isTrue,
      );
      controlService.value.model.path = '/directory';
      expect(
        await helper.hasActiveModel('/directory', 'digest', false),
        isFalse,
      );
      controlService.reject = true;
      expect(
        await helper.hasActiveModel('/model.litertlm', 'digest', false),
        isFalse,
      );
      helper.stopping = true;
      expect(
        await helper.hasActiveModel('/model.litertlm', 'digest', false),
        isFalse,
      );
    },
  );

  test(
    'helper startup publishes readiness and surfaces a failed state subscription',
    () async {
      final ready = Completer<void>(), changed = Completer<void>();
      helper.onReady = () async {
        ready.complete();
      };
      helper.changed = () {
        if (helper.state.startsWith('state stream unavailable') &&
            !changed.isCompleted)
          changed.complete();
      };
      controlService.failWatch = true;
      await helper.start();
      await ready.future;
      await changed.future.timeout(const Duration(seconds: 5));
      expect(helper.state, contains('watch disconnected'));
    },
  );

  test(
    'failed initialization is observed by resume and clears the restoring state',
    () async {
      final init = Completer<void>();
      domain.initialize(init.future);
      expect(domain.restoring, isTrue);
      final failure = expectLater(domain.resume(), throwsStateError);
      init.completeError(StateError('bootstrap failed'));
      await failure;
      expect(domain.restoring, isFalse);
      final result =
          await domain.command('meetings.create', {'title': 'Recovered'})
              as Map;
      expect(result['id'], isA<int>());
      await expectLater(
        domain.commandCurrent('notes.save', {}, () => false),
        throwsStateError,
      );
      await domain.application.close();
    },
  );
}
