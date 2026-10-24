import 'package:sqlite3/sqlite3.dart';

import '../read_models.dart';
import 'source_contents.dart';
import '../store.dart';
import 'model_store.dart';
import 'read_schema_guard.dart';

/// Restore must preserve SQL nulls: a missing model type selects the historical
/// digest fallback, and a missing backend selects llama_cpp at the runtime owner.
typedef RestorableModel = ({
  String path,
  String digest,
  String runtime,
  String? backend,
  int? modelType,
});

/// Named storage operations for Domain's serialized source/helper ownership.
/// No queue, asynchronous work or runtime handles move into persistence.
final class DomainQueries {
  DomainQueries(Store store)
    : db = store.db,
      supportedVersion = Store.schemaVersion;
  final Database db;
  final int supportedVersion;

  T _snapshot<T>(T Function() read) =>
      readSnapshot(db, read, supportedVersion: supportedVersion);

  List<String> pendingHelperDeletes() => _snapshot(
    () => [
      for (final row in db.select(
        'SELECT document_id FROM pending_helper_deletes',
      ))
        row['document_id'] as String,
    ],
  );

  bool helperDeletePending(String id) => _snapshot(
    () => db.select(
      'SELECT document_id FROM pending_helper_deletes WHERE document_id=?',
      [id],
    ).isNotEmpty,
  );

  void acknowledgeHelperDelete(String id) => _snapshot(
    () => db.execute('DELETE FROM pending_helper_deletes WHERE document_id=?', [
      id,
    ]),
  );

  String graphSourceContent(Object? id) => _snapshot(
    () =>
        db
                .select('SELECT * FROM sources WHERE id=? AND deleted=0', [id])
                .map(
                  (row) =>
                      materializeSource(db, Map<String, Object?>.from(row)),
                )
                .single['content']
            as String,
  );

  SourceDocument? activeSource(String id) => _snapshot(() {
    final rows = db.select('SELECT * FROM sources WHERE id=? AND deleted=0', [
      id,
    ]);
    return rows.isEmpty
        ? null
        : SourceDocument.fromRow(
            materializeSource(db, Map<String, Object?>.from(rows.first)),
          );
  });

  void sourceState(String id, String state, [String error = '']) => _snapshot(
    () => db.execute('UPDATE sources SET state=?,error=? WHERE id=?', [
      state,
      error,
      id,
    ]),
  );

  void sourceRevisionState(
    String id,
    int revision,
    String state, [
    String error = '',
  ]) => _snapshot(
    () => db.execute(
      'UPDATE sources SET state=?,error=? WHERE id=? AND revision=? AND deleted=0',
      [state, error, id, revision],
    ),
  );

  List<String> unreconciledDeletes() => _snapshot(
    () => [
      for (final row in db.select(
        "SELECT id FROM sources WHERE deleted=1 AND state!='deleted'",
      ))
        row['id'] as String,
    ],
  );

  void retryUnconfiguredSources() => _snapshot(
    () => db.execute(
      "UPDATE sources SET state='pending',error='' WHERE deleted=0 AND state='failed' AND error LIKE 'gRPC Error%Pipeline not initialized%'",
    ),
  );

  List<String> pendingSources() => _snapshot(
    () => [
      for (final row in db.select(
        "SELECT id FROM sources WHERE deleted=0 AND state IN ('indexing','pending') ORDER BY title",
      ))
        row['id'] as String,
    ],
  );

  bool hasModel(String kind) => _snapshot(
    () => db.select('SELECT kind FROM models WHERE kind=?', [kind]).isNotEmpty,
  );

  RestorableModel? generationRegistration() => _snapshot(() {
    final model = ModelStore(
      db,
      supportedVersion: supportedVersion,
    ).model('generation');
    return model == null ? null : _restorable(model);
  });

  // Resume historically reads the stored embedding runtime directly. Generation
  // alone resolves explicitly owned relocatable runtime metadata via ModelStore.
  RestorableModel? embeddingRegistration() => _snapshot(() {
    final rows = db.select("SELECT * FROM models WHERE kind='embedding'");
    return rows.isEmpty ? null : _restorable(rows.first);
  });

  RestorableModel _restorable(Map<String, Object?> row) => (
    path: row['path'] as String,
    digest: row['digest'] as String,
    runtime: row['runtime'] as String,
    backend: row['backend'] as String?,
    modelType: row['model_type'] as int?,
  );

  bool citationCurrent(Object? documentId, Object? revision) => _snapshot(() {
    final rows = db.select('SELECT revision,deleted FROM sources WHERE id=?', [
      documentId,
    ]);
    return rows.isNotEmpty &&
        rows.first['deleted'] == 0 &&
        rows.first['revision'] == revision;
  });
}
