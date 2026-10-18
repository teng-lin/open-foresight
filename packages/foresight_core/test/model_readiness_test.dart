import 'package:foresight_core/src/rpc_error.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/encrypted_query_runtime.dart';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Store store;
  late Map<String, String> environment;
  setUp(() {
    root = Directory.systemTemp.createTempSync('model-readiness-');
    store = Store('${root.path}/app.db');
    environment = Map.of(runtimeConfiguration.environment);
  });
  tearDown(() {
    store.close();
    runtimeConfiguration.environment
      ..clear()
      ..addAll(environment);
    root.deleteSync(recursive: true);
  });
  void registration(
    String kind,
    String path,
    String runtime, {
    String digest = dedicatedQueryModelDigest,
    String backend = dedicatedQueryBackend,
  }) {
    store.db.execute(
      'INSERT OR REPLACE INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
      [kind, path, digest, runtime, backend],
    );
  }

  File sparse(String name, int size) {
    final file = File('${root.path}/$name');
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(size);
    handle.closeSync();
    return file;
  }

  test(
    'dedicated model readiness distinguishes unsupported assets, missing runtime and encryption helpers',
    () async {
      expect(needsModel(store, dedicatedQueryModelKind), isTrue);
      final file = sparse('shape-only-fixture', dedicatedQueryModelBytes);
      registration(
        dedicatedQueryModelKind,
        file.path,
        '/missing/python',
        backend: 'unsupported',
      );
      expect(dedicatedQuerySetupProblem(store), contains('does not match'));
      registration(
        dedicatedQueryModelKind,
        file.path,
        '/missing/python',
        digest: 'wrong',
      );
      expect(dedicatedQuerySetupProblem(store), contains('does not match'));
      registration(dedicatedQueryModelKind, file.path, '/missing/python');
      expect(
        dedicatedQuerySetupProblem(store),
        contains('runtime is unavailable'),
      );
      final worker = File('${root.path}/worker.py')
        ..writeAsStringSync('fixture');
      runtimeConfiguration.environment['FORESIGHT_QUERY_WORKER'] = worker.path;
      registration(dedicatedQueryModelKind, file.path, '/bin/sh');
      expect(dedicatedQuerySetupProblem(store), isNull);
      expect(needsModel(store, dedicatedQueryModelKind), isFalse);
      final encrypted = sparse(
        'encrypted-shape-fixture',
        dedicatedQueryModelBytes + 33,
      );
      registration(
        dedicatedQueryModelKind,
        encrypted.path,
        '/bin/sh',
        backend: dedicatedEncryptedQueryBackend,
        digest: 'fixture',
      );
      runtimeConfiguration.environment.remove('FORESIGHT_MODEL_CRYPTO');
      expect(dedicatedQuerySetupProblem(store), contains('encryption helper'));
      runtimeConfiguration.environment['FORESIGHT_MODEL_CRYPTO'] = worker.path;
      expect(dedicatedQuerySetupProblem(store), contains('encryption helper'));
      runtimeConfiguration.environment['FORESIGHT_MODEL_CRYPTO'] = '/bin/sh';
      expect(dedicatedQuerySetupProblem(store), isNull);
      registration(
        dedicatedQueryModelKind,
        encrypted.path,
        worker.path,
        backend: dedicatedEncryptedQueryBackend,
      );
      expect(
        dedicatedQuerySetupProblem(store),
        contains('runtime is unavailable'),
      );
      worker.deleteSync();
      registration(
        dedicatedQueryModelKind,
        encrypted.path,
        '/bin/sh',
        backend: dedicatedEncryptedQueryBackend,
      );
      expect(
        dedicatedQuerySetupProblem(store),
        contains('runtime is unavailable'),
      );
      // These sparse files test readiness metadata only; they are never passed
      // to authenticated setup or inference.
      await expectLater(
        configureEncryptedDedicatedQuery(
          store,
          '/missing',
          current: () => false,
        ),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.cancelled)
              .having((e) => e.message, 'message', 'Model setup cancelled'),
        ),
      );
      await expectLater(
        configureEncryptedDedicatedQuery(store, file.path),
        throwsStateError,
      );
      final alias = Link('${root.path}/alias')..createSync(encrypted.path);
      await expectLater(
        configureEncryptedDedicatedQuery(store, alias.path),
        throwsStateError,
      );
    },
  );

  test(
    'installed speech and generation manifests verify runners and digests before adoption',
    () async {
      final model = File('${root.path}/model')..writeAsStringSync('fixture');
      final digest = sha256.convert(model.readAsBytesSync()).toString();
      final manifest = File('${root.path}/manifest.json');
      void write(Map<String, dynamic> entry) =>
          manifest.writeAsStringSync(jsonEncode(entry));
      write({});
      expect(await registerInstalledModels(store, manifest.path), 0);
      write({
        'speech': {'model': model.path, 'runtime': '/missing'},
      });
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
      write({
        'speech': {'model': model.path, 'runtime': '/bin/sh'},
      });
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
      expect(store.model('speech'), isNull);
      write({
        'speech': {'model': model.path, 'runtime': '/bin/sh', 'sha256': digest},
      });
      expect(await registerInstalledModels(store, manifest.path), 1);
      expect(speechSetupProblem(store), isNull);
      expect(needsModel(store, 'speech'), isFalse);
      registration('speech', '/missing', '/bin/sh', backend: 'llama_cpp');
      expect(speechSetupProblem(store), contains('model file is missing'));
      registration('speech', model.path, '/missing', backend: 'llama_cpp');
      expect(speechSetupProblem(store), contains('runner is missing'));
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] = '/bin/sh';
      write({
        'generation': {
          'model': model.path,
          'runtime': '/old/runner',
          'backend': 'litert_lm',
          'sha256': digest,
        },
      });
      expect(await registerInstalledModels(store, manifest.path), 1);
      expect(needsModel(store, 'generation'), isFalse);
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] = '/missing';
      expect(needsModel(store, 'generation'), isTrue);
      write({
        'query-detection': {'model': model.path, 'backend': 'unsupported'},
      });
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
      write({
        'embedding': {'model': '${root.path}/not-a-bundle'},
      });
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
    },
  );

  test(
    'directory embeddings retain a deterministic manifest digest and preserve previous models on empty input',
    () async {
      final directory = Directory('${root.path}/embedding')..createSync();
      final manifest = File('${root.path}/manifest.json')
        ..writeAsStringSync(
          jsonEncode({
            'embedding': {'model': directory.path},
          }),
        );
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
      File('${directory.path}/config.json').writeAsStringSync('{}');
      File('${directory.path}/weights.bin').writeAsStringSync('fixture');
      expect(await registerInstalledModels(store, manifest.path), 1);
      final prior = Map.of(store.model('embedding')!);
      expect((prior['digest'] as String).length, 64);
      expect(await registerInstalledModels(store, manifest.path), 0);
      final empty = Directory('${root.path}/empty')..createSync();
      await expectLater(
        store.register('embedding', empty.path, ''),
        throwsStateError,
      );
      expect(store.model('embedding'), prior);
    },
  );
}
