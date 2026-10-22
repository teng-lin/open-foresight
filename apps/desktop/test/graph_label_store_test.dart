import 'package:foresight_test_support/persistence_fixtures.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/graph_labels.dart';
import 'package:open_foresight/graph_rendering.dart';
import 'package:foresight_core/src/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'palette allocates unused colors and reuses the stored matching-label string',
    () {
      final records = <DocumentLabel>[];
      for (var i = 0; i < graphLabelPalette.length; i++) {
        final color = allocateGraphLabelColor('Label $i', records);
        expect(color, graphLabelPalette[i]);
        records.add(DocumentLabel('doc$i', 'Label $i', 'user_defined', color));
      }
      expect(allocateGraphLabelColor('LABEL 0', records), '#0EBC5F');
      final exhausted = allocateGraphLabelColor('Eighth', records);
      expect(graphLabelPalette, contains(exhausted));
      records.add(DocumentLabel('eighth', 'Eighth', 'user_defined', exhausted));
      expect(allocateGraphLabelColor('eighth', records), exhausted);
      expect(
        allocateGraphLabelColor('new', [], clusterColors: ['#0ebc5f']),
        '#60D5F3',
      );
      expect(
        allocateGraphLabelColor('label', [
          const DocumentLabel('a', 'Label', 'user_defined', ''),
        ]),
        '',
      );
    },
  );

  test(
    'color parser accepts recovered integer forms and falls back on invalid input',
    () {
      const fallback = Colors.purple;
      expect(graphLabelColor('#0EBC5F', fallback), const Color(0xff0ebc5f));
      expect(graphLabelColor('##0E#BC5F', fallback), const Color(0xff0ebc5f));
      expect(graphLabelColor('800EBC5F', fallback), const Color(0x800ebc5f));
      expect(graphLabelColor('F', fallback), const Color(0x0000000f));
      expect(graphLabelColor('invalid', fallback), fallback);
      expect(graphLabelColor(null, fallback), fallback);
      expect(graphLabelColor('', fallback), fallback);
    },
  );

  for (final apolloFirst in [true, false]) {
    test(
      'associations persist colors, metadata and removal without changing source revisions '
      '(${apolloFirst ? 'Apollo' : 'Borealis'} sorts first)',
      () {
        final dir = createTestTempDirectorySync('foresight-label-records-');
        addTearDown(() => dir.deleteSync(recursive: true));
        var store = Store('${dir.path}/app.db');
        final a = store.importText(
          'Apollo',
          'Body',
          'text/plain',
          'fixture:a',
          id: apolloFirst ? 'a' : 'z',
        );
        final b = store.importText(
          'Borealis',
          'Other body',
          'text/plain',
          'fixture:b',
          id: apolloFirst ? 'z' : 'a',
        );
        Map<String, Object?> source(String id) =>
            store.sources.singleWhere((row) => row['id'] == id);
        final original = {
          for (final id in [a, b]) id: source(id),
        };
        void expectSourceRevisionsUnchanged() {
          for (final id in [a, b]) {
            expect(source(id)['revision'], original[id]!['revision']);
            expect(source(id)['changed'], original[id]!['changed']);
          }
        }

        final expectedPositions = apolloFirst
            ? [(a, 'Planning', 0), (a, 'Local AI', 1), (b, 'planning', 0)]
            : [(b, 'planning', 0), (a, 'Planning', 0), (a, 'Local AI', 1)];
        void expectLabelOrder() {
          expect(
            store.documentLabels.map((label) => (label.documentId, label.name)),
            expectedPositions.map((row) => (row.$1, row.$2)),
          );
          expect(
            store
                .rows(
                  'SELECT document_id,label_name,position FROM document_labels '
                  'ORDER BY document_id,position',
                )
                .map(
                  (row) =>
                      (row['document_id'], row['label_name'], row['position']),
                ),
            expectedPositions,
          );
        }

        store.labels(a, ['Planning', 'Local AI']);
        store.labels(b, ['planning']);
        final expectedColors = {
          (a, 'Planning'): '#0EBC5F',
          (a, 'Local AI'): '#60D5F3',
          (b, 'planning'): '#0EBC5F',
        };
        expect({
          for (final label in store.documentLabels)
            (label.documentId, label.name): label.colorHex,
        }, expectedColors);
        expect(
          store.documentLabels.every(
            (r) => r.source == 'user_defined' && r.rationale == null,
          ),
          true,
        );
        expectLabelOrder();
        expectSourceRevisionsUnchanged();
        store.db.execute(
          'UPDATE document_labels SET rationale=? WHERE document_id=? AND label_name=?',
          ['Keep this rationale', a, 'Planning'],
        );
        store.close();
        store = Store('${dir.path}/app.db');
        expect(
          {
            for (final label in store.documentLabels)
              (label.documentId, label.name): (
                label.colorHex,
                label.source,
                label.rationale,
              ),
          },
          {
            (a, 'Planning'): ('#0EBC5F', 'user_defined', 'Keep this rationale'),
            (a, 'Local AI'): ('#60D5F3', 'user_defined', null),
            (b, 'planning'): ('#0EBC5F', 'user_defined', null),
          },
        );
        expectLabelOrder();
        expectSourceRevisionsUnchanged();
        expect(jsonDecode(source(a)['labels'] as String), [
          'Planning',
          'Local AI',
        ]);
        expect(jsonDecode(source(b)['labels'] as String), ['planning']);
        store.labels(a, ['Planning']);
        expect(
          store.documentLabels
              .where((r) => r.documentId == a)
              .map((r) => r.name),
          ['Planning'],
        );
        expect(jsonDecode(source(a)['labels'] as String), ['Planning']);
        expect(jsonDecode(source(b)['labels'] as String), ['planning']);
        store.labels(b, []);
        expect(store.documentLabels.where((r) => r.documentId == b), isEmpty);
        expect(jsonDecode(source(b)['labels'] as String), isEmpty);
        expectSourceRevisionsUnchanged();
        store.db.execute('DELETE FROM source_details WHERE source_id=?', [a]);
        store.db.execute('DELETE FROM sources WHERE id=?', [a]);
        expect(store.rows('SELECT * FROM document_labels'), isEmpty);
        store.close();
      },
    );
  }

  test(
    'legacy JSON edits reconcile atomically while source data and existing colours survive',
    () {
      final dir = createTestTempDirectorySync('foresight-label-migration-');
      addTearDown(() => dir.deleteSync(recursive: true));
      var store = Store('${dir.path}/app.db');
      final id = store.importText(
        'Document',
        'Original content',
        'text/plain',
        'fixture',
      );
      store.labels(id, ['Existing']);
      store.db.execute(
        'UPDATE document_labels SET color_hex=? WHERE document_id=?',
        ['#123456', id],
      );
      final before = Map<String, Object?>.from(store.sources.single);
      legacyLabelFixture(store.db);
      store.db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(['Existing', 'New']),
        id,
      ]);
      store.db.execute('PRAGMA user_version=8');
      before['labels'] = jsonEncode(['Existing', 'New']);
      store.close();
      store = Store('${dir.path}/app.db');
      expect(store.sources.single, before);
      expect(store.documentLabels.map((r) => r.colorHex), [
        '#123456',
        '#0EBC5F',
      ]);
      store.close();
      store = Store('${dir.path}/app.db');
      expect(store.documentLabels.length, 2);
      expect(store.documentLabels.first.colorHex, '#123456');
      store.close();
    },
  );
  test('failed association insert rolls back removals and JSON atomically', () {
    final dir = createTestTempDirectorySync('foresight-label-rollback-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store('${dir.path}/app.db');
    final id = store.importText(
      'Document',
      'Keep content',
      'text/plain',
      'fixture',
    );
    store.labels(id, ['First', 'Second']);
    final jsonBefore = store.sources.single['labels'];
    final rowsBefore = store.rows('SELECT * FROM document_labels');
    store.db.execute(
      "CREATE TRIGGER reject_label BEFORE INSERT ON document_labels WHEN NEW.label_name='Reject' BEGIN SELECT RAISE(ABORT,'injected failure'); END",
    );
    expect(
      () => store.labels(id, ['First', 'Reject']),
      throwsA(isA<SqliteException>()),
    );
    expect(store.sources.single['labels'], jsonBefore);
    expect(store.rows('SELECT * FROM document_labels'), rowsBefore);
    store.close();
  });
  test(
    'schema migration backfills a legacy database with no association table',
    () {
      final dir = createTestTempDirectorySync('foresight-label-legacy-');
      addTearDown(() => dir.deleteSync(recursive: true));
      var store = Store('${dir.path}/app.db');
      final id = store.importText(
        'Legacy',
        'Original body',
        'text/plain',
        'fixture',
        sourceUri: 'https://example.test/document',
      );
      final before = Map<String, Object?>.from(store.sources.single);
      legacyLabelFixture(store.db);
      store.db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
        jsonEncode(['First', 'Second']),
        id,
      ]);
      store.db.execute('DROP TABLE document_labels');
      store.db.execute('PRAGMA user_version=1');
      before['labels'] = jsonEncode(['First', 'Second']);
      store.close();
      store = Store('${dir.path}/app.db');
      expect(store.sources.single, before);
      expect(store.documentLabels.map((r) => r.name), ['First', 'Second']);
      expect(store.documentLabels.map((r) => r.colorHex), [
        '#0EBC5F',
        '#60D5F3',
      ]);
      expect(
        store.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      store.close();
    },
  );
}
