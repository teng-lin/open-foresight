import '../desktop_read_models.dart';
import '../store.dart';
import 'read_schema_guard.dart';

final class WorkspaceOperationsQueries {
  final Store store;
  WorkspaceOperationsQueries(this.store);
  List<ExportNote> notes() => readSnapshot(
    store.db,
    () => store.db
        .select('SELECT * FROM notes ORDER BY id')
        .map((row) => ExportNote.fromRow(Map<String, Object?>.from(row)))
        .toList(),
    supportedVersion: Store.schemaVersion,
  );
}
