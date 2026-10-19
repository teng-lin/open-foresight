import 'rpc_error.dart';
import 'model_integrity.dart';
import 'model_asset_lifecycle.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'agent_access.dart';
import 'dart:io';
import 'graph_labels.dart';
import 'label_propagation.dart';
import 'graph_layout.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

void requireEmbeddingBundle(String path) {
  if (!path.endsWith('.litertlm') || Directory(path).existsSync()) {
    throw StateError(
      'Unsupported model format: embedding requires a .litertlm file',
    );
  }
}

/// Linux application schema, independently versioned from helper databases.
class Store {
  final Database db;
  final String path;
  static const schemaVersion = 11;
  static const _privacyMaintenanceKey = 'internal.privacyMaintenancePending';
  Timer? _privacyMaintenanceRetry;
  var _privacyRetrySeconds = 1;
  var _privacyMaintenancePending = false;
  var _closed = false;

  /// Local deletion is committed even while a reader prevents WAL erasure.
  bool get privacyMaintenancePending => _privacyMaintenancePending;

  Store.readOnly(this.path) : db = sqlite3.open(path, mode: OpenMode.readOnly) {
    try {
      _checkVersion();
      _privacyMaintenancePending =
          rows(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='preferences'",
          ).isNotEmpty &&
          _hasPrivacyMaintenanceMarker();
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  Store(this.path) : db = _openForMigrations(path) {
    try {
      // Refuse newer profiles before even changing their journal mode.
      _checkVersion();
      // Migrations populate the WAL before readers open the fresh profile.
      // Switching only after COMMIT leaves no WAL for macOS read-only clients.
      db.execute('PRAGMA secure_delete=ON');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('BEGIN IMMEDIATE');
      try {
        // Re-read while holding the writer lock: another opener may have migrated.
        var version = _checkVersion();
        while (version < schemaVersion) {
          _migrateTo(++version);
          db.execute('PRAGMA user_version=$version');
        }
        db.execute('COMMIT');
      } catch (_) {
        // SQLITE_FULL/IOERR can already roll back the transaction.
        if (!db.autocommit) db.execute('ROLLBACK');
        rethrow;
      }
    } catch (_) {
      db.dispose();
      rethrow;
    }
    _privacyMaintenancePending = _hasPrivacyMaintenanceMarker();
    if (_privacyMaintenancePending) _schedulePrivacyMaintenance();
  }

  bool _hasPrivacyMaintenanceMarker() => rows(
    'SELECT 1 FROM preferences WHERE key=?',
    [_privacyMaintenanceKey],
  ).isNotEmpty;

  /// Persist the cleanup intent in the same transaction as the content deletion.
  /// Scheduling starts only after that transaction commits, via compactAfterClear.
  void markPrivacyMaintenancePending() {
    db.execute('INSERT OR IGNORE INTO preferences(key,value) VALUES(?,?)', [
      _privacyMaintenanceKey,
      '1',
    ]);
  }

  /// Erase freed pages after a committed workspace clear. Live readers can keep
  /// a checkpoint busy, so maintenance failure must not undo the local clear.
  void compactAfterClear() {
    _privacyMaintenancePending = true;
    _privacyRetrySeconds = 1;
    _retryPrivacyMaintenance();
  }

  void _schedulePrivacyMaintenance() {
    if (_closed || _privacyMaintenanceRetry != null) return;
    _privacyMaintenanceRetry = Timer(
      Duration(seconds: _privacyRetrySeconds),
      () {
        _privacyMaintenanceRetry = null;
        _retryPrivacyMaintenance();
      },
    );
    _privacyRetrySeconds = (_privacyRetrySeconds * 2).clamp(1, 30);
  }

  void _retryPrivacyMaintenance() {
    if (_closed || !_privacyMaintenancePending) return;
    try {
      // Only a constant marker is retained, never any cleared content. Persist
      // it before checkpointing so a shutdown/restart cannot lose the retry.
      markPrivacyMaintenancePending();
      for (final statement in [
        'PRAGMA wal_checkpoint(TRUNCATE)',
        'VACUUM',
        'PRAGMA wal_checkpoint(TRUNCATE)',
      ]) {
        final result = db.select(statement);
        if (statement.startsWith('PRAGMA wal_checkpoint') &&
            result.isNotEmpty &&
            result.first.values.first != 0) {
          _schedulePrivacyMaintenance();
          return;
        }
      }
      db.execute('DELETE FROM preferences WHERE key=?', [
        _privacyMaintenanceKey,
      ]);
      _privacyMaintenancePending = false;
      _privacyMaintenanceRetry?.cancel();
      _privacyMaintenanceRetry = null;
      _privacyRetrySeconds = 1;
    } catch (error) {
      // This runs after the clear committed: maintenance must not turn an
      // erased workspace into a failed transaction or discard its retry.
      stderr.writeln('Workspace privacy maintenance deferred: $error');
      _schedulePrivacyMaintenance();
    }
  }

  // Even opening and closing a writable connection can checkpoint a WAL.
  // Refuse future profiles through a separate read-only connection first.
  static Database _openForMigrations(String path) {
    if (path != ':memory:' && File(path).existsSync()) {
      final canonical = File(path).resolveSymbolicLinksSync();
      final hasWal = File('$canonical-wal').existsSync();
      // A closed WAL profile may have no sidecars. The short immutable probe
      // reads its main file without asking macOS SQLite to create a WAL.
      // An existing WAL must instead be read normally: it can hold a newer
      // user_version than the main file. Never make a live reader immutable.
      final probePath = hasWal
          ? canonical
          : Uri.file(
              canonical,
            ).replace(queryParameters: {'immutable': '1'}).toString();
      final probe = sqlite3.open(
        probePath,
        mode: OpenMode.readOnly,
        uri: !hasWal,
      );
      try {
        _supportedVersion(probe);
      } finally {
        probe.dispose();
      }
    }
    return sqlite3.open(path);
  }

  int _checkVersion() => _supportedVersion(db);

  static int _supportedVersion(Database database) {
    final version =
        database.select('PRAGMA user_version').single.values.single as int;
    if (version > schemaVersion) {
      throw StateError(
        'Unsupported newer application database version $version '
        '(maximum $schemaVersion)',
      );
    }
    return version;
  }

  void _migrateTo(int version) {
    switch (version) {
      case 1:
      case 2:
        // Historical version-1 releases added tables without bumping the version.
        // Adopt that baseline once before applying individually versioned changes.
        _createLegacyTables();
      case 3:
        _migrateNoteHistory();
      case 4:
        _migrateModelMetadata();
      case 5:
        _migrateSourceUris();
      case 6:
        _migrateAnswerHistory();
      case 7:
        _migrateMeetingQuestions();
      case 8:
        _migrateGoogleTables();
      case 9:
        _reconcileLabelRecords();
      case 10:
        db.execute(
          'CREATE TABLE IF NOT EXISTS pending_helper_deletes(document_id TEXT PRIMARY KEY, queued_at INTEGER NOT NULL)',
        );
      case 11:
        if (!rows(
          'PRAGMA table_info(sources)',
        ).any((row) => row['name'] == 'locally_edited')) {
          db.execute(
            'ALTER TABLE sources ADD COLUMN locally_edited INTEGER NOT NULL DEFAULT 0',
          );
        }
        for (final row in rows('SELECT id,provenance FROM sources')) {
          var provenance = row['provenance'] as String;
          if (!provenance.startsWith('user edit; ')) continue;
          while (provenance.startsWith('user edit; ')) {
            provenance = provenance.substring('user edit; '.length);
          }
          db.execute(
            'UPDATE sources SET locally_edited=1,provenance=? WHERE id=?',
            [provenance, row['id']],
          );
        }
      default:
        throw StateError('Missing application database migration $version');
    }
  }

  void _createLegacyTables() {
    db.execute(
      '''CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,title TEXT NOT NULL,content TEXT NOT NULL,mime TEXT NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',deleted INTEGER NOT NULL DEFAULT 0,provenance TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1,timestamp INTEGER);
    CREATE TABLE IF NOT EXISTS answers(id INTEGER PRIMARY KEY,question TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL,citations TEXT NOT NULL,model TEXT NOT NULL,created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS models(kind TEXT PRIMARY KEY,path TEXT NOT NULL,digest TEXT NOT NULL,runtime TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meetings(id INTEGER PRIMARY KEY,title TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS transcript(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),text TEXT NOT NULL,final INTEGER NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,source TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS artifacts(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),kind TEXT NOT NULL,generated TEXT NOT NULL,edited TEXT,input_revision INTEGER NOT NULL,model TEXT NOT NULL,prompt_version TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS conversation_memory(conversation TEXT PRIMARY KEY,through_answer_id INTEGER NOT NULL,messages TEXT NOT NULL,token_counts TEXT);
    CREATE TABLE IF NOT EXISTS source_details(source_id TEXT PRIMARY KEY REFERENCES sources(id),imported INTEGER NOT NULL,changed INTEGER NOT NULL,labels TEXT NOT NULL DEFAULT '[]');
    CREATE TABLE IF NOT EXISTS document_labels(document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,label_name TEXT NOT NULL,label_source TEXT NOT NULL,color_hex TEXT,rationale TEXT,PRIMARY KEY(document_id,label_name));
    CREATE TABLE IF NOT EXISTS document_clusters(cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,label TEXT UNIQUE NOT NULL,summary TEXT,centroid_embedding BLOB,center_proj_x REAL NOT NULL DEFAULT 0,center_proj_y REAL NOT NULL DEFAULT 0,radius REAL NOT NULL DEFAULT 100);
    CREATE TABLE IF NOT EXISTS graph_documents(model_identity TEXT NOT NULL,document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,source_revision INTEGER NOT NULL,embedding BLOB NOT NULL,proj_x REAL NOT NULL,proj_y REAL NOT NULL,proj_z REAL NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(model_identity,document_id));
    CREATE TABLE IF NOT EXISTS graph_layouts(model_identity TEXT PRIMARY KEY,document_set TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS graph_force_state(model_identity TEXT PRIMARY KEY REFERENCES graph_layouts(model_identity) ON DELETE CASCADE,label_set TEXT NOT NULL);
    INSERT OR IGNORE INTO source_details(source_id,imported,changed) SELECT id,0,0 FROM sources;
    CREATE TABLE IF NOT EXISTS meeting_details(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id),created INTEGER NOT NULL,reminder INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS meeting_notes(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,body TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 0,timestamp INTEGER);
    CREATE TABLE IF NOT EXISTS meeting_note_events(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meeting_notes(meeting_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,event_key TEXT NOT NULL,title TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_answers(meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,answer_id INTEGER NOT NULL REFERENCES answers(id) ON DELETE CASCADE,PRIMARY KEY(meeting_id,answer_id));
    CREATE TABLE IF NOT EXISTS meeting_question_cursors(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,transcript_id INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_questions(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,transcript_id INTEGER REFERENCES transcript(id) ON DELETE CASCADE,question TEXT NOT NULL,normalized TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'queued',answer_id INTEGER REFERENCES answers(id) ON DELETE SET NULL,error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL);
    INSERT OR IGNORE INTO meeting_details(meeting_id,created) SELECT id,0 FROM meetings;
    ''',
    );
  }

  void _migrateNoteHistory() {
    // Legacy profiles did not record when a note was saved. Preserve unknown
    // timestamps instead of manufacturing them from meeting creation times.
    for (final table in ['notes', 'meeting_notes']) {
      if (!db
          .select('PRAGMA table_info($table)')
          .any((row) => row['name'] == 'timestamp')) {
        db.execute('ALTER TABLE $table ADD COLUMN timestamp INTEGER');
      }
    }
    for (final column in ['last_enhanced', 'last_manual_edit']) {
      if (!db
          .select('PRAGMA table_info(meeting_notes)')
          .any((row) => row['name'] == column)) {
        db.execute('ALTER TABLE meeting_notes ADD COLUMN $column INTEGER');
      }
    }
    if (!db
        .select('PRAGMA table_info(meeting_notes)')
        .any((row) => row['name'] == 'enhanced_body')) {
      db.execute('ALTER TABLE meeting_notes ADD COLUMN enhanced_body TEXT');
    }
  }

  void _migrateModelMetadata() {
    if (!db
        .select('PRAGMA table_info(models)')
        .any((row) => row['name'] == 'backend')) {
      db.execute(
        "ALTER TABLE models ADD COLUMN backend TEXT NOT NULL DEFAULT 'llama_cpp'",
      );
    }
    if (!db
        .select('PRAGMA table_info(models)')
        .any((row) => row['name'] == 'model_type')) {
      db.execute(
        'ALTER TABLE models ADD COLUMN model_type INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  void _migrateSourceUris() {
    if (!db
        .select('PRAGMA table_info(source_details)')
        .any((row) => row['name'] == 'source_uri')) {
      db.execute(
        "ALTER TABLE source_details ADD COLUMN source_uri TEXT NOT NULL DEFAULT ''",
      );
      for (final row in rows('SELECT id,provenance FROM sources')) {
        final uri = _legacySourceUri(row['provenance'] as String);
        if (uri.isNotEmpty) {
          db.execute(
            'UPDATE source_details SET source_uri=? WHERE source_id=?',
            [uri, row['id']],
          );
        }
      }
    }
  }

  void _migrateAnswerHistory() {
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'conversation')) {
      db.execute(
        "ALTER TABLE answers ADD COLUMN conversation TEXT NOT NULL DEFAULT 'desktop'",
      );
    }
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'request_id')) {
      db.execute('ALTER TABLE answers ADD COLUMN request_id TEXT');
    }
    if (!db
        .select('PRAGMA table_info(answers)')
        .any((r) => r['name'] == 'model_response')) {
      db.execute('ALTER TABLE answers ADD COLUMN model_response TEXT');
    }
    if (!db
        .select('PRAGMA table_info(conversation_memory)')
        .any((r) => r['name'] == 'token_counts')) {
      db.execute(
        'ALTER TABLE conversation_memory ADD COLUMN token_counts TEXT',
      );
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS answer_request_id ON answers(request_id)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS answer_conversation_id ON answers(conversation,id)',
    );
  }

