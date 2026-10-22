import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

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
  test('SQLite identity is consistent in a fresh reader isolate', () async {
    final identity = engineIdentity();
    expect(identity['body'], 'committed');
    expect(await Isolate.run(engineIdentity), identity);
    if (Platform.isMacOS) {
      expect(identity['version'], applicationSqliteVersion);
      expect(identity['source_id'], applicationSqliteSourceId);
    }
  });

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
