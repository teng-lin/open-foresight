import 'package:foresight_core/src/persistence/sql_support.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';
import 'package:foresight_test_support/test_paths.dart';

Map<String, Object?> engineIdentity() {
  final db = sqlite3.openInMemory();
  try {
    db.execute('CREATE TABLE payload(body TEXT)');
    db.execute("INSERT INTO payload VALUES('committed')");
    return Map<String, Object?>.from(
      db
          .select(
            'SELECT sqlite_version() AS version, sqlite_source_id() AS source_id, '
            '(SELECT body FROM payload) AS body',
          )
          .single,
    );
  } finally {
    db.dispose();
  }
}

void main() {
  bootstrapSqlSupportFixture();
  test('SQLite identity is consistent in a fresh reader isolate', () async {
    final identity = engineIdentity();
    expect(identity['body'], 'committed');
    final support = currentSqlSupportBootstrap;
    final environment = runtimeConfiguration.environment;
    expect(
      await Isolate.run(() {
        installServiceWorkerEnvironment(environment);
        bindSqlSupportBootstrap(support);
        return engineIdentity();
      }),
      identity,
    );
    if (Platform.isMacOS) {
      expect(identity['version'], applicationSqliteVersion);
      expect(identity['source_id'], applicationSqliteSourceId);
    }
  });

  for (final mappingScenario in ['alias', 'physical']) {
    test(
      'AOT reader retains original mapping across changed $mappingScenario path',
      () async {
        final root = createTestTempDirectorySync('sqlite-map-');
        final binary = File('${root.path}/bin/foresight-service');
        binary.parent.createSync();
        final compilation = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          'test/fixtures/sqlite_mapping_handoff.dart',
          '-o',
          binary.path,
        ]).timeout(const Duration(seconds: 60));
        expect(
          compilation.exitCode,
          0,
          reason: '${compilation.stdout}\n${compilation.stderr}',
        );
        final result = await Process.run(
          binary.path,
          [root.path, mappingScenario],
          environment: {
            ...Platform.environment,
            if (Platform.isMacOS)
              'FORESIGHT_TEST_SQLITE_ORIGINAL_LIBRARY':
                  Platform.environment['FORESIGHT_SQLITE_LIBRARY']!,
            'FORESIGHT_SQLITE_LIBRARY': '${root.path}/lib/libsqlite3.so',
          },
        ).timeout(const Duration(seconds: 30));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains(
            'original SQLite mapping retained; alias reverse control; parent transaction; real reader',
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 100)),
    );
  }

  for (final scenario in [
    'missing',
    'relative',
    'system',
    'preloaded-system',
  ]) {
    test(
      'Mac SQLite selection refuses $scenario without fallback',
      () async {
        final environment = Map<String, String>.from(Platform.environment)
          ..remove('FORESIGHT_SQLITE_LIBRARY')
          ..remove('FORESIGHT_RESOURCES')
          ..remove('FORESIGHT_STARTUP_ENV');
        if (scenario == 'relative') {
          environment['FORESIGHT_SQLITE_LIBRARY'] =
              'libforesight_sqlite3.dylib';
        } else if (scenario == 'system') {
          environment['FORESIGHT_SQLITE_LIBRARY'] = '/usr/lib/libsqlite3.dylib';
        } else if (scenario == 'preloaded-system') {
          environment['FORESIGHT_SQLITE_LIBRARY'] =
              Platform.environment['FORESIGHT_SQLITE_LIBRARY']!;
        }
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            'test/fixtures/sqlite_runtime_probe.dart',
            if (scenario == 'preloaded-system') 'preload-system',
          ],
          environment: environment,
          includeParentEnvironment: false,
        );
        expect(
          result.exitCode,
          isNot(0),
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains(
            scenario == 'missing' || scenario == 'relative'
                ? 'application SQLite runtime is missing'
                : 'Incompatible application SQLite runtime',
          ),
        );
        expect(
          result.stdout
              .toString()
              .split('\n')
              .where((line) => line.startsWith('{'))
              .map(jsonDecode),
          isEmpty,
        );
      },
      skip: Platform.isMacOS
          ? false
          : 'Application SQLite selection is macOS-only',
    );
  }
}
