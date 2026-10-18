import 'fixtures/verified_model_files.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/speech_models.dart';
import 'package:open_foresight/speech_setup_view.dart';
import 'package:open_foresight/store.dart';

void main() {
  testWidgets(
    'active speech model finishes without probing; deleted asset offers download',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('speech-ui-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final store = Store('${directory.path}/app.db');
      final model = speechModels.first;
      final asset = File('${directory.path}/active.bin');
      final handle = asset.openSync(mode: FileMode.write);
      handle.truncateSync(model.bytes);
      handle.closeSync();
      final runner = File('${directory.path}/runner')
        ..writeAsStringSync('#!/bin/sh\nexit 98\n');
      await tester.runAsync(() => Process.run('chmod', ['+x', runner.path]));
      store.db.execute(
        'INSERT INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
        ['speech', asset.path, model.digest, runner.path, 'llama_cpp'],
      );
      var installed = false;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SpeechSetupDialog(
                  findLocalModel: verifiedFixtureModelFile,
                  store: store,
                  directory: directory,
                  runner: runner.path,
                  installed: () => installed = true,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(app());
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Done'), findsOneWidget);
        expect(find.text('Click to download'), findsNWidgets(4));
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Transcription Model'), findsNothing);
        expect(installed, false);
        asset.deleteSync();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Done'), findsNothing);
        expect(find.text('Click to download'), findsNWidgets(5));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox());
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
