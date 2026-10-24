import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/migration_backups.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/open.dart' as loader;
import 'package:test/test.dart';

Database _old(String path, [int version = 20]) {
  final db = openApplicationDatabase(path);
  db.execute(
    File('test/fixtures/persistence-c28a1561/schema15.sql').readAsStringSync(),
  );
  for (var current = 16; current <= version; current++) {
    ApplicationMigrations(db).run(current);
  }
  db.execute('PRAGMA user_version=$version');
  return db;
}

void main() {
  late String path;
  setUp(() {
    path =
        '${createTestTempDirectorySync('backup-maintenance-').path}/application.db';
  });
  test(
    'DELETE profile migration releases ownership for child readers',
    () async {
      final db = _old(path, 19);
      expect(db.select('PRAGMA journal_mode').single.values.single, 'delete');
      db.dispose();
      final store = Store(path);
      addTearDown(store.close);
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/migration_reader_probe.dart',
        path,
      ]);
      expect(child.exitCode, 0, reason: '${child.stdout}\n${child.stderr}');
      expect(child.stdout, contains('reader_opened'));
      expect(store.rows('PRAGMA locking_mode').single.values.single, 'normal');
    },
  );
  test('pending erasure completes before upgrade snapshot is created', () async {
    final db = _old(path);
    db.execute(
      "INSERT INTO preferences(key,value) VALUES('internal.backupErasurePending','1')",
    );
    db.dispose();
    final store = Store(path);
    addTearDown(store.close);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(store.privacyMaintenancePending, isFalse);
    expect(
      store.migrationBackups.snapshots(supportedVersion: Store.schemaVersion),
      hasLength(1),
    );
  });
  for (final mode in ['DELETE', 'WAL']) {
    test(
      'backup creation inspection and pruning preserve SQLite locks across processes ($mode)',
      () async {
        final db = _old(path);
        addTearDown(db.dispose);
        db.execute('PRAGMA journal_mode=$mode');
        db.execute('PRAGMA locking_mode=EXCLUSIVE');
        db.execute('BEGIN EXCLUSIVE');
        db.execute('COMMIT');
        final backups = MigrationBackups(path);
        backups.create(db, 20);
        for (final check in [
          () {},
          () => backups.snapshots(supportedVersion: 20),
          backups.prune,
        ]) {
          check();
          final result = await Process.run(Platform.resolvedExecutable, [
            'run',
            'test/fixtures/migration_lock_probe.dart',
            path,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout, contains('SQLITE_BUSY'));
        }
      },
    );
  }
  test(
    'safe stale corrupt and expired snapshots do not block the next upgrade',
    () {
      final db = _old(path);
      final backups = MigrationBackups(path);
      final snapshot = backups.create(db, 20);
      db.dispose();
      final bytes = File('${backups.directoryPath}/${snapshot.name}');
      final original = bytes.readAsBytesSync();
      bytes.writeAsBytesSync([...original, 42]);
      expect(backups.snapshots(supportedVersion: 20), isEmpty);
      expect(
        () => backups.restoreCopy(
          snapshot.name,
          supportedVersion: 20,
          confirmDataLoss: true,
        ),
        throwsStateError,
      );
      final upgraded = Store(path);
      expect(
        upgraded.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      upgraded.close();
      final previous = '$path.previous';
      File(path).renameSync(previous);
      _old(path).dispose();
      final replacement = Store(path);
      addTearDown(replacement.close);
      expect(
        replacement.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(
        replacement.migrationBackups.snapshots(
          supportedVersion: Store.schemaVersion,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'metadata pruning drops expired foreign-source records before payload verification',
    () {
      final db = _old(path);
      addTearDown(db.dispose);
      var now = DateTime.now().toUtc();
      final backups = MigrationBackups(path, now: () => now);
      final snapshot = backups.create(db, 20);
      final manifest = File('${backups.directoryPath}/${snapshot.name}.json');
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      json['source'] = 'foreign:identity';
      manifest.writeAsStringSync(jsonEncode(json));
      File(
        '${backups.directoryPath}/${snapshot.name}',
      ).writeAsStringSync('safe invalid payload');
      now = now.add(const Duration(days: 8));
      backups.prune();
      expect(Directory(backups.directoryPath).listSync(), isEmpty);
    },
  );
  test(
    'atomic publication never overwrites or introduces two-link crash states',
    () {
      final root = BackupDirectory(
        createTestTempDirectorySync('rename-').path,
        private: false,
      );
      addTearDown(root.close);
      final staging = root.open('staging', create: true);
      staging.write([1]);
      staging.close();
      root.publish('staging', 'complete');
      expect(root.containsEntry('staging'), isFalse);
      expect(root.metadata('complete').links, 1);
      final replacement = root.open('staging', create: true);
      replacement.write([2]);
      replacement.close();
      expect(() => root.publish('staging', 'complete'), throwsStateError);
      final complete = root.open('complete');
      expect(complete.readSmall(2), [1]);
      complete.close();
      expect(root.metadata('complete').links, 1);
      expect(root.metadata('staging').links, 1);
    },
  );
  test(
    'process death after payload rename leaves a one-link orphan that the next upgrade reclaims',
    () async {
      _old(path).dispose();
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/migration_publication_crash.dart',
        path,
      ]);
      expect(result.exitCode, 79, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('published_without_manifest'));
      final directory = BackupDirectory('$path.backups');
      const name = 'snapshot-1-00000000000000000000000000000000.db';
      expect(directory.metadata(name).links, 1);
      directory.close();
      expect(MigrationBackups(path).snapshots(supportedVersion: 20), isEmpty);
      final store = Store(path);
      addTearDown(store.close);
      expect(File('$path.backups/$name').existsSync(), isFalse);
      expect(
        store.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(store.rows('PRAGMA integrity_check').single.values.single, 'ok');
    },
  );

  test(
    'prepared copies have a count age bound and legacy large directories remain erasable',
    () {
      final db = _old(path);
      addTearDown(db.dispose);
      final backups = MigrationBackups(path);
      final snapshot = backups.create(db, 20);
      var latest = '';
      for (var i = 0; i < 4; i++) {
        latest = backups.restoreCopy(
          snapshot.name,
          supportedVersion: 20,
          confirmDataLoss: true,
        );
      }
      expect(
        Directory(
          backups.directoryPath,
        ).listSync().where((file) => file.path.contains('/restore-')),
        hasLength(1),
      );
      File(
        latest,
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
      backups.prune();
      expect(File(latest).existsSync(), isFalse);
      final directory = BackupDirectory(backups.directoryPath);
      for (var i = 0; i < 300; i++) {
        final file = directory.open(
          'restore-${i.toRadixString(16).padLeft(32, '0')}.db',
          create: true,
        );
        file.write([1]);
        file.close();
      }
      directory.close();
      backups.erase();
      expect(Directory(backups.directoryPath).listSync(), isEmpty);
    },
  );
  test(
    'ordinary deletion erases backups and WAL debt without executing VACUUM',
    () async {
      final old = _old(path);
      old.execute(
        "INSERT INTO notes(id,title,body,revision) VALUES(1,'Private','single-delete-canary',1)",
      );
      old.dispose();
      final store = Store(path);
      addTearDown(store.close);
      const note = 1;
      final snapshot = store.migrationBackups
          .snapshots(supportedVersion: Store.schemaVersion)
          .single;
      expect(
        latin1
            .decode(
              File(
                '${store.migrationBackups.directoryPath}/${snapshot.name}',
              ).readAsBytesSync(),
            )
            .contains('single-delete-canary'),
        isTrue,
      );
      final guard = _VacuumGuard(store.db);
      addTearDown(guard.close);
      store.db.execute('DELETE FROM notes WHERE id=?', [note]);
      expect(store.privacyMaintenancePending, isTrue);
      await eventually(() => !store.privacyMaintenancePending);
      expect(store.notes(), isEmpty);
      expect(store.contentHistory.revisions('notes', note), isEmpty);
      expect(
        Directory(store.migrationBackups.directoryPath).listSync(),
        isEmpty,
      );
      expect(guard.attempts, 0);
      // Positive control: this authorizer really does reject SQLite's VACUUM.
      expect(() => store.db.execute('VACUUM'), throwsA(isA<SqliteException>()));
      expect(guard.attempts, 1);
    },
  );
  test(
    'held WAL reader keeps individual deletion pending until checkpoint can truncate',
    () async {
      final store = Store(path);
      addTearDown(store.close);
      final marker = 'held-reader-private-note-canary';
      final note = store.saveNote(null, 'Private', marker);
      final reader = openApplicationDatabase(path, mode: OpenMode.readOnly);
      var readerClosed = false;
      addTearDown(() {
        if (!readerClosed) reader.dispose();
      });
      reader.execute('BEGIN');
      reader.select('SELECT body FROM notes');
      store.db.execute('DELETE FROM notes WHERE id=?', [note]);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(store.privacyMaintenancePending, isTrue);
      expect(
        latin1.decode(File('$path-wal').readAsBytesSync()).contains(marker),
        isTrue,
      );
      reader.execute('COMMIT');
      await eventually(() => !store.privacyMaintenancePending);
      expect(store.notes(), isEmpty);
      reader.dispose();
      readerClosed = true;
      store.close();
      // Inspect raw bytes only after database owners have closed, so the test
      // itself cannot release SQLite locks through a second raw file handle.
      expect(
        latin1.decode(File(path).readAsBytesSync()).contains(marker),
        isFalse,
      );
    },
  );
  test(
    'schema20 legacy privacy intent completes full cleanup before21 snapshot',
    () async {
      final db = _old(path);
      db.execute('CREATE TABLE cleanup_probe(body BLOB)');
      db.execute('INSERT INTO cleanup_probe VALUES(zeroblob(1048576))');
      db.execute('DELETE FROM cleanup_probe');
      expect(
        db.select('PRAGMA freelist_count').single.values.single,
        greaterThan(0),
      );
      db.execute(
        "INSERT INTO preferences(key,value) VALUES('internal.privacyMaintenancePending','1')",
      );
      db.dispose();
      final store = Store(path);
      addTearDown(store.close);
      expect(store.privacyMaintenancePending, isFalse);
      expect(store.rows('PRAGMA freelist_count').single.values.single, 0);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(
        store.migrationBackups.snapshots(supportedVersion: Store.schemaVersion),
        hasLength(1),
      );
    },
  );
  test('blocked prior cleanup refuses upgrade and retains erasure intent', () {
    final db = _old(path);
    db.execute('PRAGMA journal_mode=WAL');
    final reader = openApplicationDatabase(path, mode: OpenMode.readOnly);
    reader.execute('BEGIN');
    reader.select('SELECT COUNT(*) FROM preferences');
    db.execute(
      "INSERT INTO preferences(key,value) VALUES('internal.backupErasurePending','1')",
    );
    expect(
      () => Store(path),
      throwsA(anyOf(isA<StateError>(), isA<SqliteException>())),
    );
    expect(db.select('PRAGMA user_version').single.values.single, 20);
    expect(
      db.select(
        "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
      ),
      isNotEmpty,
    );
    expect(MigrationBackups(path).exists, isFalse);
    reader.execute('COMMIT');
    reader.dispose();
    db.dispose();
    final store = Store(path);
    addTearDown(store.close);
    expect(store.privacyMaintenancePending, isFalse);
    expect(
      store.migrationBackups.snapshots(supportedVersion: Store.schemaVersion),
      hasLength(1),
    );
  });
  test(
    'future manifests expire beyond skew while new clock-rollback backup survives admission',
    () {
      final db = _old(path);
      addTearDown(db.dispose);
      var now = DateTime.now().toUtc();
      final backups = MigrationBackups(path, now: () => now);
      final old = backups.create(db, 20);
      final manifest = File('${backups.directoryPath}/${old.name}.json');
      final value =
          jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      value['created'] = now
          .add(const Duration(days: 365))
          .millisecondsSinceEpoch;
      manifest.writeAsStringSync(jsonEncode(value));
      backups.prune();
      expect(Directory(backups.directoryPath).listSync(), isEmpty);
      var calls = 0;
      final rollback = MigrationBackups(
        path,
        now: () {
          calls++;
          return calls <= 2 ? now : now.subtract(const Duration(days: 1));
        },
      );
      final fresh = rollback.create(db, 20);
      expect(
        File('${backups.directoryPath}/${fresh.name}').existsSync(),
        isTrue,
      );
      now = now.subtract(const Duration(days: 1));
      backups.prune();
      expect(Directory(backups.directoryPath).listSync(), isEmpty);
    },
  );
}

typedef _Authorizer =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );

final class _VacuumGuard {
  _VacuumGuard(this.db) {
    _set = loader.open
        .openSqlite()
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<NativeFunction<_Authorizer>>,
            Pointer<Void>,
          ),
          int Function(
            Pointer<Void>,
            Pointer<NativeFunction<_Authorizer>>,
            Pointer<Void>,
          )
        >('sqlite3_set_authorizer');
    _callback = NativeCallable<_Authorizer>.isolateLocal((
      Pointer<Void> _,
      int action,
      Pointer<Utf8> a,
      Pointer<Utf8> b,
      Pointer<Utf8> c,
      Pointer<Utf8> d,
    ) {
      if (action == 24) {
        attempts++;
        return 1;
      }
      return 0;
    }, exceptionalReturn: 1);
    if (_set(db.handle.cast<Void>(), _callback.nativeFunction, nullptr) != 0) {
      throw StateError('Cannot install VACUUM positive control');
    }
  }
  final Database db;
  late final int Function(
    Pointer<Void>,
    Pointer<NativeFunction<_Authorizer>>,
    Pointer<Void>,
  )
  _set;
  late final NativeCallable<_Authorizer> _callback;
  int attempts = 0;
  bool _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    _set(db.handle.cast<Void>(), nullptr, nullptr);
    _callback.close();
  }
}
