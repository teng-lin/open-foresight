import 'package:sqlite3/sqlite3.dart';
import '../desktop_read_models.dart';
import '../graph_labels.dart';
import '../label_organization.dart';
import 'label_store.dart';
import 'source_queries.dart';
import 'source_store.dart';

final class LabelOrganizationStore implements LabelOrganizationPersistence {
  final Database db;
  final int supportedVersion;
  LabelOrganizationStore(this.db, {required this.supportedVersion});
  LabelStore get _labels => LabelStore(db, supportedVersion: supportedVersion);
  @override
  T transaction<T>(T Function() work) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = work();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  List<SourceDocument> sources() =>
      SourceQueries(db, supportedVersion: supportedVersion).sources();
  @override
  List<DocumentLabel> get documentLabels => _labels.documentLabels;
  @override
  void put(DocumentLabel label) {
    SourceStore(
      db,
      supportedVersion: supportedVersion,
    ).requireSource(label.documentId);
    _labels.put(label);
  }

  @override
  void saveLabelCluster(String name) => _labels.saveLabelCluster(name);
  @override
  void invalidateGraphOrganization() => _labels.invalidateGraphOrganization();
}
