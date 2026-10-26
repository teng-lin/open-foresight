import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/migration_backups.dart';
import 'package:foresight_core/src/persistence/restore_activation.dart';
import 'package:foresight_core/src/persistence/restore_pending.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart'
    show serviceEndpoint, ServiceClient;
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

Database historical(String path) {
  final db = openApplicationDatabase(path);
  db.execute(
    File('test/fixtures/persistence-c28a1561/schema15.sql').readAsStringSync(),
  );
  for (var version = 16; version <= 19; version++) {
    ApplicationMigrations(db).run(version);
  }
  db.execute('PRAGMA user_version=19');
  db.execute(
    "INSERT INTO notes(id,title,body,revision) VALUES(1,'Original','Backup private content',3)",
  );
  return db;
}

/// A `restore_reader_hold.dart` child with line-based stdout.
final class _Child {
  _Child._(this.process)
    : _lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ) {
    _errorsDone = process.stderr.transform(utf8.decoder).forEach(errors.write);
  }
  final Process process;
  final StreamIterator<String> _lines;
  final errors = StringBuffer();
  late final Future<void> _errorsDone;
  var _finished = false;

  static Future<_Child> start(List<String> arguments) async {
    final child = _Child._(
      await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/restore_reader_hold.dart',
        ...arguments,
      ]),
    );
    addTearDown(child.kill);
    return child;
  }

  Future<String> next() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 60))) {
      throw StateError('The child ended early: $errors');
    }
    return _lines.current;
  }

  Future<String> command(String line) async {
    process.stdin.writeln(line);
    await process.stdin.flush();
    return next();
  }

  Future<int> finish() async {
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 60));
    await _errorsDone;
    _finished = true;
    return code;
  }

  Future<void> kill() async {
    if (_finished) return;
    _finished = true;
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }
}

