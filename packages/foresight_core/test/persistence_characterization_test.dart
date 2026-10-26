import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

const fixtureRoot = 'test/fixtures/persistence-c28a1561';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late String path;

  setUp(() {
    root = createTestTempDirectorySync('persistence-characterization-');
    path = '${root.path}/application.db';
    addTearDown(() => root.deleteSync(recursive: true));
  });

  Database fixture(int version) {
    final db = sqlite3.open(path);
    db.execute(File('$fixtureRoot/schema$version.sql').readAsStringSync());
    return db;
  }

  void source(
    Database db,
    String id, {
    String labels = '[]',
    String provenance = 'fixture',
    bool deleted = false,
    bool locallyEdited = false,
  }) {
    db.execute(
      'INSERT INTO sources(id,title,content,mime,revision,state,deleted,provenance) '
      "VALUES(?,?,?,'text/plain',7,'ready',?,?)",
      [id, id, 'unchanged body', deleted ? 1 : 0, provenance],
    );
    if (locallyEdited) {
      db.execute('UPDATE sources SET locally_edited=1 WHERE id=?', [id]);
    }
    db.execute(
      'INSERT INTO source_details(source_id,imported,changed,labels,source_uri) '
      'VALUES(?,101,202,?,?)',
      [id, labels, 'https://example.test/$id'],
    );
  }

  test('historical fixture files are independently checksummed and pinned', () {
    final manifest =
        jsonDecode(File('$fixtureRoot/source-manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(
      manifest['source_commit'],
      'c28a1561b5091645718462169bc6c0cfd0040943',
    );
    final files = manifest['files'] as Map<String, dynamic>;
    expect(files.keys, containsAll(['schema8.sql', 'schema15.sql']));
    for (final entry in files.entries) {
      final metadata = entry.value as Map<String, dynamic>;
      expect(
        sha256
            .convert(File('$fixtureRoot/${entry.key}').readAsBytesSync())
            .toString(),
        metadata['sha256'],
        reason: entry.key,
      );
    }
  });

  test(
    'historical v9 valid JSON wins conflicts but retains matching metadata',
    () {
      final db = fixture(8);
      source(db, 'visible', labels: '["Kept","JSON only","Kept"]');
      db.execute('INSERT INTO document_labels VALUES(?,?,?,?,?)', [
        'visible',
        'Kept',
        'automatic',
        '#123456',
        'Evidence retained',
      ]);
      db.execute('INSERT INTO document_labels VALUES(?,?,?,?,?)', [
        'visible',
        'Structured only',
        'user_defined',
        '#654321',
        null,
      ]);
      ApplicationMigrations(db).run(9);
      expect(
        jsonDecode(
          db.select('SELECT labels FROM source_details').single['labels']
              as String,
        ),
        ['Kept', 'JSON only', 'Kept'],
      );
      db.execute('PRAGMA user_version=9');
      db.dispose();

      final store = Store(path);
      addTearDown(store.close);
      final kept = store.documentLabels.singleWhere(
        (label) => label.name == 'Kept',
      );
      expect(
        (kept.source, kept.colorHex, kept.rationale),
        ('automatic', '#123456', 'Evidence retained'),
      );
      expect(store.documentLabels.map((label) => label.name), [
        'Kept',
        'JSON only',
      ]);
      expect(jsonDecode(store.sources.single['labels'] as String), [
        'Kept',
        'JSON only',
      ]);
      final row = store.sources.single;
      expect(
        (row['content'], row['revision'], row['imported'], row['changed']),
        ('unchanged body', 7, 101, 202),
      );
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  for (final malformed in [
    'broken',
    '{"not":"a list"}',
    '[null]',
    '["valid",3]',
  ]) {
    test('historical v9 repairs malformed labels $malformed from records', () {
      final db = fixture(8);
      source(db, 'visible', labels: malformed);
      db.execute('INSERT INTO document_labels VALUES(?,?,?,?,?)', [
        'visible',
        'Manual retained',
        'user_defined',
        '#123456',
        'Original rationale',
      ]);
      db.dispose();

      final store = Store(path);
      addTearDown(store.close);
      final label = store.documentLabels.single;
      expect(
        (label.name, label.source, label.colorHex, label.rationale),
        ('Manual retained', 'user_defined', '#123456', 'Original rationale'),
      );
      expect(jsonDecode(store.sources.single['labels'] as String), [
        label.name,
      ]);
    });
  }

  test(
    'historical v9 keeps tombstone labels while hiding them from projections',
    () {
      final db = fixture(8);
      source(db, 'deleted', labels: '["Private label"]', deleted: true);
      db.dispose();
      final store = Store(path);
      addTearDown(store.close);
      expect(store.sources, isEmpty);
      expect(store.documentLabels, isEmpty);
      expect(
        store
            .rows('SELECT label_name FROM document_labels')
            .single['label_name'],
        'Private label',
      );
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'Google legacy timestamp repair respects edit identity and tombstones',
    () async {
      final db = fixture(15);
      for (final id in [
        'external',
        'invalid',
        'empty',
        'edited',
        'prefix',
        'deleted',
      ]) {
        source(
          db,
          id,
          locallyEdited: id == 'edited',
          provenance: id == 'prefix' ? 'user edit; user edit; drive' : 'drive',
          deleted: id == 'deleted',
        );
        db.execute('INSERT INTO google_sources VALUES(?,?,?,?,?)', [
          id,
          'account',
          id,
          id == 'invalid'
              ? 'not a date'
              : id == 'empty'
              ? ''
              : '2020-01-02T03:04:05Z',
          'text/plain',
        ]);
      }
      db.dispose();
      final store = Store(path);
      addTearDown(store.close);
      final helper = Helper('${root.path}/socket', '${root.path}/helper');
      addTearDown(helper.close);
      final auth = GoogleAuth(
        Directory('${root.path}/google'),
        secretStore: const UnavailableSecretStore(),
      );
      addTearDown(auth.close);
      final connection = GoogleConnections(AdapterDomain(store, helper), auth);
      addTearDown(connection.close);
      final rows = {
        for (final row in store.rows(
          'SELECT s.id,s.content,s.revision,d.imported,d.changed,d.source_uri '
          'FROM sources s JOIN source_details d ON d.source_id=s.id',
        ))
          row['id'] as String: row,
      };
      expect(
        rows['external']!['changed'],
        DateTime.parse('2020-01-02T03:04:05Z').millisecondsSinceEpoch,
      );
      expect(rows['invalid']!['changed'], 0);
      expect(rows['empty']!['changed'], 0);
      for (final id in ['edited', 'prefix', 'deleted']) {
        expect(rows[id]!['changed'], 202, reason: id);
      }
      for (final row in rows.values) {
        expect(
          (row['content'], row['revision'], row['imported']),
          ('unchanged body', 7, 101),
        );
        expect(row['source_uri'], 'https://example.test/${row['id']}');
      }
    },
  );
}
