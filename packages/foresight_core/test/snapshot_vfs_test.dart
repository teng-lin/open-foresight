import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/snapshot_vfs.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late BackupDirectory directory;
  late BackupFile file, journal;
  setUp(() {
    final root = BackupDirectory(
      createTestTempDirectorySync('snapshot-vfs-').path,
      private: false,
    );
    try {
      directory = root.childForTest();
    } finally {
      root.close();
    }
    file = directory.open('snapshot.db', create: true);
    journal = directory.open('journal.partial', create: true);
    addTearDown(() {
      file.close();
      journal.close();
      directory.close();
    });
  });

  test('snapshot VFS never reopens a replaced main pathname', () {
    final writer = SnapshotVfs(file, writable: true, journal: journal);
    writer.registered(() {
      final db = sqlite3.open('/snapshot', vfs: writer.name);
      try {
        db.execute('CREATE TABLE payload(value TEXT)');
        db.execute('INSERT INTO payload VALUES(?)', ['owned descriptor bytes']);
      } finally {
        db.dispose();
      }
    });
    File(
      '${directory.path}/snapshot.db',
    ).renameSync('${directory.path}/retained.db');
    File('${directory.path}/snapshot.db').writeAsStringSync('substituted path');
    final reader = SnapshotVfs(file, writable: false);
    reader.registered(() {
      final db = sqlite3.open(
        '/snapshot',
        vfs: reader.name,
        mode: OpenMode.readOnly,
      );
      try {
        expect(
          db.select('SELECT value FROM payload').single['value'],
          'owned descriptor bytes',
        );
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      } finally {
        db.dispose();
      }
    });
    expect(
      File('${directory.path}/snapshot.db').readAsStringSync(),
      'substituted path',
    );
    expect(journal.size, 0);
  });

  test(
    'snapshot VFS refuses every unregistered filename and a second main owner',
    () {
      final vfs = SnapshotVfs(file, writable: true, journal: journal);
      vfs.registered(() {
        expect(
          () => sqlite3.open('/foreign', vfs: vfs.name),
          throwsA(isA<SqliteException>()),
        );
        final first = sqlite3.open('/snapshot', vfs: vfs.name);
        try {
          expect(
            () => sqlite3.open('/snapshot', vfs: vfs.name),
            throwsA(isA<SqliteException>()),
          );
        } finally {
          first.dispose();
        }
      });
    },
  );

  test('positional IO preserves offsets and short reads zero-fill', () {
    file.writeAt(Uint8List.fromList([1, 2, 3, 4]), 9);
    final vfs = SnapshotVfs(file, writable: false);
    final opened = vfs
        .xOpen(Sqlite3Filename('/snapshot'), SqlFlag.SQLITE_OPEN_READONLY)
        .file;
    final bytes = Uint8List(8)..fillRange(0, 8, 99);
    expect(
      () => opened.xRead(bytes, 9),
      throwsA(
        isA<VfsException>().having(
          (error) => error.returnCode,
          'short read',
          SqlExtendedError.SQLITE_IOERR_SHORT_READ,
        ),
      ),
    );
    expect(bytes, [1, 2, 3, 4, 0, 0, 0, 0]);
    expect(() => opened.xWrite(Uint8List(1), 0), throwsA(isA<VfsException>()));
    opened.xClose();
    file.truncateTo(7);
    expect(file.size, 7);
  });
}

extension on BackupDirectory {
  BackupDirectory childForTest() {
    // The test helper's parent is owner-controlled but may have a public read
    // mode. Create the fixture's scoped private directory at0700, not by chmod.
    final path = '${this.path}/private';
    return BackupDirectory(path);
  }
}
