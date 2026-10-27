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
final _fchmod = _libc
    .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
      'fchmod',
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

final _fcntlEmpty = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<()>),
      int Function(int, int)
    >('fcntl');
final _fcntlInt = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');
final _flock = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'flock',
    );
final _rename = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>),
      int Function(int, Pointer<Utf8>, int, Pointer<Utf8>)
    >('renameat');
final _fstatfs = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('fstatfs');

/// Named targets only; each release records which real filesystems ran its
/// lease fixtures. Unknown/network filesystems never become persistent sinks.
enum ScopedLocalFileSystem { ext4, btrfs, xfs, overlay, apfs, unsupported }

ScopedLocalFileSystem _localFileSystem(int descriptor) {
  final buffer = calloc<Uint8>(4096);
  try {
    if (_fstatfs(descriptor, buffer) != 0) {
      return ScopedLocalFileSystem.unsupported;
    }
    if (Platform.isLinux) {
      final type = ByteData.sublistView(
        buffer.asTypedList(4096),
      ).getUint64(0, Endian.host);
      return switch (type) {
        0xef53 => ScopedLocalFileSystem.ext4,
        0x9123683e => ScopedLocalFileSystem.btrfs,
        0x58465342 => ScopedLocalFileSystem.xfs,
        0x794c7630 => ScopedLocalFileSystem.overlay,
        _ => ScopedLocalFileSystem.unsupported,
      };
    }
    if (Platform.isMacOS &&
        (buffer + 72).cast<Utf8>().toDartString(length: 4) == 'apfs') {
      return ScopedLocalFileSystem.apfs;
    }
    return ScopedLocalFileSystem.unsupported;
  } finally {
    calloc.free(buffer);
  }
}

int _relocate(int fd, int minimum) {
  if (fd < 0 || fd >= minimum) return fd;
  final next = _fcntlInt(fd, Platform.isMacOS ? 67 : 1030, minimum);
  _close(fd);
  return next;
}

int get _directory => Platform.isMacOS ? 0x100000 : 0x10000;
int get _noFollow => Platform.isMacOS ? 0x100 : 0x20000;
int get _cloexec => Platform.isMacOS ? 0x1000000 : 0x80000;
int get _nonBlocking => Platform.isMacOS ? 0x4 : 0x800;
int get _create => Platform.isMacOS ? 0x200 : 0x40;
int get _exclusive => Platform.isMacOS ? 0x800 : 0x80;

int _flockAttempt(int descriptor) {
  if (_flock(descriptor, 2 | 4) == 0) return 0;
  final code = _errno().value;
  return code == 0 ? -1 : code;
}

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

/// Optional per-instance replacement for libc directory streams. It writes the
/// names of the open directory [descriptor], except "." and "..", into
/// [names] ([capacity] bytes) as one length byte plus the name bytes each, and
/// returns the packed length or a negative refusal. It must not retain
/// [names] or [descriptor]; the caller closes the descriptor.
/// One non-blocking exclusive `flock` attempt on [descriptor]: 0 when taken,
/// otherwise the errno. Tests may inject non-contention failures; production
/// uses the real kernel call.
typedef BackupLeaseAttempt = int Function(int descriptor);

typedef BackupDirectoryReader =
    int Function(int descriptor, Pointer<Uint8> names, int capacity);

/// Packed-name buffer for one [BackupDirectoryReader] call: at most 256 names
/// of at most 255 bytes, as [BackupDirectory.entries] also allows.
const backupDirectoryNameBytes = 256 * 256;

