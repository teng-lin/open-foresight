import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/dedicated_query_acquisition.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/model_vault.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

class MetadataFixture implements ModelConfigService {
  MetadataFixture(this.value);
  final ForesightSharedConfig value;
  String? version;
  bool closed = false;
  Completer<ForesightSharedConfig>? pending;
  @override
  Future<ForesightSharedConfig> fetch({required String appVersion}) {
    version = appVersion;
    return pending?.future ?? Future.value(value);
  }

  @override
  Future<void> close() async {
    closed = true;
    final active = pending;
    if (active != null && !active.isCompleted) {
      active.completeError(StateError('Fixture cancelled'));
    }
  }
}

class DownloadFixture implements ModelBlobDownloader {
  bool closed = false;
  String? blob;
  int? requestedSize;
  @override
  Future<Uint8List> download({
    required String blobId,
    required int size,
    void Function(int, int)? onProgress,
  }) async {
    blob = blobId;
    requestedSize = size;
    return Uint8List.fromList([0, 1, 2]);
  }

  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late DownloadFixture downloader;
  setUp(() {
    root = createTestTempDirectorySync('query-acquire-test-');
    store = Store('${root.path}/app.db');
    store.db.execute(
      'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
      [
        'query-detection',
        'previous-model',
        'previous-digest',
        'previous-runtime',
        'legacy_query_cpu',
      ],
    );
    downloader = DownloadFixture();
  });
  setUp(() {
    addTearDown(() {
      store.close();
      root.deleteSync(recursive: true);
    });
  });

  DedicatedQueryAcquisition operation(MetadataFixture config) =>
      DedicatedQueryAcquisition(
        store: store,
        config: config,
        downloader: downloader,
        vault: MacModelVault(
          root: Directory('${root.path}/vault'),
          helperPath: '/missing/fixture-helper',
        ),
        stagingRoot: root,
      );
  OnDeviceModelMetadata model({
    int type = 4,
    int size = dedicatedQueryModelBytes,
    String blob = '/remote/model.tflite',
  }) => OnDeviceModelMetadata(modelType: type, size: Int64(size), blobId: blob);
  void previousUnchanged() {
    expect(store.model('query-detection')!['path'], 'previous-model');
    expect(root.listSync().whereType<Directory>(), isEmpty);
  }

  test(
    'missing or incompatible metadata fails before downloading and preserves registration',
    () async {
      for (final models in [
        <OnDeviceModelMetadata>[],
        [model(type: 2)],
        [model(size: 17)],
      ]) {
        final config = MetadataFixture(
          ForesightSharedConfig(onDeviceModelMetadatas: models),
        );
        await expectLater(operation(config).run(), throwsStateError);
        expect(config.version, '1.0.0');
        expect(config.closed, isTrue);
        expect(downloader.blob, isNull);
        previousUnchanged();
      }
    },
  );
  test(
    'last advertised detector basename is selected but unauthenticated bytes never persist',
    () async {
      final config = MetadataFixture(
        ForesightSharedConfig(
          onDeviceModelMetadatas: [
            model(blob: '/old/first'),
            model(blob: '/updated/nested/last.tflite'),
          ],
        ),
      );
      await expectLater(operation(config).run(), throwsStateError);
      expect(downloader.blob, 'last.tflite');
      expect(downloader.requestedSize, dedicatedQueryModelBytes);
      expect(downloader.closed, isTrue);
      previousUnchanged();
    },
  );
  test(
    'close cancels owned metadata work and waits for operation cleanup',
    () async {
      final config = MetadataFixture(ForesightSharedConfig())
        ..pending = Completer();
      final active = operation(config);
      final result = active.run();
      final rejected = expectLater(
        result,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await active.close();
      await rejected;
      await active.done.catchError((Object _) {});
      expect(config.closed, isTrue);
      expect(downloader.closed, isTrue);
      previousUnchanged();
      expect(() => active.run(), throwsStateError);
    },
  );
  test('caller cancellation prevents even metadata acquisition', () async {
    final config = MetadataFixture(
      ForesightSharedConfig(onDeviceModelMetadatas: [model()]),
    );
    await expectLater(
      operation(config).run(current: () => false),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
    expect(config.version, isNull);
    previousUnchanged();
  });
}
