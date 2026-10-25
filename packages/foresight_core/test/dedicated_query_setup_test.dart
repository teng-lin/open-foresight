import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
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
  late Map<String, String> environment;
  setUp(() {
    scratch = createTestTempDirectorySync('dedicated-query-import-');
    store = Store('${scratch.path}/app.db');
    environment = Map.of(runtimeConfiguration.environment);
  });
  setUp(() {
    addTearDown(() {
      store.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
      scratch.deleteSync(recursive: true);
    });
  });

  Future<Map<String, Object?>> existing() async {
    final model = File('${scratch.path}/previous-model')
      ..writeAsStringSync('previous');
    await store.register(
      'query-detection',
      model.path,
      '/bin/false',
      backend: 'legacy_query_cpu',
    );
    return Map.of(store.model('query-detection')!);
  }

  test(
    'wrong size and fixed digest mismatch preserve existing registration',
    () async {
      final prior = await existing();
      final file = File('${scratch.path}/wrong-model')
        ..writeAsStringSync('encrypted or unsupported bytes');
      await expectLater(
        configureDedicatedQuery(store, file.path),
        throwsStateError,
      );
      expect(store.model('query-detection'), prior);
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(dedicatedQueryModelBytes);
      handle.closeSync();
      // This sparse fixture has the expected length but unauthenticated contents.
      // Rejection happens before attempting any interpreter or worker startup.
      runtimeConfiguration.environment['FORESIGHT_LITERT_PYTHON'] =
          '/must-not-execute';
      await expectLater(
        configureDedicatedQuery(store, file.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('authenticated asset'),
          ),
        ),
      );
      expect(store.model('query-detection'), prior);
    },
  );

  test(
    'a caller cannot substitute its own digest to authorize an arbitrary asset',
    () async {
      final prior = await existing();
      await expectLater(
        configureDedicatedQuery(
          store,
          '${scratch.path}/missing',
          expectedDigest: '0' * 64,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('digest is incorrect'),
          ),
        ),
      );
      expect(store.model('query-detection'), prior);
    },
  );

  test('cancelled setup does not replace persistent configuration', () async {
    final prior = await existing();
    await expectLater(
      configureDedicatedQuery(
        store,
        '${scratch.path}/missing',
        current: () => false,
      ),
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', RpcErrorCode.cancelled)
            .having((e) => e.message, 'message', 'Model setup cancelled'),
      ),
    );
    expect(store.model('query-detection'), prior);
  });

  test(
    'optional existing manifest entry respects explicit registration and validates new import',
    () async {
      final prior = await existing();
      final manifest = File('${scratch.path}/installed.json')
        ..writeAsStringSync(
          jsonEncode({
            'query-detection': {
              'model': '${scratch.path}/missing',
              'sha256': '0' * 64,
              'backend': 'legacy_query_cpu',
            },
          }),
        );
      expect(await registerInstalledModels(store, manifest.path), 0);
      expect(store.model('query-detection'), prior);
      store.db.execute('DELETE FROM models WHERE kind=?', ['query-detection']);
      await expectLater(
        registerInstalledModels(store, manifest.path),
        throwsStateError,
      );
      expect(store.model('query-detection'), isNull);
      expect(needsModel(store, 'query-detection'), isTrue);
    },
  );
}
