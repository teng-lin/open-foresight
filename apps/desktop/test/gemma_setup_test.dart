import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_linux/gemma_download.dart';
import 'package:foresight_linux/gemma_setup_view.dart';
import 'package:foresight_linux/store.dart';

void main() {
  testWidgets('14 GB host offers E2B and prevents larger model installation', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('gemma-chooser-');
    final store = Store('${root.path}/app.db');
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              store: store,
              directory: root,
              library: '',
              runner: '',
              memoryGb: 14,
              installed: (_, _) => fail('No model should be installed'),
              localSetup: () {},
            ),
          ),
        ),
      );
      final options = tester
          .widgetList<RadioListTile<GemmaModel>>(
            find.byType(RadioListTile<GemmaModel>),
          )
          .toList();
      expect(options.map((o) => o.value.name), [
        'Gemma 4 12B',
        'Gemma 4 E4B',
        'Gemma 4 E2B',
      ]);
      expect(options.map((o) => o.enabled), [false, false, true]);
      final group = tester.widget<RadioGroup<GemmaModel>>(
        find.byType(RadioGroup<GemmaModel>),
      );
      expect(group.groupValue?.name, 'Gemma 4 E2B');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
            .onPressed,
        isNull,
      );
      expect(
        find.text('Set up the local Gemma runner before downloading.'),
        findsOneWidget,
      );
      expect(store.rows('SELECT * FROM models'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    } finally {
      store.close();
      root.deleteSync(recursive: true);
    }
  });
}
