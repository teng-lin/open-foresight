import '../model_identity.dart';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../platform_services.dart';
import 'read_schema_guard.dart';

const modelRuntimeResources = {
  'generation': 'FORESIGHT_LITERT_RUNNER',
  'query-detection': 'FORESIGHT_QUERY_RUNTIME',
  'speech': 'FORESIGHT_WHISPER_RUNTIME',
};

/// Registration reads resolve only existing explicit runtime provenance.
class ModelQueries {
  final Database db;
  final int supportedVersion;
  ModelQueries(this.db, {required this.supportedVersion});
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
  String? ownedRuntime(String resource) {
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
    final resource = modelRuntimeResources[kind];
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
      final current = ownedRuntime(resource);
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
}
