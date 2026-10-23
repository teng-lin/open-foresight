import 'fixtures/setup_process.dart';
import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';
import 'package:foresight_core/desktop.dart'
    show StoreReadQueries, preparedNeedsModel;
import '../test_support/current_read.dart';

class LocalDownload extends GemmaDownload {
  final File asset;
  final calls = <GemmaModel>[];
  LocalDownload(this.asset);
  @override
  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int, int)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  }) async {
    calls.add(model);
    progress?.call(model.bytes, model.bytes);
    return asset;
  }
}

void main() {
  test(
    'a missing model file reopens setup without discarding its registration',
    () async {
      final root = createTestTempDirectorySync('foresight-model-missing-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/app.db');
      try {
        final file = File('${root.path}/embedding.litertlm')
          ..writeAsStringSync('fixture');
        await store.register('embedding', file.path, '');
        expect(
          preparedNeedsModel(
            await currentRead(
              fixtureReader(store),
              StoreReadQueries.model('embedding'),
            ),
            'embedding',
          ),
          false,
        );
        file.deleteSync();
        expect(
          preparedNeedsModel(
            await currentRead(
              fixtureReader(store),
              StoreReadQueries.model('embedding'),
            ),
            'embedding',
          ),
          true,
        );
        expect(store.rows('SELECT * FROM models'), hasLength(1));
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'embedding-only recovery loads before completion and preserves generation',
    (tester) async {
      final root = createTestTempDirectorySync('foresight-onboarding-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = Store('${root.path}/app.db');
      final generation = File('${root.path}/generation.litertlm')
        ..writeAsStringSync('existing');
      final embedding = File('${root.path}/embedding.litertlm')
        ..writeAsStringSync('download fixture');
      final download = LocalDownload(embedding);
      store.setPreference(
        'modelTerms.${embeddingGemmaModel.repository}.${embeddingGemmaModel.revision}',
        'accepted',
      );
      var loaded = false;
      await tester.runAsync(
        () => store.register('generation', generation.path, '/usr/bin/true'),
      );
      final previous = store
          .rows("SELECT * FROM models WHERE kind='generation'")
          .single;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => GemmaSetupDialog(
                      environment: setupEnvironment(),
                      store: fixtureReader(store),
                      savePreference: (key, value) async =>
                          store.setPreference(key, value),
                      directory: root,
                      library: '',
                      runner: '/usr/bin/true',
                      memoryGb: 4,
                      firstRun: true,
                      needsEmbedding: true,
                      needsGeneration: false,
                      createDownload: () => download,
                      installEmbedding: (file, current) async {
                        expect(current(), true);
                        expect(file.path, embedding.path);
                        await store.register(
                          'embedding',
                          file.path,
                          '',
                          backend: 'litert_lm_embedding_gpu',
                        );
                        loaded = true;
                      },
                      installed: (_, _) =>
                          fail('Existing generation must be retained'),
                      localSetup: () {},
                    ),
                  ),
                  child: const Text('Setup'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Setup'));
        await tester.pumpAndSettle();
        expect(find.text('EmbeddingGemma 2'), findsOneWidget);
        expect(find.byType(RadioListTile<GemmaModel>), findsNothing);
        await tester.runAsync(() async {
          await tester.tap(
            find.widgetWithText(FilledButton, 'Download EmbeddingGemma 2'),
          );
          await eventually(() => loaded);
        });
        await tester.pumpAndSettle();
        expect(loaded, true);
        expect(download.calls, [embeddingGemmaModel]);
        expect(find.byType(GemmaSetupDialog), findsNothing);
        expect(
          store.rows("SELECT * FROM models WHERE kind='generation'").single,
          previous,
        );
        await tester.pumpWidget(const SizedBox());
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
