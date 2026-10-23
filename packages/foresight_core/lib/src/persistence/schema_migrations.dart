// Historical executable definitions. Change schema by appending a version.
// Migrations 1–15 and their complete private helper closure are frozen at c28a1561.
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

class ApplicationMigrations {
  final Database db;
  ApplicationMigrations(this.db);
  void run(int version) {
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
      case 12:
        if (!rows(
          'PRAGMA table_info(artifacts)',
        ).any((row) => row['name'] == 'created')) {
          // Older output has no generation date. Keep it in lifetime totals
          // without inventing a week from the meeting's creation date.
          db.execute('ALTER TABLE artifacts ADD COLUMN created INTEGER');
        }
      case 13:
        db.execute(
          'CREATE TABLE IF NOT EXISTS request_keys(key TEXT PRIMARY KEY,operation TEXT NOT NULL,arguments TEXT NOT NULL,result TEXT NOT NULL,created INTEGER NOT NULL)',
        );
      case 14:
        if (!rows(
          'PRAGMA table_info(artifacts)',
        ).any((row) => row['name'] == 'manifest')) {
          db.execute('ALTER TABLE artifacts ADD COLUMN manifest TEXT');
        }
        db.execute(
          'CREATE TABLE IF NOT EXISTS meeting_summary_checkpoints(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,artifact_id INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,input_length INTEGER NOT NULL,input_digest TEXT NOT NULL,identity TEXT NOT NULL)',
        );
      case 15:
        db.execute(
          "UPDATE artifacts SET kind='actions' WHERE kind='action_items'",
        );
        db.execute(
          'CREATE TABLE IF NOT EXISTS meeting_tasks(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,task_key TEXT NOT NULL,task TEXT NOT NULL,owner TEXT,due TEXT,status TEXT NOT NULL,evidence TEXT NOT NULL,input_revision INTEGER NOT NULL,stale INTEGER NOT NULL DEFAULT 0,manual INTEGER NOT NULL DEFAULT 0,UNIQUE(meeting_id,task_key))',
        );
        db.execute(
          'CREATE TABLE IF NOT EXISTS document_summary_cache(cache_key TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,source_revision INTEGER NOT NULL,body TEXT NOT NULL,identity TEXT NOT NULL,clipped INTEGER NOT NULL DEFAULT 0)',
        );
      case 16:
        _restoreGoogleModificationTimes();
      case 17:
        _canonicalizeLabels();
      case 18:
        _createContentHistory();
      default:
        throw StateError('Missing application database migration $version');
    }
  }

  void _createContentHistory() {
    db.execute(
      'CREATE TABLE content_revisions(id INTEGER PRIMARY KEY,entity TEXT NOT NULL,entity_id TEXT NOT NULL,snapshot TEXT NOT NULL,created INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE INDEX content_revisions_entity ON content_revisions(entity,entity_id,id)',
    );
    const entities = {
      'notes': ['id', 'title', 'body', 'revision', 'timestamp'],
      'meeting_notes': [
        'meeting_id',
        'body',
        'revision',
        'enhanced_body',
        'timestamp',
        'last_enhanced',
        'last_manual_edit',
      ],
      'artifacts': [
        'id',
        'meeting_id',
        'kind',
        'generated',
        'edited',
        'input_revision',
        'model',
        'prompt_version',
        'created',
        'manifest',
      ],
      'meeting_tasks': [
        'id',
        'meeting_id',
        'task_key',
        'task',
        'owner',
        'due',
        'status',
        'evidence',
        'input_revision',
        'stale',
        'manual',
      ],
      'sources': [
        'id',
        'title',
        'content',
        'mime',
        'revision',
        'state',
        'error',
        'deleted',
        'provenance',
        'locally_edited',
      ],
    };
    for (final entity in entities.entries) {
      final table = entity.key;
      final id = entity.value.first;
      final snapshot = entity.value
          .map((column) => "'$column',OLD.$column")
          .join(',');
      const content = {
        'notes': ['title', 'body'],
        'meeting_notes': ['body', 'enhanced_body'],
        'artifacts': ['generated', 'edited'],
        'meeting_tasks': [
          'task',
          'owner',
          'due',
          'status',
          'evidence',
          'manual',
        ],
        'sources': ['title', 'content', 'mime', 'provenance'],
      };
      final changed = content[table]!
          .map((column) => 'OLD.$column IS NOT NEW.$column')
          .join(' OR ');
      final retained = table == 'sources'
          ? 'OLD.deleted=0 AND ($changed)'
          : changed;
      db.execute(
        'CREATE TRIGGER ${table}_retain_revision BEFORE UPDATE ON $table WHEN $retained BEGIN '
        "INSERT INTO content_revisions(entity,entity_id,snapshot,created) VALUES('$table',CAST(OLD.$id AS TEXT),json_object($snapshot),CAST(strftime('%s','now') AS INTEGER)*1000); END",
      );
      db.execute(
        'CREATE TRIGGER ${table}_erase_revisions AFTER DELETE ON $table BEGIN '
        "DELETE FROM content_revisions WHERE entity='$table' AND entity_id=CAST(OLD.$id AS TEXT); END",
      );
    }
    // Source deletion is soft; history must obey the same erasure boundary.
    db.execute(
      "CREATE TRIGGER sources_erase_deleted_revisions AFTER UPDATE OF deleted ON sources WHEN NEW.deleted=1 BEGIN DELETE FROM content_revisions WHERE entity='sources' AND entity_id=NEW.id; END",
    );
  }

  void _canonicalizeLabels() {
    final oldSignature = jsonEncode(
      _documentLabels
          .map((label) => [label.documentId, label.name, label.source])
          .toList(),
    );
    final oldMembers =
        _documentLabels
            .map(
              (label) =>
                  jsonEncode([label.documentId, label.name, label.source]),
            )
            .toList()
          ..sort();
    final validLayouts = rows(
      'SELECT model_identity FROM graph_force_state WHERE label_set=?',
      [oldSignature],
    ).map((row) => row['model_identity']).toSet();
    db.execute(
      'ALTER TABLE document_labels ADD COLUMN position INTEGER NOT NULL DEFAULT 0',
    );
    final records = _documentLabels;
    for (final source in rows(
      'SELECT identities.source_id,d.labels FROM '
      '(SELECT source_id FROM source_details UNION SELECT document_id FROM document_labels) identities '
      'LEFT JOIN source_details d ON d.source_id=identities.source_id ORDER BY identities.source_id',
    )) {
      final id = source['source_id'] as String;
      final existing = {
        for (final row in rows(
          'SELECT * FROM document_labels WHERE document_id=? ORDER BY label_name',
          [id],
        ))
          row['label_name'] as String: row,
      };
      var names = <String>[];
      try {
        names = (jsonDecode(source['labels'] as String) as List)
            .cast<String>()
            .toList();
      } catch (_) {
        // Malformed legacy JSON cannot erase structured manual or automatic rows.
      }
      names = {...names, ...existing.keys}.toList();
      for (var position = 0; position < names.length; position++) {
        final name = names[position];
        if (existing.containsKey(name)) {
          db.execute(
            'UPDATE document_labels SET position=? WHERE document_id=? AND label_name=?',
            [position, id, name],
          );
        } else {
          final color = _historicalAllocateGraphLabelColor(name, records);
          db.execute(
            'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale,position) VALUES(?,?,?,?,NULL,?)',
            [id, name, 'user_defined', color, position],
          );
          records.add(
            _HistoricalDocumentLabel(id, name, 'user_defined', color),
          );
        }
      }
    }
    // SQLite table rebuilding works on every supported host library. Keep the
    // original key, foreign key, timestamps and URI; only the duplicate JSON
    // representation disappears. No DROP COLUMN support is assumed.
    final indexes = rows(
      "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='source_details' AND sql IS NOT NULL",
    ).map((row) => row['sql'] as String).toList();
    final oldDetailsCount = rows(
      'SELECT COUNT(*) AS n FROM source_details',
    ).single['n'];
    db.execute('''CREATE TABLE source_details_canonical(
      source_id TEXT PRIMARY KEY REFERENCES sources(id),imported INTEGER NOT NULL,
      changed INTEGER NOT NULL,source_uri TEXT NOT NULL DEFAULT '');
      INSERT INTO source_details_canonical(source_id,imported,changed,source_uri)
        SELECT source_id,imported,changed,source_uri FROM source_details;
      DROP TABLE source_details;
      ALTER TABLE source_details_canonical RENAME TO source_details;''');
    for (final index in indexes) {
      db.execute(index);
    }
    if (rows('SELECT COUNT(*) AS n FROM source_details').single['n'] !=
        oldDetailsCount) {
      throw StateError('Source details changed during label migration');
    }
    final ordered = rows(
      'SELECT l.document_id,l.label_name,l.label_source FROM document_labels l '
      'JOIN sources s ON s.id=l.document_id WHERE s.deleted=0 ORDER BY l.document_id,l.position',
    );
    final signature = jsonEncode(
      ordered
          .map(
            (row) => [
              row['document_id'],
              row['label_name'],
              row['label_source'],
            ],
          )
          .toList(),
    );
    final members =
        ordered
            .map(
              (row) => jsonEncode([
                row['document_id'],
                row['label_name'],
                row['label_source'],
              ]),
            )
            .toList()
          ..sort();
    if (jsonEncode(oldMembers) == jsonEncode(members)) {
      for (final model in validLayouts) {
        db.execute(
          'UPDATE graph_force_state SET label_set=? WHERE model_identity=?',
          [signature, model],
        );
      }
    }
    // A previously stale layout must not accidentally become valid merely
    // because canonical ordering now matches its old signature.
    for (final row in rows(
      'SELECT model_identity FROM graph_force_state WHERE label_set=?',
      [signature],
    )) {
      if (!validLayouts.contains(row['model_identity'])) {
        db.execute('DELETE FROM graph_force_state WHERE model_identity=?', [
          row['model_identity'],
        ]);
      }
    }
  }

  void _restoreGoogleModificationTimes() {
    for (final row in rows(
      "SELECT sources.id,google_sources.modified FROM google_sources JOIN sources ON sources.id=google_sources.source_id WHERE sources.deleted=0 AND sources.locally_edited=0 AND sources.provenance NOT LIKE 'user edit; %'",
    )) {
      final modified = row['modified'];
      final changed = modified is String
          ? DateTime.tryParse(modified)?.millisecondsSinceEpoch ?? 0
          : 0;
      db.execute(
        'UPDATE source_details SET changed=? WHERE source_id=? AND changed<>?',
        [changed, row['id'], changed],
      );
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
  List<_HistoricalDocumentLabel> get _documentLabels => rows(
    'SELECT l.* FROM document_labels l JOIN sources s ON s.id=l.document_id WHERE s.deleted=0',
  ).map(_HistoricalDocumentLabel.fromRow).toList();
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
    final records = _documentLabels;
    for (final name in names.toSet()) {
      if (rows(
        'SELECT 1 FROM document_labels WHERE document_id=? AND label_name=?',
        [id, name],
      ).isNotEmpty) {
        continue;
      }
      final color = _historicalAllocateGraphLabelColor(name, records);
      db.execute(
        'INSERT INTO document_labels(document_id,label_name,label_source,color_hex,rationale) VALUES(?,?,?,?,NULL)',
        [id, name, 'user_defined', color],
      );
      records.add(_HistoricalDocumentLabel(id, name, 'user_defined', color));
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
}

const _historicalGraphLabelPalette = [
  '#0EBC5F',
  '#60D5F3',
  '#7372FE',
  '#FEC700',
  '#FF8D41',
  '#3186FF',
  '#FF69C3',
];

class _HistoricalDocumentLabel {
  final String documentId, name, source;
  final String? colorHex, rationale;
  const _HistoricalDocumentLabel(
    this.documentId,
    this.name,
    this.source,
    this.colorHex, [
    this.rationale,
  ]);
  factory _HistoricalDocumentLabel.fromRow(Map<String, Object?> row) =>
      _HistoricalDocumentLabel(
        row['document_id'] as String,
        row['label_name'] as String,
        row['label_source'] as String,
        row['color_hex'] as String?,
        row['rationale'] as String?,
      );
}

String _historicalAllocateGraphLabelColor(
  String name,
  Iterable<_HistoricalDocumentLabel> labels, {
  Iterable<String?> clusterColors = const [],
}) {
  final existing = labels.toList();
  for (final label in existing) {
    if (label.name.toLowerCase() == name.toLowerCase() &&
        label.colorHex != null) {
      return label.colorHex!;
    }
  }
  final used = {
    for (final label in existing)
      if (label.colorHex != null) label.colorHex!.toUpperCase(),
    for (final color in clusterColors)
      if (color != null) color.toUpperCase(),
  };
  for (final color in _historicalGraphLabelPalette) {
    if (!used.contains(color.toUpperCase())) return color;
  }
  return _historicalGraphLabelPalette[name.hashCode.abs() %
      _historicalGraphLabelPalette.length];
}
