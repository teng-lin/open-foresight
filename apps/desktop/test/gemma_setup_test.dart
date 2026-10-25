import 'fixtures/setup_process.dart';
import 'store_reader_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'fixtures/verified_model_files.dart';
import 'dart:io';
import 'dart:async';
import 'pump_until.dart';
import 'controller_fixture.dart' show ReadyGeneration;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';

void main() {
  testWidgets(
    'Done rejects a corrupt registered candidate and requires download consent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = createTestTempDirectorySync('gemma-current-corrupt-');
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final model = gemmaModels.last;
      final file = File('${root.path}/registered.litertlm')..createSync();
      file.openSync(mode: FileMode.write)
        ..truncateSync(model.bytes)
        ..closeSync();
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
        ['generation', file.path, model.digest, '/usr/bin/true', 'litert_lm'],
      );
      final before = store.rows('SELECT * FROM models').single;
      var verifications = 0, finished = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              environment: setupEnvironment(),
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
              directory: root,
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 64,
              findLocalModel: (model, directory, {registration}) async {
                verifications++;
                return null;
              },
              createDownload: () => GemmaDownload(
                createClient: () => throw StateError(
                  'Must obtain consent before downloading a replacement',
                ),
              ),
              onDone: () => finished = true,
              installed: (_, _) =>
                  fail('A corrupt registered file must not be loaded'),
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(verifications, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntil(
        tester,
        () => find.text('${model.name} terms').evaluate().isNotEmpty,
      );
      expect(verifications, 1);
      expect(finished, isFalse);
      expect(find.textContaining('Current model'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(finished, isFalse);
      expect(store.rows('SELECT * FROM models').single, before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'activation verifies a local model once and reuses it without downloading',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = createTestTempDirectorySync('gemma-local-activation-');
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final model = gemmaModels.last;
      final file = File('${root.path}/${model.directory}/${model.filename}')
        ..createSync(recursive: true);
      file.openSync(mode: FileMode.write)
        ..truncateSync(model.bytes)
        ..closeSync();
      var verifications = 0, installs = 0, finishes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
              environment: setupEnvironment(),
              directory: root,
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 64,
              findLocalModel: (model, directory, {registration}) async {
                verifications++;
                return verifiedFixtureModelFile(
                  model,
                  directory,
                  registration: registration,
                );
              },
              createDownload: () => GemmaDownload(
                createClient: () => throw StateError(
                  'Verified local models must not use the network',
                ),
              ),
              installGeneration: (path, runner, current) async {
                expect(verifications, 1);
                expect(path, file.path);
                expect(current(), isTrue);
                installs++;
                return ReadyGeneration();
              },
              onDone: () => finishes++,
              installed: (_, chosen) => expect(chosen, model),
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(verifications, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Use model'));
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntil(tester, () => finishes == 1);
      expect(verifications, 1);
      expect(installs, 1);
      expect(find.text('${model.name} terms'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selection stays available during discovery and is not overwritten',
    (tester) async {
      final root = createTestTempDirectorySync('gemma-discovery-');
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final discovery = Completer<File?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
              environment: setupEnvironment(),
              directory: root,
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 64,
              findLocalCandidate: (model, directory, {registration}) =>
                  discovery.future,
              findLocalModel: (model, directory, {registration}) =>
                  throw StateError('Opening the chooser must not hash files'),
              installed: (_, _) => fail('No installation requested'),
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Checking local files…'), findsNWidgets(3));
      await tester.tap(find.text('Gemma 4 E4B'));
      await tester.pump();
      final group = find.byType(RadioGroup<GemmaModel>);
      expect(
        tester.widget<RadioGroup<GemmaModel>>(group).groupValue,
        gemmaModels[1],
      );
      discovery.complete(null);
      await tester.pumpAndSettle();
      expect(
        tester.widget<RadioGroup<GemmaModel>>(group).groupValue,
        gemmaModels[1],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local file is verified only on activation and corruption requires download consent',
    (tester) async {
      final root = createTestTempDirectorySync('gemma-discovery-integrity-');
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final model = gemmaModels.last;
      final file = File('${root.path}/${model.directory}/${model.filename}')
        ..createSync(recursive: true);
      file.openSync(mode: FileMode.write)
        ..truncateSync(model.bytes)
        ..closeSync();
      var verifications = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
              environment: setupEnvironment(),
              directory: root,
              library: '',
              runner: '/usr/bin/true',
              memoryGb: 64,
              findLocalModel: (model, directory, {registration}) async {
                verifications++;
                return null;
              },
              installed: (_, _) => fail('Corrupt model must not be loaded'),
              localSetup: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(verifications, 0);
      expect(
        find.textContaining('Found locally; verified before use'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use model'));
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntil(tester, () => verifications > 0);
      await pumpUntil(
        tester,
        () => find.text('${model.name} terms').evaluate().isNotEmpty,
      );
      expect(verifications, 1);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(store.model('generation'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final firstRun in [true, false]) {
    testWidgets(
      'fresh setup defaults to E2B with 64 GB RAM (firstRun: $firstRun)',
      (tester) async {
        final root = createTestTempDirectorySync('gemma-default-');
        final store = Store('${root.path}/app.db');
        addTearDown(store.close);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GemmaSetupDialog(
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
                environment: setupEnvironment(),
                directory: root,
                library: '',
                runner: '/usr/bin/true',
                memoryGb: 64,
                firstRun: firstRun,
                needsEmbedding: true,
                installed: (_, _) => fail('No installation requested'),
                localSetup: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final group = find.byType(RadioGroup<GemmaModel>);
        expect(
          tester.widget<RadioGroup<GemmaModel>>(group).groupValue,
          gemmaModels.last,
        );
        await tester.tap(find.text('Gemma 4 E4B'));
        await tester.pump();
        expect(
          tester.widget<RadioGroup<GemmaModel>>(group).groupValue,
          gemmaModels[1],
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Download models'),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('missing runner reuses a registered model outside the cache', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('gemma-runner-repair-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
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
              environment: setupEnvironment(),
              findLocalModel: verifiedFixtureModelFile,
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
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
      final root = createTestTempDirectorySync('embedding-cache-ui-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
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
                environment: setupEnvironment(),
                findLocalModel: verifiedFixtureModelFile,
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
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
          find.text('Found locally · Checksum verified before use'),
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
    final root = createTestTempDirectorySync('gemma-chooser-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = Store('${root.path}/app.db');
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GemmaSetupDialog(
              environment: setupEnvironment(),
              findLocalModel: verifiedFixtureModelFile,
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
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
      expect(options.map((o) => o.enabled), [true, true, true]);
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
    'current E4B waits for Done verification without loading or downloading',
    (tester) async {
      final root = createTestTempDirectorySync('gemma-current-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
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
      final verification = Completer<File?>();
      var verifications = 0;
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
                      findLocalModel: (model, directory, {registration}) {
                        verifications++;
                        return verification.future;
                      },
                      store: fixtureReader(store),
                      savePreference: (key, value) async =>
                          store.setPreference(key, value),
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
        expect(verifications, 0);
        expect(tester.widget<FilledButton>(done).onPressed, isNotNull);
        await tester.tap(done);
        await tester.pump();
        expect(verifications, 1);
        expect(find.byType(GemmaSetupDialog), findsOneWidget);
        expect(tester.widget<FilledButton>(done).onPressed, isNull);
        verification.complete(file);
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
    final root = createTestTempDirectorySync('gemma-cached-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
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
              environment: setupEnvironment(),
              findLocalModel: verifiedFixtureModelFile,
              store: fixtureReader(store),
              savePreference: (key, value) async =>
                  store.setPreference(key, value),
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
