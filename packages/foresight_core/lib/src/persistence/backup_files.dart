import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

final _libc = DynamicLibrary.process();
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>),
      int Function(Pointer<Utf8>, int)
    >('open');
final _openAt = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
      int Function(int, Pointer<Utf8>, int, int)
    >('openat');
final _mkdirAt = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Uint32),
      int Function(int, Pointer<Utf8>, int)
    >('mkdirat');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _sync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'fsync',
);
final _seek = _libc
    .lookupFunction<
      Int64 Function(Int32, Int64, Int32),
      int Function(int, int, int)
    >('lseek');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');
final _pread = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int64),
      int Function(int, Pointer<Uint8>, int, int)
    >('pread');
final _pwrite = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int64),
      int Function(int, Pointer<Uint8>, int, int)
    >('pwrite');
final _ftruncate = _libc
    .lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
      'ftruncate',
    );
final _unlink = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32),
      int Function(int, Pointer<Utf8>, int)
    >('unlinkat');
final _renameNoReplace = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
      int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
    >(Platform.isMacOS ? 'renameatx_np' : 'renameat2');
final _fstatat = Platform.isMacOS
    ? _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
      >('fstatat')
    : null;
final _uid = _libc.lookupFunction<Uint32 Function(), int Function()>('geteuid');
final _statx = Platform.isLinux
    ? _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
      >('statx')
    : null;
final _fstat = Platform.isMacOS
    ? _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('fstat')
    : null;
final _errno = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );
final _fdopendir = _libc
    .lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>(
      'fdopendir',
    );
final _readdir = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>),
      Pointer<Uint8> Function(Pointer<Void>)
    >('readdir');
final _closedir = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'closedir',
    );

int get _directory => Platform.isMacOS ? 0x100000 : 0x10000;
int get _noFollow => Platform.isMacOS ? 0x100 : 0x20000;
int get _cloexec => Platform.isMacOS ? 0x1000000 : 0x80000;
int get _nonBlocking => Platform.isMacOS ? 0x4 : 0x800;
int get _create => Platform.isMacOS ? 0x200 : 0x40;
int get _exclusive => Platform.isMacOS ? 0x800 : 0x80;

Never _refuse() => throw StateError(
  'Cannot safely access migration backups; no migration was started. Check private profile storage and available space.',
);

T _name<T>(String name, T Function(Pointer<Utf8>) use) {
  if (name.contains('\u0000')) _refuse();
  final pointer = name.toNativeUtf8(allocator: calloc);
  try {
    return use(pointer);
  } finally {
    calloc.free(pointer);
  }
}

typedef ScopedFileMetadata = ({
  String identity,
  int mode,
  int uid,
  int links,
  int size,
  int modifiedMillis,
});

ScopedFileMetadata _decodeMetadata(Pointer<Uint8> buffer) {
  if (Platform.isLinux) {
    final b = ByteData.sublistView(buffer.asTypedList(256));
    if (b.getUint32(0, Endian.host) & 0x35f != 0x35f) _refuse();
    return (
      identity:
          '${b.getUint32(136, Endian.host)}:${b.getUint32(140, Endian.host)}:${b.getUint64(32, Endian.host)}',
      mode: b.getUint16(28, Endian.host),
      uid: b.getUint32(20, Endian.host),
      links: b.getUint32(16, Endian.host),
      size: b.getUint64(40, Endian.host),
      modifiedMillis:
          b.getInt64(112, Endian.host) * 1000 +
          b.getUint32(120, Endian.host) ~/ 1000000,
    );
  }
  final b = ByteData.sublistView(buffer.asTypedList(144));
  return (
    identity: '${b.getUint32(0, Endian.host)}:${b.getUint64(8, Endian.host)}',
    mode: b.getUint16(4, Endian.host),
    uid: b.getUint32(16, Endian.host),
    links: b.getUint16(6, Endian.host),
    size: b.getInt64(96, Endian.host),
    modifiedMillis:
        b.getInt64(48, Endian.host) * 1000 +
        b.getInt64(56, Endian.host) ~/ 1000000,
  );
}

ScopedFileMetadata _metadata(int fd) {
  final buffer = calloc<Uint8>(256);
  try {
    if (Platform.isLinux) {
      if (_name('', (name) => _statx!(fd, name, 0x1000, 0x7ff, buffer)) != 0) {
        _refuse();
      }
    } else if (!Platform.isMacOS || _fstat!(fd, buffer) != 0) {
      _refuse();
    }
    return _decodeMetadata(buffer);
  } finally {
    calloc.free(buffer);
  }
}

