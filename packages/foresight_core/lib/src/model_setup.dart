import 'model_setup_status.dart';
export 'model_setup_status.dart';
import 'rpc_error.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'store.dart';
import 'persistence/domain_queries.dart';
import 'model_asset_lifecycle.dart';
import 'model_acquisition.dart' show ForesightSharedConfig;
import 'native.dart';
import 'platform_services.dart';
import 'dedicated_query_runtime.dart';
import 'model_vault.dart';
import 'package:crypto/crypto.dart';

/// Probe a candidate before replacing persistent configuration. The caller
/// adopts the returned runtime, then closes its previous runtime.
Future<NativeRuntime> configureGeneration(
  Store store,
  String library,
  String model,
  String runner, {
  String backend = 'litert_lm',
  int? modelType,
  bool Function()? current,
  void Function(NativeRuntime)? onCandidate,
  void Function()? onRegister,
  Future<void> Function(NativeRuntime)? retire,
  bool Function()? registrationAllowed,
  RuntimeConfiguration? configuration,
}) async {
  bool valid() =>
      (current?.call() ?? true) && (registrationAllowed?.call() ?? true);
  if (!valid()) throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
  if (backend == 'litert_lm') {
    runner = liteRtRunner(runner, configuration: configuration);
  }
  final candidate = NativeRuntime(library);
  try {
    onCandidate?.call(candidate);
    if (!valid()) {
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    }
    final digest = backend == 'litert_lm'
        ? (await sha256.bind(File(model).openRead()).first).toString()
        : null;
    if (!valid()) {
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    }
    candidate.modelType =
        modelType ?? referenceGenerationModelType(digest ?? '');
    await candidate.load(runner, model, backend: backend);
    if (!valid()) {
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    }
    onRegister?.call();
    await store.register(
      'generation',
      model,
      runner,
      backend: backend,
      expectedDigest: digest,
      modelType: candidate.modelType,
      current: valid,
    );
    // Registration is the commit boundary. A disconnected subscriber cannot
    // retract it; the slot still enforces workspace/epoch/close ownership.
    return candidate;
  } catch (error, stack) {
    try {
      if (retire != null) {
        await retire(candidate);
      } else {
        candidate.close();
        await candidate.closed;
      }
    } catch (_) {
      // Keep the original setup error primary. The lifetime owner retains its
      // cleanup failure independently through the same retirement future.
    }
    Error.throwWithStackTrace(error, stack);
  }
}

/// Discover only this profile's previously downloaded distribution files.
/// Explicit existing registrations always win. No metadata RPC or download is
/// needed for the recovered directory fallback after a registry is lost.
Future<NativeRuntime?> discoverGenerationRuntime(
  Store store,
  String library, {
  String? runner,
  RuntimeConfiguration? configuration,
  bool Function()? current,
  void Function(NativeRuntime)? onCandidate,
  Future<void> Function(NativeRuntime)? retire,
}) async {
  if (store.model('generation') != null) return null;
  final catalog = ModelAssetLifecycle(
    root: Directory('${File(store.path).parent.path}/distribution-assets'),
    fetch: () async => ForesightSharedConfig(),
  );
  try {
    for (final type in referenceInferenceModelOrder) {
      final path = await catalog.localPath(type);
      if (path == null) continue;
      final runtime =
          runner ??
          (configuration ?? runtimeConfiguration)['FORESIGHT_LITERT_RUNNER'];
      if (runtime == null) {
        throw StateError('Bundled generation runtime is unavailable');
      }
      return configureGeneration(
        store,
        library,
        path,
        runtime,
        backend: 'litert_lm',
        modelType: type,
        onCandidate: onCandidate,
        retire: retire,
        current: current,
        registrationAllowed: () => store.model('generation') == null,
        configuration: configuration,
      );
    }
    return null;
  } finally {
    await catalog.close();
  }
}

