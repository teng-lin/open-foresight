import 'desktop_fixture_owner.dart';
import 'package:foresight_core/desktop.dart' show Citation;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controller_fixture.dart';

void main() {
  testWidgets(
    'opening a local citation leaves its source edit action available',
    (tester) async => withDesktopFixtures(tester, () async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.importText(
        'Cited source',
        'Original evidence',
        'text/plain',
        'fixture',
      );
      f.shell.chatFeature.cite(
        Citation.fromRow({
          'document_id': id,
          'revision': 1,
          'excerpt': 'Original evidence',
        }),
      );
      await tester.pumpAndSettle();
      final edit = find.widgetWithText(TextButton, 'Edit source');
      expect(edit, findsOneWidget);
      expect(tester.widget<TextButton>(edit).onPressed, isNotNull);
      expect(f.shell.busy, false);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.text('Save and index'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(f.store.sourceById(id).single['revision'], 1);
      expect(tester.takeException(), isNull);
    }),
  );
}
