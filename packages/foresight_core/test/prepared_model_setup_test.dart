import 'dart:io';

import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/model_setup.dart'
    show dedicatedQueryModelBytes;
import 'package:foresight_core/src/dedicated_query_runtime.dart'
    show dedicatedQueryModelKind, dedicatedQueryBackend;
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File asset, runner;
  setUp(() {
    root = createTestTempDirectorySync('prepared-model-');
    asset = File('${root.path}/model.litertlm')..writeAsStringSync('fixture');
    runner = File('${root.path}/runner')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    expect(Process.runSync('/bin/chmod', ['700', runner.path]).exitCode, 0);
  });

  ModelRegistration model(String kind, {String backend = 'fixture'}) =>
      ModelRegistration.fromRow({
        'kind': kind,
        'path': asset.path,
        'runtime': runner.path,
        'backend': backend,
        'digest': dedicatedQueryModelDigest,
      });

  test(
    'prepared speech validation remains usable after its reader closes',
    () async {
      final writer = Store('${root.path}/application.db');
      addTearDown(writer.close);
      await writer.register('speech', asset.path, runner.path);
      final reader = SqliteStoreReader.open(
        writer.path,
        profile: 'fixture',
        connection: 'fixture',
      );
      addTearDown(reader.close);
      final result = await reader.read(StoreReadQueries.model('speech'));
      expect(result.current, isTrue);
      await reader.close();
      expect(preparedSpeechSetupProblem(result.value), isNull);
      asset.deleteSync();
      expect(
        preparedSpeechSetupProblem(result.value),
        contains('model file is missing'),
      );
      expect(
        preparedSpeechSetupProblem(null),
        contains('Set up a speech model'),
      );
    },
  );

  test(
    'prepared model availability validates registration and local assets',
    () {
      for (final kind in ['speech', 'generation', 'embedding']) {
        expect(preparedNeedsModel(null, kind), isTrue);
      }
      expect(preparedNeedsModel(model('speech'), 'speech'), isFalse);
      expect(preparedNeedsModel(model('generation'), 'generation'), isFalse);
      expect(preparedNeedsModel(model('embedding'), 'embedding'), isTrue);
      expect(
        preparedNeedsModel(
          model('embedding', backend: 'litert_lm_embedding_cpu'),
          'embedding',
        ),
        isFalse,
      );
      expect(Process.runSync('/bin/chmod', ['600', runner.path]).exitCode, 0);
      expect(preparedNeedsModel(model('generation'), 'generation'), isTrue);
      expect(
        preparedSpeechSetupProblem(model('speech')),
        contains('not executable'),
      );
      asset.deleteSync();
      expect(preparedNeedsModel(model('speech'), 'speech'), isTrue);
    },
  );

  test(
    'prepared dedicated model validation preserves supported asset checks',
    () {
      final environment = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(environment),
      );
      runtimeConfiguration.environment['FORESIGHT_QUERY_WORKER'] = runner.path;
      expect(
        preparedDedicatedQuerySetupProblem(null),
        contains('Import the supported'),
      );
      expect(preparedNeedsModel(null, dedicatedQueryModelKind), isTrue);
      final registration = model(
        dedicatedQueryModelKind,
        backend: dedicatedQueryBackend,
      );
      expect(
        preparedDedicatedQuerySetupProblem(registration),
        contains('does not match'),
      );
      // Sparse bytes exercise the readiness metadata check, never real inference.
      final handle = asset.openSync(mode: FileMode.write);
      handle.truncateSync(dedicatedQueryModelBytes);
      handle.closeSync();
      expect(preparedDedicatedQuerySetupProblem(registration), isNull);
      expect(
        preparedNeedsModel(registration, dedicatedQueryModelKind),
        isFalse,
      );
      runtimeConfiguration.environment.remove('FORESIGHT_QUERY_WORKER');
      expect(
        preparedDedicatedQuerySetupProblem(registration),
        contains('runtime is unavailable'),
      );
      expect(preparedNeedsModel(registration, dedicatedQueryModelKind), isTrue);
    },
  );
}
