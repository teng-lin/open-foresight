import 'dart:ffi';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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
  final root = Directory(arguments.first);
  final scenario = arguments.length > 1 ? arguments[1] : 'alias';
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
  // Mac already supplies an exact test artifact path, so locate it without
  // mapping the source image. The actual selected copy must be fixture-owned.
  final initialPath = Platform.isMacOS
      ? File(
          Platform.environment['FORESIGHT_TEST_SQLITE_ORIGINAL_LIBRARY']!,
        ).resolveSymbolicLinksSync()
      : captureSqliteMapping(
          loader.open.openSqlite(),
          'fixture-path-only',
        ).path;
  final original = File(initialPath).copySync('${lib.path}/original-sqlite');
  final alias = Link('${lib.path}/libsqlite3.so')..createSync(original.path);
  bootstrapSqlSupportFixture();
  final bootstrap = initializeSqliteRuntime(
    supportLibrary: Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY']!,
  );
  // The explicit legacy-negative modes run the prior API, which has no mapping
  // handoff. They never perform the physical-file replacement below.
  if (!scenario.startsWith('legacy-')) {
    check(
      boundSqliteMapping!.path == original.resolveSymbolicLinksSync(),
      'the selected physical SQLite file is not owned by this fixture',
    );
  }
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
    if (scenario == 'physical') {
      // Replace the frozen physical filename, not only the discovery alias.
      // The already mapped original inode remains retained by the process.
      original.renameSync('${lib.path}/retained-original-inode');
      replacement.copySync(original.path);
      check(
        sha256.convert(original.readAsBytesSync()) ==
            sha256.convert(replacement.readAsBytesSync()),
        'the frozen physical file was not replaced',
      );
    }
    // Reverse control: the alias really changed to loadable non-SQLite bytes.
    check(
      !DynamicLibrary.open(
        alias.path,
      ).providesSymbol('sqlite3_progress_handler'),
      'reverse alias control still selected SQLite',
    );
    if (!scenario.endsWith('reader-only')) {
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
    }
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
      '$scenario: original SQLite mapping retained; alias reverse control; parent transaction; real reader',
    );
  } finally {
    await worker.close();
    store.close();
  }
}
