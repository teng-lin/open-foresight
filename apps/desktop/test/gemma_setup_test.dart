import 'fixtures/verified_model_files.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/gemma_download.dart';
import 'package:open_foresight/gemma_setup_view.dart';
import 'package:open_foresight/store.dart';

void main() {
  testWidgets('missing runner reuses a registered model outside the cache', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('gemma-runner-repair-');
    final store = Store('${root.path}/application.db');
    final model = gemmaModels.first;
    final file = File('${root.path}/custom.litertlm');
    file.openSync(mode: FileMode.write)
      ..truncateSync(model.bytes)
      ..closeSync();
    store.db.execute(
      'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
      ['generation', file.path, model.digest, '/missing/runner', 'litert_lm'],
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              findLocalModel: verifiedFixtureModelFile,
              store: store,
              directory: Directory('${root.path}/cache'),
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 64,
              installed: (_, _) {},
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Use model'), findsOneWidget);
      final option = tester.widget<RadioListTile<GemmaModel>>(
        find.byWidgetPredicate(
          (w) => w is RadioListTile<GemmaModel> && w.value == model,
        ),
      );
      expect(option.secondary, isNull);
      expect(find.text('Done'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      store.close();
      root.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'cached embedding setup offers reuse instead of another download',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('embedding-cache-ui-');
      final store = Store('${root.path}/application.db');
      final model = embeddingGemmaModel;
      final file = File(
        '${root.path}/embeddinggemma2/${model.directory}/${model.filename}',
      )..createSync(recursive: true);
      file.openSync(mode: FileMode.write)
        ..truncateSync(model.bytes)
        ..closeSync();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GemmaSetupDialog(
                findLocalModel: verifiedFixtureModelFile,
                store: store,
                directory: Directory('${root.path}/gemma4'),
                library: '',
                runner: '/usr/bin/true',
                memoryGb: 16,
                needsEmbedding: true,
                needsGeneration: false,
                installed: (_, _) {},
                localSetup: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(FilledButton, 'Use EmbeddingGemma 2'),
          findsOneWidget,
        );
        expect(find.text('Download EmbeddingGemma 2'), findsNothing);
        expect(
          find.text('Downloaded · Ready to use for local source search'),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );

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
              findLocalModel: verifiedFixtureModelFile,
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
      await tester.pumpAndSettle();
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
  testWidgets(
    'current E4B closes with Done without verification, loading or download',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('gemma-current-');
      final store = Store('${root.path}/app.db');
      final model = gemmaModels[1];
      final file = File('${root.path}/${model.filename}');
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(
        model.bytes,
      ); // Sparse fixture; never hash or load it.
      handle.closeSync();
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
        ['generation', file.path, model.digest, '/usr/bin/true', 'litert_lm'],
      );
      final before = store.rows('SELECT * FROM models').single;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => GemmaSetupDialog(
                      findLocalModel: verifiedFixtureModelFile,
                      store: store,
                      directory: root,
                      library: '',
                      runner: '',
                      memoryGb: 15,
                      createDownload: () => throw StateError(
                        'Must not start work for the current model',
                      ),
                      installed: (_, _) =>
                          fail('Must not reload the current model'),
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
        final current = tester.widget<RadioListTile<GemmaModel>>(
          find.byWidgetPredicate(
            (w) => w is RadioListTile<GemmaModel> && w.value == model,
          ),
        );
        expect(current.secondary, isNull);
        expect(find.text('Click to download'), findsNWidgets(2));
        final done = find.widgetWithText(FilledButton, 'Done');
        expect(tester.widget<FilledButton>(done).onPressed, isNotNull);
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byType(GemmaSetupDialog), findsNothing);
        expect(store.rows('SELECT * FROM models').single, before);
        await tester.pumpWidget(const SizedBox());
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  testWidgets('downloaded inactive model has no download action on the right', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('gemma-cached-');
    final store = Store('${root.path}/app.db');
    final model = gemmaModels.last;
    final file = File('${root.path}/${model.directory}/${model.filename}');
    file.parent.createSync(recursive: true);
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(model.bytes);
    handle.closeSync();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              findLocalModel: verifiedFixtureModelFile,
              store: store,
              directory: root,
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 14,
              installed: (_, _) => fail('No activation requested'),
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cached = tester.widget<RadioListTile<GemmaModel>>(
        find.byWidgetPredicate(
          (w) => w is RadioListTile<GemmaModel> && w.value == model,
        ),
      );
      expect(cached.secondary, isNull);
      expect(find.text('Click to download'), findsNWidgets(2));
      expect(find.widgetWithText(FilledButton, 'Use model'), findsOneWidget);
      expect(store.rows('SELECT * FROM models'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    } finally {
      store.close();
      root.deleteSync(recursive: true);
    }
  });
}
