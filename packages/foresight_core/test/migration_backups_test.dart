import 'dart:io';

import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/migration_backups.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

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

void main() {
  late String path;
  setUp(() {
    path = '${createTestTempDirectorySync('backup-').path}/application.db';
  });

  test('descriptor VACUUM preserves a verified schema19 restore candidate', () {
    historical(path).dispose();
    final store = Store(path);
    addTearDown(store.close);
    final backups = store.migrationBackups;
    final snapshot = backups
        .snapshots(supportedVersion: Store.schemaVersion)
        .single;
    expect(snapshot.schema, 19);
    expect(store.notes().single['body'], 'Backup private content');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    expect(FileStat.statSync(backups.directoryPath).mode & 0x1ff, 0x1c0);
    for (final file in Directory(backups.directoryPath).listSync()) {
      expect(file.statSync().mode & 0x1ff, 0x180);
    }
    expect(
      () => backups.restoreCopy(
        snapshot.name,
        supportedVersion: 19,
        confirmDataLoss: false,
      ),
      throwsStateError,
    );
    expect(
      () => backups.restoreCopy(
        snapshot.name,
        supportedVersion: 18,
        confirmDataLoss: true,
      ),
      throwsStateError,
    );
    final restored = backups.restoreCopy(
      snapshot.name,
      supportedVersion: 19,
      confirmDataLoss: true,
    );
    final reader = openApplicationDatabase(restored, mode: OpenMode.readOnly);
    try {
      expect(reader.select('PRAGMA user_version').single.values.single, 19);
      expect(
        reader.select('SELECT body FROM notes').single['body'],
        'Backup private content',
      );
      expect(
        reader.select('PRAGMA integrity_check').single.values.single,
        'ok',
      );
    } finally {
      reader.dispose();
    }
    expect(store.notes().single['body'], 'Backup private content');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
  });

  test(
    'backup includes committed WAL and excludes uncommitted writer work',
    () {
      final source = historical(path);
      source.execute('PRAGMA journal_mode=WAL');
      source.execute('PRAGMA wal_autocheckpoint=0');
      source.execute("UPDATE notes SET body='committed WAL'");
      final competing = openApplicationDatabase(path);
      competing.execute('BEGIN IMMEDIATE');
      competing.execute("UPDATE notes SET body='uncommitted'");
      expect(() => Store(path), throwsA(isA<SqliteException>()));
      competing.execute('ROLLBACK');
      competing.dispose();
      source.dispose();
      final store = Store(path);
      addTearDown(store.close);
      final snapshot = store.migrationBackups
          .snapshots(supportedVersion: 20)
          .single;
      final restored = store.migrationBackups.restoreCopy(
        snapshot.name,
        supportedVersion: 19,
        confirmDataLoss: true,
      );
      final reader = openApplicationDatabase(restored, mode: OpenMode.readOnly);
      try {
        expect(
          reader.select('SELECT body FROM notes').single['body'],
          'committed WAL',
        );
      } finally {
        reader.dispose();
      }
    },
  );

  test(
    'failed migration retains verified backup and unchanged original schema',
    () {
      final source = historical(path);
      source.execute(
        "CREATE TRIGGER deny_upgrade BEFORE INSERT ON preferences BEGIN SELECT RAISE(ABORT,'fixture interrupted upgrade'); END",
      );
      source.dispose();
      expect(() => Store(path), throwsA(isA<SqliteException>()));
      final reader = openApplicationDatabase(path);
      try {
        expect(reader.select('PRAGMA user_version').single.values.single, 19);
        expect(
          reader.select('SELECT body FROM notes').single['body'],
          'Backup private content',
        );
        expect(
          reader
              .select('PRAGMA table_info(sources)')
              .any((r) => r['name'] == 'generated'),
          isFalse,
        );
        expect(
          MigrationBackups(path).snapshots(supportedVersion: 19),
          hasLength(1),
        );
        reader.execute('DROP TRIGGER deny_upgrade');
      } finally {
        reader.dispose();
      }
      final retried = Store(path);
      addTearDown(retried.close);
      expect(
        retried.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
    },
  );

  test('backup failure refuses migration without pruning original history', () {
    historical(path).dispose();
    File('$path.backups').writeAsStringSync('not a directory');
    expect(() => Store(path), throwsStateError);
    final reader = openApplicationDatabase(path);
    try {
      expect(reader.select('PRAGMA user_version').single.values.single, 19);
      expect(
        reader.select('SELECT body FROM notes').single['body'],
        'Backup private content',
      );
      expect(
        reader
            .select('PRAGMA table_info(sources)')
            .any((r) => r['name'] == 'generated'),
        isFalse,
      );
    } finally {
      reader.dispose();
    }
  });

  test(
    'real file-size failure leaves old schema intact and no restore candidate',
    () async {
      final source = historical(path);
      source.execute('UPDATE notes SET body=?', [
        'constrained filesystem fixture ' * 8192,
      ]);
      source.dispose();
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/migration_backup_limit.dart',
        path,
      ]);
      // Keep captured subprocess output in the failing assertion, not just status.
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('migration_refused'));
      expect(
        Directory('$path.backups').existsSync(),
        isTrue,
        reason: 'The constrained write reached backup admission.',
      );
      final db = openApplicationDatabase(path);
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 19);
        expect(
          (db.select('SELECT body FROM notes').single['body'] as String).length,
          greaterThan(8192),
        );
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      } finally {
        db.dispose();
      }
      expect(MigrationBackups(path).snapshots(supportedVersion: 19), isEmpty);
    },
  );

  test(
    'retention keeps two completed snapshots and expires after seven days',
    () {
      final db = historical(path);
      addTearDown(db.dispose);
      var now = DateTime.utc(2026, 10, 1);
      final backups = MigrationBackups(path, now: () => now);
      final first = backups.create(db, 19);
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(hours: 1));
        backups.create(db, 19);
      }
      expect(backups.snapshots(supportedVersion: 19), hasLength(2));
      expect(
        File('${backups.directoryPath}/${first.name}').existsSync(),
        isFalse,
      );
      now = now.add(const Duration(days: 8));
      expect(backups.snapshots(supportedVersion: 19), isEmpty);
      backups.create(db, 19);
      expect(backups.snapshots(supportedVersion: 19), hasLength(1));
      expect(Directory(backups.directoryPath).listSync(), hasLength(2));
    },
  );

  test(
    'clock rollback cannot evict the backup just taken before migration',
    () {
      final db = historical(path);
      addTearDown(db.dispose);
      var now = DateTime.utc(2026, 10, 10);
      final backups = MigrationBackups(path, now: () => now);
      backups.create(db, 19);
      now = now.add(const Duration(hours: 1));
      backups.create(db, 19);
      now = now.subtract(const Duration(days: 1));
      final current = backups.create(db, 19);
      expect(backups.snapshots(supportedVersion: 19), hasLength(2));
      expect(
        backups.snapshots(supportedVersion: 19).map((s) => s.name),
        contains(current.name),
      );
    },
  );

  test(
    'partial snapshots never become candidates and bad checksums fail closed',
    () {
      final db = historical(path);
      final backups = MigrationBackups(path);
      final snapshot = backups.create(db, 19);
      db.dispose();
      final directory = BackupDirectory(backups.directoryPath);
      final partial = directory.open(
        'snapshot-1-${'0' * 32}.db.partial',
        create: true,
      );
      partial.write([1, 2, 3]);
      partial.close();
      directory.close();
      expect(backups.snapshots(supportedVersion: 19), hasLength(1));
      final file = File('${backups.directoryPath}/${snapshot.name}');
      final handle = file.openSync(mode: FileMode.append);
      handle.writeByteSync(42);
      handle.closeSync();
      expect(backups.snapshots(supportedVersion: 19), isEmpty);
      expect(
        () => backups.restoreCopy(
          snapshot.name,
          supportedVersion: 19,
          confirmDataLoss: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'backup paths reject symlinks, hardlinks, unsafe modes and replaced directories',
    () {
      final db = historical(path);
      final backups = MigrationBackups(path);
      final snapshot = backups.create(db, 19);
      db.dispose();
      final snapshotPath = '${backups.directoryPath}/${snapshot.name}';
      final held = '$path.held';
      File(snapshotPath).renameSync(held);
      Link(snapshotPath).createSync(held);
      expect(() => backups.snapshots(supportedVersion: 19), throwsStateError);
      Link(snapshotPath).deleteSync();
      File(held).renameSync(snapshotPath);
      expect(Process.runSync('/bin/chmod', ['644', snapshotPath]).exitCode, 0);
      expect(() => backups.snapshots(supportedVersion: 19), throwsStateError);
      expect(Process.runSync('/bin/chmod', ['600', snapshotPath]).exitCode, 0);
      final hardlink = '${backups.directoryPath}/snapshot-2-${'1' * 32}.db';
      expect(Process.runSync('/bin/ln', [snapshotPath, hardlink]).exitCode, 0);
      expect(() => backups.snapshots(supportedVersion: 19), throwsStateError);
      File(hardlink).deleteSync();
      final directory = BackupDirectory(backups.directoryPath);
      Directory(
        backups.directoryPath,
      ).renameSync('${backups.directoryPath}.held');
      Directory(backups.directoryPath).createSync();
      expect(() => directory.verifyAnchor(), throwsStateError);
      directory.close();
    },
  );

  test(
    'backup root and special-file substitution are refused without following them',
    () {
      historical(path).dispose();
      final foreign = createTestTempDirectorySync('not-backups-');
      final sentinel = File('${foreign.path}/sentinel')
        ..writeAsStringSync('retained');
      Link('$path.backups').createSync(foreign.path);
      expect(() => Store(path), throwsStateError);
      expect(sentinel.readAsStringSync(), 'retained');
      Link('$path.backups').deleteSync();
      final store = Store(path);
      addTearDown(store.close);
      final snapshot = store.migrationBackups
          .snapshots(supportedVersion: 20)
          .single;
      final target = '${store.migrationBackups.directoryPath}/${snapshot.name}';
      File(target).deleteSync();
      expect(
        Process.runSync('/usr/bin/mkfifo', ['-m', '600', target]).exitCode,
        0,
      );
      expect(
        () => store.migrationBackups.snapshots(supportedVersion: 20),
        throwsStateError,
      );
      expect(sentinel.readAsStringSync(), 'retained');
    },
  );

  test('snapshot source identity cannot be transferred to another profile', () {
    historical(path).dispose();
    final store = Store(path);
    store.close();
    final displaced = '$path.previous';
    File(path).renameSync(displaced);
    historical(path).dispose();
    expect(
      MigrationBackups(path).snapshots(supportedVersion: Store.schemaVersion),
      isEmpty,
    );
    final reader = openApplicationDatabase(path);
    try {
      expect(reader.select('PRAGMA user_version').single.values.single, 19);
    } finally {
      reader.dispose();
    }
  });

  test(
    'clear erases snapshots and restored copies; unsafe cleanup intent survives restart',
    () async {
      historical(path).dispose();
      var store = Store(path);
      final snapshot = store.migrationBackups
          .snapshots(supportedVersion: 20)
          .single;
      store.migrationBackups.restoreCopy(
        snapshot.name,
        supportedVersion: 19,
        confirmDataLoss: true,
      );
      final unknown = File(
        '${store.migrationBackups.directoryPath}/unexpected',
      );
      unknown.writeAsStringSync('must not silently unlink an unknown entry');
      WorkspacePersistence(store).clearLocalData([]);
      store.compactAfterClear();
      expect(store.privacyMaintenancePending, isTrue);
      expect(store.notes(), isEmpty);
      store.close();
      store = Store(path);
      addTearDown(() => store.close());
      expect(store.privacyMaintenancePending, isTrue);
      unknown.deleteSync();
      await eventually(() => !store.privacyMaintenancePending);
      expect(
        Directory(store.migrationBackups.directoryPath).listSync(),
        isEmpty,
      );
    },
  );

  test(
    'individual deletion erases every snapshot containing the removed entity',
    () async {
      historical(path).dispose();
      final store = Store(path);
      addTearDown(store.close);
      expect(
        store.migrationBackups.snapshots(supportedVersion: 20),
        hasLength(1),
      );
      store.db.execute('DELETE FROM notes WHERE id=1');
      expect(store.privacyMaintenancePending, isTrue);
      await eventually(() => !store.privacyMaintenancePending);
      expect(store.migrationBackups.snapshots(supportedVersion: 20), isEmpty);
    },
  );
}
