import 'dart:io';

import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/store.dart' show Store;

/// Persistence receipts belong to this disposable test profile, not the UI's
/// reader capability. The inspector owns only its separate read-only handle.
final class IntegrationPersistenceReceipts {
  final Store _reader;
  IntegrationPersistenceReceipts(String profile)
    : _reader = Store.readOnly('${Directory(profile).path}/application.db');

  List<Map<String, Object?>> get graphDocuments =>
      _reader.rows('SELECT * FROM graph_documents');
  List<Map<String, Object?>> get graphLayouts =>
      _reader.rows('SELECT * FROM graph_layouts');
  List<Map<String, Object?>> get graphForceState =>
      _reader.rows('SELECT * FROM graph_force_state');
  List<Map<String, Object?>> get graphPositions => _reader.rows(
    'SELECT document_id,proj_x,proj_y,proj_z FROM graph_documents',
  );
  List<Map<String, Object?>> get graphEmbeddingReceipts => _reader.rows(
    'SELECT document_id,proj_x,proj_y,proj_z,length(embedding) AS bytes FROM graph_documents',
  );
  List<String> get graphModelIdentities => _reader
      .rows('SELECT model_identity FROM graph_layouts')
      .map((row) => row['model_identity'] as String)
      .toList();
  List<Map<String, Object?>> labels({
    String? name,
    String? document,
    String? excludingDocument,
  }) {
    final predicates = <String>[], arguments = <Object?>[];
    if (name != null) {
      predicates.add('label_name=?');
      arguments.add(name);
    }
    if (document != null) {
      predicates.add('document_id=?');
      arguments.add(document);
    }
    if (excludingDocument != null) {
      predicates.add('document_id<>?');
      arguments.add(excludingDocument);
    }
    return _reader.rows(
      'SELECT * FROM document_labels${predicates.isEmpty ? '' : ' WHERE ${predicates.join(' AND ')}'}',
      arguments,
    );
  }

  List<Map<String, Object?>> clusters([String? label]) => _reader.rows(
    'SELECT * FROM document_clusters${label == null ? '' : ' WHERE label=?'}',
    label == null ? const [] : [label],
  );

  // These whole-table receipts preserve cardinality checks, including orphan
  // rows that scoped UI projections must deliberately hide.
  List<SavedAnswer> get answers => _reader
      .rows('SELECT * FROM answers ORDER BY id DESC')
      .map(SavedAnswer.fromRow)
      .toList();
  List<MeetingArtifact> artifacts({int? meeting, String? kind}) {
    final predicates = <String>[], arguments = <Object?>[];
    if (meeting != null) {
      predicates.add('meeting_id=?');
      arguments.add(meeting);
    }
    if (kind != null) {
      predicates.add('kind=?');
      arguments.add(kind);
    }
    return _reader
        .rows(
          'SELECT * FROM artifacts${predicates.isEmpty ? '' : ' WHERE ${predicates.join(' AND ')}'}',
          arguments,
        )
        .map(MeetingArtifact.fromRow)
        .toList();
  }

  List<MeetingArtifact> artifactById(int id) => _reader
      .rows('SELECT * FROM artifacts WHERE id=?', [id])
      .map(MeetingArtifact.fromRow)
      .toList();
  void close() => _reader.close();
}

/// The service import explicitly requested index:false and has acknowledged
/// this fixture-owned ID. Hold a short writer transaction solely to mark that
/// source failed before the later reconnect; close this writer immediately.
void seedMissingGraphVector(String profile, String source) {
  final writer = Store('${Directory(profile).path}/application.db');
  try {
    writer.db.execute('BEGIN IMMEDIATE');
    writer.state(source, 'failed', 'Missing-vector fixture');
    writer.db.execute('COMMIT');
  } catch (_) {
    if (!writer.db.autocommit) writer.db.execute('ROLLBACK');
    rethrow;
  } finally {
    writer.close();
  }
}
