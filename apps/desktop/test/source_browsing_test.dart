import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:foresight_linux/domain.dart';
import 'package:foresight_linux/main.dart';
import 'package:foresight_linux/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class BrowsingStore extends Store {
  int bodyReads = 0;
  int metadataReads = 0;
  BrowsingStore(super.path);
  @override
  List<Map<String, Object?>> rows(String sql, [List<Object?> args = const []]) {
    if (sql.startsWith('SELECT sources.id,sources.title')) metadataReads++;
    return super.rows(sql, args);
  }

  @override
  List<Map<String, Object?>> get sources {
    bodyReads++;
    return super.sources;
  }
}

void main() {
  testWidgets('large source browsing avoids bodies during scrolling and progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tmp = Directory.systemTemp.createTempSync('source-browse-');
    final path = '${tmp.path}/app.db';
    final store = BrowsingStore(path);
    final text = 'needle ${'word ' * 8000}';
    final ids = <String>[];
    store.db.execute('BEGIN');
    for (var i = 0; i < 847; i++) {
      ids.add(
        store.importText(
          'Source ${i.toString().padLeft(4, '0')}',
          text,
          'text/plain',
          'fixture',
        ),
      );
    }
    store.db.execute('COMMIT');
    final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
    try {
      await tester.pumpWidget(
        Foresight(Domain(store, helper), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      final before = store.bodyReads;
      final metadataBefore = store.metadataReads;
      final timer = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        helper.changed?.call();
        await tester.pump();
      }
      final list = find.byType(ListView).last;
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        find.text('Source 0846'),
        1800,
        scrollable: scrollable,
        maxScrolls: 100,
      );
      final browseMs = timer.elapsedMilliseconds;
      expect(
        store.bodyReads,
        before,
        reason: 'Scroll and helper progress must not reload document bodies',
      );
      expect(before, 0, reason: 'Normal source entry uses only metadata');
      expect(
        store.metadataReads,
        metadataBefore,
        reason:
            'Unchanged helper progress and scrolling reuse the metadata snapshot',
      );
      expect(find.text('Source 0846'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pumpAndSettle();
      expect(store.bodyReads, 1);
      for (var i = 0; i < 20; i++) {
        helper.changed?.call();
        await tester.pump();
      }
      expect(
        store.bodyReads,
        1,
        reason: 'Unchanged searches reuse matching IDs across progress updates',
      );
      store.importText(
        'Source 0000',
        'Edited full body',
        'text/plain',
        'fixture',
        id: ids.first,
      );
      helper.changed?.call();
      await tester.pumpAndSettle();
      expect(find.text('846 of 847 shown'), findsOneWidget);
      final external = sqlite3.open(path);
      external.execute('UPDATE sources SET content=? WHERE id=?', [
        'External edit',
        ids[1],
      ]);
      external.dispose();
      helper.changed?.call();
      await tester.pumpAndSettle();
      expect(find.text('845 of 847 shown'), findsOneWidget);
      store.db.execute('BEGIN');
      store.db.execute('UPDATE sources SET title=? WHERE id=?', [
        'Temporary title',
        ids.first,
      ]);
      expect(
        store.sourceSummaries.any((s) => s['title'] == 'Temporary title'),
        true,
      );
      store.db.execute('ROLLBACK');
      expect(
        store.sourceSummaries.any((s) => s['title'] == 'Temporary title'),
        false,
      );
      await tester.ensureVisible(find.text('Clear filters'));
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Source 0000'));
      await tester.pumpAndSettle();
      expect(
        find.text('Edited full body'),
        findsOneWidget,
        reason: 'Opening a metadata row loads its current complete source',
      );
      expect(tester.takeException(), isNull);
      final report = Platform.environment['FORESIGHT_BROWSE_REPORT'];
      if (report != null)
        File(report).writeAsStringSync(
          jsonEncode({
            'sources': 847,
            'fixture_content_characters': 847 * text.length,
            'debug_test_progress_and_scroll_ms': browseMs,
            'full_body_reads_for_browsing_and_20_progress_updates': before,
            'unchanged_search_reused': true,
            'own_and_external_edits_invalidate_search': true,
            'last_source_reachable': true,
            'selected_source_body_loaded_on_demand': true,
            'scope':
                'Synthetic Flutter widget regression; not native release frame timing',
          }),
        );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      tmp.deleteSync(recursive: true);
    }
  });
}
