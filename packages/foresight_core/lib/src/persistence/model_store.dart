import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../model_integrity.dart';
import '../model_asset_lifecycle.dart';
import '../platform_services.dart';
import '../rpc_error.dart';
import 'read_schema_guard.dart';

void requireEmbeddingBundle(String path) {
  if (!path.endsWith('.litertlm') || Directory(path).existsSync()) {
    throw StateError(
      'Unsupported model format: embedding requires a .litertlm file',
    );
  }
}

class ModelStore {
  final Database db;
  final int supportedVersion;
  ModelStore(this.db, {required this.supportedVersion});
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    db,
    () => db
        .select(sql, args)
        .map((row) => Map<String, Object?>.from(row))
        .toList(),
    supportedVersion: supportedVersion,
  );
  String _preference(String key, [String fallback = '']) =>
      _rows('SELECT value FROM preferences WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String? ??
      fallback;
  void _setPreference(String key, String value) => db.execute(
    'INSERT INTO preferences VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  static const _runtimeResources = {
    'generation': 'FORESIGHT_LITERT_RUNNER',
    'query-detection': 'FORESIGHT_QUERY_RUNTIME',
    'speech': 'FORESIGHT_WHISPER_RUNTIME',
  };

  String? _ownedRuntime(String resource) {
    final root = runtimeConfiguration['FORESIGHT_INSTALL_ROOT'];
    final path =
        runtimeConfiguration[resource] ??
        (resource == 'FORESIGHT_QUERY_RUNTIME'
            ? runtimeConfiguration['FORESIGHT_LITERT_PYTHON']
            : null);
    if (root == null || path == null) return null;
    try {
      final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
      final file = File(path);
      final canonical = file.resolveSymbolicLinksSync();
      if (!canonical.startsWith('$canonicalRoot/') ||
          (file.statSync().mode & 0x49) == 0) {
        return null;
      }
      return canonical;
    } on FileSystemException {
      return null;
    }
  }

  /// Resolve only provenance recorded during an explicit model registration.
  /// Legacy absolute paths and external runners never acquire inferred ownership.
  Map<String, Object?> resolveModelRuntime(Map<String, Object?> model) =>
      readSnapshot(
        db,
        () => _resolveModelRuntime(model),
        supportedVersion: supportedVersion,
      );
  Map<String, Object?> _resolveModelRuntime(Map<String, Object?> model) {
    final kind = model['kind'];
    final resource = _runtimeResources[kind];
    if (resource == null) return model;
    try {
      final record = jsonDecode(_preference('modelRuntimeResource.$kind'));
      if (record is! Map ||
          (record['resource'] != resource &&
              !(kind == 'query-detection' &&
                  record['resource'] == 'FORESIGHT_LITERT_PYTHON')) ||
          record['runtime'] != model['runtime'] ||
          record['digest'] != model['digest'] ||
          record['backend'] != model['backend']) {
        return model;
      }
      final current = _ownedRuntime(resource);
      if (current == null) return model;
      return {...model, 'runtime': current};
    } on FormatException {
      return model;
    }
  }

  Map<String, Object?>? model(String kind) =>
      readSnapshot(db, () => _model(kind), supportedVersion: supportedVersion);
  Map<String, Object?>? _model(String kind) {
    final registration = _rows('SELECT * FROM models WHERE kind=?', [
      kind,
    ]).firstOrNull;
    if (registration == null) return null;
    final resolved = resolveModelRuntime(registration);
    if (kind == 'generation' &&
        resolved['backend'] == 'litert_lm' &&
        resolved['model_type'] == 0) {
      return {
        ...resolved,
        'model_type': referenceGenerationModelType(
          resolved['digest'] as String,
        ),
      };
    }
    return resolved;
  }

  List<Map<String, Object?>> get models => readSnapshot(
    db,
    () => _rows('SELECT * FROM models').map(resolveModelRuntime).toList(),
    supportedVersion: supportedVersion,
  );

  /// Re-read stored bytes before any model worker is created. Startup rejects
  /// invalid registrations while preserving their files so setup can repair them.
  Future<List<String>> verifyRegisteredModels({
    bool rejectInvalidRegistrations = false,
  }) async {
    final rejected = <Map<String, Object?>>[];
    for (final model in _rows('SELECT kind,path,digest FROM models')) {
      String? actual;
      try {
        actual = await modelAssetDigest(model['path'] as String);
      } on FileSystemException {
        // Missing/unreadable files cannot retain trust from a stored digest.
      } on StateError {
        // An empty model directory is also an invalid registration.
      }
      if (actual != model['digest']) rejected.add(model);
    }
    if (rejected.isNotEmpty && !rejectInvalidRegistrations) {
      throw StateError(
        'The ${rejected.first['kind']} model no longer matches its stored digest. '
        'Restore or replace the model.',
      );
    }
    db.execute('SAVEPOINT verify_model_assets');
    try {
      for (final model in rejected) {
        // Do not erase a replacement that was registered while hashing awaited IO.
        db.execute('DELETE FROM models WHERE kind=? AND path=? AND digest=?', [
          model['kind'],
          model['path'],
          model['digest'],
        ]);
        if (db.updatedRows == 0) continue;
        db.execute('DELETE FROM preferences WHERE key=?', [
          'modelRuntimeResource.${model['kind']}',
        ]);
        _setPreference(
          'modelIntegrityError.${model['kind']}',
          'Stored ${model['kind']} model changed or is missing. Set up the model again.',
        );
      }
      db.execute('RELEASE verify_model_assets');
    } catch (_) {
      db.execute('ROLLBACK TO verify_model_assets');
      db.execute('RELEASE verify_model_assets');
      rethrow;
    }
    return rejected.map((model) => model['kind'] as String).toList();
  }

  Future<void> register(
    String kind,
    String path,
    String runtime, {
    String? backend,
    String? expectedDigest,
    int? modelType,
    bool Function()? current,
  }) async {
    if (modelType != null && (modelType < 0 || modelType > 17)) {
      throw ArgumentError.value(modelType, 'modelType');
    }
    if (kind == 'embedding') requireEmbeddingBundle(path);
    backend ??= kind == 'embedding' ? 'litert_lm_embedding_cpu' : 'llama_cpp';
    final backends = [
      if (kind != 'embedding') ...['llama_cpp', 'litert_lm'],
      if (kind == 'query-detection') ...[
        'legacy_query_cpu',
        'legacy_query_cpu_encrypted',
        'raw_query_jsonl_v1',
      ],
      if (kind == 'embedding') ...[
        'litert_lm_embedding_cpu',
        'litert_lm_embedding_gpu',
      ],
    ];
    if (!backends.contains(backend)) throw ArgumentError.value(backend);
    final digest = await modelAssetDigest(path);
    if (current != null && !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Model setup cancelled');
    }
    if (expectedDigest != null && digest != expectedDigest) {
      throw StateError(
        'The $kind model does not match its installation digest',
      );
    }
    String? resource = _runtimeResources[kind];
    if (resource != null) {
      final owned = _ownedRuntime(resource);
      try {
        if (owned == null ||
            File(runtime).resolveSymbolicLinksSync() != owned) {
          resource = null;
        } else {
          runtime = File(runtime).absolute.path;
        }
      } on FileSystemException {
        resource = null;
      }
    }
    db.execute('SAVEPOINT register_model_runtime');
    try {
      db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend,model_type) VALUES(?,?,?,?,?,?) ON CONFLICT(kind) DO UPDATE SET path=excluded.path,digest=excluded.digest,runtime=excluded.runtime,backend=excluded.backend,model_type=excluded.model_type',
        [
          kind,
          File(path).absolute.path,
          digest.toString(),
          runtime,
          backend,
          modelType ??
              (kind == 'generation' && backend == 'litert_lm'
                  ? referenceGenerationModelType(digest)
                  : 0),
        ],
      );
      db.execute('DELETE FROM preferences WHERE key=?', [
        'modelIntegrityError.$kind',
      ]);
      final key = 'modelRuntimeResource.$kind';
      if (resource == null) {
        db.execute('DELETE FROM preferences WHERE key=?', [key]);
      } else {
        _setPreference(
          key,
          jsonEncode({
            'resource': resource,
            'runtime': runtime,
            'digest': digest.toString(),
            'backend': backend,
          }),
        );
      }
      db.execute('RELEASE register_model_runtime');
    } catch (_) {
      db.execute('ROLLBACK TO register_model_runtime');
      db.execute('RELEASE register_model_runtime');
      rethrow;
    }
  }
}