/// Compile-time metadata selecting this source tree and its build, as a
/// source-built entrypoint has; the compiled program then runs its own
/// production bootstrap. Never a runtime selector.
List<String> sourceBuildDefines() {
  final support = Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY']!;
  return [
    '-DFORESIGHT_DIAGNOSTIC_TEST_CONTEXT=true',
    '-DFORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR='
        '${p.normalize(Directory.current.parent.parent.absolute.path)}',
    '-DFORESIGHT_DIAGNOSTIC_BUILD_ROOT=${p.dirname(p.dirname(support))}',
  ];
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory scratch;
  late ProfilePaths profile;
  late String path;
  setUp(() {
    scratch = Directory(
      createTestTempDirectorySync('restore-').resolveSymbolicLinksSync(),
    );
    profile = ProfilePaths('${scratch.path}/data', '${scratch.path}/run');
    Directory(profile.data).createSync();
    expect(Process.runSync('/bin/chmod', ['700', profile.data]).exitCode, 0);
    path = '${profile.data}/application.db';
  });

  RestoreActivation activation({
    int? supportedVersion,
    DateTime Function()? now,
    void Function(String stage)? checkpoint,
  }) => RestoreActivation(
    profile: profile,
    databasePath: path,
    supportedVersion: supportedVersion ?? Store.schemaVersion,
    now: now,
    checkpoint: checkpoint,
  );

  /// A schema19 profile upgraded by Store, then changed after its snapshot.
  MigrationSnapshot upgradedProfile() {
    historical(path).dispose();
    final store = Store(path);
    try {
      store.saveNote(null, 'After upgrade', 'newer profile content');
    } finally {
      store.close();
    }
    return MigrationBackups(
      path,
    ).snapshots(supportedVersion: Store.schemaVersion).single;
  }

  String identity(String name) {
    final directory = BackupDirectory(
      profile.data,
      create: false,
      private: false,
    );
    try {
      return directory.metadata(name, private: false).identity;
    } finally {
      directory.close();
    }
  }

  /// Also proves the entry is an owner-only file managed backups accept.
  String backupIdentity(String name) {
    final directory = BackupDirectory('$path.backups', create: false);
    try {
      return directory.metadata(name).identity;
    } finally {
      directory.close();
    }
  }

  String backup(MigrationSnapshot snapshot) => '$path.backups/${snapshot.name}';

  List<String> backupEntries() => [
    for (final entry in Directory('$path.backups').listSync())
      entry.path.split('/').last,
  ]..sort();

  T read<T>(String file, T Function(Database) use) {
    final db = openApplicationDatabase(file);
    try {
      return use(db);
    } finally {
      db.dispose();
    }
  }

  List<Object?> bodies(Database db) => db
      .select('SELECT body FROM notes ORDER BY id')
      .map((row) => row['body'])
      .toList();
  Object? schema(Database db) =>
      db.select('PRAGMA user_version').single.values.single;

  List<String> residue() => [
    for (final entry in Directory(profile.data).listSync())
      if (entry.path.contains('.restoring-') ||
          entry.path.contains('.displaced-'))
        entry.path,
  ];

  void expectUnchanged(String before) {
    expect(identity('application.db'), before);
    expect(residue(), isEmpty);
    read(path, (db) {
      expect(schema(db), Store.schemaVersion);
      expect(bodies(db), contains('newer profile content'));
    });
  }

  /// The previous profile is a managed, listed snapshot of the restored one.
  void expectDisplaced(MigrationSnapshot displaced, String before) {
    expect(backupIdentity(displaced.name), before);
    expect(displaced.schema, Store.schemaVersion);
    final listed = activation().candidates().where(
      (snapshot) => snapshot.name == displaced.name,
    );
    expect(listed.single.sha256, displaced.sha256);
    expect(listed.single.created, displaced.created);
    read(backup(displaced), (db) {
      expect(schema(db), Store.schemaVersion);
      expect(bodies(db), contains('newer profile content'));
    });
  }

  List<String> sidecars() => [
    for (final suffix in ['-wal', '-shm', '-journal'])
      if (File('$path$suffix').existsSync()) suffix,
  ];

  test(
    'activation installs a verified snapshot and retains the newer profile as a managed snapshot',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      final result = await activation().activate(
        snapshot.name,
        acceptDataLossOf: snapshot.name,
      );
      expect(result.snapshot.name, snapshot.name);
      expect(result.snapshot.created, snapshot.created);
      expect(result.replacedSchema, Store.schemaVersion);
      expect(result.database, path);
      expect(residue(), isEmpty);
      expect(File('$path-wal').existsSync(), isFalse);
      expect(File('$path-journal').existsSync(), isFalse);
      expectDisplaced(result.displaced, before);
      read(path, (db) {
        expect(schema(db), 19);
        expect(bodies(db), ['Backup private content']);
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      });
      // The production Store opens and upgrades the restored profile. Its new
      // pre-upgrade snapshot does not evict the retained previous profile,
      // while the activated snapshot of the previous file is pruned.
      final store = Store(path);
      try {
        expect(
          store.rows('PRAGMA user_version').single.values.single,
          Store.schemaVersion,
        );
        expect(store.notes().single['body'], 'Backup private content');
        final kept = store.migrationBackups.snapshots(
          supportedVersion: Store.schemaVersion,
        );
        expect(kept, hasLength(2));
        expect(kept.map((s) => s.name), contains(result.displaced.name));
        expect(kept.map((s) => s.name), isNot(contains(snapshot.name)));
      } finally {
        store.close();
      }
      // The displaced snapshot undoes the activation like any other.
      final undo = await activation().activate(
        result.displaced.name,
        acceptDataLossOf: result.displaced.name,
      );
      read(path, (db) {
        expect(schema(db), Store.schemaVersion);
        expect(bodies(db), ['Backup private content', 'newer profile content']);
      });
      read(
        backup(undo.displaced),
        (db) => expect(bodies(db), ['Backup private content']),
      );
    },
  );

  test(
    'unacknowledged, newer-schema and corrupt snapshots refuse before any change',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      final backups = backupEntries();
      await expectLater(
        activation().activate(snapshot.name, acceptDataLossOf: 'other'),
        throwsA(isA<RestoreActivationRefused>()),
      );
      expectUnchanged(before);
      expect(backupEntries(), backups);
      // Injected from older code: a schema19 snapshot must not reach schema18.
      await expectLater(
        activation(
          supportedVersion: 18,
        ).activate(snapshot.name, acceptDataLossOf: snapshot.name),
        throwsA(isA<RestoreActivationRefused>()),
      );
      expectUnchanged(before);
      expect(backupEntries(), backups);
      final payload = File('$path.backups/${snapshot.name}');
      payload.writeAsBytesSync([...payload.readAsBytesSync(), 42]);
      await expectLater(
        activation().activate(snapshot.name, acceptDataLossOf: snapshot.name),
        throwsA(isA<RestoreActivationRefused>()),
      );
      expectUnchanged(before);
    },
  );

  test(
    'a live profile newer than this installation refuses before any change',
    () async {
      final snapshot = upgradedProfile();
      expect(snapshot.schema, 19);
      final before = identity('application.db');
      final bytes = File(path).readAsBytesSync();
      final files = sidecars();
      final backups = backupEntries();
      // Older code: it supports the snapshot's schema, not the live profile's.
      await expectLater(
        activation(
          supportedVersion: 19,
        ).activate(snapshot.name, acceptDataLossOf: snapshot.name),
        throwsA(
          isA<RestoreActivationRefused>().having(
            (error) => error.message,
            'message',
            contains(
              'Unsupported newer application database version '
              '${Store.schemaVersion} (maximum 19)',
            ),
          ),
        ),
      );
      expect(identity('application.db'), before);
      expect(File(path).readAsBytesSync(), bytes);
      expect(sidecars(), files);
      expect(residue(), isEmpty);
      expect(backupEntries(), backups);
      // Page 1 still says WAL (bytes 18/19) at the newer user_version (60).
      expect([bytes[18], bytes[19]], [2, 2]);
      expect(
        ByteData.sublistView(bytes).getUint32(60, Endian.big),
        Store.schemaVersion,
      );
      // The installation that supports the live profile may still restore.
      final result = await activation().activate(
        snapshot.name,
        acceptDataLossOf: snapshot.name,
      );
      expectDisplaced(result.displaced, before);
    },
  );

  test(
    'pending deletion erasure refuses activation so deleted content stays erased',
    () async {
      final snapshot = upgradedProfile();
      final store = Store(path);
      // The snapshot holds this note; deleting it records erasure intent.
      store.db.execute('DELETE FROM notes WHERE id=1');
      expect(store.privacyMaintenancePending, isTrue);
      store.close();
      final before = identity('application.db');
      await expectLater(
        activation().activate(snapshot.name, acceptDataLossOf: snapshot.name),
        throwsA(
          isA<RestoreActivationRefused>().having(
            (error) => error.message,
            'message',
            contains('has not finished erasing its backups'),
          ),
        ),
      );
      expect(identity('application.db'), before);
      expect(residue(), isEmpty);
      // Refused before the journal mode changed.
      read(path, (db) {
        expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
        expect(bodies(db), ['newer profile content']);
      });
      // The service's maintenance then erases the snapshot as intended.
      final reopened = Store(path);
      addTearDown(reopened.close);
      await eventually(() => !reopened.privacyMaintenancePending);
      expect(Directory('$path.backups').listSync(), isEmpty);
    },
  );

  test(
    'workspace deletion erases the displaced profile with every other backup',
    () async {
      final snapshot = upgradedProfile();
      final result = await activation().activate(
        snapshot.name,
        acceptDataLossOf: snapshot.name,
      );
      expect(
        latin1
            .decode(File(backup(result.displaced)).readAsBytesSync())
            .contains('newer profile content'),
        isTrue,
      );
      final store = Store(path);
      store.db.execute('DELETE FROM notes WHERE id=1');
      expect(store.privacyMaintenancePending, isTrue);
      await eventually(() => !store.privacyMaintenancePending);
      store.close();
      expect(Directory('$path.backups').listSync(), isEmpty);
      // No file left in the profile still holds the displaced content.
      for (final entry in Directory(profile.data).listSync(recursive: true)) {
        if (entry is File) {
          expect(
            latin1.decode(entry.readAsBytesSync()),
            isNot(contains('newer profile content')),
            reason: entry.path,
          );
        }
      }
    },
  );

  test('the displaced profile expires with the bounded retention', () async {
    final snapshot = upgradedProfile();
    final result = await activation().activate(
      snapshot.name,
      acceptDataLossOf: snapshot.name,
    );
    final created = result.displaced.created;
    MigrationBackups(
      path,
      now: () => created.add(const Duration(days: 6)),
    ).prune();
    expect(backupEntries(), [
      result.displaced.name,
      '${result.displaced.name}.json',
    ]);
    MigrationBackups(
      path,
      now: () => created.add(const Duration(days: 8)),
    ).prune();
    expect(backupEntries(), isEmpty);
  });

  test(
    'a failure before or after the exchange rolls back to the previous profile',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      for (final stage in [
        'quiesced',
        'staged',
        'exchanging',
        'exchanged',
        'confirmed',
      ]) {
        await expectLater(
          activation(
            checkpoint: (reached) {
              if (reached == stage) throw StateError('injected at $stage');
            },
          ).activate(snapshot.name, acceptDataLossOf: snapshot.name),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'injected at $stage',
            ),
          ),
        );
        expectUnchanged(before);
        expect(File('$path-journal').existsSync(), isFalse);
        expect(
          activation().candidates().map((s) => s.name),
          contains(snapshot.name),
        );
      }
    },
  );

  Future<void> crashAt(MigrationSnapshot snapshot, String stage) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/restore_activation_crash.dart',
      profile.data,
      profile.runtime,
      snapshot.name,
      stage,
    ]);
    expect(result.exitCode, 79, reason: '${result.stdout}\n${result.stderr}');
  }

  for (final stage in ['prepared', 'marked']) {
    test(
      'process death at $stage leaves only a managed prepared copy',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        await crashAt(snapshot, stage);
        expect(identity('application.db'), before);
        expect(File('$path-journal').existsSync(), isFalse);
        // The marker is published only at `marked`; nothing was staged.
        expect(residue(), hasLength(stage == 'marked' ? 1 : 0));
        final prepared = [
          for (final entry in backupEntries())
            if (entry.startsWith('restore-')) entry,
        ];
        expect(prepared, hasLength(1));
        expect(await activation().recover(), isEmpty);
        expectUnchanged(before);
        // The prepared copy is a managed backup: one copy for seven days.
        MigrationBackups(path).prune();
        expect(backupEntries(), [
          ...prepared,
          snapshot.name,
          '${snapshot.name}.json',
        ]);
        final result = await activation().activate(
          snapshot.name,
          acceptDataLossOf: snapshot.name,
        );
        expectDisplaced(result.displaced, before);
        // The next restore copy replaced the stale one before it was staged.
        expect(
          backupEntries().where((entry) => entry.startsWith('restore-')),
          isEmpty,
        );
        MigrationBackups(
          path,
          now: () => DateTime.now().add(const Duration(days: 8)),
        ).prune();
        expect(backupEntries(), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final stage in ['quiesced', 'staged', 'exchanging']) {
    test(
      'process death at $stage keeps the previous profile live',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        await crashAt(snapshot, stage);
        expect(identity('application.db'), before);
        expect(File('$path-journal').existsSync(), isFalse);
        expect(residue(), hasLength(stage == 'quiesced' ? 0 : 2));
        expect(await activation().recover(), isEmpty);
        expectUnchanged(before);
        // Nothing stale blocks the next activation.
        final result = await activation().activate(
          snapshot.name,
          acceptDataLossOf: snapshot.name,
        );
        expectDisplaced(result.displaced, before);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final stage in ['exchanged', 'confirmed', 'retaining', 'retained']) {
    test(
      'process death at $stage is recovered without losing either profile',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        await crashAt(snapshot, stage);
        expect(identity('application.db'), isNot(before));
        // After the retain rename only the marker is left in the profile.
        expect(residue(), hasLength(stage == 'retained' ? 1 : 2));
        expect(File('$path-journal').existsSync(), isFalse);
        read(path, (db) => expect(schema(db), 19));
        final displaced = await activation().recover();
        expect(residue(), isEmpty);
        expectDisplaced(displaced.single, before);
        // The next prune drops the stale activated snapshot and any orphan
        // manifest from the interrupted attempt; the retained profile stays.
        MigrationBackups(path).prune();
        expect(backupEntries(), [
          displaced.single.name,
          '${displaced.single.name}.json',
        ]);
        final store = Store(path);
        addTearDown(store.close);
        expect(store.notes().single['body'], 'Backup private content');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'an interrupted restore keeps Store and the service closed until recovery',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      await crashAt(snapshot, 'exchanged');
      final pending = {
        for (final entry in residue()) entry: File(entry).readAsBytesSync(),
      };
      expect(pending, hasLength(2));
      final staged = pending.keys.singleWhere(
        (entry) => !entry.endsWith('.json'),
      );
      final restored = identity('application.db');
      final live = File(path).readAsBytesSync();
      final files = sidecars();
      final refusal = isA<PendingProfileRestore>().having(
        (error) => error.message,
        'message',
        contains('run foresight-service --restore-recover'),
      );
      expect(() => Store(path), throwsA(refusal));
      expect(() => Store.readOnly(path), throwsA(refusal));
      // Ordinary product startup: a real service process does not serve.
      final kernel = File('${scratch.path}/service.dill');
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        ...sourceBuildDefines(),
        'bin/service.dart',
        '-o',
        kernel.path,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout} ${compilation.stderr}',
      );
      final diagnostics = StringBuffer();
      final service = await Process.start(
        Platform.resolvedExecutable,
        [kernel.path],
        environment: {
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
          'FORESIGHT_HELPER': '',
        },
      );
      final output = [
        service.stdout.transform(utf8.decoder).forEach(diagnostics.write),
        service.stderr.transform(utf8.decoder).forEach(diagnostics.write),
      ];
      int? exit;
      try {
        exit = await service.exitCode.timeout(const Duration(seconds: 60));
      } on TimeoutException {
        service.kill(ProcessSignal.sigkill);
        await service.exitCode;
      }
      await Future.wait(output);
      expect(exit, isNot(anyOf(isNull, 0)), reason: diagnostics.toString());
      expect(
        diagnostics.toString(),
        contains('run foresight-service --restore-recover'),
        reason: diagnostics.toString(),
      );
      // Nothing was opened, discarded or rewritten.
      expect(residue()..sort(), pending.keys.toList()..sort());
      for (final entry in pending.entries) {
        expect(File(entry.key).readAsBytesSync(), entry.value);
      }
      expect(identity('application.db'), restored);
      expect(File(path).readAsBytesSync(), live);
      expect(sidecars(), files);
      final displaced = (await activation().recover()).single;
      expect(residue(), isEmpty);
      expect(backupIdentity(displaced.name), before);
      expect(File(backup(displaced)).readAsBytesSync(), pending[staged]);
      final store = Store(path);
      try {
        expect(store.notes().single['body'], 'Backup private content');
        // Store's workspace clear: content deletion, then clear maintenance.
        store.db.execute('DELETE FROM notes');
        store.compactAfterClear();
        await eventually(() => !store.privacyMaintenancePending);
      } finally {
        store.close();
      }
      expect(Directory('$path.backups').listSync(), isEmpty);
      for (final entry in Directory(profile.data).listSync(recursive: true)) {
        if (entry is File) {
          expect(
            latin1.decode(entry.readAsBytesSync()),
            isNot(contains('newer profile content')),
            reason: entry.path,
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a reader in another process blocks activation of the open database',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      final reader = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/restore_reader_hold.dart',
        'read',
        path,
      ]);
      final output = StreamIterator(
        reader.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = StringBuffer();
      final errorsDone = reader.stderr
          .transform(utf8.decoder)
          .forEach(errors.write);
      var released = false;
      addTearDown(() async {
        if (!released) reader.kill(ProcessSignal.sigkill);
        await reader.exitCode;
      });
      expect(
        await output.moveNext().timeout(const Duration(seconds: 60)),
        isTrue,
        reason: errors.toString(),
      );
      expect(output.current, 'holding');
      await expectLater(
        activation().activate(snapshot.name, acceptDataLossOf: snapshot.name),
        throwsA(isA<RestoreActivationRefused>()),
      );
      expect(identity('application.db'), before);
      expect(residue(), isEmpty);
      await reader.stdin.close();
      released = true;
      expect(await output.moveNext(), isTrue);
      // The refused activation left the live profile in its WAL mode.
      expect(output.current, 'journal_mode=wal');
      expect(await reader.exitCode, 0, reason: errors.toString());
      await errorsDone;
      final result = await activation().activate(
        snapshot.name,
        acceptDataLossOf: snapshot.name,
      );
      expectDisplaced(result.displaced, before);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // SQLITE_BUSY (5), from Store's preflight or a connection of its own.
  final busy = anyOf(
    contains('qualification failed (5)'),
    contains('database is locked'),
  );
  for (final (kind, mode, stage, refusal) in [
    ('Store', 'write', 'quiesced', busy),
    // The marker exists by then, so Store refuses before SQLite is reached.
    (
      'Store',
      'write',
      'exchanging',
      contains('restore of this profile is running or was interrupted'),
    ),
    // A connection that bypasses Store meets only the quiesce lock.
    ('raw SQLite', 'write-raw', 'quiesced', busy),
    ('raw SQLite', 'write-raw', 'exchanging', busy),
    // The restored database stays reserved through retention.
    ('raw SQLite', 'write-raw', 'retained', busy),
  ]) {
    test(
      'a $kind writer arriving after quiesce ($stage) cannot write or attach',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        final trigger = '${scratch.path}/late-writer';
        final writer = await Process.start(Platform.resolvedExecutable, [
          'run',
          'test/fixtures/restore_reader_hold.dart',
          mode,
          path,
          trigger,
        ]);
        final output = StreamIterator(
          writer.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        final errors = StringBuffer();
        final errorsDone = writer.stderr
            .transform(utf8.decoder)
            .forEach(errors.write);
        var released = false;
        addTearDown(() async {
          if (!released) writer.kill(ProcessSignal.sigkill);
          await writer.exitCode;
        });
        expect(
          await output.moveNext().timeout(const Duration(seconds: 60)),
          isTrue,
          reason: errors.toString(),
        );
        expect(output.current, 'ready');
        String? outcome;
        Object? failure;
        RestoreActivationResult? result;
        try {
          result = await activation(
            checkpoint: (reached) {
              if (reached != stage) return;
              // The activation is synchronous: let the waiting child open the
              // profile database now and wait here for its outcome.
              File(trigger).writeAsStringSync('go');
              final report = File('$trigger.result');
              final clock = Stopwatch()..start();
              while (!report.existsSync()) {
                if (clock.elapsed > const Duration(seconds: 90)) {
                  throw StateError('The late writer did not report.');
                }
                sleep(const Duration(milliseconds: 20));
              }
              outcome = report.readAsStringSync();
            },
          ).activate(snapshot.name, acceptDataLossOf: snapshot.name);
        } catch (error) {
          failure = error;
        }
        await writer.stdin.close();
        released = true;
        final exit = await writer.exitCode.timeout(const Duration(seconds: 60));
        await errorsDone;
        Object? live;
        try {
          live = read(path, (db) => [schema(db), bodies(db)]);
        } catch (error) {
          live = error;
        }
        final state =
            'writer: $outcome; activation: ${failure ?? 'completed'}; '
            'live: $live; sidecars: ${[
              for (final suffix in ['-wal', '-journal'])
                if (File('$path$suffix').existsSync()) suffix,
            ]}; writer stderr: $errors';
        expect(exit, 0, reason: state);
        expect(failure, isNull, reason: state);
        expect(outcome, startsWith('refused: '), reason: state);
        expect(outcome, refusal, reason: state);
        expect(live, [
          19,
          ['Backup private content'],
        ], reason: state);
        expect(File('$path-wal').existsSync(), isFalse, reason: state);
        expect(File('$path-journal').existsSync(), isFalse, reason: state);
        read(path, (db) {
          expect(
            db.select('PRAGMA integrity_check').single.values.single,
            'ok',
          );
        });
        expectDisplaced(result!.displaced, before);
        read(backup(result.displaced), (db) {
          expect(bodies(db), isNot(contains('late writer content')));
        });
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  /// Lets a `sql`/`write` child waiting on [trigger] run now, from inside the
  /// synchronous activation, and returns its report.
  String fire(String trigger) {
    File(trigger).writeAsStringSync('go');
    final report = File('$trigger.result');
    final clock = Stopwatch()..start();
    while (!report.existsSync()) {
      if (clock.elapsed > const Duration(seconds: 90)) {
        throw StateError('The child did not report.');
      }
      sleep(const Duration(milliseconds: 20));
    }
    return report.readAsStringSync();
  }

  /// Every file in the profile, including managed backups, by name.
  Map<String, String> profileFiles() => {
    for (final entry in Directory(profile.data).listSync(recursive: true))
      if (entry is File) entry.path: latin1.decode(entry.readAsBytesSync()),
  };

  const lateInsert =
      "INSERT INTO notes(title,body,timestamp) VALUES('Late writer','late writer content',0)";
  for (final (kind, mode) in [('committing', 'sql'), ('WAL', 'write-raw')]) {
    test(
      'a $kind writer at the exchange cannot commit into a restore that then rolls back',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        final trigger = '${scratch.path}/late-writer';
        final writer = await _Child.start([
          mode,
          path,
          trigger,
          if (mode == 'sql') lateInsert,
        ]);
        expect(await writer.next(), 'ready');
        String? outcome;
        Object? failure;
        try {
          await activation(
            checkpoint: (reached) {
              if (reached == 'exchanged') outcome = fire(trigger);
              if (reached == 'confirmed') {
                throw StateError('injected at confirmed');
              }
            },
          ).activate(snapshot.name, acceptDataLossOf: snapshot.name);
        } catch (error) {
          failure = error;
        }
        final exit = await writer.finish();
        final files = profileFiles();
        final state =
            'writer: $outcome; activation: $failure; sidecars: ${sidecars()}; '
            'residue: ${residue()}; writer stderr: ${writer.errors}';
        expect(exit, 0, reason: state);
        expect(
          failure,
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected at confirmed',
          ),
          reason: state,
        );
        // A write the writer saw commit would have to survive somewhere.
        expect(
          files.values.any((bytes) => bytes.contains('late writer content')),
          outcome == 'written',
          reason: state,
        );
        expect(outcome, allOf(startsWith('refused: '), busy), reason: state);
        expect(
          files.keys.where((name) => name.endsWith('-journal')),
          isEmpty,
          reason: state,
        );
        expect(File('$path-wal').existsSync(), isFalse, reason: state);
        expectUnchanged(before);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final (intent, statement, refusal) in [
    (
      'a newer schema',
      'PRAGMA user_version=${Store.schemaVersion + 1}',
      contains(
        'Unsupported newer application database version '
        '${Store.schemaVersion + 1}',
      ),
    ),
    (
      'a deletion',
      'DELETE FROM notes WHERE id=1',
      contains('has not finished erasing its backups'),
    ),
  ]) {
    test(
      '$intent committed after the early checks is refused under the lock',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        final backups = backupEntries();
        final trigger = '${scratch.path}/racing-writer';
        final writer = await _Child.start(['sql', path, trigger, statement]);
        expect(await writer.next(), 'ready');
        String? outcome;
        Object? failure;
        try {
          await activation(
            checkpoint: (reached) {
              if (reached == 'preflighted') outcome = fire(trigger);
            },
          ).activate(snapshot.name, acceptDataLossOf: snapshot.name);
        } catch (error) {
          failure = error;
        }
        final exit = await writer.finish();
        final state =
            'writer: $outcome; activation: $failure; live: ${read(path, (db) => [schema(db), bodies(db), db.select("SELECT key FROM preferences WHERE key LIKE 'internal.%'")])}; '
            'writer stderr: ${writer.errors}';
        expect(exit, 0, reason: state);
        // The race really happened: the writer committed between the checks.
        expect(outcome, 'written', reason: state);
        expect(
          failure,
          isA<RestoreActivationRefused>().having(
            (error) => error.message,
            'message',
            refusal,
          ),
          reason: state,
        );
        expect(identity('application.db'), before);
        expect(residue(), isEmpty);
        expect(backupEntries(), backups);
        expect(File('$path-journal').existsSync(), isFalse);
        // The racing commit stays in the live profile.
        read(path, (db) {
          if (statement.startsWith('PRAGMA')) {
            expect(schema(db), Store.schemaVersion + 1);
          } else {
            expect(bodies(db), ['newer profile content']);
          }
        });
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final mode in ['rw', 'ro']) {
    test(
      'an idle $mode WAL connection that has read blocks activation',
      () async {
        final snapshot = upgradedProfile();
        final before = identity('application.db');
        final idle = await _Child.start(['idle', path, mode]);
        expect(await idle.next(), 'idle');
        await expectLater(
          activation().activate(snapshot.name, acceptDataLossOf: snapshot.name),
          throwsA(isA<RestoreActivationRefused>()),
        );
        expect(identity('application.db'), before);
        expect(residue(), isEmpty);
        // It is still a working connection to the unchanged profile.
        if (mode == 'rw') expect(await idle.command('write'), 'written');
        expect(await idle.command('read'), contains('newer profile content'));
        expect(await idle.command('close'), 'closed');
        expect(await idle.finish(), 0, reason: idle.errors.toString());
        final result = await activation().activate(
          snapshot.name,
          acceptDataLossOf: snapshot.name,
        );
        expectDisplaced(result.displaced, before);
        if (mode == 'rw') {
          read(
            backup(result.displaced),
            (db) => expect(bodies(db), contains('idle writer content')),
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'an idle rollback-journal connection is not detected; SQLite refuses its later writes',
    () async {
      final snapshot = upgradedProfile();
      final first = await activation().activate(
        snapshot.name,
        acceptDataLossOf: snapshot.name,
      );
      // The restored live database stays in rollback-journal mode until
      // Store opens it; an idle connection then holds no SQLite lock.
      read(path, (db) {
        expect(db.select('PRAGMA journal_mode').single.values.single, 'delete');
      });
      final writer = await _Child.start(['idle', path, 'rw']);
      final reader = await _Child.start(['idle', path, 'ro']);
      expect(await writer.next(), 'idle');
      expect(await reader.next(), 'idle');
      final undo = await activation().activate(
        first.displaced.name,
        acceptDataLossOf: first.displaced.name,
      );
      final observed = <String, String>{
        'reader read': await reader.command('read'),
        'writer read': await writer.command('read'),
        'write': await writer.command('write'),
        'wal-write': await writer.command('wal-write'),
        'hold-write': await writer.command('hold-write'),
      };
      // Process death with any transaction it managed to open.
      await writer.kill();
      expect(await reader.command('close'), 'closed');
      expect(await reader.finish(), 0);
      final state =
          '$observed; sidecars: ${sidecars()}; ${profileFiles().keys}';
      // Both still see the displaced database through their descriptors.
      expect(observed['reader read'], '["Backup private content"]');
      expect(observed['writer read'], '["Backup private content"]');
      // SQLITE_READONLY_DBMOVED (1032): the name now holds another file.
      for (final write in ['write', 'wal-write', 'hold-write']) {
        expect(observed[write], startsWith('refused: 1032 '), reason: state);
      }
      expect(
        profileFiles().keys.where(
          (name) => name.endsWith('-journal') || name.endsWith('-wal'),
        ),
        isEmpty,
        reason: state,
      );
      read(path, (db) {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(schema(db), Store.schemaVersion);
        expect(bodies(db), ['Backup private content', 'newer profile content']);
      });
      read(backup(undo.displaced), (db) {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(bodies(db), ['Backup private content']);
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // The service entrypoint, compiled from this source for each test that runs
  // it (shared with the service tests' kernel), then run with its restore
  // route like an installed command.
  Future<String> compileCommand() async {
    final kernel = '${scratch.path}/service.dill';
    if (File(kernel).existsSync()) return kernel;
    final compilation = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      ...sourceBuildDefines(),
      'bin/service.dart',
      '-o',
      kernel,
    ]);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout} ${compilation.stderr}',
    );
    return kernel;
  }

  Future<ProcessResult> command(List<String> arguments) async => Process.run(
    Platform.resolvedExecutable,
    [await compileCommand(), ...arguments],
    environment: {
      'HOME': scratch.path,
      'FORESIGHT_DATA': profile.data,
      'FORESIGHT_RUNTIME': profile.runtime,
    },
  );

  test(
    'a real service process owns the profile and refuses activation',
    () async {
      historical(path).dispose();
      final kernel = File('${scratch.path}/service.dill');
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        ...sourceBuildDefines(),
        'bin/service.dart',
        '-o',
        kernel.path,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout} ${compilation.stderr}',
      );
      final diagnostics = StringBuffer();
      Process? service = await Process.start(
        Platform.resolvedExecutable,
        [kernel.path],
        environment: {
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
          'FORESIGHT_HELPER': '',
        },
      );
      service.stdout.transform(utf8.decoder).listen(diagnostics.write);
      service.stderr.transform(utf8.decoder).listen(diagnostics.write);
      ServiceClient? client;
      try {
        for (
          final clock = Stopwatch()..start();
          clock.elapsed < const Duration(seconds: 60);
        ) {
          try {
            client = await ServiceClient.connect(serviceEndpoint(profile));
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(client, isNotNull, reason: diagnostics.toString());
        expect((await client!.call('status') as Map)['pid'], service.pid);
        await client.call('notes.save', {
          'title': 'Served',
          'body': 'newer profile content',
        });
        final snapshot = MigrationBackups(
          path,
        ).snapshots(supportedVersion: Store.schemaVersion).single;
        final before = identity('application.db');
        await expectLater(
          activation().activate(snapshot.name, acceptDataLossOf: snapshot.name),
          throwsA(isA<ActiveProfileOwner>()),
        );
        await expectLater(
          activation().recover(),
          throwsA(isA<ActiveProfileOwner>()),
        );
        final refused = await command([
          '--restore-activate=${snapshot.name}',
          '--accept-data-loss=${snapshot.name}',
        ]);
        expect(refused.exitCode, 75, reason: '${refused.stderr}');
        expect(identity('application.db'), before);
        expect(residue(), isEmpty);
        // The refused attempts did not disturb the owner.
        expect(
          (await client.call('notes.list') as List).map((n) => n['body']),
          contains('newer profile content'),
        );
        await client.close();
        client = null;
        service.kill(ProcessSignal.sigterm);
        expect(
          await service.exitCode.timeout(const Duration(seconds: 60)),
          0,
          reason: diagnostics.toString(),
        );
        service = null;
        final result = await activation().activate(
          snapshot.name,
          acceptDataLossOf: snapshot.name,
        );
        read(path, (db) => expect(bodies(db), ['Backup private content']));
        expectDisplaced(result.displaced, before);
      } finally {
        await client?.close();
        if (service != null) {
          service.kill(ProcessSignal.sigkill);
          await service.exitCode;
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'the command lists, requires acknowledgement, activates and recovers',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      final listed = await command(['--restore-list']);
      expect(listed.exitCode, 0, reason: '${listed.stderr}');
      final listing = jsonDecode(listed.stdout as String) as Map;
      expect(listing['supported_schema'], Store.schemaVersion);
      final entry = (listing['snapshots'] as List).single as Map;
      expect(entry['name'], snapshot.name);
      expect(entry['data_loss_point'], snapshot.created.toIso8601String());
      for (final unconfirmed in [
        ['--restore-activate=${snapshot.name}'],
        ['--restore-activate=${snapshot.name}', '--accept-data-loss=other'],
      ]) {
        final refused = await command(unconfirmed);
        expect(refused.exitCode, 64, reason: '${refused.stderr}');
        expectUnchanged(before);
      }
      final activated = await command([
        '--restore-activate=${snapshot.name}',
        '--accept-data-loss=${snapshot.name}',
      ]);
      expect(activated.exitCode, 0, reason: '${activated.stderr}');
      final result = jsonDecode(activated.stdout as String) as Map;
      expect(result['schema'], 19);
      expect(result['data_loss_point'], snapshot.created.toIso8601String());
      final displaced = result['displaced_snapshot'] as String;
      expect(backupIdentity(displaced), before);
      expect(
        DateTime.parse(result['displaced_retained_until'] as String),
        isA<DateTime>(),
      );
      read(path, (db) => expect(bodies(db), ['Backup private content']));
      final recovered = await command(['--restore-recover']);
      expect(recovered.exitCode, 0, reason: '${recovered.stderr}');
      expect(jsonDecode(recovered.stdout as String), {
        'displaced_snapshots': <Object?>[],
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'without a verified runtime selection the command refuses before the profile lock or SQLite',
    () async {
      final snapshot = upgradedProfile();
      final bytes = File(path).readAsBytesSync();
      final files = sidecars();
      final lock = File('${profile.data}/.application.lock');
      expect(lock.existsSync(), isFalse);
      // No source-build metadata: no SQL support can be selected.
      final kernel = '${scratch.path}/unselected.dill';
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        'bin/service.dart',
        '-o',
        kernel,
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
      final refused = await Process.run(
        Platform.resolvedExecutable,
        [
          kernel,
          '--restore-activate=${snapshot.name}',
          '--accept-data-loss=${snapshot.name}',
        ],
        environment: {
          'HOME': scratch.path,
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
        },
      );
      expect(refused.exitCode, 1, reason: '${refused.stderr}');
      expect(
        refused.stderr,
        contains(
          'The restore command could not start: Diagnostic startup is '
          'unavailable',
        ),
      );
      expect(refused.stdout, isEmpty);
      expect(lock.existsSync(), isFalse);
      expect(File(path).readAsBytesSync(), bytes);
      expect(sidecars(), files);
      expect(residue(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'restore arguments and the confirmation are rejected before bootstrap, SQLite or profile access',
    () async {
      final snapshot = upgradedProfile();
      final bytes = File(path).readAsBytesSync();
      final files = sidecars();
      final lock = File('${profile.data}/.application.lock');
      // Without source-build metadata this kernel's bootstrap refuses with
      // exit 1, so exit 64 shows the rejection came first.
      final kernel = '${scratch.path}/unselected.dill';
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        'bin/service.dart',
        '-o',
        kernel,
      ]);
      expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
      final name = snapshot.name;
      for (final (arguments, message) in [
        (['--restore-activate=$name'], 'Repeat the snapshot name'),
        (
          ['--restore-activate=$name', '--accept-data-loss=other'],
          'Repeat the snapshot name',
        ),
        (['--accept-data-loss=$name'], 'Usage: foresight-service'),
        (['--restore-list', '--restore-recover'], 'Usage: foresight-service'),
        (['--restore-list=1'], 'Usage: foresight-service'),
        (['--restore-activate='], 'Usage: foresight-service'),
        (['--restore-bogus'], 'Usage: foresight-service'),
        (['--restore-list', '--status'], 'Usage: foresight-service'),
      ]) {
        final refused = await Process.run(
          Platform.resolvedExecutable,
          [kernel, ...arguments],
          environment: {
            'HOME': scratch.path,
            'FORESIGHT_DATA': profile.data,
            'FORESIGHT_RUNTIME': profile.runtime,
          },
        );
        expect(refused.exitCode, 64, reason: '$arguments ${refused.stderr}');
        expect(refused.stderr, contains(message), reason: '$arguments');
        expect(refused.stderr, isNot(contains('could not start')));
        expect(refused.stdout, isEmpty, reason: '$arguments');
      }
      expect(lock.existsSync(), isFalse);
      expect(File(path).readAsBytesSync(), bytes);
      expect(sidecars(), files);
      expect(residue(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the service worker route keeps precedence over the restore route',
    () async {
      upgradedProfile();
      final bytes = File(path).readAsBytesSync();
      final routed = await Process.run(
        Platform.resolvedExecutable,
        [await compileCommand(), '--model-transport-worker', '--restore-list'],
        environment: {
          'HOME': scratch.path,
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
        },
      );
      // The worker route's own argument check answers; restore never runs.
      expect(routed.exitCode, 64, reason: '${routed.stderr}');
      expect(routed.stdout, isEmpty);
      expect(routed.stderr, isNot(contains('Usage: foresight-service')));
      expect(File('${profile.data}/.application.lock').existsSync(), isFalse);
      expect(File(path).readAsBytesSync(), bytes);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'recovery reports a previous profile retained before process death',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      await crashAt(snapshot, 'retained');
      final recovered = await command(['--restore-recover']);
      expect(recovered.exitCode, 0, reason: '${recovered.stderr}');
      final names =
          (jsonDecode(recovered.stdout as String) as Map)['displaced_snapshots']
              as List;
      expect(backupIdentity(names.single as String), before);
      expect(residue(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'activation reports the snapshots its recovery retained',
    () async {
      final snapshot = upgradedProfile();
      final before = identity('application.db');
      await crashAt(snapshot, 'retained');
      // Already a managed candidate of the restored live profile.
      final listed = await command(['--restore-list']);
      expect(listed.exitCode, 0, reason: '${listed.stderr}');
      final name =
          ((jsonDecode(listed.stdout as String) as Map)['snapshots'] as List)
                  .single['name']
              as String;
      expect(backupIdentity(name), before);
      final activated = await command([
        '--restore-activate=$name',
        '--accept-data-loss=$name',
      ]);
      expect(activated.exitCode, 0, reason: '${activated.stderr}');
      final result = jsonDecode(activated.stdout as String) as Map;
      expect(result['recovered_snapshots'], [name]);
      expect(result['snapshot'], name);
      expect(residue(), isEmpty);
      read(path, (db) {
        expect(bodies(db), ['Backup private content', 'newer profile content']);
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
