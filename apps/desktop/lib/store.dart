import 'dart:convert';
import 'dart:io';
import 'graph_labels.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Linux application schema, independently versioned from helper databases.
class Store {
  final Database db;
  final String path;
  Store(this.path) : db = sqlite3.open(path) {
    db.execute('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) throw StateError('Unsupported newer application database');
    db.execute(
      '''CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,title TEXT NOT NULL,content TEXT NOT NULL,mime TEXT NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',deleted INTEGER NOT NULL DEFAULT 0,provenance TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE IF NOT EXISTS answers(id INTEGER PRIMARY KEY,question TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL,citations TEXT NOT NULL,model TEXT NOT NULL,created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS models(kind TEXT PRIMARY KEY,path TEXT NOT NULL,digest TEXT NOT NULL,runtime TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meetings(id INTEGER PRIMARY KEY,title TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS transcript(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),text TEXT NOT NULL,final INTEGER NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,source TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS artifacts(id INTEGER PRIMARY KEY,meeting_id INTEGER NOT NULL REFERENCES meetings(id),kind TEXT NOT NULL,generated TEXT NOT NULL,edited TEXT,input_revision INTEGER NOT NULL,model TEXT NOT NULL,prompt_version TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS source_details(source_id TEXT PRIMARY KEY REFERENCES sources(id),imported INTEGER NOT NULL,changed INTEGER NOT NULL,labels TEXT NOT NULL DEFAULT '[]');
    CREATE TABLE IF NOT EXISTS document_labels(document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,label_name TEXT NOT NULL,label_source TEXT NOT NULL,color_hex TEXT,rationale TEXT,PRIMARY KEY(document_id,label_name));
    CREATE TABLE IF NOT EXISTS document_clusters(cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,label TEXT UNIQUE NOT NULL,summary TEXT,centroid_embedding BLOB,center_proj_x REAL NOT NULL DEFAULT 0,center_proj_y REAL NOT NULL DEFAULT 0,radius REAL NOT NULL DEFAULT 100);
    CREATE TABLE IF NOT EXISTS graph_documents(model_identity TEXT NOT NULL,document_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,source_revision INTEGER NOT NULL,embedding BLOB NOT NULL,proj_x REAL NOT NULL,proj_y REAL NOT NULL,proj_z REAL NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(model_identity,document_id));
    CREATE TABLE IF NOT EXISTS graph_layouts(model_identity TEXT PRIMARY KEY,document_set TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS graph_force_state(model_identity TEXT PRIMARY KEY REFERENCES graph_layouts(model_identity) ON DELETE CASCADE,label_set TEXT NOT NULL);
    INSERT OR IGNORE INTO source_details(source_id,imported,changed) SELECT id,0,0 FROM sources;
    CREATE TABLE IF NOT EXISTS meeting_details(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id),created INTEGER NOT NULL,reminder INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS meeting_notes(meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,body TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS meeting_answers(meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,answer_id INTEGER NOT NULL REFERENCES answers(id) ON DELETE CASCADE,PRIMARY KEY(meeting_id,answer_id));
    INSERT OR IGNORE INTO meeting_details(meeting_id,created) SELECT id,0 FROM meetings;
    PRAGMA user_version=1;''',
    );
    if (!db
        .select('PRAGMA table_info(models)')
        .any((row) => row['name'] == 'backend'))
      db.execute(
        "ALTER TABLE models ADD COLUMN backend TEXT NOT NULL DEFAULT 'llama_cpp'",
      );
    if (!db
        .select('PRAGMA table_info(source_details)')
        .any((row) => row['name'] == 'source_uri')) {
      db.execute(
        "ALTER TABLE source_details ADD COLUMN source_uri TEXT NOT NULL DEFAULT ''",
      );
      for (final row in rows('SELECT id,provenance FROM sources')) {
        final uri = _legacySourceUri(row['provenance'] as String);
        if (uri.isNotEmpty)
          db.execute(
            'UPDATE source_details SET source_uri=? WHERE source_id=?',
            [uri, row['id']],
          );
      }
    }
    _reconcileLabelRecords();
  }

  // Reconcile the legacy JSON projection on opening so labels edited by an
  // older Linux bundle retain their names and acquire persistent colors.
  void _reconcileLabelRecords() {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in rows('SELECT source_id,labels FROM source_details')) {
        final names = (jsonDecode(row['labels'] as String) as List)
            .cast<String>();
        _writeLabelRecords(row['source_id'] as String, names);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

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
      ).isNotEmpty)
        continue;
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
    if (marker >= 0)
      return Uri.file(provenance.substring(marker + 2)).toString();
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
        'SELECT sources.id,sources.title,sources.mime,sources.provenance,sources.state,sources.error,sources.revision,sources.deleted,source_details.imported,source_details.changed,source_details.labels,source_details.source_uri FROM sources LEFT JOIN source_details ON sources.id=source_details.source_id WHERE deleted=0 ORDER BY title',
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
  }) {
    id ??= sha256
        .convert(utf8.encode('$title:${DateTime.now().microsecondsSinceEpoch}'))
        .toString();
    db.execute(
      'INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES(?,?,?,?,1,\'pending\',?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,mime=excluded.mime,revision=sources.revision+1,state=\'pending\',error=\'\',deleted=0,provenance=excluded.provenance',
      [id, title, text, mime, provenance],
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
    String model,
  ) => db.execute(
    'INSERT INTO answers(question,body,status,citations,model,created) VALUES(?,?,?,?,?,?)',
    [
      question,
      body,
      status,
      jsonEncode(citations),
      model,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
  void saveNote(int? id, String title, String body) {
    if (id == null) {
      db.execute('INSERT INTO notes(title,body) VALUES(?,?)', [title, body]);
    } else {
      db.execute(
        'UPDATE notes SET title=?,body=?,revision=revision+1 WHERE id=?',
        [title, body, id],
      );
    }
  }

  Future<void> register(
    String kind,
    String path,
    String runtime, {
    String backend = 'llama_cpp',
    String? expectedDigest,
    bool Function()? current,
  }) async {
    final backends = [
      'llama_cpp',
      'litert_lm',
      if (kind == 'embedding') ...[
        'sentence_transformers_cpu',
        'litert_lm_embedding_cpu',
        'litert_lm_embedding_gpu',
      ],
    ];
    if (!backends.contains(backend)) throw ArgumentError.value(backend);
    String digest;
    if (Directory(path).existsSync()) {
      final files =
          Directory(path)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) throw StateError('Empty model directory');
      final manifest = StringBuffer();
      for (final file in files) {
        manifest.writeln(
          '${file.path.substring(Directory(path).path.length)}:${await sha256.bind(file.openRead()).first}',
        );
      }
      digest = sha256.convert(utf8.encode(manifest.toString())).toString();
    } else {
      digest = (await sha256.bind(File(path).openRead()).first).toString();
    }
    if (current != null && !current())
      throw StateError('Model setup cancelled');
    if (expectedDigest != null && digest != expectedDigest)
      throw StateError(
        'The $kind model does not match its installation digest',
      );
    db.execute(
      'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?) ON CONFLICT(kind) DO UPDATE SET path=excluded.path,digest=excluded.digest,runtime=excluded.runtime,backend=excluded.backend',
      [kind, File(path).absolute.path, digest.toString(), runtime, backend],
    );
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

  void saveMeetingNotes(int meetingId, String body) => db.execute(
    'INSERT INTO meeting_notes(meeting_id,body,revision) VALUES(?,?,1) '
    'ON CONFLICT(meeting_id) DO UPDATE SET body=excluded.body,revision=meeting_notes.revision+1',
    [meetingId, body],
  );

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
    if (finalText)
      db.execute('UPDATE meetings SET revision=revision+1 WHERE id=?', [
        meeting,
      ]);
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
    db.execute(
      'INSERT INTO artifacts(meeting_id,kind,generated,input_revision,model,prompt_version) VALUES(?,?,?,?,?,?)',
      [meeting, kind, generated, revision, model, 'meeting-v1'],
    );
  }

  void editArtifact(int id, String text) =>
      db.execute('UPDATE artifacts SET edited=? WHERE id=?', [text, id]);
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
    db.execute('BEGIN IMMEDIATE');
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
      db.execute('COMMIT');
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
        if (names.remove(name))
          db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
            jsonEncode(names),
            row['source_id'],
          ]);
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
    if (rows('SELECT 1 FROM source_details WHERE source_id=?', [id]).isEmpty)
      return;
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

  void close() => db.dispose();
}

class Parser {
  Future<(String, String)> extract(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.pdf')) {
      final r = await Process.run('pdftotext', ['-layout', path, '-']);
      if (r.exitCode != 0)
        throw StateError('PDF extraction failed: ${r.stderr}');
      return (r.stdout as String, 'pdftotext -layout (Linux adapter)');
    }
    if (lower.endsWith('.rtf')) {
      final r = await Process.run('unrtf', ['--text', path]);
      if (r.exitCode != 0)
        throw StateError('RTF extraction failed: ${r.stderr}');
      return (r.stdout as String, 'unrtf --text (Linux adapter)');
    }
    return (await File(path).readAsString(), 'UTF-8 text');
  }
}
