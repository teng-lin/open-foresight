import 'fixtures/setup_process.dart';
import 'store_reader_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';
import 'package:open_foresight/features/settings/speech_setup_view.dart';

import 'controller_fixture.dart' show ReadyGeneration;
import 'pump_until.dart';

class FixtureDownload extends GemmaDownload {
  final File asset;
  final calls = <GemmaModel>[];
  Object? failure;
  bool cancelled = false;
  FixtureDownload(this.asset);
  @override
  void cancel() {
    cancelled = true;
    super.cancel();
  }

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
    for (final value in ModelDownloadPhase.values) {
      phase?.call(value);
    }
    progress?.call(model.bytes ~/ 2, model.bytes);
    if (failure != null) throw failure!;
    progress?.call(model.bytes, model.bytes);
    return asset;
  }
}

void main() {
  for (final speech in [false, true]) {
    group(speech ? 'speech installation' : 'Gemma installation', () {
      late Directory root;
      late Store store;
      late FixtureDownload download;
      late ReadyGeneration runtime;
      int installed = 0, finished = 0;
      Completer<void>? loading;
      bool Function()? current;
      Object? loadFailure;
      setUp(() {
        root = createTestTempDirectorySync('install-ui-');
        store = Store('${root.path}/app.db');
        download = FixtureDownload(
          File('${root.path}/fixture')
            ..writeAsStringSync('UI installer fixture'),
        );
        runtime = ReadyGeneration();
        installed = finished = 0;
        loading = null;
        current = null;
        loadFailure = null;
        for (final model in [...speechModels, ...gemmaModels]) {
          store.setPreference(
            'modelTerms.${model.repository}.${model.revision}',
            'accepted',
          );
        }
      });
      tearDown(() {
        store.close();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      Future<void> mount(WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        Future<void> load(bool Function() active) async {
          current = active;
          if (loadFailure != null) throw loadFailure!;
          await loading?.future;
        }

        final widget = speech
            ? SpeechSetupDialog(
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
                directory: root,
                runner: '/usr/bin/true',
                createDownload: () => download,
                onDone: () => finished++,
                findLocalModel: (model, directory, {registration}) async =>
                    null,
                installSpeech: (asset, runner, digest, active) async {
                  expect(asset.path, download.asset.path);
                  expect(runner, '/usr/bin/true');
                  expect(speechModels.any((m) => m.digest == digest), true);
                  await load(active);
                },
                installed: () => installed++,
              )
            : GemmaSetupDialog(
                environment: setupEnvironment(),
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
                directory: root,
                library: '',
                runner: '/usr/bin/true',
                memoryGb: 64,
                createDownload: () => download,
                onDone: () => finished++,
                findLocalModel: (model, directory, {registration}) async =>
                    null,
                installGeneration: (path, runner, active) async {
                  await load(active);
                  return runtime;
                },
                installed: (_, _) => installed++,
                localSetup: () {},
              );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: widget)),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> start(WidgetTester tester) async {
        final button = find.byType(FilledButton);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 300));
      }

      testWidgets(
        'waits for adoption before completing and prevents duplicate installation',
        (tester) async {
          loading = Completer<void>();
          await mount(tester);
          await start(tester);
          await pumpUntil(tester, () => current != null);
          expect(current!(), true);
          expect(installed, 0);
          expect(finished, 0);
          expect(download.calls, hasLength(1));
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          loading!.complete();
          await pumpUntil(tester, () => finished == 1);
          expect(installed, 1);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets('load failure remains visible and retry can complete', (
        tester,
      ) async {
        loadFailure = StateError(
          'Model adoption failed /private/model-canary?token=secret-canary',
        );
        await mount(tester);
        await start(tester);
        await pumpUntil(
          tester,
          () => find
              .text(
                'Unable to download or load this model. Retry or use local model setup.',
              )
              .evaluate()
              .isNotEmpty,
        );
        expect(find.textContaining('Model adoption failed'), findsNothing);
        expect(find.textContaining('model-canary'), findsNothing);
        expect(find.textContaining('secret-canary'), findsNothing);
        expect(installed, 0);
        expect(finished, 0);
        loadFailure = null;
        await start(tester);
        await pumpUntil(tester, () => finished == 1);
        expect(installed, 1);
        expect(download.calls, hasLength(2));
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets(
        'download cancellation completes no installation and permits retry',
        (tester) async {
          download.failure = ModelDownloadCancelled();
          await mount(tester);
          await start(tester);
          await pumpUntil(
            tester,
            () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
          );
          expect(installed, 0);
          expect(finished, 0);
          download.failure = null;
          await start(tester);
          await pumpUntil(tester, () => finished == 1);
          expect(installed, 1);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'disposing while loading invalidates adoption and cancels owned download',
        (tester) async {
          loading = Completer<void>();
          await mount(tester);
          await start(tester);
          await pumpUntil(tester, () => current != null);
          await tester.pumpWidget(const SizedBox());
          expect(current!(), false);
          expect(download.cancelled, true);
          loading!.complete();
          await tester.pumpAndSettle();
          if (!speech) expect(runtime.closed, true);
          expect(installed, 0);
          expect(finished, 0);
          expect(tester.takeException(), isNull);
        },
      );
    });
  }
}