/// Backup-only descriptor operations. Every path component is opened without
/// following links. Existing entries are never chmod'ed into apparent safety.
/// Linux x86-64 statx and Darwin arm64 stat/dirent layouts are explicit here;
/// both require their real-platform fixtures before release qualification.
final class BackupDirectory {
  BackupDirectory(String path, {bool create = true, bool private = true})
    : path = p.normalize(p.absolute(path)),
      _private = private {
    final components = p.split(this.path);
    var fd = _name('/', (name) => _open(name, _directory | _cloexec));
    if (fd < 0) _refuse();
    try {
      for (var i = 1; i < components.length; i++) {
        final last = i == components.length - 1;
        final next = _name(components[i], (name) {
          if (last && create) _mkdirAt(fd, name, 0x1c0);
          return _openAt(fd, name, _directory | _noFollow | _cloexec, 0);
        });
        if (next < 0) _refuse();
        _close(fd);
        fd = next;
      }
      final info = _metadata(fd);
      if (info.mode & 0xf000 != 0x4000 ||
          (private ? info.mode & 0x3f != 0 : info.mode & 0x12 != 0) ||
          info.uid != _uid()) {
        _refuse();
      }
      _identity = info.identity;
      _fd = fd;
      fd = -1;
    } finally {
      if (fd >= 0) _close(fd);
    }
  }
  final String path;
  final bool _private;
  late final int _fd;
  late final String _identity;
  bool _closed = false;

  void verifyAnchor() {
    final probe = BackupDirectory(path, create: false, private: _private);
    try {
      if (probe._identity != _identity) _refuse();
    } finally {
      probe.close();
    }
  }

  BackupFile open(String name, {bool create = false, bool private = true}) {
    if (_closed || p.basename(name) != name || name == '.' || name == '..') {
      _refuse();
    }
    final fd = _name(
      name,
      (name) => _openAt(
        _fd,
        name,
        2 |
            _nonBlocking |
            _noFollow |
            _cloexec |
            (create ? _create | _exclusive : 0),
        0x180,
      ),
    );
    if (fd < 0) _refuse();
    try {
      final info = _metadata(fd);
      if (info.mode & 0xf000 != 0x8000 ||
          (private && info.mode & 0x3f != 0) ||
          info.uid != _uid() ||
          info.links != 1) {
        _refuse();
      }
      return BackupFile._(fd, info.identity);
    } catch (_) {
      _close(fd);
      rethrow;
    }
  }

