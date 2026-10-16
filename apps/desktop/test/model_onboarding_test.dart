import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight/gemma_download.dart';
import 'package:foresight/gemma_setup_view.dart';
import 'package:foresight/model_setup.dart';
import 'package:foresight/store.dart';

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
      final root = Directory.systemTemp.createTempSync(
        'foresight-model-missing-',
      );
      final store = Store('${root.path}/app.db');
      try {
        final file = File('${root.path}/embedding.litertlm')
          ..writeAsStringSync('fixture');
        await store.register('embedding', file.path, '');
        expect(needsModel(store, 'embedding'), false);
        file.deleteSync();
        expect(needsModel(store, 'embedding'), true);
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
      final root = Directory.systemTemp.createTempSync('foresight-onboarding-');
      final store = Store('${root.path}/app.db');
      final generation = File('${root.path}/generation.litertlm')
        ..writeAsStringSync('existing');
      final embedding = File('${root.path}/embedding.litertlm')
        ..writeAsStringSync('download fixture');
      final download = LocalDownload(embedding);
      var loaded = false;
      await tester.runAsync(
        () => store.register('generation', generation.path, '/bin/true'),
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
                      store: store,
                      directory: root,
                      library: '',
                      runner: '/bin/true',
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
        expect(find.text('Set up local source search'), findsOneWidget);
        expect(find.byType(RadioListTile<GemmaModel>), findsNothing);
        await tester.runAsync(() async {
          await tester.tap(find.text('Continue'));
          for (var i = 0; i < 100 && !loaded; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
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
