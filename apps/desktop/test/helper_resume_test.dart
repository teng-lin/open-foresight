import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/helper.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated/helper_control.pbgrpc.dart' as control;
import '../../../packages/foresight_core/test/fixtures/delayed_index_service.dart'
    show DelayedIndexService;

class ResumeStateService extends control.HelperControlServiceBase {
  control.State value = control.State();
  int loadingReplies = 0;
  @override
  Future<control.State> getState(
    ServiceCall call,
    control.Empty request,
  ) async {
    if (loadingReplies-- > 0) return control.State(pipeline: 'loading');
    return value;
  }

  @override
  Stream<control.State> watchState(
    ServiceCall call,
    control.WatchRequest request,
  ) => const Stream.empty();
}

void main() {
  test(
    'reconnect reuses a matching ready model and waits out an existing rebuild',
    () async {
      final tmp = Directory.systemTemp.createTempSync('helper-resume-');
      final store = Store('${tmp.path}/app.db');
      final model = File('${tmp.path}/model.litertlm')
        ..writeAsStringSync('fixture');
      await store.register(
        'embedding',
        model.path,
        '',
        backend: 'litert_lm_embedding_gpu',
      );
      final registered = store
          .rows("SELECT * FROM models WHERE kind='embedding'")
          .single;
      final rpc = DelayedIndexService();
      final status = ResumeStateService()
        ..value = control.State(
          pipeline: 'ready',
          tokenizerReady: true,
          model: control.ModelIdentity(
            path: model.path,
            modelDigest: registered['digest'] as String,
            backend: 'litert-lm-embedding-gpu',
          ),
        );
      final socket = '${tmp.path}/helper.sock';
      final server = Server.create(services: [rpc, status]);
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${tmp.path}/helper');
      final domain = Domain(store, helper);
      try {
        await domain.resume();
        expect(rpc.configurations, isEmpty);
        status.loadingReplies = 1;
        await domain.resume();
        expect(
          rpc.configurations,
          isEmpty,
          reason: 'An existing rebuild must not trigger a second rebuild',
        );
        status.value.model.modelDigest = 'different';
        await domain.resume();
        expect(
          rpc.configurations.length,
          1,
          reason: 'Changed model identity must be configured',
        );
        status.value.model.modelDigest = registered['digest'] as String;
        await store.register(
          'embedding',
          model.path,
          '',
          backend: 'litert_lm_embedding_cpu',
        );
        await domain.resume();
        expect(
          rpc.configurations.length,
          2,
          reason: 'Backend changes must not reuse the old configuration',
        );
        expect(rpc.configurations.last.useGpu, false);
      } finally {
        domain.close();
        await helper.close();
        await server.shutdown();
        store.close();
        tmp.deleteSync(recursive: true);
      }
    },
  );
}
