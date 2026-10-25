import 'sql_support_test_bootstrap.dart';
import 'dart:io';

import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'lost-registry recovery preserves local generation assets when bundled runtime is absent',
    () async {
      final root = createTestTempDirectorySync('discovery-no-runtime-');
      final environment = Map.of(runtimeConfiguration.environment);
      final store = Store('${root.path}/app.db');
      addTearDown(() {
        store.close();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(environment);
        root.deleteSync(recursive: true);
      });
      // Discovery reads only this profile's existing distribution tree. These
      // bytes are never offered to an inference runtime or called a model proof.
      final local =
          File('${root.path}/distribution-assets/models/16/fixture/model')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('owned recovery fixture');
      runtimeConfiguration.environment.remove('FORESIGHT_LITERT_RUNNER');
      await expectLater(
        discoverGenerationRuntime(store, '/must-not-open'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'Bundled generation runtime is unavailable',
          ),
        ),
      );
      expect(store.model('generation'), isNull);
      expect(local.readAsStringSync(), 'owned recovery fixture');
      // A user registration takes precedence over a recoverable distribution
      // asset and prevents probing an unavailable native library.
      await store.register('generation', local.path, '/bin/true');
      expect(await discoverGenerationRuntime(store, '/must-not-open'), isNull);
      expect(store.model('generation')!['path'], local.path);
    },
  );
}