  void _migrateGoogleTables() {
    db.execute(
      '''CREATE TABLE IF NOT EXISTS google_sources(source_id TEXT PRIMARY KEY REFERENCES sources(id),account TEXT NOT NULL,file_id TEXT NOT NULL,modified TEXT NOT NULL,mime TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS calendar_events(event_key TEXT PRIMARY KEY,account TEXT NOT NULL,calendar_id TEXT NOT NULL,google_id TEXT NOT NULL,meeting_id INTEGER NOT NULL REFERENCES meetings(id),source_id TEXT NOT NULL,starts INTEGER NOT NULL,ends INTEGER NOT NULL,status TEXT NOT NULL,metadata TEXT NOT NULL,synced INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS google_folders(account TEXT NOT NULL,folder_id TEXT NOT NULL,PRIMARY KEY(account,folder_id));''',
    );
  }

  // Keep durable history while allowing interim origins and repeated questions
  // after rolling filter expiry. Rebuild legacy schemas without changing IDs.
  void _migrateMeetingQuestions() {
    final requiredOrigin = db
        .select('PRAGMA table_info(meeting_questions)')
        .any((row) => row['name'] == 'transcript_id' && row['notnull'] == 1);
    final lifetimeUnique = db
        .select('PRAGMA index_list(meeting_questions)')
        .any(
          (row) =>
              row['unique'] == 1 &&
              db
                      .select(
                        'SELECT name FROM pragma_index_info(?) ORDER BY seqno',
                        [row['name']],
                      )
                      .map((column) => column['name'])
                      .join(',') ==
                  'meeting_id,normalized',
        );
    if (!requiredOrigin && !lifetimeUnique) return;
    db.execute("""
        CREATE TABLE meeting_questions_interim(
          id INTEGER PRIMARY KEY,
          meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          transcript_id INTEGER REFERENCES transcript(id) ON DELETE CASCADE,
          question TEXT NOT NULL,normalized TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'queued',
          answer_id INTEGER REFERENCES answers(id) ON DELETE SET NULL,
          error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL);
        INSERT INTO meeting_questions_interim
          SELECT id,meeting_id,transcript_id,question,normalized,state,answer_id,error,created
          FROM meeting_questions;
        DROP TABLE meeting_questions;
        ALTER TABLE meeting_questions_interim RENAME TO meeting_questions;
      """);
  }

