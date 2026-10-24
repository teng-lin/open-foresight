import 'dart:async';
import 'dart:io';

import 'package:foresight_core/desktop.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class DownloadConnection
    implements DesktopConnection, ModelAssetProgressSource {
  final updates = StreamController<void>.broadcast(sync: true);
  final reply = Completer<Object?>();
  Map<String, Object?> arguments = {};
  bool Function()? requestCurrent;
  @override
  ModelAssetDownloadPresentation modelAssetDownload =
      const ModelAssetDownloadPresentation();
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) {
    expect(operation, Operation.modelsDownloadAsset);
    arguments = Map<String, Object?>.from(args);
    requestCurrent = current;
    return reply.future;
  }

  void progress(String requestId, String digest) {
    modelAssetDownload = ModelAssetDownloadPresentation(
      requestId: requestId,
      digest: digest,
      active: true,
      phase: ModelDownloadPhase.downloading,
      received: 2,
      total: 4,
    );
    updates.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late DownloadConnection connection;
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('desktop-model-proxy-');
    connection = DownloadConnection();
    addTearDown(connection.updates.close);
  });
  test('only this request and pinned digest publish progress', () async {
    final model = gemmaModels.last;
    final proxy = RemoteModelDownloader(connection);
    final progress = <(int, int)>[];
    final phases = <ModelDownloadPhase>[];
    final work = proxy.download(
      model,
      root,
      progress: (received, total) => progress.add((received, total)),
      phase: phases.add,
    );
    expect(connection.arguments['kind'], 'generation');
    expect(connection.arguments['digest'], model.digest);
    expect(connection.arguments.containsKey('root'), isFalse);
    final id = connection.arguments['requestId'] as String;
    connection.progress('other-request', model.digest);
    connection.progress(id, 'other-digest');
    expect(progress, isEmpty);
    connection.progress(id, model.digest);
    expect(progress, [(2, 4)]);
    expect(phases, [ModelDownloadPhase.downloading]);
    connection.reply.complete({'path': '${root.path}/verified.litertlm'});
    expect((await work).path, '${root.path}/verified.litertlm');
    connection.progress(id, model.digest);
    expect(progress, hasLength(1));
  });
  test(
    'cancellation revokes current and refuses a late completed path',
    () async {
      final proxy = RemoteModelDownloader(connection);
      final work = proxy.download(gemmaModels.last, root);
      final rejected = expectLater(
        work,
        throwsA(isA<ModelDownloadCancelled>()),
      );
      expect(connection.requestCurrent!(), isTrue);
      proxy.cancel();
      expect(connection.requestCurrent!(), isFalse);
      connection.reply.complete({'path': '${root.path}/late.litertlm'});
      await rejected;
    },
  );
  test(
    'callback failure cancels work while preserving the original error',
    () async {
      final model = gemmaModels.last,
          failure = StateError('presentation callback failed');
      final proxy = RemoteModelDownloader(connection);
      final work = proxy.download(
        model,
        root,
        progress: (_, _) => throw failure,
      );
      final rejected = expectLater(work, throwsA(same(failure)));
      connection.progress(
        connection.arguments['requestId'] as String,
        model.digest,
      );
      await rejected;
      expect(connection.requestCurrent!(), isFalse);
      connection.reply.complete({'path': '${root.path}/late.litertlm'});
    },
  );
  test('malformed sent result remains an unknown outcome', () async {
    final proxy = RemoteModelDownloader(connection);
    final work = proxy.download(gemmaModels.last, root);
    final rejected = expectLater(
      work,
      throwsA(
        isA<RpcError>().having(
          (error) => error.reason,
          'reason',
          RpcErrorReason.outcomeUnknown,
        ),
      ),
    );
    connection.reply.complete({'path': 7});
    await rejected;
  });
}
