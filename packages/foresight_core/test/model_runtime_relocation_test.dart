import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory scratch;
  late Store store;
  late Map<String, String> previous;
  late String root, generation, speech, query;
  late File asset;
  File runner(String path) {
    final file = File(path)..createSync(recursive: true);
    file.writeAsStringSync('#!/bin/sh\nprintf relocated');
    expect(Process.runSync('/bin/chmod', ['700', path]).exitCode, 0);
    return file;
  }

  setUp(() {
    scratch = createTestTempDirectorySync('runtime-relocation-');
    previous = Map.of(runtimeConfiguration.environment);
    root = '${scratch.path}/Old App.app';
    generation = '$root/Contents/Resources/bin/litert-runner';
    speech = '$root/Contents/Resources/bin/whisper-cli';
    query = '$root/Contents/Resources/bin/foresight-query';
    runner(generation);
    runner(speech);
    runner(query);
    runtimeConfiguration.environment.addAll({
      'FORESIGHT_INSTALL_ROOT': root,
      'FORESIGHT_LITERT_RUNNER': generation,
      'FORESIGHT_WHISPER_RUNTIME': speech,
      'FORESIGHT_QUERY_RUNTIME': query,
    });
    asset = File('${scratch.path}/model.bin')..writeAsStringSync('model');
    store = Store('${scratch.path}/application.db');
  });
  setUp(() {
    addTearDown(() {
      store.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(previous);
      scratch.deleteSync(recursive: true);
    });
  });
  void move() {
    final moved = '${scratch.path}/Moved App With Spaces.app';
    Directory(root).renameSync(moved);
    runtimeConfiguration.environment.addAll({
      'FORESIGHT_INSTALL_ROOT': moved,
      'FORESIGHT_LITERT_RUNNER': generation.replaceFirst(root, moved),
      'FORESIGHT_WHISPER_RUNTIME': speech.replaceFirst(root, moved),
      'FORESIGHT_QUERY_RUNTIME': query.replaceFirst(root, moved),
    });
  }

  test(
    'configured speech generation and dedicated query runtimes follow moved app',
    () async {
      await store.register(
        'generation',
        asset.path,
        generation,
        backend: 'litert_lm',
      );
      await store.register('speech', asset.path, speech);
      await store.register(
        'query-detection',
        asset.path,
        query,
        backend: 'legacy_query_cpu',
      );
      move();
      store.close();
      store = Store('${scratch.path}/application.db');
      for (final kind in ['generation', 'speech', 'query-detection']) {
        final resolved = store.model(kind)!;
        expect(resolved['runtime'], contains('Moved App With Spaces.app'));
        expect(
          (await Process.run(resolved['runtime'] as String, [])).stdout,
          'relocated',
        );
        expect(
          store.rows('SELECT runtime FROM models WHERE kind=?', [
            kind,
          ]).single['runtime'],
          startsWith(root),
        );
      }
      expect(needsModel(store, 'generation'), isFalse);
      expect(speechSetupProblem(store), isNull);
      expect(
        store.models.every(
          (m) => (m['runtime'] as String).contains('Moved App'),
        ),
        isTrue,
      );
    },
  );
  test(
    'owned legacy query interpreter registration adopts the native runtime',
    () async {
      await store.register(
        'query-detection',
        asset.path,
        query,
        backend: 'legacy_query_cpu',
      );
      final key = 'modelRuntimeResource.query-detection';
      final record = jsonDecode(store.preference(key)) as Map;
      store.setPreference(
        key,
        jsonEncode({...record, 'resource': 'FORESIGHT_LITERT_PYTHON'}),
      );
      move();
      expect(
        store.model('query-detection')!['runtime'],
        contains('Moved App With Spaces.app'),
      );
      expect(
        store.model('query-detection')!['runtime'],
        endsWith('/bin/foresight-query'),
      );
    },
  );

  test(
    'explicit external registration clears provenance and remains unchanged',
    () async {
      await store.register(
        'generation',
        asset.path,
        generation,
        backend: 'litert_lm',
      );
      final external = runner('${scratch.path}/external');
      await store.register(
        'generation',
        asset.path,
        external.path,
        backend: 'litert_lm',
      );
      expect(store.preference('modelRuntimeResource.generation'), isEmpty);
      move();
      expect(store.model('generation')!['runtime'], external.path);
    },
  );
  test(
    'legacy rows and stale digest runtime backend resource metadata are ignored',
    () async {
      await store.register('speech', asset.path, speech);
      await store.register(
        'query-detection',
        asset.path,
        query,
        backend: 'legacy_query_cpu',
      );
      final key = 'modelRuntimeResource.speech';
      final original = jsonDecode(store.preference(key)) as Map;
      move();
      for (final field in ['digest', 'runtime', 'backend', 'resource']) {
        store.setPreference(key, jsonEncode({...original, field: 'stale'}));
        expect(store.model('speech')!['runtime'], speech);
      }
      store.setPreference(key, '{malformed');
      expect(store.model('speech')!['runtime'], speech);
      store.db.execute('DELETE FROM preferences WHERE key=?', [key]);
      expect(speechSetupProblem(store), contains('runner is missing'));
    },
  );
  test(
    'external resource overrides and symlinks out of bundle are not trusted',
    () async {
      final external = runner('${scratch.path}/external');
      runtimeConfiguration.environment['FORESIGHT_WHISPER_RUNTIME'] =
          external.path;
      await store.register('speech', asset.path, external.path);
      expect(store.preference('modelRuntimeResource.speech'), isEmpty);
      File(speech).deleteSync();
      Link(speech).createSync(external.path);
      runtimeConfiguration.environment['FORESIGHT_WHISPER_RUNTIME'] = speech;
      await store.register('speech', asset.path, speech);
      await store.register(
        'query-detection',
        asset.path,
        query,
        backend: 'legacy_query_cpu',
      );
      expect(store.preference('modelRuntimeResource.speech'), isEmpty);
      await store.register(
        'generation',
        asset.path,
        generation,
        backend: 'litert_lm',
      );
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] =
          external.path;
      expect(store.model('generation')!['runtime'], generation);
    },
  );
}
