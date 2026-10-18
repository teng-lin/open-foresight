import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/store.dart';

void main() {
  test(
    'verified embedding bundle installs GPU selection without replacing user models',
    () async {
      final temporary = createTestTempDirectorySync('foresight-model-install-');
      addTearDown(() {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
      final store = Store('${temporary.path}/app.db');
      final bundle = File('${temporary.path}/embedding.litertlm')
        ..writeAsStringSync('installation fixture');
      final manifest = File('${temporary.path}/installed.json');
      void write(String digest, String backend) => manifest.writeAsStringSync(
        jsonEncode({
          'embedding': {
            'model': bundle.path,
            'sha256': digest,
            'backend': backend,
          },
        }),
      );
      try {
        write('invalid digest', 'litert_lm_embedding_gpu');
        await expectLater(
          registerInstalledModels(store, manifest.path),
          throwsStateError,
        );
        expect(store.rows('SELECT * FROM models'), isEmpty);
        final digest = sha256.convert(bundle.readAsBytesSync()).toString();
        write(digest, 'litert_lm_embedding_gpu');
        expect(await registerInstalledModels(store, manifest.path), 1);
        final installed = store.rows('SELECT * FROM models').single;
        expect(installed['digest'], digest);
        expect(installed['backend'], 'litert_lm_embedding_gpu');
        expect(installed['runtime'], '');
        final replacement = File('${temporary.path}/replacement.litertlm')
          ..writeAsStringSync('different model bytes');
        await expectLater(
          store.register(
            'embedding',
            replacement.path,
            '',
            backend: 'litert_lm_embedding_cpu',
            expectedDigest: digest,
          ),
          throwsStateError,
        );
        expect(store.rows('SELECT * FROM models').single, installed);
        write(digest, 'litert_lm_embedding_cpu');
        expect(await registerInstalledModels(store, manifest.path), 0);
        expect(store.rows('SELECT * FROM models').single, installed);
      } finally {
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
