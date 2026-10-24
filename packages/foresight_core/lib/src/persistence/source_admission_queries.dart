import '../read_models.dart';
import 'source_contents.dart';
import '../store.dart';
import 'read_schema_guard.dart';

typedef IndexedSourceIdentity = ({
  String title,
  int revision,
  String provenance,
});

/// Source admission and post-await revision checks use the domain's existing
/// writer connection. This facade owns no database or asynchronous lifetime.
final class SourceAdmissionQueries {
  SourceAdmissionQueries(this.store);
  final Store store;
  List<Map<String, Object?>> _rows(String sql, List<Object?> args) =>
      readSnapshot(
        store.db,
        () => store.rows(sql, args),
        supportedVersion: Store.schemaVersion,
      );

  List<SourceDocument> get documents => store.sourceQueries.sources();
  List<SourceSummary> get summaries => store.sourceQueries.summaries();

  /// Resolve import identity without materializing unrelated document bodies.
  String? importIdForUri(String uri, {bool urlOnly = false}) =>
      _rows(
            'SELECT sources.id FROM source_details '
            'JOIN sources ON sources.id=source_details.source_id '
            'WHERE source_details.source_uri=? AND sources.deleted=0 '
            "AND (?=0 OR substr(sources.provenance,1,4)='url:' "
            "OR instr(sources.provenance,'; url:')>0) "
            'ORDER BY sources.title,sources.id LIMIT 1',
            [uri, urlOnly ? 1 : 0],
          ).firstOrNull?['id']
          as String?;

  SourceDocument? active(String id) => readSnapshot(store.db, () {
    final row = _rows('SELECT * FROM sources WHERE id=? AND deleted=0', [
      id,
    ]).firstOrNull;
    return row == null
        ? null
        : SourceDocument.fromRow(materializeSource(store.db, row));
  }, supportedVersion: Store.schemaVersion);

  bool isCurrent(String id, int revision) => _rows(
    'SELECT id FROM sources WHERE id=? AND revision=? AND deleted=0',
    [id, revision],
  ).isNotEmpty;

  IndexedSourceIdentity? indexedAtRevision(String id, int revision) {
    final row = _rows(
      "SELECT title,revision,provenance FROM sources WHERE id=? AND revision=? AND deleted=0 AND state='indexed'",
      [id, revision],
    ).firstOrNull;
    return row == null
        ? null
        : (
            title: row['title'] as String,
            revision: row['revision'] as int,
            provenance: row['provenance'] as String,
          );
  }

  ({String? error})? indexingFailure(String id) {
    final row = _rows(
      "SELECT error FROM sources WHERE id=? AND deleted=0 AND state='failed'",
      [id],
    ).firstOrNull;
    return row == null ? null : (error: row['error'] as String?);
  }
}
