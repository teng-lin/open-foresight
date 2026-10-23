import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';

void main() {
  for (final generation in [false, true]) {
    testWidgets('embedding download is explicit, generation=$generation', (
      tester,
    ) async {
      final root = createTestTempDirectorySync('embedding-prompt-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/profile.db');
      var downloads = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => GemmaSetupDialog(
                      store: fixtureReader(store),
                      savePreference: (key, value) async =>
                          store.setPreference(key, value),
                      firstRun: true,
                      needsEmbedding: true,
                      needsGeneration: generation,
                      directory: root,
                      library: '',
                      runner: '/usr/bin/true',
                      memoryGb: 24,
                      createDownload: () {
                        downloads++;
                        return GemmaDownload();
                      },
                      installEmbedding: (_, _) async =>
                          fail('No registration before confirmation'),
                      installed: (_, _) =>
                          fail('No generation before confirmation'),
                      localSetup: () {},
                    ),
                  ),
                  child: const Text('Open setup'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open setup'));
        await tester.pumpAndSettle();
        expect(find.text('EmbeddingGemma 2'), findsOneWidget);
        expect(
          find.text('485 MB download · Required for local source search'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(
            FilledButton,
            generation ? 'Download models' : 'Download EmbeddingGemma 2',
          ),
          findsOneWidget,
        );
        if (generation) {
          await tester.ensureVisible(find.text('Gemma 4 E2B'));
          await tester.tap(find.text('Gemma 4 E2B'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<RadioGroup<GemmaModel>>(
                  find.byType(RadioGroup<GemmaModel>),
                )
                .groupValue
                ?.name,
            'Gemma 4 E2B',
          );
          expect(find.text('Click to download'), findsNothing);
        }
        expect(downloads, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Open setup'), findsOneWidget);
        expect(downloads, 0);
        expect(store.rows('SELECT * FROM models'), isEmpty);
        expect(root.listSync().whereType<Directory>(), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    });
  }
}
