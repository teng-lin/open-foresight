import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Database db;
  setUp(() {
    root = createTestTempDirectorySync('label-migration-');
    db = sqlite3.open('${root.path}/application.db');
    db.execute(
      File(
        'test/fixtures/persistence-c28a1561/schema15.sql',
      ).readAsStringSync(),
    );
    addTearDown(() {
      db.dispose();
      root.deleteSync(recursive: true);
    });
  });
  void source(String id, String labels, {bool deleted = false}) {
    db.execute(
      "INSERT INTO sources(id,title,content,mime,revision,state,deleted,provenance) VALUES(?,?,?,'text/plain',7,'ready',?,'fixture')",
      [id, id, 'preserved body', deleted ? 1 : 0],
    );
    db.execute(
      'INSERT INTO source_details(source_id,imported,changed,labels,source_uri) VALUES(?,11,22,?,?)',
      [id, labels, 'https://example.test/$id'],
    );
  }

  void label(String id, String name, {String source = 'automatic'}) =>
      db.execute('INSERT INTO document_labels VALUES(?,?,?,?,?)', [
        id,
        name,
        source,
        '#123456',
        'preserved rationale',
      ]);
  List<List<Object?>> labels() => db
      .select(
        'SELECT document_id,label_name,label_source,color_hex,rationale,position FROM document_labels ORDER BY document_id,position',
      )
      .map((r) => r.values.toList())
      .toList();
  String signature({bool canonical = false}) => jsonEncode(
    db
        .select(
          'SELECT l.document_id,l.label_name,l.label_source FROM document_labels l JOIN sources s ON s.id=l.document_id WHERE s.deleted=0${canonical ? ' ORDER BY l.document_id,l.position' : ''}',
        )
        .map((r) => r.values.toList())
        .toList(),
  );
  void layout(String id, String signature) {
    db.execute('INSERT INTO graph_layouts VALUES(?,?)', [
      id,
      'preserved document identities',
    ]);
    db.execute('INSERT INTO graph_force_state VALUES(?,?)', [id, signature]);
  }

  void migrate() {
    db.execute('BEGIN IMMEDIATE');
    try {
      ApplicationMigrations(db).run(17);
      db.execute('PRAGMA user_version=17');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  test(
    'JSON first occurrences then structured-only labels retain all metadata',
    () {
      db.execute('CREATE INDEX source_changed ON source_details(changed)');
      source('a', '["Z","A","Z","JSON only"]');
      label('a', 'A');
      label('a', 'Structured only', source: 'user_defined');
      label('a', 'Z');
      migrate();
      expect(labels().map((r) => r[1]), [
        'Z',
        'A',
        'JSON only',
        'Structured only',
      ]);
      expect(
        labels().where((r) => r[1] != 'JSON only').map((r) => r.sublist(2, 5)),
        [
          ['automatic', '#123456', 'preserved rationale'],
          ['automatic', '#123456', 'preserved rationale'],
          ['user_defined', '#123456', 'preserved rationale'],
        ],
      );
      expect(labels()[2][2], 'user_defined');
      expect(
        db.select('PRAGMA table_info(source_details)').map((r) => r['name']),
        ['source_id', 'imported', 'changed', 'source_uri'],
      );
      expect(db.select('SELECT * FROM source_details').single, {
        'source_id': 'a',
        'imported': 11,
        'changed': 22,
        'source_uri': 'https://example.test/a',
      });
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='source_changed'",
        ),
        hasLength(1),
      );
      final before = labels();
      db.execute('VACUUM');
      expect(labels(), before);
    },
  );
  for (final invalid in ['{broken', '["mixed",42]', '{}']) {
    test(
      'malformed JSON $invalid retains structured manual and automatic rows',
      () {
        source('a', invalid);
        label('a', 'Z');
        label('a', 'A', source: 'user_defined');
        migrate();
        expect(labels().map((r) => r[1]), ['A', 'Z']);
      },
    );
  }
  test('deleted source labels and original foreign key remain stored', () {
    source('dead', '["Tombstone"]', deleted: true);
    migrate();
    expect(labels().single[1], 'Tombstone');
    expect(
      db.select('PRAGMA foreign_key_list(source_details)').single['table'],
      'sources',
    );
    expect(db.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('pre-existing orphan labels remain physically stored and invisible', () {
    label('orphan', 'Preserved', source: 'user_defined');
    label('orphan', 'A');
    migrate();
    expect(labels().map((row) => [row[1], row[5]]), [
      ['A', 0],
      ['Preserved', 1],
    ]);
    expect(labels().last.sublist(0, 5), [
      'orphan',
      'Preserved',
      'user_defined',
      '#123456',
      'preserved rationale',
    ]);
    expect(signature(canonical: true), '[]');
  });
  test(
    'valid unchanged graph membership adopts canonical order; stale never revives',
    () {
      source('a', '["A","Z"]');
      label('a', 'Z');
      label('a', 'A');
      final old = signature();
      layout('valid', old);
      layout(
        'stale',
        jsonEncode([
          ['a', 'A', 'automatic'],
          ['a', 'Z', 'automatic'],
        ]),
      );
      db.execute(
        "INSERT INTO graph_documents VALUES('valid','a',7,x'010203',1.5,2.5,3.5,99)",
      );
      migrate();
      expect(db.select('SELECT * FROM graph_force_state').single, {
        'model_identity': 'valid',
        'label_set': signature(canonical: true),
      });
      final vector = db
          .select(
            'SELECT embedding,proj_x,proj_y,proj_z,updated FROM graph_documents',
          )
          .single;
      expect(vector['embedding'], [1, 2, 3]);
      expect(vector['proj_x'], 1.5);
      expect(vector['updated'], 99);
      expect(db.select('SELECT * FROM graph_layouts'), hasLength(2));
    },
  );
  test('real membership delta keeps existing graph invalidation policy', () {
    source('a', '["A","Added"]');
    label('a', 'A');
    layout('model', signature());
    migrate();
    expect(
      db.select('SELECT label_set FROM graph_force_state').single['label_set'],
      isNot(signature(canonical: true)),
    );
  });
  test(
    'failure rolls back canonical rows, JSON rebuild and version together',
    () {
      source('a', '["A"]');
      label('a', 'A');
      db.execute(
        "CREATE TRIGGER fail_labels BEFORE UPDATE ON document_labels BEGIN SELECT RAISE(ABORT,'fixture rollback'); END",
      );
      expect(migrate, throwsA(isA<SqliteException>()));
      expect(db.select('PRAGMA user_version').single.values.single, 15);
      expect(
        db.select('PRAGMA table_info(document_labels)').map((r) => r['name']),
        isNot(contains('position')),
      );
      expect(
        db.select('SELECT labels FROM source_details').single['labels'],
        '["A"]',
      );
      db.execute('DROP TRIGGER fail_labels');
      migrate();
      expect(db.select('PRAGMA user_version').single.values.single, 17);
    },
  );
  test(
    'signature rewrite failure rolls back layout and representation together',
    () {
      source('a', '["A","Z"]');
      label('a', 'Z');
      label('a', 'A');
      final old = signature();
      layout('valid', old);
      db.execute(
        "CREATE TRIGGER reject_signature AFTER UPDATE ON graph_force_state BEGIN SELECT RAISE(ABORT,'layout rollback'); END",
      );
      expect(migrate, throwsA(isA<SqliteException>()));
      expect(
        db
            .select('SELECT label_set FROM graph_force_state')
            .single['label_set'],
        old,
      );
      expect(
        db.select('SELECT labels FROM source_details').single['labels'],
        '["A","Z"]',
      );
      expect(
        db.select('PRAGMA table_info(document_labels)').map((r) => r['name']),
        isNot(contains('position')),
      );
      expect(db.select('PRAGMA user_version').single.values.single, 15);
    },
  );
}
