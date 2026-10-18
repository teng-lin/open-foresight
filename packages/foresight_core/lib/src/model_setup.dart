import 'rpc_error.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'store.dart';
import 'model_asset_lifecycle.dart';
import 'model_acquisition.dart' show ForesightSharedConfig;
import 'native.dart';
import 'platform_services.dart';
import 'dedicated_query_runtime.dart';
import 'encrypted_query_runtime.dart';
import 'model_vault.dart';
import 'package:crypto/crypto.dart';

/// Probe a candidate before replacing persistent configuration. The caller
/// adopts the returned runtime, then closes its previous runtime.
Future<NativeRuntime> configureGeneration(
  Store store,
  String library,
  String model,
  String runner, {
  String backend = 'llama_cpp',
  int? modelType,
  bool Function()? current,
  void Function(NativeRuntime)? onCandidate,
  void Function()? onRegister,
}) async {
  if (backend == 'litert_lm') runner = liteRtRunner(runner);
  final candidate = NativeRuntime(library);
  try {
    onCandidate?.call(candidate);
    if (current != null && !current())
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    final digest = backend == 'litert_lm'
        ? (await sha256.bind(File(model).openRead()).first).toString()
        : null;
    candidate.modelType =
        modelType ?? referenceGenerationModelType(digest ?? '');
    await candidate.load(runner, model, backend: backend);
    if (current != null && !current())
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    onRegister?.call();
    await store.register(
      'generation',
      model,
      runner,
      backend: backend,
      expectedDigest: digest,
      modelType: candidate.modelType,
      current: current,
    );
    return candidate;
  } catch (_) {
    candidate.close();
    rethrow;
  }
}

/// Discover only this profile's previously downloaded distribution files.
/// Explicit existing registrations always win. No metadata RPC or download is
/// needed for the recovered directory fallback after a registry is lost.
Future<NativeRuntime?> discoverGenerationRuntime(
  Store store,
  String library, {
  String? runner,
  bool Function()? current,
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
      final runtime = runner ?? runtimeConfiguration['FORESIGHT_LITERT_RUNNER'];
      if (runtime == null)
        throw StateError('Bundled generation runtime is unavailable');
      return configureGeneration(
        store,
        library,
        path,
        runtime,
        backend: 'litert_lm',
        modelType: type,
        current: () =>
            (current?.call() ?? true) && store.model('generation') == null,
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
    );
    return true;
  } finally {
    await catalog.close();
  }
}

const dedicatedQueryModelDigest =
    '889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f';
const dedicatedQueryModelBytes = 179437568;

