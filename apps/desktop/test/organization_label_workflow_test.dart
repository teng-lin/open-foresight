import 'desktop_connection_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/graph_labels.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  test(
    'replacement writes all association fields and cluster update preserves ID and nullable data',
    () {
      final dir = Directory.systemTemp.createTempSync(
        'foresight-cluster-write-',
      );
      final store = Store('${dir.path}/app.db');
      final id = store.importText('Title', 'Body', 'text/plain', 'fixture');
      store.putDocumentLabel(
        DocumentLabel(id, 'Alpha', 'user_defined', '#0EBC5F', 'old'),
      );
      store.putDocumentLabel(
        DocumentLabel(id, 'Alpha', 'propagated', '#60D5F3', 'new'),
      );
      expect(store.documentLabels.single.source, 'propagated');
      expect(store.documentLabels.single.rationale, 'new');
      expect(jsonDecode(store.sources.single['labels'] as String), ['Alpha']);
      store.saveLabelCluster('Alpha');
      final cluster = store.rows('SELECT * FROM document_clusters').single;
      expect(cluster['radius'], 90);
      expect(cluster['summary'], isNull);
      expect(cluster['centroid_embedding'], isNull);
      store.db.execute(
        "UPDATE document_clusters SET summary='Keep summary',center_proj_x=50,radius=250",
      );
      store.saveLabelCluster('Alpha');
      final saved = store.rows('SELECT * FROM document_clusters').single;
      expect(saved['cluster_id'], cluster['cluster_id']);
      expect(saved['summary'], 'Keep summary');
      expect(saved['center_proj_x'], 0);
      expect(saved['radius'], 90);
      store.close();
      dir.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'global label creation uses all documents despite active search and deletion requires confirmation',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync(
        'foresight-label-workflow-',
      );
      final store = Store('${dir.path}/app.db');
      final a = store.importText(
        'Apollo planning',
        'Unrelated body',
        'text/plain',
        'fixture:a',
      );
      final b = store.importText(
        'Borealis budget',
        'Unrelated body',
        'text/plain',
        'fixture:b',
      );
      final helper = OfflineHelper('${dir.path}/socket', '${dir.path}/helper');
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(Domain(store, helper)), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Borealis');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add label'));
      await tester.pumpAndSettle();
      expect(find.text('Create New Organization Label'), findsOneWidget);
      await tester.tap(find.text('Create & Auto-Assign'));
      await tester.pumpAndSettle();
      expect(find.text('Create New Organization Label'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Apollo');
      await tester.tap(find.text('Create & Auto-Assign'));
      final dynamic state = tester.state(find.byType(Workspace));
      for (
        var i = 0;
        i < 100 &&
            (state.busy ||
                store.rows('SELECT * FROM document_clusters').isEmpty);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(state.error, isEmpty);
      expect(store.documentLabels.single.documentId, a);
      expect(store.documentLabels.single.name, 'Apollo');
      expect(store.documentLabels.where((r) => r.documentId == b), isEmpty);
      final chip = find.widgetWithText(FilterChip, 'Apollo');
      await tester.tap(
        find.descendant(of: chip, matching: find.byType(Icon)).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete Label'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.documentLabels, isNotEmpty);
      await tester.tap(
        find.descendant(of: chip, matching: find.byType(Icon)).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store.documentLabels, isEmpty);
      expect(store.rows('SELECT * FROM document_clusters'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await helper.close();
      dir.deleteSync(recursive: true);
    },
  );
}
