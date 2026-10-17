import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';

void main() {
  late Directory root;
  late Store store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('auto-label-');
    store = Store('${root.path}/app.db');
    for (final id in ['a', 'b']) {
      store.importText(
        'Apollo $id',
        'Apollo work for $id',
        'text/plain',
        'fixture',
        id: id,
      );
    }
  });
  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  test('service operation publishes all labels and cluster together', () async {
    final domain = Domain(
      store,
      Helper('${root.path}/socket', '${root.path}/helper'),
    );
    final app = Application(domain);
    try {
      expect(await app.call('labels.auto_assign', {'name': 'Apollo'}), 2);
      expect(store.documentLabels.map((label) => label.documentId), ['a', 'b']);
      expect(store.documentClusterNames().single['label'], 'Apollo');
      expect(store.sources.every((row) => row['labels'] == '["Apollo"]'), true);
    } finally {
      await app.close();
      domain.close();
      await domain.helper.close();
    }
  });

  test('a failed second document rolls back earlier labels and cluster', () {
    store.db.execute(
      "CREATE TRIGGER reject_b BEFORE INSERT ON document_labels WHEN NEW.document_id='b' BEGIN SELECT RAISE(ABORT,'injected'); END",
    );
    expect(
      () => store.autoAssignLabel('Apollo', store.sources, {}),
      throwsA(anything),
    );
    expect(store.documentLabels, isEmpty);
    expect(store.documentClusters(), isEmpty);
    expect(store.sources.every((row) => row['labels'] == '[]'), true);
    expect(store.db.autocommit, true);
  });

  test('stale acquisition cannot publish labels against changed sources', () {
    final snapshot = store.sources;
    store.importText('Apollo a', 'Updated', 'text/plain', 'fixture', id: 'a');
    expect(
      () => store.autoAssignLabel('Apollo', snapshot, {}),
      throwsStateError,
    );
    expect(store.documentLabels, isEmpty);
    expect(store.documentClusters(), isEmpty);
  });

  test(
    'output words refresh after local and WAL changes and handle empty text',
    () {
      expect(store.localOutputWords, 0);
      store.answer('q', ' one  two\nthree ', 'completed', [], 'fixture');
      expect(store.localOutputWords, 3);
      expect(store.weeklyAnswerWords(DateTime.now()).last, 3);
      final writer = Store(store.path);
      try {
        writer.answer('q', '', 'completed', [], 'fixture');
        writer.answer('q', 'four five', 'completed', [], 'fixture');
        expect(store.localOutputWords, 5);
      } finally {
        writer.close();
      }
    },
  );
}