  // Version 9 imports legacy labels once. Repair malformed JSON from structured
  // records without discarding their names or metadata. The migration owns the transaction.
  void _reconcileLabelRecords() {
    for (final row in rows('SELECT source_id,labels FROM source_details')) {
      final id = row['source_id'] as String;
      List<String> names;
      try {
        names = (jsonDecode(row['labels'] as String) as List)
            .cast<String>()
            .toList();
      } on FormatException {
        names = _storedLabelNames(id);
      } on TypeError {
        names = _storedLabelNames(id);
      }
      _writeLabelRecords(id, names);
      db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(names),
        id,
      ]);
    }
  }

  List<String> _storedLabelNames(String id) => rows(
    'SELECT label_name FROM document_labels WHERE document_id=?',
    [id],
  ).map((row) => row['label_name'] as String).toList();

  List<DocumentLabel> get documentLabels => rows(
    'SELECT l.* FROM document_labels l JOIN sources s ON s.id=l.document_id WHERE s.deleted=0',
  ).map(DocumentLabel.fromRow).toList();

  void _writeLabelRecords(String id, List<String> names) {
    for (final row in rows(
      'SELECT label_name FROM document_labels WHERE document_id=?',
      [id],
    )) {
      if (!names.contains(row['label_name'])) {
        db.execute(
          'DELETE FROM document_labels WHERE document_id=? AND label_name=?',
          [id, row['label_name']],
        );
      }
    }
    if (names.isEmpty) return;
    final records = documentLabels;
    for (final name in names.toSet()) {
      if (rows(
        'SELECT 1 FROM document_labels WHERE document_id=? AND label_name=?',
        [id, name],
      ).isNotEmpty) {
        continue;
      }
      final color = allocateGraphLabelColor(name, records);
      db.execute(
        'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale) VALUES(?,?,?,?,NULL)',
        [id, name, 'user_defined', color],
      );
      records.add(DocumentLabel(id, name, 'user_defined', color));
    }
  }

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

  List<Map<String, Object?>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();
  List<Map<String, Object?>> get sources => rows(
    'SELECT sources.*,source_details.imported,source_details.changed,source_details.labels,source_details.source_uri FROM sources LEFT JOIN source_details ON sources.id=source_details.source_id WHERE deleted=0 ORDER BY title',
  );
  // Browsing needs metadata, not every document body. Load content only for
  // search, graph embeddings, or the selected source detail.
  int _transactionReads = 0;
  String get dataRevision {
    // Never reuse an uncommitted snapshot after rollback or across transactions.
    if (!db.autocommit) return 'transaction:${++_transactionReads}';
    return '${db.select('SELECT total_changes()').single.values.single}:${db.select('PRAGMA data_version').single.values.single}';
  }

  String? _summaryRevision;
  List<Map<String, Object?>> _sourceSummaries = [];
  List<Map<String, Object?>> get sourceSummaries {
    final revision = dataRevision;
    if (_summaryRevision != revision) {
      _sourceSummaries = rows(
        'SELECT sources.id,sources.title,sources.mime,sources.provenance,sources.locally_edited,sources.state,sources.error,sources.revision,sources.deleted,source_details.imported,source_details.changed,source_details.labels,source_details.source_uri FROM sources LEFT JOIN source_details ON sources.id=source_details.source_id WHERE deleted=0 ORDER BY title',
      );
      _summaryRevision = revision;
    }
    return _sourceSummaries;
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
  }) {
    while (provenance.startsWith('user edit; ')) {
      locallyEdited = true;
      provenance = provenance.substring('user edit; '.length);
    }
    id ??= sha256
        .convert(utf8.encode('$title:${DateTime.now().microsecondsSinceEpoch}'))
        .toString();
    db.execute(
      'INSERT INTO sources(id,title,content,mime,revision,state,provenance,locally_edited) VALUES(?,?,?,?,1,\'pending\',?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,mime=excluded.mime,revision=sources.revision+1,state=\'pending\',error=\'\',deleted=0,provenance=excluded.provenance,locally_edited=excluded.locally_edited',
      [id, title, text, mime, provenance, locallyEdited ? 1 : 0],
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
    return id;
  }

  void state(String id, String state, [String error = '']) => db.execute(
    'UPDATE sources SET state=?,error=? WHERE id=?',
    [state, error, id],
  );
  void tombstone(String id) => db.execute(
    'UPDATE sources SET deleted=1,state=\'deleting\',revision=revision+1 WHERE id=?',
    [id],
  );
  void answer(
    String question,
    String body,
    String status,
    List<Map<String, Object?>> citations,
    String model, {
    String conversation = 'desktop',
    String? requestId,
    Map<String, dynamic>? modelResponse,
  }) => db.execute(
    'INSERT INTO answers(question,body,status,citations,model,created,conversation,request_id,model_response) VALUES(?,?,?,?,?,?,?,?,?)',
    [
      question,
      body,
      status,
      jsonEncode(citations),
      model,
      DateTime.now().millisecondsSinceEpoch,
      conversation,
      requestId,
      modelResponse == null ? null : jsonEncode(modelResponse),
    ],
  );
  void saveNote(int? id, String title, String body) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    if (id == null) {
      db.execute('INSERT INTO notes(title,body,timestamp) VALUES(?,?,?)', [
        title,
        body,
        timestamp,
      ]);
    } else {
      db.execute(
        'UPDATE notes SET title=?,body=?,revision=revision+1,timestamp=? WHERE id=?',
        [title, body, timestamp, id],
      );
    }
  }

  static const _runtimeResources = {
    'generation': 'FORESIGHT_LITERT_RUNNER',
    'query-detection': 'FORESIGHT_QUERY_RUNTIME',
    'speech': 'FORESIGHT_WHISPER_RUNTIME',
  };

  String? _ownedRuntime(String resource) {
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
  Map<String, Object?> resolveModelRuntime(Map<String, Object?> model) {
    final kind = model['kind'];
    final resource = _runtimeResources[kind];
    if (resource == null) return model;
    try {
      final record = jsonDecode(preference('modelRuntimeResource.$kind'));
      if (record is! Map ||
          (record['resource'] != resource &&
              !(kind == 'query-detection' &&
                  record['resource'] == 'FORESIGHT_LITERT_PYTHON')) ||
          record['runtime'] != model['runtime'] ||
          record['digest'] != model['digest'] ||
          record['backend'] != model['backend']) {
        return model;
      }
      final current = _ownedRuntime(resource);
      if (current == null) return model;
      return {...model, 'runtime': current};
    } on FormatException {
      return model;
    }
  }

  Map<String, Object?>? model(String kind) {
    final registration = rows('SELECT * FROM models WHERE kind=?', [
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

  List<Map<String, Object?>> get models =>
      rows('SELECT * FROM models').map(resolveModelRuntime).toList();

  /// Re-read stored bytes before any model worker is created. Startup rejects
  /// invalid registrations while preserving their files so setup can repair them.
  Future<List<String>> verifyRegisteredModels({
    bool rejectInvalidRegistrations = false,
  }) async {
    final rejected = <Map<String, Object?>>[];
    for (final model in rows('SELECT kind,path,digest FROM models')) {
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
        setPreference(
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
    String? resource = _runtimeResources[kind];
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
        setPreference(
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

  int meeting(String title) {
    db.execute('INSERT INTO meetings(title,state) VALUES(?,\'idle\')', [title]);
    final id = db.lastInsertRowId;
    db.execute('INSERT INTO meeting_details(meeting_id,created) VALUES(?,?)', [
      id,
      DateTime.now().millisecondsSinceEpoch,
    ]);
    return id;
  }

  void saveMeetingNotes(int meetingId, String body, {int? lastManualEdit}) {
    final previous = rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
      meetingId,
    ]).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    final manual =
        lastManualEdit ?? (body != (previous?['body'] ?? '') ? now : null);
    db.execute('SAVEPOINT save_meeting_notes');
    try {
      if (previous == null) _snapshotMeetingEvents(meetingId);
      db.execute(
        'INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,last_manual_edit) VALUES(?,?,1,?,?) '
        'ON CONFLICT(meeting_id) DO UPDATE SET body=excluded.body,revision=meeting_notes.revision+1,timestamp=excluded.timestamp,'
        'last_manual_edit=COALESCE(excluded.last_manual_edit,meeting_notes.last_manual_edit)',
        [meetingId, body, now, manual],
      );
      db.execute('RELEASE save_meeting_notes');
    } catch (_) {
      db.execute('ROLLBACK TO save_meeting_notes');
      db.execute('RELEASE save_meeting_notes');
      rethrow;
    }
  }

  // Original event/document associations capture a name when the note is
  // inserted. Later calendar refreshes do not supply that historical name.
  void _snapshotMeetingEvents(int meeting) {
    if (rows(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_events'",
    ).isEmpty) {
      return;
    }
    for (final event in rows(
      'SELECT event_key,metadata FROM calendar_events WHERE meeting_id=? ORDER BY rowid',
      [meeting],
    )) {
      final key = event['event_key'] as String;
      if (key.isEmpty) continue;
      var title = '';
      try {
        final metadata = jsonDecode(event['metadata'] as String);
        if (metadata is Map && metadata['summary'] is String) {
          title = metadata['summary'] as String;
        }
      } on FormatException {
        // Malformed legacy metadata cannot establish a captured event name.
      }
      db.execute(
        'INSERT INTO meeting_note_events(meeting_id,event_key,title) VALUES(?,?,?)',
        [meeting, key, title],
      );
    }
  }

  void transcript(
    int meeting,
    String text,
    bool finalText,
    int start,
    int end,
    String source,
  ) {
    db.execute(
      'INSERT INTO transcript(meeting_id,text,final,start_ms,end_ms,source) VALUES(?,?,?,?,?,?)',
      [meeting, text, finalText ? 1 : 0, start, end, source],
    );
    if (finalText) {
      db.execute('UPDATE meetings SET revision=revision+1 WHERE id=?', [
        meeting,
      ]);
    }
  }

  void artifact(
    int meeting,
    String kind,
    String generated,
    String model, {
    int? inputRevision,
  }) {
    final revision =
        inputRevision ??
        rows('SELECT revision FROM meetings WHERE id=?', [
          meeting,
        ]).first['revision'];
    void insert() => db.execute(
      'INSERT INTO artifacts(meeting_id,kind,generated,input_revision,model,prompt_version) VALUES(?,?,?,?,?,?)',
      [meeting, kind, generated, revision, model, 'meeting-v1'],
    );
    if (kind == 'enhanced_notes') {
      _writeEnhancedNote(meeting, insert, body: generated);
    } else {
      insert();
    }
  }

  void editArtifact(int id, String text, {int? lastManualEdit}) {
    final enhanced = rows(
      "SELECT selected.meeting_id,COALESCE((SELECT enhanced_body FROM meeting_notes WHERE meeting_id=selected.meeting_id),selected.edited,selected.generated) AS body FROM artifacts AS selected WHERE selected.id=? AND selected.kind='enhanced_notes' "
      'AND NOT EXISTS (SELECT 1 FROM artifacts AS newer WHERE newer.meeting_id=selected.meeting_id '
      'AND newer.kind=selected.kind AND newer.id>selected.id)',
      [id],
    ).firstOrNull;
    void update() =>
        db.execute('UPDATE artifacts SET edited=? WHERE id=?', [text, id]);
    if (enhanced == null) {
      update();
    } else {
      _writeEnhancedNote(
        enhanced['meeting_id'] as int,
        update,
        body: text,
        manual: true,
        editTimestamp: lastManualEdit,
        changed: enhanced['body'] != text,
      );
    }
  }

  String meetingEnhancedNotes(int meeting) =>
      rows(
            "SELECT COALESCE((SELECT enhanced_body FROM meeting_notes WHERE meeting_id=?),(SELECT COALESCE(edited,generated) FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1),'') AS body",
            [meeting, meeting],
          ).first['body']
          as String;

  void restoreMeetingEnhancedDraft(int meeting, String body) {
    db.execute('UPDATE meeting_notes SET enhanced_body=? WHERE meeting_id=?', [
      body,
      meeting,
    ]);
  }

  void saveMeetingEnhancedDraft(int meeting, String body) =>
      _writeEnhancedNote(meeting, () {}, body: body, completed: false);

  // The original saves the current raw/enhanced fields and save timestamp as
  // one Note replacement. Historical artifacts do not replace that current Note.
  void _writeEnhancedNote(
    int meeting,
    void Function() write, {
    required String body,
    bool manual = false,
    bool completed = true,
    int? editTimestamp,
    bool changed = true,
  }) {
    db.execute('SAVEPOINT save_enhanced_note');
    try {
      if (rows('SELECT meeting_id FROM meeting_notes WHERE meeting_id=?', [
        meeting,
      ]).isEmpty) {
        _snapshotMeetingEvents(meeting);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final column = manual ? 'last_manual_edit' : 'last_enhanced';
      final date = manual
          ? editTimestamp ?? (changed ? now : null)
          : completed
          ? now
          : null;
      db.execute(
        "INSERT INTO meeting_notes(meeting_id,body,revision,timestamp,$column,enhanced_body) VALUES(?,'',0,?,?,?) "
        'ON CONFLICT(meeting_id) DO UPDATE SET timestamp=excluded.timestamp,enhanced_body=excluded.enhanced_body,'
        '$column=COALESCE(excluded.$column,meeting_notes.$column)',
        [meeting, now, date, body],
      );
      write();
      db.execute('RELEASE save_enhanced_note');
    } catch (_) {
      db.execute('ROLLBACK TO save_enhanced_note');
      db.execute('RELEASE save_enhanced_note');
      rethrow;
    }
  }

  String preference(String key, [String fallback = '']) =>
      rows('SELECT value FROM preferences WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String? ??
      fallback;
  void setPreference(String key, String value) => db.execute(
    'INSERT INTO preferences VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  void putDocumentLabel(DocumentLabel label) {
    db.execute('SAVEPOINT put_document_label');
    try {
      db.execute(
        'REPLACE INTO document_labels(document_id,label_name,label_source,color_hex,rationale) VALUES(?,?,?,?,?)',
        [
          label.documentId,
          label.name,
          label.source,
          label.colorHex,
          label.rationale,
        ],
      );
      final row = rows('SELECT labels FROM source_details WHERE source_id=?', [
        label.documentId,
      ]).single;
      final names = (jsonDecode(row['labels'] as String) as List)
          .cast<String>();
      if (!names.contains(label.name)) names.add(label.name);
      db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(names),
        label.documentId,
      ]);
      db.execute('RELEASE put_document_label');
    } catch (_) {
      db.execute('ROLLBACK TO put_document_label');
      db.execute('RELEASE put_document_label');
      rethrow;
    }
  }

  /// Planning and publication share one write transaction. The vectors were
  /// acquired asynchronously, so reject any source snapshot that became stale.
  int autoAssignLabel(
    String name,
    List<Map<String, Object?>> expectedSources,
    Map<String, List<double>> vectors,
  ) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final current = sources;
      String revisions(List<Map<String, Object?>> rows) => jsonEncode(
        rows.map((row) => [row['id'], row['revision'], row['state']]).toList(),
      );
      if (revisions(current) != revisions(expectedSources)) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Sources changed while organizing labels; retry',
        );
      }
      final plan = planLabelPropagation(
        name,
        [
          for (final row in current)
            LabelDocument(
              row['id'] as String,
              row['content'] as String,
              title: row['title'] as String?,
            ),
        ],
        documentLabels,
        vectors,
        semanticGraphEdges(vectors),
      );
      for (final label in plan.writes) {
        putDocumentLabel(label);
      }
      saveLabelCluster(name);
      invalidateGraphOrganization();
      db.execute('COMMIT');
      return plan.writes.length;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void saveLabelCluster(
    String label, {
    double x = 0,
    double y = 0,
    double radius = 90,
  }) {
    final existing = rows(
      'SELECT cluster_id FROM document_clusters WHERE label=?',
      [label],
    );
    if (existing.isNotEmpty) {
      db.execute(
        'UPDATE document_clusters SET center_proj_x=?,center_proj_y=?,radius=? WHERE cluster_id=?',
        [x, y, radius, existing.single['cluster_id']],
      );
    } else {
      db.execute(
        'REPLACE INTO document_clusters(label,summary,centroid_embedding,center_proj_x,center_proj_y,radius) VALUES(?,NULL,NULL,?,?,?)',
        [label, x, y, radius],
      );
    }
  }

  String graphLabelSet() => jsonEncode(
    documentLabels
        .map((label) => [label.documentId, label.name, label.source])
        .toList(),
  );
  void invalidateGraphOrganization() =>
      db.execute('DELETE FROM graph_force_state');
  void acknowledgeGraphLabelRemoval() =>
      db.execute('UPDATE graph_force_state SET label_set=?', [graphLabelSet()]);

  void deleteOrganizationLabel(String name) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in rows('SELECT source_id,labels FROM source_details')) {
        final names = (jsonDecode(row['labels'] as String) as List)
            .cast<String>();
        if (names.remove(name)) {
          db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
            jsonEncode(names),
            row['source_id'],
          ]);
        }
      }
      db.execute('DELETE FROM document_labels WHERE label_name=?', [name]);
      db.execute('DELETE FROM document_clusters WHERE label=?', [name]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void labels(String id, List<String> labels) {
    if (rows('SELECT 1 FROM source_details WHERE source_id=?', [id]).isEmpty) {
      return;
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      _writeLabelRecords(id, labels);
      db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(labels),
        id,
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? _outputStatsRevision;
  int _localOutputWords = 0;
  List<({int created, int words})> _answerWordCounts = [];

  void _refreshOutputStats() {
    final revision = dataRevision;
    if (_outputStatsRevision == revision) return;
    int words(String text) => RegExp(r'\S+').allMatches(text).length;
    _answerWordCounts = [
      for (final row in completedAnswerHistory())
        (created: row['created'] as int, words: words(row['body'] as String)),
    ];
    _localOutputWords =
        _answerWordCounts.fold<int>(0, (sum, row) => sum + row.words) +
        artifactBodies().fold<int>(
          0,
          (sum, row) => sum + words(row['generated'] as String),
        );
    _outputStatsRevision = revision;
  }

  /// Saved text has no tokenizer usage metadata. Report words honestly and cache
  /// the scan across builds until the WAL snapshot or this connection changes.
  int get localOutputWords {
    _refreshOutputStats();
    return _localOutputWords;
  }

  List<int> weeklyAnswerWords(DateTime now) {
    _refreshOutputStats();
    final weekly = List<int>.filled(5, 0);
    for (final row in _answerWordCounts) {
      final days = now
          .difference(DateTime.fromMillisecondsSinceEpoch(row.created))
          .inDays;
      if (days >= 0 && days < 35) weekly[4 - days ~/ 7] += row.words;
    }
    return weekly;
  }

  // Typed desktop queries keep SQL and snapshot policy in core.
  List<Map<String, Object?>> registeredEmbedding() =>
      rows("SELECT * FROM models WHERE kind='embedding'");
  List<Map<String, Object?>> sourceById(
    String id, {
    bool includeDeleted = false,
  }) => rows('SELECT * FROM sources WHERE id=? AND (? OR deleted=0)', [
    id,
    includeDeleted ? 1 : 0,
  ]);
  List<Map<String, Object?>> notes() =>
      rows('SELECT * FROM notes ORDER BY id DESC');
  List<Map<String, Object?>> noteSummaries() =>
      rows('SELECT id,title,revision FROM notes ORDER BY id DESC');
  String noteBody(int id) =>
      rows('SELECT body FROM notes WHERE id=?', [id]).single['body'] as String;
  List<Map<String, Object?>> completedAnswerBodies() =>
      rows('SELECT body FROM answers WHERE status=\'completed\'');
  List<Map<String, Object?>> artifactBodies() =>
      rows('SELECT generated FROM artifacts');
  List<Map<String, Object?>> googleSourceMimes() =>
      rows('SELECT source_id,mime FROM google_sources');
  List<Map<String, Object?>> documentClusters() =>
      rows('SELECT * FROM document_clusters');
  List<Map<String, Object?>> documentClusterNames() =>
      rows('SELECT label FROM document_clusters');
  List<Map<String, Object?>> conversationAnswers(int? meetingId) => rows(
    meetingId == null
        ? "SELECT * FROM answers WHERE conversation='desktop' ORDER BY id"
        : 'SELECT answers.* FROM answers JOIN meeting_answers ON answer_id=answers.id WHERE meeting_id=? ORDER BY answers.id',
    meetingId == null ? [] : [meetingId],
  );
  List<Map<String, Object?>> meetingCollection() => rows(
    'SELECT meetings.*,meeting_details.created,meeting_details.reminder,'
    'calendar_events.starts AS calendar_starts,calendar_events.ends AS calendar_ends,'
    'calendar_events.status AS calendar_status,'
    'COALESCE(saved.has_transcript,0) AS has_transcript,saved.duration_ms '
    'FROM meetings LEFT JOIN meeting_details ON meetings.id=meeting_details.meeting_id '
    'LEFT JOIN calendar_events ON meetings.id=calendar_events.meeting_id '
    'LEFT JOIN (SELECT meeting_id,1 AS has_transcript,MAX(end_ms) AS duration_ms '
    'FROM transcript WHERE final=1 GROUP BY meeting_id) AS saved ON saved.meeting_id=meetings.id '
    'ORDER BY COALESCE(calendar_events.starts,meeting_details.created),meetings.id',
  );
  List<Map<String, Object?>> recordedMeetingCountRows() => rows(
    'SELECT COUNT(DISTINCT meeting_id) AS n FROM transcript WHERE final=1',
  );
  List<Map<String, Object?>> completedAnswerCountRows() =>
      rows("SELECT COUNT(*) AS n FROM answers WHERE status='completed'");
  List<Map<String, Object?>> completedAnswerHistory() =>
      rows("SELECT body,created FROM answers WHERE status='completed'");
  List<Map<String, Object?>> meetingNoteRows(int id) =>
      rows('SELECT * FROM meeting_notes WHERE meeting_id=?', [id]);
  List<Map<String, Object?>> meetingPreviewRows(int id) => rows(
    'SELECT meetings.*,meeting_details.created,calendar_events.starts AS calendar_starts,calendar_events.ends AS calendar_ends,'
    '(SELECT MAX(end_ms) FROM transcript WHERE meeting_id=meetings.id AND final=1) AS duration_ms FROM meetings '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN calendar_events ON calendar_events.meeting_id=meetings.id WHERE meetings.id=?',
    [id],
  );
  List<Map<String, Object?>> meetingWorkspaceRows(int id) => rows(
    'SELECT meetings.*,meeting_details.created,calendar_events.starts,calendar_events.ends FROM meetings '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN calendar_events ON calendar_events.meeting_id=meetings.id WHERE meetings.id=?',
    [id],
  );
  List<Map<String, Object?>> enhancedNoteArtifacts(int id) => rows(
    "SELECT * FROM artifacts WHERE meeting_id=? AND kind='enhanced_notes' ORDER BY id DESC LIMIT 1",
    [id],
  );
  List<Map<String, Object?>> meetingQuestions(int id) => rows(
    'SELECT q.*,a.body,a.citations FROM meeting_questions q '
    'LEFT JOIN answers a ON a.id=q.answer_id WHERE q.meeting_id=? ORDER BY q.id',
    [id],
  );
  List<Map<String, Object?>> finalTranscript(int id) => rows(
    'SELECT text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
    [id],
  );
  List<Map<String, Object?>> meetingTranscript(int id) =>
      rows('SELECT * FROM transcript WHERE meeting_id=? ORDER BY id', [id]);
  List<Map<String, Object?>> meetingArtifacts(int id, String kind) => rows(
    'SELECT * FROM artifacts WHERE meeting_id=? AND kind=? ORDER BY id DESC',
    [id, kind],
  );
  List<Map<String, Object?>> exportNotes() => rows(
    'WITH candidates(note_type,note_id,timestamp) AS ('
    'SELECT 0,meeting_id,timestamp FROM meeting_notes UNION ALL '
    'SELECT 1,id,timestamp FROM notes), '
    'acquired AS (SELECT * FROM candidates ORDER BY timestamp DESC LIMIT 1000) '
    'SELECT * FROM ('
    'SELECT meetings.id,meetings.title,meeting_notes.body,'
    'COALESCE(meeting_notes.enhanced_body,(SELECT COALESCE(edited,generated) FROM artifacts '
    "WHERE artifacts.meeting_id=meetings.id AND kind='enhanced_notes' "
    'ORDER BY id DESC LIMIT 1)) AS enhanced_body,'
    'COALESCE(calendar_events.starts,meeting_notes.timestamp,meeting_details.created,0) AS export_date,'
    'calendar_events.ends AS export_end,calendar_events.metadata AS export_metadata,'
    '(SELECT title FROM meeting_note_events WHERE meeting_id=meetings.id '
    'AND event_key=note_event.event_key AND title!=\'\' ORDER BY id DESC LIMIT 1) AS association_title '
    'FROM acquired JOIN meetings ON acquired.note_type=0 AND meetings.id=acquired.note_id '
    'JOIN meeting_notes ON meeting_notes.meeting_id=meetings.id '
    'LEFT JOIN meeting_details ON meeting_details.meeting_id=meetings.id '
    'LEFT JOIN meeting_note_events AS note_event ON note_event.id=('
    'SELECT id FROM meeting_note_events WHERE meeting_id=meetings.id '
    'AND event_key!=\'\' ORDER BY id LIMIT 1) '
    'LEFT JOIN calendar_events ON calendar_events.event_key=COALESCE(note_event.event_key,('
    'SELECT event_key FROM calendar_events AS export_event '
    'WHERE export_event.meeting_id=meetings.id ORDER BY export_event.rowid LIMIT 1'
    ')) UNION ALL '
    'SELECT notes.id,notes.title,notes.body,NULL AS enhanced_body,'
    'COALESCE(notes.timestamp,0) AS export_date,NULL AS export_end,NULL AS export_metadata,NULL AS association_title '
    'FROM acquired JOIN notes ON acquired.note_type=1 AND notes.id=acquired.note_id'
    ') ORDER BY export_date DESC,id',
  );
  List<Map<String, Object?>> registeredSpeech() =>
      rows("SELECT digest FROM models WHERE kind='speech'");
  void close() {
    _closed = true;
    _privacyMaintenanceRetry?.cancel();
    _privacyMaintenanceRetry = null;
    db.dispose();
  }
}

class Parser {
  final bool _macOS;
  final String? _macParser;
  final Duration extractionTimeout;
  final Future<Process> Function(String, List<String>) _startProcess;
  Parser({
    bool? macOS,
    String? macParser,
    this.extractionTimeout = const Duration(seconds: 30),
    Future<Process> Function(String, List<String>)? startProcess,
  }) : _macOS = macOS ?? Platform.isMacOS,
       _macParser = macParser,
       _startProcess =
           startProcess ??
           ((executable, arguments) => Process.start(
             executable,
             arguments,
             includeParentEnvironment: false,
             environment: {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
           ));

  Future<ProcessResult> _extractProcess(
    String executable,
    List<String> arguments,
  ) async {
    if (!executable.startsWith('/')) {
      throw StateError('Extractor must use an absolute path');
    }
    final process = await _startProcess(executable, arguments);
    var expired = false;
    final timer = Timer(extractionTimeout, () {
      expired = true;
      process.kill(ProcessSignal.sigkill);
    });
    Future<String> bounded(Stream<List<int>> stream) async {
      final bytes = <int>[];
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > ImportPolicy.maxFileBytes) {
          process.kill(ProcessSignal.sigkill);
          throw StateError('Extracted document exceeds the 10 MiB limit');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    try {
      final output = await Future.wait([
        bounded(process.stdout),
        bounded(process.stderr),
      ]);
      final code = await process.exitCode;
      if (expired) {
        throw TimeoutException(
          'Document extraction timed out',
          extractionTimeout,
        );
      }
      return ProcessResult(process.pid, code, output[0], output[1]);
    } finally {
      timer.cancel();
    }
  }

  Future<ProcessResult> _linuxExtractor(
    String tool,
    String path,
    List<String> options,
  ) async {
    final file = File(path).resolveSymbolicLinksSync();
    final isolated = '/input/document${tool == 'pdftotext' ? '.pdf' : '.rtf'}';
    // A fresh user/PID/network/mount namespace exposes only system runtime
    // libraries and the one selected input. Profile files and credentials are
    // absent. Failure to establish the sandbox fails the import closed.
    ProcessResult result;
    try {
      result = await _extractProcess('/usr/bin/bwrap', [
        '--unshare-all',
        '--die-with-parent',
        '--new-session',
        '--cap-drop',
        'ALL',
        '--ro-bind',
        '/usr',
        '/usr',
        '--ro-bind-try',
        '/lib',
        '/lib',
        '--ro-bind-try',
        '/lib64',
        '/lib64',
        '--ro-bind-try',
        '/etc/fonts',
        '/etc/fonts',
        '--proc',
        '/proc',
        '--dev',
        '/dev',
        '--tmpfs',
        '/tmp',
        '--dir',
        '/input',
        '--ro-bind',
        file,
        isolated,
        '--chdir',
        '/input',
        '--clearenv',
        '--setenv',
        'HOME',
        '/tmp',
        '--setenv',
        'PATH',
        '/nonexistent',
        '--',
        '/usr/bin/$tool',
        ...options,
        isolated,
        if (tool == 'pdftotext') '-',
      ]);
    } on ProcessException catch (error) {
      final dependency = tool == 'pdftotext' ? 'poppler-utils' : 'unrtf';
      throw StateError(
        'Cannot start the document sandbox at /usr/bin/bwrap. '
        'Install the Linux import dependencies (bubblewrap and $dependency) '
        'and check executable permissions: '
        '${error.message}',
      );
    }
    final diagnostic = result.stderr.toString().trim();
    final namespaceFailure =
        diagnostic.startsWith('bwrap:') &&
        !RegExp(r'^bwrap:\s*exec\w*\b').hasMatch(diagnostic) &&
        RegExp(
          r'namespace|unshare|userns|[ug]id map|capset|^bwrap:\s*loopback:',
          caseSensitive: false,
        ).hasMatch(diagnostic);
    if (result.exitCode != 0 && namespaceFailure) {
      throw StateError(
        'The document sandbox could not start. Check the bubblewrap installation '
        'and host user-namespace permissions. On Ubuntu 24.04, an administrator '
        'may need to allow bubblewrap user namespaces in its AppArmor profile. '
        '$diagnostic',
      );
    }
    return result;
  }

  Future<(String, String)> extract(String path) async {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file ||
        File(path).lengthSync() > ImportPolicy.maxFileBytes) {
      throw StateError('Import requires a regular file no larger than 10 MiB');
    }
    final lower = path.toLowerCase();
    if (_macOS && (lower.endsWith('.pdf') || lower.endsWith('.rtf'))) {
      final executable =
          _macParser ?? runtimeConfiguration['FORESIGHT_FILE_PARSER'];
      if (executable == null || executable.isEmpty) {
        throw StateError(
          'The bundled PDF/RTF extractor is unavailable. Reinstall Open Foresight.',
        );
      }
      ProcessResult result;
      try {
        result = await _extractProcess(executable, [
          lower.endsWith('.pdf') ? '--pdf' : '--rtf',
          path,
        ]);
      } on ProcessException catch (error) {
        throw StateError(
          'Cannot launch the bundled file extractor. Reinstall Open Foresight: ${error.message}',
        );
      }
      if (result.exitCode != 0) {
        throw StateError(
          'File extraction failed: ${result.stderr.toString().trim()}',
        );
      }
      final text = result.stdout as String;
      if (text.trim().isEmpty) {
        throw StateError('The selected document contains no extractable text.');
      }
      return (
        text,
        lower.endsWith('.pdf')
            ? 'PDFKit (macOS adapter)'
            : 'NSAttributedString RTF (macOS adapter)',
      );
    }
    if (lower.endsWith('.pdf')) {
      final r = await _linuxExtractor('pdftotext', path, ['-layout']);
      if (r.exitCode != 0) {
        throw StateError('PDF extraction failed: ${r.stderr}');
      }
      return (r.stdout as String, 'pdftotext -layout (Linux adapter)');
    }
    if (lower.endsWith('.rtf')) {
      final r = await _linuxExtractor('unrtf', path, ['--text', '--quiet']);
      if (r.exitCode != 0) {
        throw StateError('RTF extraction failed: ${r.stderr}');
      }
      // unrtf 0.21 emits this separator even when --quiet hides its metadata.
      var text = r.stdout as String;
      final banner = RegExp(
        r'^-----------------\r?$',
        multiLine: true,
      ).firstMatch(text);
      if (banner != null) {
        final prefix = text.substring(0, banner.start);
        if (prefix.trim().isEmpty ||
            prefix.trimLeft().startsWith('### Translation from RTF')) {
          text = text.substring(banner.end).trimLeft();
        }
      }
      return (text, 'unrtf --text (Linux adapter)');
    }
    final bytes = <int>[];
    await for (final chunk in File(
      path,
    ).openRead().timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > ImportPolicy.maxFileBytes) {
        throw StateError('File exceeds the 10 MiB import limit');
      }
      bytes.addAll(chunk);
    }
    return (utf8.decode(bytes, allowMalformed: true), 'UTF-8 text');
  }
}
