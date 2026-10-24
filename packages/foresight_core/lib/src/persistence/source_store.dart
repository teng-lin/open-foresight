import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../rpc_error.dart';
import 'read_schema_guard.dart';

class SourceStore {
  final Database db;
  final int supportedVersion;
  SourceStore(this.db, {required this.supportedVersion});
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
  static String _legacySourceUri(String provenance) {
    while (provenance.startsWith('user edit; ')) {
      provenance = provenance.substring('user edit; '.length);
    }
    if (provenance.startsWith('url:')) return provenance.substring(4);
    final marker = provenance.indexOf('; /');
    if (marker >= 0) {
      return Uri.file(provenance.substring(marker + 2)).toString();
    }
    return '';
  }

  String importText(
    String title,
    String text,
    String mime,
    String provenance, {
    String? id,
    // Null uses the local creation/edit time; zero means unknown external metadata.
    int? modifiedAtMs,
    String? sourceUri,
    bool locallyEdited = false,
    bool generated = false,
  }) {
    while (provenance.startsWith('user edit; ')) {
      locallyEdited = true;
      provenance = provenance.substring('user edit; '.length);
    }
    id ??= sha256
        .convert(utf8.encode('$title:${DateTime.now().microsecondsSinceEpoch}'))
        .toString();
    db.execute('SAVEPOINT import_source');
    try {
      db.execute(
        'INSERT INTO sources(id,title,content,mime,revision,state,provenance,locally_edited,generated) VALUES(?,?,?,?,1,\'pending\',?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,mime=excluded.mime,revision=sources.revision+1,state=\'pending\',error=\'\',deleted=0,provenance=excluded.provenance,locally_edited=excluded.locally_edited,generated=CASE WHEN excluded.locally_edited=1 THEN 0 ELSE MAX(sources.generated,excluded.generated) END',
        [
          id,
          title,
          text,
          mime,
          provenance,
          locallyEdited ? 1 : 0,
          generated && !locallyEdited ? 1 : 0,
        ],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        'INSERT INTO source_details(source_id,imported,changed,source_uri) VALUES(?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET changed=excluded.changed,source_uri=COALESCE(?,source_details.source_uri)',
        [
          id,
          now,
          modifiedAtMs ?? now,
          sourceUri ?? _legacySourceUri(provenance),
          sourceUri,
        ],
      );
      db.execute('RELEASE import_source');
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO import_source');
        db.execute('RELEASE import_source');
      }
      rethrow;
    }
    return id;
  }

  void state(String id, String state, [String error = '']) => db.execute(
    'UPDATE sources SET state=?,error=? WHERE id=?',
    [state, error, id],
  );
  void tombstone(String id) {
    db.execute(
      'UPDATE sources SET deleted=1,state=\'deleting\',revision=revision+1 WHERE id=?',
      [id],
    );
    // No idempotency digest of the deleted text outlives the delete. (The
    // tombstoned row itself keeps its content, as it always has.)
    db.execute('DELETE FROM request_keys WHERE operation=? AND result=?', [
      'sources.import',
      jsonEncode({'id': id}),
    ]);
  }

  void requireSource(String id, {bool forImport = false}) {
    final row = _rows(
      'SELECT deleted,source_id FROM sources LEFT JOIN source_details ON source_id=id WHERE id=?',
      [id],
    ).firstOrNull;
    if (row != null && row['deleted'] == 0 && row['source_id'] != null) return;
    throw RpcError(
      RpcErrorCode.notFound,
      row != null && row['deleted'] != 0
          ? 'This source no longer exists.'
          : forImport
          ? 'No source has this ID; omit id to create one.'
          : 'No source has this ID.',
    );
  }
}
