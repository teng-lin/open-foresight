import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'backup_files.dart';
import 'sqlite_runtime.dart';

/// SQLite sees a private, already-open snapshot and scratch journal. Neither
/// main-file operations nor journal probes reopen names, including on Darwin where the
/// standard Unix VFS cannot open /dev/fd with its ordinary creation flags.
/// This VFS is not suitable for shared/live databases: the migration owner alone
/// owns the fresh destination and retains its source's exclusive SQLite lock.
final class SnapshotVfs extends BaseVirtualFileSystem {
  SnapshotVfs(this.file, {required this.writable, this.journal})
    : super(
        name:
            'foresight_snapshot_${Random.secure().nextInt(0x7fffffff)}_${Random.secure().nextInt(0x7fffffff)}',
      );
  final BackupFile file;
  final bool writable;
  final BackupFile? journal;
  bool _opened = false, _journalOpened = false, _journalExists = false;
  static const _path = '/snapshot';
  String get uri => 'file:$_path?vfs=$name';

  @override
  XOpenResult xOpen(Sqlite3Filename path, int flags) {
    if (path.path == '$_path-journal' &&
        writable &&
        journal != null &&
        !_journalOpened &&
        flags & SqlFlag.SQLITE_OPEN_MAIN_JOURNAL != 0) {
      _journalOpened = true;
      _journalExists = true;
      return (
        outFlags: SqlFlag.SQLITE_OPEN_READWRITE,
        file: _SnapshotFile(
          journal!,
          writable: true,
          closed: () => _journalOpened = false,
        ),
      );
    }
    if (path.path != _path ||
        _opened ||
        (!writable && flags & SqlFlag.SQLITE_OPEN_READWRITE != 0)) {
      throw const VfsException(SqlError.SQLITE_CANTOPEN);
    }
    _opened = true;
    return (
      outFlags: writable
          ? SqlFlag.SQLITE_OPEN_READWRITE
          : SqlFlag.SQLITE_OPEN_READONLY,
      file: _SnapshotFile(
        file,
        writable: writable,
        closed: () => _opened = false,
      ),
    );
  }

  @override
  int xAccess(String path, int flags) =>
      path == _path || path == '$_path-journal' && _journalExists ? 1 : 0;
  @override
  void xDelete(String path, int syncDir) {
    if (path != '$_path-journal' || journal == null || !writable) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_DELETE);
    }
    try {
      journal!.truncateTo(0);
      _journalExists = false;
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_DELETE);
    }
  }

  @override
  String xFullPathName(String path) {
    if (path != _path) throw const VfsException(SqlError.SQLITE_CANTOPEN);
    return _path;
  }

  @override
  void xSleep(Duration duration) => sleep(
    duration > const Duration(milliseconds: 50)
        ? const Duration(milliseconds: 50)
        : duration,
  );

  T registered<T>(T Function() use) {
    sqlite3.registerVirtualFileSystem(this);
    try {
      return use();
    } finally {
      // Every SQLite connection using the callbacks must close before this.
      if (_opened || _journalOpened) {
        throw StateError('Snapshot SQLite owner did not close');
      }
      sqlite3.unregisterVirtualFileSystem(this);
    }
  }
}

final class _SnapshotFile extends BaseVfsFile {
  _SnapshotFile(this.file, {required this.writable, required this.closed});
  final BackupFile file;
  final bool writable;
  final void Function() closed;
  bool _closed = false;
  int _lock = 0;
  @override
  void xClose() {
    _closed = true;
    closed();
  }

  @override
  int readInto(Uint8List buffer, int offset) {
    if (_closed) throw const VfsException(SqlError.SQLITE_IOERR);
    try {
      return file.readAt(buffer, offset);
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_READ);
    }
  }

  @override
  void xWrite(Uint8List buffer, int fileOffset) {
    if (_closed || !writable) {
      throw const VfsException(SqlError.SQLITE_READONLY);
    }
    try {
      file.writeAt(buffer, fileOffset);
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_WRITE);
    }
  }

  @override
  void xTruncate(int size) {
    if (_closed || !writable) {
      throw const VfsException(SqlError.SQLITE_READONLY);
    }
    try {
      file.truncateTo(size);
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_TRUNCATE);
    }
  }

  @override
  void xSync(int flags) {
    try {
      file.sync();
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_FSYNC);
    }
  }

  @override
  int xFileSize() {
    try {
      return file.size;
    } catch (_) {
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_FSTAT);
    }
  }

  // These locks protect a VFS-private fresh candidate, not an application DB.
  // The source connection and profile retain the actual migration authority.
  @override
  void xLock(int mode) {
    _lock = mode;
  }

  @override
  void xUnlock(int mode) {
    _lock = mode;
  }

  @override
  int xCheckReservedLock() => _lock >= 2 ? 1 : 0;
}
