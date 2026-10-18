import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';

class DeferredEmbeddingDomain extends Domain {
  DeferredEmbeddingDomain(super.store, super.helper);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) async {
    entered.complete();
    await release.future;
    return {
      for (final row in sources) row['id'] as String: [1, 0],
    };
  }
}

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

  for (final cancel in [false, true]) {
    test(
      'deferred service assignment publishes only after commit, cancelled=$cancel',
      () async {
        for (final source in store.sources)
          store.state(source['id'] as String, 'indexed');
        final domain = DeferredEmbeddingDomain(
          store,
          Helper('${root.path}/socket', '${root.path}/helper'),
        );
        final app = Application(domain);
        final observedCounts = <int>[];
        final subscription = app.changes.stream.listen(
          (_) => observedCounts.add(store.documentLabels.length),
        );
        var current = true;
        try {
          final pending = app.call('labels.auto_assign', {
            'name': 'Apollo',
          }, current: () => current);
          final checked = cancel
              ? expectLater(
                  pending,
                  throwsA(
                    isA<RpcError>().having(
                      (e) => e.code,
                      'code',
                      RpcErrorCode.cancelled,
                    ),
                  ),
                )
              : expectLater(pending, completion(2));
          await domain.entered.future;
          await Future<void>.delayed(Duration.zero);
          expect(observedCounts, isEmpty);
          if (cancel) current = false;
          domain.release.complete();
          await checked;
          await Future<void>.delayed(Duration.zero);
          expect(store.documentLabels.length, cancel ? 0 : 2);
          expect(observedCounts, [cancel ? 0 : 2]);
        } finally {
          await subscription.cancel();
          await app.close();
          domain.close();
          await domain.helper.close();
        }
      },
    );
  }

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
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
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
