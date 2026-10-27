export 'dedicated_query_terms.dart';
import 'rpc_error.dart';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'model_acquisition.dart';
import 'model_asset_lifecycle.dart';
import 'model_setup.dart';
import 'model_vault.dart';
import 'platform_services.dart';
import 'store.dart';

/// Compatibility version of the inspected distribution, whose detector this
/// runtime authenticates. This is internal distribution data, not user setup.
const referenceDetectorDistributionVersion = '1.0.0';

/// One owned metadata/download/encryption/registration operation. The existing
/// registration remains usable until the new encrypted candidate passes the
/// fixed model identity and real worker readiness checks.
class DedicatedQueryAcquisition {
  DedicatedQueryAcquisition({
    required this.store,
    required this.config,
    required this.downloader,
    required this.vault,
    Directory? stagingRoot,
    this.runtime,
    this.catalog,
    RuntimeConfiguration? configuration,
  }) : configuration = configuration?.snapshot() ?? currentOwnerRuntimeSnapshot,
       stagingRoot = stagingRoot ?? File(store.path).parent;

  /// Bundled resources come from the owner's [configuration]. The distribution
  /// credential keeps its separately owned value-supply path.
  factory DedicatedQueryAcquisition.distribution(
    Store store, {
    RuntimeConfiguration? configuration,
  }) {
    final key = runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'];
    final resources = runtimeSnapshot(configuration);
    if (!Platform.isMacOS) {
      throw StateError('Automatic question model acquisition requires macOS.');
    }
    if (key == null || key.isEmpty) {
      throw StateError(
        'Automatic question model download is unavailable in this distribution.',
      );
    }
    for (final name in ['FORESIGHT_QUERY_WORKER', 'FORESIGHT_MODEL_CRYPTO']) {
      final value = resources[name];
      if (value == null || !File(value).existsSync()) {
        throw StateError(
          'The bundled automatic question runtime is unavailable.',
        );
      }
    }
    final queryRuntime =
        resources['FORESIGHT_QUERY_RUNTIME'] ??
        resources['FORESIGHT_LITERT_PYTHON'];
    if (queryRuntime == null || !File(queryRuntime).existsSync()) {
      throw StateError(
        'The bundled automatic question runtime is unavailable.',
      );
    }
    final config = ModelConfigService(apiKey: key);
    return DedicatedQueryAcquisition(
      store: store,
      config: config,
      catalog: ModelAssetLifecycle(
        root: Directory('${File(store.path).parent.path}/distribution-assets'),
        fetch: () =>
            config.fetch(appVersion: referenceDetectorDistributionVersion),
        protectedPaths: () =>
            store.models.map((model) => model['path'] as String),
      ),
      downloader: ModelBlobDownloader(apiKey: key),
      vault: MacModelVault(
        root: Directory(
          '${File(store.path).parent.path}/models/query-detector',
        ),
        configuration: resources,
      ),
      configuration: resources,
    );
  }

  final ModelAssetLifecycle? catalog;
  final Store store;
  final ModelConfigService config;
  final ModelBlobDownloader downloader;
  final MacModelVault vault;
  final Directory stagingRoot;
  final String? runtime;
  final RuntimeConfiguration? configuration;
  bool _closed = false;
  bool _started = false;
  Future<void>? _closing;
  Future<void>? _running;
  Future<void> get done => _running ?? Future.value();

  Future<void> run({
    bool Function()? current,
    void Function(int, int)? onProgress,
  }) {
    if (_started || _closed) {
      throw StateError('Model acquisition is already used or closed.');
    }
    _started = true;
    return _running = _run(current: current, onProgress: onProgress);
  }

  Future<void> _run({
    bool Function()? current,
    void Function(int, int)? onProgress,
  }) async {
    bool valid() => !_closed && (current == null || current());
    void check() {
      if (!valid()) {
        throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
      }
    }

    Directory? stage;
    File? encrypted;
    var accepted = false;
    try {
      check();
      final ForesightSharedConfig metadata;
      if (catalog case final assets?) {
        await assets.refresh();
        metadata = ForesightSharedConfig(
          onDeviceModelMetadatas: assets.assets.map((asset) => asset.metadata),
        );
      } else {
        metadata = await config.fetch(
          appVersion: referenceDetectorDistributionVersion,
        );
      }
      check();
      final plan = referenceModelDownloadPlan(
        metadata.onDeviceModelMetadatas,
        referenceQueryDetectorModelType,
      );
      if (plan == null ||
          plan.blobName.isEmpty ||
          plan.blobName == '.' ||
          plan.blobName == '..') {
        throw StateError(
          'This distribution does not advertise the dedicated question model.',
        );
      }
      if (plan.metadata.size.toInt() != dedicatedQueryModelBytes) {
        throw StateError(
          'The advertised question model is not supported by this runtime.',
        );
      }
      final bytes = await downloader.download(
        blobId: plan.blobName,
        size: dedicatedQueryModelBytes,
        onProgress: onProgress,
      );
      check();
      if (bytes.length != dedicatedQueryModelBytes ||
          sha256.convert(bytes).toString() != dedicatedQueryModelDigest) {
        throw StateError(
          'The downloaded question model does not match the supported authenticated asset.',
        );
      }
      stage = await createPrivateTempDirectory(
        stagingRoot,
        'query-acquisition-',
      );
      final plaintext = File('${stage.path}/model.tflite');
      await plaintext.writeAsBytes(bytes, flush: true);
      final protected = await Process.run('/bin/chmod', [
        '600',
        plaintext.path,
      ]);
      if (protected.exitCode != 0) {
        throw StateError('Cannot protect the downloaded question model.');
      }
      check();
      // The reference encrypts type 4 before persistence. The port uses its own
      // Keychain entry and retains plaintext only in operation-owned leases.
      encrypted = await vault.persist(
        plaintext,
        version: dedicatedQueryModelDigest,
        current: valid,
      );
      check();
      Future<void> adopt(File candidate) => configureEncryptedDedicatedQuery(
        store,
        candidate.path,
        runtime: runtime,
        current: valid,
        vault: vault,
        configuration: configuration,
      );
      if (catalog case final assets?) {
        await assets.publish(plan.metadata, encrypted, adopt);
      } else {
        await adopt(encrypted);
      }
      accepted = true;
    } catch (_) {
      check();
      rethrow;
    } finally {
      try {
        await close();
      } finally {
        try {
          if (stage != null) await stage.delete(recursive: true);
        } finally {
          if ((!accepted || catalog != null) && encrypted != null) {
            await encrypted.parent.delete(recursive: true);
          }
        }
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    downloader.close();
    await Future.wait([config.close(), vault.close()]);
    await catalog?.close();
  }
}
