import 'store_reader_fixture.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/gemma_download.dart';
import 'package:open_foresight/gemma_setup_view.dart';
import 'package:foresight_core/src/speech_models.dart';
import 'package:open_foresight/speech_setup_view.dart';
import 'package:foresight_core/src/store.dart';
import 'fixtures/verified_model_files.dart';

void main() {
  for (final speech in [false, true]) {
    testWidgets(
      'embedded ${speech ? 'speech' : 'Gemma'} setup reuses the current model and advances without popping the page',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final root = createTestTempDirectorySync('of-embed-');
        final store = Store('${root.path}/app.db');
        final model = speech ? speechModels.first : gemmaModels.first;
        final file = File('${root.path}/current.bin');
        file.openSync(mode: FileMode.write)
          ..truncateSync(model.bytes)
          ..closeSync();
        final runner = File('${root.path}/runner')
          ..writeAsStringSync('#!/bin/sh\nexit 99\n');
        Process.runSync('/bin/chmod', ['700', runner.path]);
        store.db.execute(
          'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
          [
            speech ? 'speech' : 'generation',
            file.path,
            model.digest,
            runner.path,
            speech ? 'whisper_cpp' : 'litert_lm',
          ],
        );
        var advances = 0;
        final installer = speech
            ? SpeechSetupDialog(
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
                directory: root,
                runner: runner.path,
                findLocalModel: verifiedFixtureModelFile,
                onDone: () => advances++,
                installed: () => fail('Current model must be reused'),
              )
            : GemmaSetupDialog(
                store: fixtureReader(store),
                savePreference: (key, value) async =>
                    store.setPreference(key, value),
                directory: root,
                library: '',
                runner: runner.path,
                memoryGb: 64,
                findLocalModel: verifiedFixtureModelFile,
                onDone: () => advances++,
                installed: (_, _) => fail('Current model must be reused'),
                localSetup: () => fail('Must remain in onboarding'),
              );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: installer)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Cancel'), findsNothing);
          expect(find.text('Done'), findsOneWidget);
          if (speech)
            expect(
              find.byType(RadioListTile<GemmaModel>),
              findsNWidgets(speechModels.length),
            );
          await tester.ensureVisible(find.text('Done'));
          await tester.tap(find.text('Done'));
          await tester.pumpAndSettle();
          expect(advances, 1);
          expect(find.byWidget(installer), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          store.close();
        }
      },
    );
  }
}
