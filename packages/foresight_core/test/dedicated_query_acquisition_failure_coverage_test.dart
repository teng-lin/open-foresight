import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/dedicated_query_acquisition.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_asset_lifecycle.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/model_vault.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _Metadata implements ModelConfigService {
  _Metadata(this.value);
  final ForesightSharedConfig value;
  int calls = 0, closes = 0;
  @override
  Future<ForesightSharedConfig> fetch({required String appVersion}) async {
    calls++;
    return value;
  }

  @override
  Future<void> close() async => closes++;
}

class _Download implements ModelBlobDownloader {
  final entered = Completer<void>();
  final released = Completer<Uint8List>();
  int closes = 0;
  @override
  Future<Uint8List> download({
    required String blobId,
    required int size,
    void Function(int, int)? onProgress,
  }) {
    onProgress?.call(1, size);
    entered.complete();
    return released.future;
  }

  @override
  void close() => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Store store;
  setUp(() {
    root = createTestTempDirectorySync('acquisition-failures-');
    store = Store('${root.path}/app.db');
    store.db.execute(
      'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
      [
        'query-detection',
        'prior-model',
        'prior-digest',
        'prior-runtime',
        'legacy_query_cpu',
      ],
    );
    addTearDown(() {
      store.close();
      root.deleteSync(recursive: true);
    });
  });
  ForesightSharedConfig metadata() => ForesightSharedConfig(
    onDeviceModelMetadatas: [
      OnDeviceModelMetadata(
        modelType: 4,
        name: 'detector',
        version: 'fixture',
        blobId: '/fixture/model',
        size: Int64(dedicatedQueryModelBytes),
      ),
    ],
  );

  test(
    'catalog rejection closes its own catalog without fetching a second metadata source',
    () async {
      final config = _Metadata(metadata());
      final download = _Download();
      final catalog = ModelAssetLifecycle(
        root: Directory('${root.path}/catalog'),
        fetch: () async => ForesightSharedConfig(),
      );
      final operation = DedicatedQueryAcquisition(
        store: store,
        config: config,
        downloader: download,
        vault: MacModelVault(
          root: Directory('${root.path}/vault'),
          helperPath: '/must-not-run',
        ),
        catalog: catalog,
        stagingRoot: root,
      );
      await expectLater(operation.run(), throwsStateError);
      expect(config.calls, 0);
      expect(config.closes, 1);
      expect(download.closes, 1);
      expect(download.entered.isCompleted, isFalse);
      await expectLater(catalog.refresh(), throwsStateError);
      expect(store.model('query-detection')!['path'], 'prior-model');
      expect(
        root.listSync().whereType<Directory>().where(
          (d) => d.path.contains('query-acquisition-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'late cancelled download cannot publish bytes and joins owned cleanup',
    () async {
      final config = _Metadata(metadata());
      final download = _Download();
      final operation = DedicatedQueryAcquisition(
        store: store,
        config: config,
        downloader: download,
        vault: MacModelVault(
          root: Directory('${root.path}/vault'),
          helperPath: '/must-not-run',
        ),
        stagingRoot: root,
      );
      var current = true;
      final progress = <(int, int)>[];
      final pending = operation.run(
        current: () => current,
        onProgress: (received, total) => progress.add((received, total)),
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await download.entered.future;
      current = false;
      download.released.complete(Uint8List.fromList([1, 2, 3]));
      await rejected;
      await operation.done.catchError((Object _) {});
      await operation.close();
      expect(progress, [(1, dedicatedQueryModelBytes)]);
      expect(download.closes, 1);
      expect(config.closes, 1);
      expect(store.model('query-detection')!['path'], 'prior-model');
      expect(root.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'download failure retains its diagnostic and cannot replace registration',
    () async {
      final config = _Metadata(metadata());
      final download = _Download();
      final operation = DedicatedQueryAcquisition(
        store: store,
        config: config,
        downloader: download,
        vault: MacModelVault(
          root: Directory('${root.path}/vault'),
          helperPath: '/must-not-run',
        ),
        stagingRoot: root,
      );
      final rejected = expectLater(
        operation.run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'local transport failed',
          ),
        ),
      );
      await download.entered.future;
      download.released.completeError(StateError('local transport failed'));
      await rejected;
      expect(config.closes, 1);
      expect(download.closes, 1);
      expect(store.model('query-detection')!['path'], 'prior-model');
    },
  );
}