Future<bool> discoverDedicatedQueryModel(
  Store store, {
  bool Function()? current,
  MacModelVault? vault,
  String? runtime,
  RuntimeConfiguration? configuration,
}) async {
  if (store.model(dedicatedQueryModelKind) != null) return false;
  final catalog = ModelAssetLifecycle(
    root: Directory('${File(store.path).parent.path}/distribution-assets'),
    fetch: () async => ForesightSharedConfig(),
  );
  try {
    final path = await catalog.localPath(4);
    if (path == null) return false;
    await configureEncryptedDedicatedQuery(
      store,
      path,
      vault: vault,
      runtime: runtime,
      current: () =>
          (current?.call() ?? true) &&
          store.model(dedicatedQueryModelKind) == null,
      configuration: configuration,
    );
    return true;
  } finally {
    await catalog.close();
  }
}

/// Import an already-decrypted authenticated asset through existing model setup.
/// This is not the original authenticated remote download/decryption pipeline.
Future<void> configureDedicatedQuery(
  Store store,
  String path, {
  String? runtime,
  String? expectedDigest,
  bool Function()? current,
  RuntimeConfiguration? configuration,
}) async {
  if (expectedDigest != null && expectedDigest != dedicatedQueryModelDigest) {
    throw StateError(
      'The dedicated question model installation digest is incorrect',
    );
  }
  final python = await _prepareDedicatedQuery(
    path,
    runtime: runtime,
    current: current,
    configuration: configuration ?? runtimeConfiguration,
  );
  await store.register(
    dedicatedQueryModelKind,
    File(path).absolute.path,
    python,
    backend: dedicatedQueryBackend,
    expectedDigest: dedicatedQueryModelDigest,
    current: current,
  );
}

/// Verify decrypted bytes and the real worker before adopting encrypted storage.
Future<void> configureEncryptedDedicatedQuery(
  Store store,
  String path, {
  String? runtime,
  bool Function()? current,
  MacModelVault? vault,
  RuntimeConfiguration? configuration,
}) async {
  if (current != null && !current()) {
    throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
  }
  final encrypted = File(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      await encrypted.length() != dedicatedQueryModelBytes + 33) {
    throw StateError(
      'The encrypted dedicated question model has an invalid size.',
    );
  }
  final digest = (await sha256.bind(encrypted.openRead()).first).toString();
  final ownedVault =
      vault ??
      MacModelVault(root: encrypted.parent, configuration: configuration);
  ModelVaultLease? lease;
  late final String python;
  try {
    lease = await ownedVault.openLease(encrypted);
    python = await _prepareDedicatedQuery(
      lease.path,
      runtime: runtime,
      current: current,
      configuration: configuration ?? runtimeConfiguration,
    );
  } finally {
    try {
      if (vault == null) await ownedVault.close();
    } finally {
      await lease?.close();
    }
  }
  // Adoption is the final fallible step. A lease-cleanup failure must not leave
  // a new registration that the acquisition owner will treat as rejected and
  // remove from disk.
  await store.register(
    dedicatedQueryModelKind,
    encrypted.absolute.path,
    python,
    backend: dedicatedEncryptedQueryBackend,
    expectedDigest: digest,
    current: current,
  );
}

