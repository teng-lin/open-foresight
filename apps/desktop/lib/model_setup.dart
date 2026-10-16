import 'dart:convert';
import 'dart:io';
import 'store.dart';
import 'native.dart';

/// Probe a candidate before replacing persistent configuration. The caller
/// adopts the returned runtime, then closes its previous runtime.
Future<NativeRuntime> configureGeneration(
  Store store,
  String library,
  String model,
  String runner, {
  String backend = 'llama_cpp',
  bool Function()? current,
  void Function(NativeRuntime)? onCandidate,
}) async {
  final candidate = NativeRuntime(library);
  try {
    onCandidate?.call(candidate);
    if (current != null && !current())
      throw StateError('Model setup cancelled');
    await candidate.load(runner, model, backend: backend);
    if (current != null && !current())
      throw StateError('Model setup cancelled');
    await store.register(
      'generation',
      model,
      runner,
      backend: backend,
      current: current,
    );
    return candidate;
  } catch (_) {
    candidate.close();
    rethrow;
  }
}

/// Register an explicitly supplied, digest-identified local installation.
/// Existing user registrations win. No network or model downloads occur here.
Future<int> registerInstalledModels(Store store, String manifestPath) async {
  final manifest =
      jsonDecode(await File(manifestPath).readAsString())
          as Map<String, dynamic>;
  var registered = 0;
  for (final kind in ['speech', 'generation', 'embedding']) {
    if (store.rows('SELECT kind FROM models WHERE kind=?', [kind]).isNotEmpty)
      continue;
    final entry = manifest[kind] as Map<String, dynamic>?;
    if (entry == null) continue;
    final model = entry['model'] as String;
    final runtime = kind == 'embedding' ? '' : entry['runtime'] as String;
    String? expectedDigest;
    if (kind == 'embedding' && Directory(model).existsSync()) {
      // Legacy SentenceTransformers installations are directory manifests.
    } else {
      if (kind == 'embedding' && !model.endsWith('.litertlm'))
        throw StateError(
          'Embedding model directory or .litertlm bundle is missing',
        );
      if (kind != 'embedding' &&
          (!File(runtime).existsSync() ||
              (File(runtime).statSync().mode & 0x49) == 0)) {
        throw StateError('The $kind runner is missing or not executable');
      }
      if (entry['sha256'] is! String)
        throw StateError('The $kind installation digest is missing');
      expectedDigest = entry['sha256'] as String;
    }
    await store.register(
      kind,
      model,
      runtime,
      backend: entry['backend'] as String? ?? 'llama_cpp',
      expectedDigest: expectedDigest,
    );
    registered++;
  }
  return registered;
}

String? speechSetupProblem(Store store) {
  final model = store
      .rows("SELECT * FROM models WHERE kind='speech'")
      .firstOrNull;
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