/// Backup-only descriptor operations. Every path component is opened without
/// following links. Existing entries are never chmod'ed into apparent safety.
/// Linux x86-64 statx and Darwin arm64 stat/dirent layouts are explicit here;
/// both require their real-platform fixtures before release qualification.
final class BackupDirectory {
  BackupDirectory(
    String path, {
    bool create = true,
    bool private = true,
    int minimumDescriptor = 0,
    BackupDirectoryReader? reader,
    BackupLeaseAttempt? leaseAttempt,
  }) : path = p.normalize(p.absolute(path)),
       _private = private,
       _minimumDescriptor = minimumDescriptor,
       _reader = reader,
       _leaseAttempt = leaseAttempt {
    final components = p.split(this.path);
    var fd = _relocate(
      _name('/', (name) => _open(name, _directory | _cloexec)),
      minimumDescriptor,
    );
    if (fd < 0) _refuse();
    try {
      for (var i = 1; i < components.length; i++) {
        final last = i == components.length - 1;
        final next = _relocate(
          _name(components[i], (name) {
            if (last && create) _mkdirAt(fd, name, 0x1c0);
            return _openAt(fd, name, _directory | _noFollow | _cloexec, 0);
          }),
          minimumDescriptor,
        );
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
  final int _minimumDescriptor;
  final BackupDirectoryReader? _reader;
  final BackupLeaseAttempt? _leaseAttempt;
  late final int _fd;
  late final String _identity;
  bool _closed = false;

  void verifyAnchor() {
    final probe = BackupDirectory(
      path,
      create: false,
      private: _private,
      minimumDescriptor: _minimumDescriptor,
    );
    try {
      if (probe._identity != _identity) _refuse();
    } finally {
      probe.close();
    }
  }

  BackupFile open(
    String name, {
    bool create = false,
    bool private = true,
    bool readOnly = false,
  }) {
    if (create && readOnly) {
      throw ArgumentError('Read-only files cannot be created');
    }
    if (_closed || p.basename(name) != name || name == '.' || name == '..') {
      _refuse();
    }
    final fd = _relocate(
      _name(
        name,
        (name) => _openAt(
          _fd,
          name,
          (readOnly ? 0 : 2) |
              _nonBlocking |
              _noFollow |
              _cloexec |
              (create ? _create | _exclusive : 0),
          0x180,
        ),
      ),
      _minimumDescriptor,
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
      return BackupFile._(fd, info.identity, _leaseAttempt);
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
    final duplicate = _relocate(
      _name(
        '.',
        (name) => _openAt(_fd, name, _directory | _noFollow | _cloexec, 0),
      ),
      _minimumDescriptor,
    );
    if (duplicate < 0) _refuse();
    if (_reader case final reader?) {
      try {
        _readEntries(reader, duplicate, visit);
      } finally {
        _close(duplicate);
      }
      return;
    }
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

  /// The configured reader lists exactly [duplicate], once verified to be this
  /// anchor, into one bounded buffer; no libc directory stream is opened.
  void _readEntries(
    BackupDirectoryReader reader,
    int duplicate,
    bool Function(String name) visit,
  ) {
    if (_metadata(duplicate).identity != _identity) _refuse();
    final names = calloc<Uint8>(backupDirectoryNameBytes);
    try {
      final length = reader(duplicate, names, backupDirectoryNameBytes);
      if (length < 0 || length > backupDirectoryNameBytes) _refuse();
      var count = 0;
      for (var offset = 0; offset < length;) {
        final size = names[offset++];
        if (size == 0 || size > length - offset || ++count > 256) _refuse();
        final name = (names + offset).cast<Utf8>().toDartString(length: size);
        offset += size;
        if (name == '.' ||
            name == '..' ||
            name.contains('/') ||
            name.contains('\u0000')) {
          _refuse();
        }
        if (!visit(name)) break;
      }
    } finally {
      calloc.free(names);
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

  /// Descriptor-relative existence without enumerating an unbounded directory.
  /// A symlink or other entry exists; callers still use metadata() to require a
  /// safe regular file. Only ENOENT means absence, never a permission/I/O error.
  bool entryExists(String name) {
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
      if (result == 0) return true;
      if (_errno().value == 2) {
        return false; // ENOENT on both supported platforms.
      }
      _refuse();
    } finally {
      calloc.free(buffer);
    }
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

  /// Explicit shared primitives for the diagnostic writer. Backup ownership and
  /// publication semantics above remain unchanged; no general writer uses them.
  int get descriptor => _fd;
  bool get closeOnExec {
    final flags = _fcntlEmpty(_fd, 1);
    return flags >= 0 && flags & 1 == 1;
  }

  String get identity => _identity;
  ScopedLocalFileSystem get localFileSystem => _localFileSystem(_fd);

  BackupDirectory child(String name, {bool create = true}) {
    if (p.basename(name) != name || name == '.' || name == '..') _refuse();
    verifyAnchor();
    final child = BackupDirectory(
      p.join(path, name),
      create: create,
      minimumDescriptor: _minimumDescriptor,
      reader: _reader,
      leaseAttempt: _leaseAttempt,
    );
    try {
      verifyAnchor();
      return child;
    } catch (_) {
      child.close();
      rethrow;
    }
  }

  BackupFile openOrCreate(String name) {
    try {
      return open(name);
    } catch (_) {
      try {
        return open(name, create: true);
      } catch (_) {
        return open(name);
      }
    }
  }

  void replace(String temporary, String complete) {
    if ([
      temporary,
      complete,
    ].any((name) => p.basename(name) != name || name == '.' || name == '..')) {
      _refuse();
    }
    verifyAnchor();
    final source = metadata(temporary);
    if (entryExists(complete)) metadata(complete);
    if (_name(
          temporary,
          (from) => _name(complete, (to) => _rename(_fd, from, _fd, to)),
        ) !=
        0) {
      _refuse();
    }
    if (metadata(complete).identity != source.identity) _refuse();
    verifyAnchor();
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

  /// Offline activation only: one atomic rename of [from] here to [to] in
  /// [target] on the same filesystem. Without [exchange] it never replaces;
  /// with it both names must exist and swap, so neither is ever absent.
  /// Linux renameat2 NOREPLACE=1/EXCHANGE=2, Darwin renameatx_np EXCL=4/SWAP=2.
  /// [fromPrivate]/[toPrivate] describe the files initially at each name.
  void renameInto(
    String from,
    BackupDirectory target,
    String to, {
    bool exchange = false,
    bool fromPrivate = true,
    bool toPrivate = true,
  }) {
    if (target._closed ||
        [from, to].any(
          (name) => p.basename(name) != name || name == '.' || name == '..',
        )) {
      _refuse();
    }
    verifyAnchor();
    target.verifyAnchor();
    final source = metadata(from, private: fromPrivate);
    final replaced = exchange ? target.metadata(to, private: toPrivate) : null;
    final flags = exchange ? 2 : (Platform.isMacOS ? 4 : 1);
    if (_name(
          from,
          (f) =>
              _name(to, (t) => _renameNoReplace(_fd, f, target._fd, t, flags)),
        ) !=
        0) {
      _refuse();
    }
    if (target.metadata(to, private: fromPrivate).identity != source.identity ||
        (replaced != null &&
            metadata(from, private: toPrivate).identity != replaced.identity)) {
      _refuse();
    }
    sync();
    if (!identical(target, this)) target.sync();
    verifyAnchor();
    target.verifyAnchor();
  }

  void remove(String name, {bool private = true, String? expectedIdentity}) {
    // The caller owns an anchored private staging directory with no other
    // legitimate writers. This is not an atomic inode-conditional unlink.
    // Arbitrary same-UID mutations inside that staging area are out of scope.
    final actual = metadata(name, private: private);
    if (expectedIdentity != null && actual.identity != expectedIdentity) {
      _refuse();
    }
    if (_name(name, (name) => _unlink(_fd, name, 0)) != 0) _refuse();
  }

  /// Only an owned private immediate child may be removed, and only empty.
  /// unlinkat(AT_REMOVEDIR) never follows a swapped symlink or recursively
  /// deletes contents. No other legitimate writer owns this random staging name.
  void removeEmptyChild(BackupDirectory child) {
    if (_closed ||
        child._closed ||
        !child._private ||
        p.dirname(child.path) != path) {
      _refuse();
    }
    verifyAnchor();
    child.verifyAnchor();
    final probe = BackupDirectory(child.path, create: false);
    try {
      if (probe.identity != child.identity) _refuse();
    } finally {
      probe.close();
    }
    if (_name(
          p.basename(child.path),
          (name) => _unlink(_fd, name, Platform.isMacOS ? 0x80 : 0x200),
        ) !=
        0) {
      _refuse();
    }
    sync();
    verifyAnchor();
  }

  /// Publish a completed private immediate child at an absent sibling name.
  /// The atomic no-replace operation never overwrites an existing profile or
  /// backup. A post-rename identity conflict preserves directories for recovery.
  BackupDirectory publishChild(BackupDirectory child, String name) {
    if (_closed ||
        child._closed ||
        !child._private ||
        p.dirname(child.path) != path ||
        p.basename(name) != name ||
        name == '.' ||
        name == '..' ||
        name == p.basename(child.path)) {
      _refuse();
    }
    verifyAnchor();
    child.verifyAnchor();
    final identity = child.identity;
    if (_name(
          p.basename(child.path),
          (from) => _name(
            name,
            (to) =>
                _renameNoReplace(_fd, from, _fd, to, Platform.isMacOS ? 4 : 1),
          ),
        ) !=
        0) {
      _refuse();
    }
    sync();
    verifyAnchor();
    final published = this.child(name, create: false);
    if (published.identity != identity) {
      published.close();
      _refuse();
    }
    return published;
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
  BackupFile._(this._fd, this.identity, this._leaseAttempt);
  final int _fd;
  final BackupLeaseAttempt? _leaseAttempt;
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

  int get descriptor => _fd;
  bool get closeOnExec {
    final flags = _fcntlEmpty(_fd, 1);
    return flags >= 0 && flags & 1 == 1;
  }

  ScopedLocalFileSystem get localFileSystem => _localFileSystem(_fd);

  bool tryExclusiveLease() => _flock(_fd, 2 | 4) == 0;

  /// Distinguish actual kernel contention from a broken descriptor/operation.
  /// Media acquisition may wait for the former; it must never retry the latter.
  bool tryExclusiveLeaseChecked() {
    if (_closed) _refuse();
    final code = (_leaseAttempt ?? _flockAttempt)(_fd);
    if (code == 0) return true;
    if (code == (Platform.isMacOS ? 35 : 11)) {
      return false; // EWOULDBLOCK/EAGAIN
    }
    _refuse();
  }

  static String? inspectDescriptorIdentity(int descriptor) {
    try {
      return _metadata(descriptor).identity;
    } catch (_) {
      return null;
    }
  }

  void truncate() {
    truncateTo(0);
    rewind();
  }

  bool writeOnce(Uint8List bytes) {
    if (_closed || bytes.length > 16384) _refuse();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      return _write(_fd, buffer, bytes.length) == bytes.length;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Offline activation only: make owner-only the previous live database,
  /// whose identity the caller has already proved. An untrusted entry is
  /// never chmod'ed into apparent safety.
  void restrictToOwner() {
    if (_closed || _fchmod(_fd, 0x180) != 0) _refuse();
    if (_metadata(_fd).mode & 0x3f != 0) _refuse();
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