Future<String> _prepareDedicatedQuery(
  String path, {
  String? runtime,
  bool Function()? current,
  required RuntimeConfiguration configuration,
}) async {
  void checkCurrent() {
    if (current != null && !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    }
  }

  checkCurrent();
  final file = File(path);
  if (!await file.exists() || await file.length() != dedicatedQueryModelBytes) {
    throw StateError(
      'Choose the supported already-decrypted dedicated question model (179437568 bytes)',
    );
  }
  final digest = (await sha256.bind(file.openRead()).first).toString();
  checkCurrent();
  if (digest != dedicatedQueryModelDigest) {
    throw StateError(
      'The dedicated question model does not match the supported authenticated asset',
    );
  }
  final python = runtime?.trim().isNotEmpty == true
      ? runtime!
      : (configuration['FORESIGHT_QUERY_RUNTIME'] ??
            configuration['FORESIGHT_LITERT_PYTHON']);
  final worker = configuration['FORESIGHT_QUERY_WORKER'];
  if (python == null ||
      !File(python).existsSync() ||
      (File(python).statSync().mode & 0x49) == 0 ||
      worker == null ||
      !File(worker).existsSync()) {
    throw StateError(
      'The dedicated question runtime is unavailable. Install a package with its bundled question runtime.',
    );
  }
  // The real worker authenticates the model again, imports NumPy/SentencePiece,
  // loads its tensors and completes a harmless fixed fixture before adoption.
  final candidate = DedicatedQueryRuntime(
    python: python,
    worker: worker,
    model: file.absolute.path,
  );
  final cancellation = current == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (!current()) candidate.cancel('query-model-setup');
        });
  try {
    checkCurrent();
    final response = await candidate.complete(
      ' <ctrl1>The meeting starts at three.',
      'query-model-setup',
    );
    if (response.trim().isNotEmpty) {
      throw StateError(
        'The dedicated question runtime failed its readiness check',
      );
    }
    checkCurrent();
    return python;
  } finally {
    cancellation?.cancel();
    await candidate.close();
  }
}

String? dedicatedQuerySetupProblem(Store store) =>
    preparedDedicatedQuerySetupProblem(
      store.sourceQueries.model(dedicatedQueryModelKind),
    );

/// Register an explicitly supplied, digest-identified local installation.
/// Existing user registrations win. No network or model downloads occur here.
Future<int> registerInstalledModels(
  Store store,
  String manifestPath, {
  RuntimeConfiguration? configuration,
}) async {
  final manifest =
      jsonDecode(await File(manifestPath).readAsString())
          as Map<String, dynamic>;
  var registered = 0;
  for (final kind in [
    'speech',
    'generation',
    'embedding',
    dedicatedQueryModelKind,
  ]) {
    if (DomainQueries(store).hasModel(kind)) {
      continue;
    }
    final entry = manifest[kind] as Map<String, dynamic>?;
    if (entry == null) continue;
    final model = entry['model'] as String;
    if (kind == dedicatedQueryModelKind) {
      if (entry['backend'] != null &&
          entry['backend'] != dedicatedQueryBackend) {
        throw StateError('Unsupported dedicated question model backend');
      }
      await configureDedicatedQuery(
        store,
        model,
        runtime: entry['runtime'] as String?,
        expectedDigest: entry['sha256'] as String?,
        configuration: configuration,
      );
      registered++;
      continue;
    }
    final runtime = kind == 'embedding'
        ? ''
        : kind == 'generation' && entry['backend'] == 'litert_lm'
        ? liteRtRunner(entry['runtime'] as String, configuration: configuration)
        : entry['runtime'] as String;
    if (kind == 'embedding') requireEmbeddingBundle(model);
    if (kind != 'embedding' &&
        (!File(runtime).existsSync() ||
            (File(runtime).statSync().mode & 0x49) == 0)) {
      throw StateError('The $kind runner is missing or not executable');
    }
    if (entry['sha256'] is! String) {
      throw StateError('The $kind installation digest is missing');
    }
    final expectedDigest = entry['sha256'] as String;
    await store.register(
      kind,
      model,
      runtime,
      backend: entry['backend'] as String?,
      expectedDigest: expectedDigest,
      modelType: entry['model_type'] as int?,
    );
    registered++;
  }
  return registered;
}

String? speechSetupProblem(Store store) =>
    preparedSpeechSetupProblem(store.sourceQueries.model('speech'));

/// Registration alone is insufficient when a user has moved a model file.
bool needsModel(Store store, String kind) {
  if (kind == dedicatedQueryModelKind) {
    return dedicatedQuerySetupProblem(store) != null;
  }
  return preparedNeedsModel(store.sourceQueries.model(kind), kind);
}
