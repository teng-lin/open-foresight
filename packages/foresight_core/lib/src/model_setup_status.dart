import 'model_identity.dart';
import 'model_runtime_paths.dart';
import 'dart:io';

import 'platform_services.dart';
import 'read_models.dart';

const dedicatedQueryModelDigest =
    '889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f';
const dedicatedQueryModelBytes = 179437568;

/// Validate a registration prepared with an asynchronous model read.
String? preparedDedicatedQuerySetupProblem(ModelRegistration? model) =>
    _dedicatedQuerySetupProblem(model?.toRow());
String? _dedicatedQuerySetupProblem(Map<String, Object?>? model) {
  if (model == null) {
    return 'Import the supported dedicated question model to enable automatic questions.';
  }
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

/// Validate a registration prepared with an asynchronous model read.
String? preparedSpeechSetupProblem(ModelRegistration? model) =>
    _speechSetupProblem(model?.toRow());
String? _speechSetupProblem(Map<String, Object?>? model) {
  if (model == null) {
    return 'Set up a speech model and runner before recording.';
  }
  final asset = File(model['path'] as String);
  final runner = File(model['runtime'] as String);
  if (!asset.existsSync()) {
    return 'The registered speech model file is missing.';
  }
  if (!runner.existsSync() || (runner.statSync().mode & 0x49) == 0) {
    return 'The registered speech runner is missing or not executable.';
  }
  return null;
}

/// Inspect a prepared registration without issuing a synchronous store read.
bool preparedNeedsModel(ModelRegistration? model, String kind) =>
    kind == dedicatedQueryModelKind
    ? preparedDedicatedQuerySetupProblem(model) != null
    : _needsModel(model?.toRow(), kind);

bool _needsModel(Map<String, Object?>? model, String kind) {
  if (model == null) return true;
  final path = model['path'] as String;
  if (kind == 'embedding' &&
      (!path.endsWith('.litertlm') ||
          !const [
            'litert_lm_embedding_cpu',
            'litert_lm_embedding_gpu',
          ].contains(model['backend']))) {
    return true;
  }
  if (!File(path).existsSync()) return true;
  if (kind == 'generation') {
    final registered = model['runtime'] as String;
    final runtime = File(
      model['backend'] == 'litert_lm'
          ? resolveLiteRtRunner(
              registered,
              runtimeConfiguration['FORESIGHT_LITERT_RUNNER'],
            )
          : registered,
    );
    return !runtime.existsSync() || (runtime.statSync().mode & 0x49) == 0;
  }
  return false;
}
