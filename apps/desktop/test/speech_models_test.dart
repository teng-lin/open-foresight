import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/speech_models.dart';
import 'package:open_foresight/gemma_download.dart';
import 'package:open_foresight/store.dart';

void main() {
  test('speech candidates are pinned multilingual models', () {
    expect(speechModels.length, 5);
    expect(speechModels.any((m) => m.filename.contains('.en')), false);
    expect(
      speechModels.map((m) => m.filename),
      contains('ggml-large-v3-turbo.bin'),
    );
    for (final model in speechModels) {
      expect(model.digest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(model.revision, matches(RegExp(r'^[a-f0-9]{40}$')));
    }
  });
  test(
    'download reuses verified speech .bin without creating a client',
    () async {
      final root = Directory.systemTemp.createTempSync('speech-reuse-');
      final bytes = [1, 2, 3, 4];
      final model = GemmaModel(
        'fixture',
        '',
        '',
        'fixture.bin',
        sha256.convert(bytes).toString(),
        bytes.length,
        0,
      );
      final file = File('${root.path}/${model.directory}/${model.filename}');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      try {
        final reused = await GemmaDownload(
          createClient: () => throw StateError('must not download'),
        ).download(model, root);
        expect(reused.path, file.path);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'registration follows load and preserves old on failure or cancellation',
    () async {
      final root = Directory.systemTemp.createTempSync('speech-setup-test-');
      final store = Store('${root.path}/app.db');
      final old = File('${root.path}/old.bin')..writeAsStringSync('old model');
      final asset = File('${root.path}/model.bin')
        ..writeAsStringSync('candidate');
      final runner = File('${root.path}/runner');
      Future<void> script(String body) async {
        runner.writeAsStringSync('#!/bin/sh\n$body\n');
        await Process.run('chmod', ['+x', runner.path]);
      }

      final digest = sha256.convert(asset.readAsBytesSync()).toString();
      try {
        await script('exit 1');
        await store.register('speech', old.path, runner.path);
        await expectLater(
          configureSpeech(
            store,
            asset,
            runner.path,
            digest,
            current: () => true,
          ),
          throwsStateError,
        );
        expect(
          store
              .rows("SELECT path FROM models WHERE kind='speech'")
              .single['path'],
          old.path,
        );
        await script('exit 0');
        await expectLater(
          configureSpeech(
            store,
            asset,
            runner.path,
            digest,
            current: () => false,
          ),
          throwsA(anything),
        );
        expect(
          store
              .rows("SELECT path FROM models WHERE kind='speech'")
              .single['path'],
          old.path,
        );
        await configureSpeech(
          store,
          asset,
          runner.path,
          digest,
          current: () => true,
        );
        expect(
          store
              .rows("SELECT path FROM models WHERE kind='speech'")
              .single['path'],
          asset.path,
        );
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