/// Import an already-decrypted authenticated asset through existing model setup.
/// This is not the original authenticated remote download/decryption pipeline.
Future<void> configureDedicatedQuery(
  Store store,
  String path, {
  String? runtime,
  String? expectedDigest,
  bool Function()? current,
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
}) async {
  if (current != null && !current())
    throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
  final encrypted = File(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      await encrypted.length() != dedicatedQueryModelBytes + 33) {
    throw StateError(
      'The encrypted dedicated question model has an invalid size.',
    );
  }
  final digest = (await sha256.bind(encrypted.openRead()).first).toString();
  final ownedVault = vault ?? MacModelVault(root: encrypted.parent);
  ModelVaultLease? lease;
  late final String python;
  try {
    lease = await ownedVault.openLease(encrypted);
    python = await _prepareDedicatedQuery(
      lease.path,
      runtime: runtime,
      current: current,
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
}) async {
  void checkCurrent() {
    if (current != null && !current())
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
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
      : (runtimeConfiguration['FORESIGHT_QUERY_RUNTIME'] ??
            runtimeConfiguration['FORESIGHT_LITERT_PYTHON']);
  final worker = runtimeConfiguration['FORESIGHT_QUERY_WORKER'];
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
    if (response.trim().isNotEmpty)
      throw StateError(
        'The dedicated question runtime failed its readiness check',
      );
    checkCurrent();
    return python;
  } finally {
    cancellation?.cancel();
    await candidate.close();
  }
}

String? dedicatedQuerySetupProblem(Store store) {
  final model = store.model(dedicatedQueryModelKind);
  if (model == null)
    return 'Import the supported dedicated question model to enable automatic questions.';
  final asset = File(model['path'] as String);
  final encrypted = model['backend'] == dedicatedEncryptedQueryBackend;
  if ((!encrypted && model['backend'] != dedicatedQueryBackend) ||
      (!encrypted && model['digest'] != dedicatedQueryModelDigest) ||
      !asset.existsSync() ||
      asset.lengthSync() != dedicatedQueryModelBytes + (encrypted ? 33 : 0)) {
    return 'The imported dedicated question model is missing or does not match the supported asset.';
  }
  final python = File(model['runtime'] as String);
  final worker = runtimeConfiguration['FORESIGHT_QUERY_WORKER'];
  final crypto = runtimeConfiguration['FORESIGHT_MODEL_CRYPTO'];
  if (encrypted &&
      (crypto == null ||
          !File(crypto).existsSync() ||
          (File(crypto).statSync().mode & 0x49) == 0)) {
    return 'The bundled model encryption helper is unavailable.';
  }
  if (!python.existsSync() ||
      (python.statSync().mode & 0x49) == 0 ||
      worker == null ||
      !File(worker).existsSync()) {
    return 'The dedicated question runtime is unavailable in this installation.';
  }
  return null;
}

/// Register an explicitly supplied, digest-identified local installation.
/// Existing user registrations win. No network or model downloads occur here.
Future<int> registerInstalledModels(Store store, String manifestPath) async {
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
    if (store.rows('SELECT kind FROM models WHERE kind=?', [kind]).isNotEmpty)
      continue;
    final entry = manifest[kind] as Map<String, dynamic>?;
    if (entry == null) continue;
    final model = entry['model'] as String;
    if (kind == dedicatedQueryModelKind) {
      if (entry['backend'] != null && entry['backend'] != dedicatedQueryBackend)
        throw StateError('Unsupported dedicated question model backend');
      await configureDedicatedQuery(
        store,
        model,
        runtime: entry['runtime'] as String?,
        expectedDigest: entry['sha256'] as String?,
      );
      registered++;
      continue;
    }
    final runtime = kind == 'embedding'
        ? ''
        : kind == 'generation' && entry['backend'] == 'litert_lm'
        ? liteRtRunner(entry['runtime'] as String)
        : entry['runtime'] as String;
    if (kind == 'embedding') requireEmbeddingBundle(model);
    if (kind != 'embedding' &&
        (!File(runtime).existsSync() ||
            (File(runtime).statSync().mode & 0x49) == 0)) {
      throw StateError('The $kind runner is missing or not executable');
    }
    if (entry['sha256'] is! String)
      throw StateError('The $kind installation digest is missing');
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

String? speechSetupProblem(Store store) {
  final model = store.model('speech');
  if (model == null)
    return 'Set up a speech model and runner before recording.';
  final asset = File(model['path'] as String);
  final runner = File(model['runtime'] as String);
  if (!asset.existsSync())
    return 'The registered speech model file is missing.';
  if (!runner.existsSync() || (runner.statSync().mode & 0x49) == 0) {
    return 'The registered speech runner is missing or not executable.';
  }
  return null;
}

/// Registration alone is insufficient when a user has moved a model file.
bool needsModel(Store store, String kind) {
  if (kind == dedicatedQueryModelKind)
    return dedicatedQuerySetupProblem(store) != null;
  final model = store.model(kind);
  if (model == null) return true;
  final path = model['path'] as String;
  if (kind == 'embedding' &&
      (!path.endsWith('.litertlm') ||
          !const [
            'litert_lm_embedding_cpu',
            'litert_lm_embedding_gpu',
          ].contains(model['backend'])))
    return true;
  if (!File(path).existsSync()) return true;
  if (kind == 'generation') {
    final registered = model['runtime'] as String;
    final runtime = File(
      model['backend'] == 'litert_lm' ? liteRtRunner(registered) : registered,
    );
    return !runtime.existsSync() || (runtime.statSync().mode & 0x49) == 0;
  }
  return false;
}