  /// No database descriptor is opened or closed here: closing a second FD on
  /// SQLite's live file would release this process's POSIX database locks.
  ScopedFileMetadata metadata(String name, {bool private = true}) {
    if (_closed || p.basename(name) != name || name == '.' || name == '..') {
      _refuse();
    }
    final buffer = calloc<Uint8>(256);
    try {
      final result = _name(
        name,
        (path) => Platform.isLinux
            ? _statx!(_fd, path, 0x100, 0x7ff, buffer)
            : _fstatat!(_fd, path, buffer, 0x20),
      );
      if (result != 0) _refuse();
      final info = _decodeMetadata(buffer);
      if (info.mode & 0xf000 != 0x8000 ||
          info.uid != _uid() ||
          info.links != 1 ||
          private && info.mode & 0x3f != 0) {
        _refuse();
      }
      return info;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Callback iteration keeps memory bounded even for legacy directories with
  /// many owned copies. Returning false stops iteration and closes its FD.
  void visitEntries(bool Function(String name) visit) {
    final duplicate = _name(
      '.',
      (name) => _openAt(_fd, name, _directory | _noFollow | _cloexec, 0),
    );
    if (duplicate < 0) _refuse();
    final directory = _fdopendir(duplicate);
    if (directory == nullptr) {
      _close(duplicate);
      _refuse();
    }
    try {
      while (true) {
        _errno().value = 0;
        final entry = _readdir(directory);
        if (entry == nullptr) {
          if (_errno().value != 0) _refuse();
          break;
        }
        final offset = Platform.isMacOS ? 21 : 19;
        var length = 0;
        while (length <= 255 && entry[offset + length] != 0) {
          length++;
        }
        if (length > 255) _refuse();
        final name = (entry + offset).cast<Utf8>().toDartString(length: length);
        if (name != '.' && name != '..' && !visit(name)) break;
      }
    } finally {
      _closedir(directory);
    }
  }

  List<String> entries({bool allowTruncated = false}) {
    final result = <String>[];
    visitEntries((name) {
      if (result.length == 256) {
        if (!allowTruncated) _refuse();
        return false;
      }
      result.add(name);
      return true;
    });
    return result;
  }

  bool containsEntry(String expected) {
    var found = false;
    visitEntries((name) {
      if (name == expected) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  void publish(String temporary, String complete) {
    if ([
      temporary,
      complete,
    ].any((name) => p.basename(name) != name || name == '.' || name == '..')) {
      _refuse();
    }
    verifyAnchor();
    final source = metadata(temporary);
    // One atomic no-replace rename has no crash window with a second hardlink.
    // Linux renameat2(RENAME_NOREPLACE=1), Darwin renameatx_np(RENAME_EXCL=4).
    if (_name(
          temporary,
          (from) => _name(
            complete,
            (to) =>
                _renameNoReplace(_fd, from, _fd, to, Platform.isMacOS ? 4 : 1),
          ),
        ) !=
        0) {
      _refuse();
    }
    if (metadata(complete).identity != source.identity) _refuse();
    sync();
    verifyAnchor();
  }

  void remove(String name) {
    // Validate immediately before unlink; unlinkat never follows the entry.
    metadata(name);
    if (_name(name, (name) => _unlink(_fd, name, 0)) != 0) _refuse();
  }

  void sync() {
    if (_sync(_fd) != 0) _refuse();
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _close(_fd);
    }
  }
}

final class BackupFile {
  BackupFile._(this._fd, this.identity);
  final int _fd;
  final String identity;
  bool _closed = false;

  /// Positional I/O for the snapshot-only SQLite VFS. These operations never
  /// reopen a pathname or transfer descriptor destruction to SQLite.
  int readAt(Uint8List destination, int offset) {
    if (_closed || offset < 0 || destination.length > 1024 * 1024) _refuse();
    final buffer = calloc<Uint8>(destination.length);
    try {
      var read = 0;
      while (read < destination.length) {
        final count = _pread(
          _fd,
          buffer + read,
          destination.length - read,
          offset + read,
        );
        if (count < 0) _refuse();
        if (count == 0) break;
        read += count;
      }
      destination.setRange(0, read, buffer.asTypedList(read));
      return read;
    } finally {
      calloc.free(buffer);
    }
  }

  void writeAt(Uint8List bytes, int offset) {
    if (_closed || offset < 0 || bytes.length > 1024 * 1024) _refuse();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var written = 0;
      while (written < bytes.length) {
        final count = _pwrite(
          _fd,
          buffer + written,
          bytes.length - written,
          offset + written,
        );
        if (count <= 0) _refuse();
        written += count;
      }
    } finally {
      calloc.free(buffer);
    }
  }

  void truncateTo(int size) {
    if (_closed || size < 0 || _ftruncate(_fd, size) != 0) _refuse();
  }

  String get descriptorPath =>
      Platform.isLinux ? '/proc/self/fd/$_fd' : '/dev/fd/$_fd';
  int get size => _metadata(_fd).size;
  void rewind() {
    if (_seek(_fd, 0, 0) != 0) _refuse();
  }

  T readChunks<T>(T Function(Iterable<Uint8List>) use) => use(_chunks());
  Iterable<Uint8List> _chunks() sync* {
    rewind();
    final buffer = calloc<Uint8>(65536);
    try {
      while (true) {
        final count = _read(_fd, buffer, 65536);
        if (count < 0) _refuse();
        if (count == 0) break;
        yield buffer.asTypedList(count);
      }
    } finally {
      calloc.free(buffer);
    }
  }

  String digest() {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    for (final chunk in _chunks()) {
      input.add(chunk);
    }
    input.close();
    return sink.value!.toString();
  }

  Uint8List readSmall(int maximum) {
    if (size > maximum) _refuse();
    final bytes = BytesBuilder(copy: true);
    for (final chunk in _chunks()) {
      bytes.add(chunk);
      if (bytes.length > maximum) _refuse();
    }
    return bytes.takeBytes();
  }

  void copyTo(BackupFile destination) {
    for (final chunk in _chunks()) {
      destination.write(chunk);
    }
    destination.sync();
  }

  void write(List<int> bytes) {
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var written = 0;
      while (written < bytes.length) {
        final count = _write(_fd, buffer + written, bytes.length - written);
        if (count <= 0) _refuse();
        written += count;
      }
    } finally {
      calloc.free(buffer);
    }
  }

  void sync() {
    if (_sync(_fd) != 0) _refuse();
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _close(_fd);
    }
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}
