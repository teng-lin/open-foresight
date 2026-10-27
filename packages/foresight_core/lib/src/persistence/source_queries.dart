import 'preference_entities.dart';
import '../platform_services.dart'
    show RuntimeConfiguration, currentOwnerRuntimeSnapshot;
import 'dart:convert';
import 'source_contents.dart';
import 'package:sqlite3/sqlite3.dart';
import '../read_models.dart';
import 'label_queries.dart';
import 'model_queries.dart';
import 'read_schema_guard.dart';

/// Immutable named reads on the caller's connection and short SQLite snapshot.
class SourceQueries {
  final Database db;
  final int supportedVersion;

  /// An explicit or bound owner snapshot, fixed at construction (an editable
  /// boundary passed here is frozen); null outside any owner scope.
  final RuntimeConfiguration? configuration;
  SourceQueries(
    this.db, {
    required this.supportedVersion,
    RuntimeConfiguration? configuration,
  }) : configuration = configuration?.snapshot() ?? currentOwnerRuntimeSnapshot;
  T _read<T>(T Function() read) =>
      readSnapshot(db, read, supportedVersion: supportedVersion);
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => _read(
    () => db
        .select(sql, args)
        .map((row) => Map<String, Object?>.from(row))
        .toList(),
  );
  LabelQueries get _labels =>
      LabelQueries(db, supportedVersion: supportedVersion);
  List<SourceSummary> summaries() => _labels
      .sourceRows(
        'SELECT sources.id,sources.title,sources.mime,sources.provenance,sources.locally_edited,sources.state,sources.error,sources.revision,sources.deleted,source_details.imported,source_details.changed,source_details.source_uri '
        'FROM sources LEFT JOIN source_details ON sources.id=source_details.source_id WHERE deleted=0 ORDER BY title',
      )
      .map(SourceSummary.fromRow)
      .toList();
  List<SourceDocument> sources() => _read(
    () => _labels
        .sourceRows(
          'SELECT sources.*,source_details.imported,source_details.changed,source_details.source_uri '
          'FROM sources LEFT JOIN source_details ON sources.id=source_details.source_id WHERE deleted=0 ORDER BY title',
        )
        .map((row) => SourceDocument.fromRow(materializeSource(db, row)))
        .toList(),
  );
  SourceDocument? source(String id, {bool includeDeleted = false}) => _read(() {
    final row = _rows('SELECT * FROM sources WHERE id=? AND (? OR deleted=0)', [
      id,
      includeDeleted ? 1 : 0,
    ]).firstOrNull;
    return row == null
        ? null
        : SourceDocument.fromRow({
            ...materializeSource(db, row),
            'labels': jsonEncode(_labels.names(id)),
          });
  });

  Set<String> search(String query) {
    final lower = query.toLowerCase();
    return sources()
        .where(
          (source) =>
              '${source.title} ${source.content}'.toLowerCase().contains(lower),
        )
        .map((source) => source.id)
        .toSet();
  }

  List<NoteSummary> noteSummaries() => _rows(
    'SELECT id,title,revision FROM notes ORDER BY id DESC',
  ).map(NoteSummary.fromRow).toList();
  List<ExportNote> notes() => _rows(
    'SELECT * FROM notes ORDER BY id DESC',
  ).map(ExportNote.fromRow).toList();
  String noteBody(int id) =>
      _rows('SELECT body FROM notes WHERE id=?', [id]).single['body'] as String;
  String preference(String key, [String fallback = '']) => _read(
    () =>
        PreferenceEntities(db).read(key) ??
        _rows('SELECT value FROM preferences WHERE key=?', [
              key,
            ]).firstOrNull?['value']
            as String? ??
        fallback,
  );
  Map<String, String> googleSourceMimes() => {
    for (final row in _rows('SELECT source_id,mime FROM google_sources'))
      row['source_id'] as String: row['mime'] as String,
  };
  ModelQueries get _models => ModelQueries(
    db,
    supportedVersion: supportedVersion,
    configuration: configuration,
  );
  ModelRegistration? model(String kind) => _read(() {
    final row = _models.model(kind);
    return row == null ? null : ModelRegistration.fromRow(row);
  });
  List<ModelRegistration> models() =>
      _read(() => _models.models.map(ModelRegistration.fromRow).toList());
  List<ModelRegistration> registeredEmbedding() => _rows(
    "SELECT * FROM models WHERE kind='embedding'",
  ).map(ModelRegistration.fromRow).toList();
  String? registeredSpeechDigest() =>
      _rows(
            "SELECT digest FROM models WHERE kind='speech'",
          ).firstOrNull?['digest']
          as String?;
  List<DocumentCluster> clusters() => _rows(
    'SELECT * FROM document_clusters',
  ).map(DocumentCluster.fromRow).toList();
  List<String> clusterNames() => _rows(
    'SELECT label FROM document_clusters',
  ).map((row) => row['label'] as String).toList();
  List<String> completedAnswerBodies() => _rows(
    "SELECT body FROM answers WHERE status='completed'",
  ).map((row) => row['body'] as String).toList();
  List<String> artifactBodies() => _rows(
    'SELECT generated FROM artifacts',
  ).map((row) => row['generated'] as String).toList();
}
