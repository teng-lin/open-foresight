import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class HeldModelUpdate extends RagServiceBase {
  final updateEntered = Completer<void>(), updateRelease = Completer<void>();
  final peerEntered = Completer<void>(), peerRelease = Completer<void>();
  ServiceCall? updateCall, peerCall;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    updateCall = call;
    updateEntered.complete();
    await updateRelease.future;
    return UpdateModelPathsResponse(success: true);
  }

  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    peerCall = call;
    peerEntered.complete();
    await peerRelease.future;
    return RetrieveResponse();
  }
}

void main() {
  test(
    'shutdown cancels only the owned embedding update and joins its configuration lease',
    () async {
      final directory = createTestTempDirectorySync('embedding-close-');
      final store = Store('${directory.path}/app.db');
      final rag = HeldModelUpdate();
      final socket = '${directory.path}/helper.sock';
      final server = Server.create(services: [rag]);
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(
        socket,
        '${directory.path}/helper',
        manageProcess: false,
      );
      final domain = AdapterDomain(store, helper);
      final app = Application(domain);
      addTearDown(() async {
        if (!rag.updateRelease.isCompleted) rag.updateRelease.complete();
        if (!rag.peerRelease.isCompleted) rag.peerRelease.complete();
        await app.close();
        domain.close();
        await helper.close();
        await server.shutdown();
        store.close();
        directory.deleteSync(recursive: true);
      });
      final peer = helper.client.retrieveContext(RetrieveRequest());
      final peerResult = peer.then<Object>(
        (response) => response,
        onError: (Object error) => error,
      );
      var peerSettled = false;
      unawaited(peerResult.then((_) => peerSettled = true));
      await rag.peerEntered.future;
      final model = File('${directory.path}/embedding.litertlm')
        ..writeAsStringSync('fixture');
      final configuration = app.call(Operation.modelsEmbedding.wire, {
        'path': model.path,
      });
      final cancelled = expectLater(
        configuration,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      await rag.updateEntered.future;
      expect(app.modelBusy, isTrue);
      await app.close().timeout(const Duration(seconds: 2));
      await cancelled;
      expect(rag.updateRelease.isCompleted, isFalse);
      expect(app.modelBusy, isFalse);
      expect(store.model('embedding'), isNull);
      await eventually(() => rag.updateCall!.isCanceled);
      expect(rag.peerCall!.isCanceled, isFalse);
      expect(peerSettled, isFalse);
      rag.peerRelease.complete();
      expect(await peerResult, isA<RetrieveResponse>());
      // A successful late server result cannot register or restart source work.
      rag.updateRelease.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.model('embedding'), isNull);
      expect(domain.indexed, isEmpty);
    },
  );
}
