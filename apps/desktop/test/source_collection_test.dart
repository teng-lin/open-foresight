import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/domain.dart';
import 'package:foresight_linux/main.dart';
import 'package:foresight_linux/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets(
    '847 sources remain reachable in list and grid with type filters',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final tmp = Directory.systemTemp.createTempSync('source-collection-');
      final store = Store('${tmp.path}/app.db');
      for (var i = 0; i < 847; i++) {
        final id = store.importText(
          'Source ${i.toString().padLeft(4, '0')}',
          'Controlled source $i',
          i < 59 ? 'application/pdf' : 'text/plain',
          'fixture',
        );
        store.db.execute("UPDATE sources SET state='indexed' WHERE id=?", [id]);
        if (i == 0) store.labels(id, ['Fixture label']);
      }
      final helper = OfflineHelper('${tmp.path}/socket', '${tmp.path}/helper');
      try {
        Future<void> tapVisible(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          Foresight(Domain(store, helper), deviceLoader: () async => []),
        );
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        expect(
          find.text('847 sources identified, 847 indexed'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ListView>(find.byType(ListView).last)
              .childrenDelegate
              .estimatedChildCount,
          849,
        );
        Future<void> reachLastSource(Type viewType) async {
          final scrollable = find
              .descendant(
                of: find.byType(viewType).last,
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(
            find.text('Source 0846'),
            1800,
            scrollable: scrollable,
            maxScrolls: 100,
          );
          expect(find.text('Source 0846'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        await reachLastSource(ListView);
        await tapVisible(find.byTooltip('Grid view'));
        await reachLastSource(GridView);
        await tapVisible(find.byTooltip('PDF: 59'));
        expect(
          tester
              .widget<GridView>(find.byType(GridView).last)
              .childrenDelegate
              .estimatedChildCount,
          59,
        );
        expect(
          find.text('847 sources identified, 847 indexed'),
          findsOneWidget,
        );
        expect(find.text('59 of 847 shown'), findsOneWidget);
        await tapVisible(find.widgetWithText(FilterChip, 'All 847'));
        await tester.enterText(find.byType(TextField), 'Source 000');
        await tester.pumpAndSettle();
        expect(find.text('10 of 847 shown'), findsOneWidget);
        await tester.tap(find.text('Stats'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'Source 000',
          reason: 'An active search must remain visible after navigation',
        );
        await tapVisible(find.byTooltip('PDF: 59'));
        await tapVisible(find.widgetWithText(FilterChip, 'Fixture label'));
        expect(find.text('1 of 847 shown'), findsOneWidget);
        await tapVisible(find.text('Clear filters'));
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<GridView>(find.byType(GridView).last)
              .childrenDelegate
              .estimatedChildCount,
          847,
        );
        expect(find.text('Clear filters'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await helper.close();
        tmp.deleteSync(recursive: true);
      }
    },
  );
}
