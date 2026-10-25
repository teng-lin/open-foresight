import 'sqlite_runtime.dart';
import 'source_queries.dart';
import 'application_schema.dart';
import 'read_schema_guard.dart';

/// Connection and revision identity needed by a snapshot reader. Implementations
/// may borrow the service writer, but expose no mutation or migration methods.
abstract interface class SqliteSnapshotSource {
  Database get db;
  String get path;
  String get dataRevision;
  String preference(String key, [String fallback]);
}

/// An owned read-only connection. Opening it never migrates or runs maintenance.
final class SqliteSnapshotDatabase implements SqliteSnapshotSource {
  @override
  final Database db;
  @override
  final String path;
  SqliteSnapshotDatabase.open(this.path)
    : db = openApplicationDatabase(path, mode: OpenMode.readOnly) {
    try {
      readSnapshot(db, () {}, supportedVersion: applicationSchemaVersion);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }
  @override
  String get dataRevision =>
      '${db.select('SELECT total_changes()').single.values.single}:${db.select('PRAGMA data_version').single.values.single}';
  @override
  String preference(String key, [String fallback = '']) => SourceQueries(
    db,
    supportedVersion: applicationSchemaVersion,
  ).preference(key, fallback);
  void close() => db.dispose();
}
