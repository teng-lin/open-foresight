import 'model_queries.dart';
import '../platform_services.dart'
    show RuntimeConfiguration, currentOwnerRuntimeSnapshot;
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../model_integrity.dart';
import '../model_asset_lifecycle.dart';
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

  /// An explicit or bound owner snapshot, fixed at construction (an editable
  /// boundary passed here is frozen); null outside any owner scope.
  final RuntimeConfiguration? configuration;
  ModelStore(
    this.db, {
    required this.supportedVersion,
    RuntimeConfiguration? configuration,
  }) : configuration = configuration?.snapshot() ?? currentOwnerRuntimeSnapshot;
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
  void _setPreference(String key, String value) => db.execute(
    'INSERT INTO preferences VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  ModelQueries get _queries => ModelQueries(
    db,
    supportedVersion: supportedVersion,
    configuration: configuration,
  );
  Map<String, Object?> resolveModelRuntime(Map<String, Object?> model) =>
      _queries.resolveModelRuntime(model);
  Map<String, Object?>? model(String kind) => _queries.model(kind);
  List<Map<String, Object?>> get models => _queries.models;
  String? _ownedRuntime(String resource) => _queries.ownedRuntime(resource);

  /// Explicitly re-read stored bytes. Invalid registrations can be rejected
  /// while preserving their files so setup can repair them.
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
    String? resource = modelRuntimeResources[kind];
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
