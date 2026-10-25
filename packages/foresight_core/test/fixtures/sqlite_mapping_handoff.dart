import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/persistence_bootstrap.dart';
import 'package:foresight_core/src/persistence/sqlite_mapping.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/sqlite_read_worker.dart';
import 'package:foresight_core/src/store.dart';
import 'package:sqlite3/open.dart' as loader;

import '../sql_support_test_bootstrap.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  final root = Directory(arguments.single);
  final lib = Directory('${root.path}/lib')..createSync(recursive: true);
  Directory('${root.path}/app').createSync();
  final resources = Directory('${root.path}/share/open-foresight')
    ..createSync(recursive: true);
  File('${resources.path}/runtime.json').writeAsStringSync(
    jsonEncode({
      'FORESIGHT_NATIVE': '../../lib/unused-application-native',
      'FORESIGHT_RUNTIME_REVISION': 'mapping-fixture',
      'FORESIGHT_SQLITE_LIBRARY': '../../lib/libsqlite3.so',
    }),
  );
  final initial = Platform.isMacOS
      ? DynamicLibrary.open(
          Platform.environment['FORESIGHT_TEST_SQLITE_ORIGINAL_LIBRARY']!,
        )
      : loader.open.openSqlite();
  // Locate fixture bytes before the application gate, with no connection open.
  // This creates no application mapping binding and does not initialize sqlite3.
  final initialPath = captureSqliteMapping(initial, 'fixture-path-only').path;
  final original = File(initialPath).copySync('${lib.path}/original-sqlite');
  final alias = Link('${lib.path}/libsqlite3.so')..createSync(original.path);
  bootstrapSqlSupportFixture();
  final bootstrap = initializeSqliteRuntime(
    supportLibrary: Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY']!,
  );
  final anchor = applicationSqliteProgressInstaller.address;
  final source = sqlite3.version.sourceId;
  final store = Store('${root.path}/parent.db');
  final worker = SqliteReadWorker(
    store.path,
    environment: {
      ...runtimeConfiguration.environment,
      'FORESIGHT_SQLITE_LIBRARY': alias.path,
    },
  );
  try {
    store.setPreference('mapping-witness', 'committed');
    final identity = ReadIdentity(
      owner: 'mapping-fixture',
      profile: 'mapping-fixture',
      connection: 'mapping-fixture',
      epoch: store.workspaceEpoch,
      revision: store.dataRevision,
    );
    store.db.execute('BEGIN IMMEDIATE');
    store.db.execute(
      "UPDATE preferences SET value='uncommitted' WHERE key='mapping-witness'",
    );
    final replacement = File(
      Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY']!,
    ).copySync('${lib.path}/replacement-image');
    alias.deleteSync();
    alias.createSync(replacement.path);
    // Reverse control: the alias really changed to loadable non-SQLite bytes.
    check(
      !DynamicLibrary.open(
        alias.path,
      ).providesSymbol('sqlite3_progress_handler'),
      'reverse alias control still selected SQLite',
    );
    final direct = await Isolate.run(() {
      var aliasOpened = false;
      loader.open.overrideForAll(() {
        aliasOpened = true;
        return DynamicLibrary.open(alias.path);
      });
      installServiceWorkerEnvironment({
        ...Platform.environment,
        'FORESIGHT_SQLITE_LIBRARY': alias.path,
      });
      bindSqliteRuntime(bootstrap);
      final db = openApplicationDatabase(':memory:');
      try {
        return (
          aliasOpened,
          applicationSqliteProgressInstaller.address,
          sqlite3.version.sourceId,
          db.select('SELECT 42').single.values.single,
        );
      } finally {
        db.dispose();
      }
    });
    check(
      direct == (false, anchor, source, 42),
      'fresh isolate changed mapping',
    );
    final reply = await worker.read(
      ReadWorkerRequest(
        projection: 'preference',
        arguments: {'key': 'mapping-witness'},
        identity: identity,
        sequence: 1,
      ),
    );
    check(
      reply.value == 'committed',
      'real reader did not use original mapping',
    );
    check(
      store.db
              .select(
                "SELECT value FROM preferences WHERE key='mapping-witness'",
              )
              .single['value'] ==
          'uncommitted',
      'parent transaction was not held',
    );
    store.db.execute('ROLLBACK');
    stdout.writeln(
      'original SQLite mapping retained; alias reverse control; parent transaction; real reader',
    );
  } finally {
    await worker.close();
    store.close();
  }
}
