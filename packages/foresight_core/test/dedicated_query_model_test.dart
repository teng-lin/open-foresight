import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/dedicated_query_acquisition.dart';
import 'package:foresight_core/src/encrypted_query_runtime.dart';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_asset_lifecycle.dart';
import 'package:foresight_core/src/model_vault.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/reference_query_detector.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

class _LocalMetadata implements ModelConfigService {
  @override
  Future<ForesightSharedConfig> fetch({required String appVersion}) async =>
      ForesightSharedConfig(
        onDeviceModelMetadatas: [
          OnDeviceModelMetadata(
            modelType: 4,
            name: 'detector.tflite',
            version: '1.0',
            blobId: '/fixture/detector.tflite',
            size: Int64(dedicatedQueryModelBytes),
          ),
        ],
      );
  @override
  Future<void> close() async {}
}

class _LocalDownload implements ModelBlobDownloader {
  _LocalDownload(this.path);
  final String path;
  @override
  Future<Uint8List> download({
    required String blobId,
    required int size,
    void Function(int, int)? onProgress,
  }) => File(path).readAsBytes();
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingLeaseCleanup implements ModelVaultLease {
  _FailingLeaseCleanup(this.lease);
  final ModelVaultLease lease;
  @override
  String get path => lease.path;
  @override
  Future<void> close() async {
    await lease.close();
    throw StateError('Fixture lease cleanup failed');
  }
}

class _LeaseCleanupFailureVault extends MacModelVault {
  _LeaseCleanupFailureVault({
    required super.root,
    required super.helperPath,
    required super.tempRoot,
  });
  @override
  Future<ModelVaultLease> openLease(File encrypted) async =>
      _FailingLeaseCleanup(await super.openLease(encrypted));
}

void main() {
  bootstrapSqlSupportFixture();
  final env = Platform.environment;
  test(
    'lease cleanup failure rejects acquisition before replacing registration',
    () async {
      final directory = createTestTempDirectorySync('query-cleanup-failure-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      try {
        final previous = File('${directory.path}/previous')
          ..writeAsStringSync('previous');
        await store.register(
          dedicatedQueryModelKind,
          previous.path,
          '/bin/false',
          backend: dedicatedQueryBackend,
        );
        final registration = Map.of(store.model(dedicatedQueryModelKind)!);
        final helper = File('${directory.path}/vault-fixture');
        helper.writeAsStringSync(
          '#!/bin/sh\nset -eu\numask 077\nif [ "\$1" = encrypt ]; then\n  { printf "%033d" 0; /bin/cat "\$3"; } > "\$5"\nelse\n  /usr/bin/tail -c +34 "\$3" > "\$5"\nfi\n',
        );
        expect(
          (await Process.run('/bin/chmod', ['700', helper.path])).exitCode,
          0,
        );
        final leases = Directory('${directory.path}/leases')..createSync();
        final models = Directory('${directory.path}/models');
        final acquisition = DedicatedQueryAcquisition(
          store: store,
          config: _LocalMetadata(),
          downloader: _LocalDownload(env['FORESIGHT_QUERY_MODEL']!),
          vault: _LeaseCleanupFailureVault(
            root: models,
            helperPath: helper.path,
            tempRoot: leases,
          ),
        );
        await expectLater(
          acquisition.run(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'reason',
              'Fixture lease cleanup failed',
            ),
          ),
        );
        expect(store.model(dedicatedQueryModelKind), registration);
        expect(previous.readAsStringSync(), 'previous');
        expect(models.listSync(), isEmpty);
        expect(leases.listSync(), isEmpty);
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: env['FORESIGHT_QUERY_MODEL_TEST'] != '1'
        ? 'Set supported asset and bundled runtime for cleanup integration'
        : false,
  );
  test(
    'fixture acquisition registers encrypted storage and real detector reopens a private lease',
    () async {
      final directory = createTestTempDirectorySync('query-acquisition-model-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      EncryptedDedicatedQueryRuntime? detectorRuntime;
      try {
        // A framing-only vault fixture exercises the complete registration and
        // lease pipeline without touching Keychain. Native crypto is tested with
        // its separate fixed Tink/AES vectors; this is not a crypto oracle.
        final helper = File('${directory.path}/vault-fixture');
        helper.writeAsStringSync(
          '#!/bin/sh\nset -eu\numask 077\nif [ "\$1" = encrypt ]; then\n  { printf "%033d" 0; /bin/cat "\$3"; } > "\$5"\nelse\n  /usr/bin/tail -c +34 "\$3" > "\$5"\nfi\n',
        );
        expect(
          (await Process.run('/bin/chmod', ['700', helper.path])).exitCode,
          0,
        );
        final leases = Directory('${directory.path}/leases')..createSync();
        final models = Directory('${directory.path}/models');
        final operation = DedicatedQueryAcquisition(
          store: store,
          config: _LocalMetadata(),
          downloader: _LocalDownload(env['FORESIGHT_QUERY_MODEL']!),
          catalog: ModelAssetLifecycle(
            root: Directory('${directory.path}/distribution-assets'),
            fetch: () => _LocalMetadata().fetch(appVersion: '1.0.0'),
            protectedPaths: () =>
                store.models.map((model) => model['path'] as String),
          ),
          vault: MacModelVault(
            root: models,
            helperPath: helper.path,
            tempRoot: leases,
          ),
        );
        await operation.run();
        final registered = store.model(dedicatedQueryModelKind)!;
        expect(
          registered['path'],
          '${directory.path}/distribution-assets/models/4/1.0/detector.tflite',
        );
        // A lost registry entry is restored from our own distribution tree,
        // authenticated and probed again without contacting the distribution.
        store.db.execute('DELETE FROM models WHERE kind=?', [
          dedicatedQueryModelKind,
        ]);
        final recoveryVault = MacModelVault(
          root: models,
          helperPath: helper.path,
          tempRoot: leases,
        );
        try {
          expect(
            await discoverDedicatedQueryModel(
              store,
              vault: recoveryVault,
              runtime: env['FORESIGHT_QUERY_PYTHON'],
            ),
            isTrue,
          );
        } finally {
          await recoveryVault.close();
        }
        expect(
          store.model(dedicatedQueryModelKind)!['path'],
          registered['path'],
        );

        expect(registered['backend'], dedicatedEncryptedQueryBackend);
        expect(
          File(registered['path'] as String).lengthSync(),
          dedicatedQueryModelBytes + 33,
        );
        expect(leases.listSync(), isEmpty);
        expect(
          directory.listSync().whereType<Directory>().any(
            (d) => d.path
                .substring(directory.path.length + 1)
                .startsWith('query-acquisition-'),
          ),
          isFalse,
        );
        detectorRuntime = EncryptedDedicatedQueryRuntime(
          python: env['FORESIGHT_QUERY_PYTHON']!,
          worker: env['FORESIGHT_QUERY_WORKER']!,
          encryptedModel: registered['path'] as String,
          vaultRoot: models,
          vaultFactory: (root) => MacModelVault(
            root: root,
            helperPath: helper.path,
            tempRoot: leases,
          ),
        );
        final result = await ReferenceQueryDetector(detectorRuntime.complete)
            .detect(
              'The launch is scheduled for Friday. What risks could delay it?',
              'encrypted-positive',
            );
        expect(result, ['What risks could delay the launch?']);
        await detectorRuntime.close();
        expect(leases.listSync(), isEmpty);
        expect(File(registered['path'] as String).existsSync(), isTrue);
      } finally {
        await detectorRuntime?.close();
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: env['FORESIGHT_QUERY_MODEL_TEST'] != '1'
        ? 'Set original model and bundled runtime for acquisition integration'
        : false,
  );
  test(
    'guided import authenticates the actual asset and selects bundled runtime',
    () async {
      final directory = createTestTempDirectorySync('query-import-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      try {
        await configureDedicatedQuery(store, env['FORESIGHT_QUERY_MODEL']!);
        final registered = store.model(dedicatedQueryModelKind)!;
        expect(registered['backend'], dedicatedQueryBackend);
        expect(registered['digest'], dedicatedQueryModelDigest);
        expect(
          registered['runtime'],
          env['FORESIGHT_QUERY_RUNTIME'] ?? env['FORESIGHT_LITERT_PYTHON'],
        );
        expect(dedicatedQuerySetupProblem(store), isNull);
        final reopened = Store('${directory.path}/app.db');
        try {
          expect(reopened.model(dedicatedQueryModelKind), registered);
        } finally {
          reopened.close();
        }
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
    skip: env['FORESIGHT_QUERY_MODEL_TEST'] != '1'
        ? 'Set dedicated model and bundled runtime paths for guided import'
        : false,
  );
  test(
    'dedicated original weights complete through the owned Dart runtime',
    () async {
      final runtime = DedicatedQueryRuntime(
        python: env['FORESIGHT_QUERY_PYTHON']!,
        worker: env['FORESIGHT_QUERY_WORKER']!,
        model: env['FORESIGHT_QUERY_MODEL']!,
      );
      final detector = ReferenceQueryDetector(runtime.complete);
      final report = <String, dynamic>{
        'backend': dedicatedQueryBackend,
        'original_gpu_parity_verified': false,
      };
      try {
        final positive = await detector.detect(
          'The launch is scheduled for Friday. What risks could delay it?',
          'actual-positive',
        );
        final negative = await detector.detect(
          'The meeting starts at three.',
          'actual-negative',
        );
        expect(positive, ['What risks could delay the launch?']);
        expect(negative, isEmpty);
        report['positive'] = positive;
        report['negative'] = negative;
      } finally {
        await runtime.close();
      }
      report['closed'] = true;
      final path = env['FORESIGHT_QUERY_MODEL_REPORT'];
      if (path != null) {
        File(
          path,
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      }
    },
    skip: env['FORESIGHT_QUERY_MODEL_TEST'] != '1'
        ? 'Set dedicated model, worker and Python paths to run original weights'
        : false,
  );
}
