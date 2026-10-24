import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

final _libc = DynamicLibrary.process();
final _openat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
      int Function(int, Pointer<Utf8>, int, int)
    >('openat');
final _mkdirat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Uint32),
      int Function(int, Pointer<Utf8>, int)
    >('mkdirat');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _fstat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Void>),
      int Function(int, Pointer<Void>)
    >('fstat');
final _flock = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'flock',
    );
final _fcntlInt = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');
final _getuid = _libc.lookupFunction<Uint32 Function(), int Function()>(
  'getuid',
);

/// Linux x86-64/Darwin arm64 system-libc ABI. New-path flock leases belong to
/// each open file description; closing another profile's probe cannot release
/// them. Released services retain their separately checked POSIX lock path.
class InstallationLock {
  InstallationLock._(this._fd);
  int _fd;
  static int get _directory => Platform.isMacOS ? 0x100000 : 0x10000;
  static int get _noFollow => Platform.isMacOS ? 0x100 : 0x20000;
  static int get _cloexec => Platform.isMacOS ? 0x1000000 : 0x80000;
  static int get _create => Platform.isMacOS ? 0x200 : 0x40;

  static InstallationLock acquire(String path) {
    if (Abi.current() != Abi.linuxX64 && Abi.current() != Abi.macosArm64) {
      throw UnsupportedError(
        'Installation locks require Linux x86-64 or macOS arm64',
      );
    }
    if (!path.startsWith('/') || path.contains('\u0000')) {
      throw StateError('Invalid installation lock path');
    }
    final uid = _getuid();
    var directory = -1, file = -1;
    final info = calloc<Uint8>(256);
    int open(int parent, String name, int flags, int mode) {
      final encoded = name.toNativeUtf8(allocator: calloc);
      try {
        return _openat(parent, encoded, flags, mode);
      } finally {
        calloc.free(encoded);
      }
    }

    void validate(
      int descriptor, {
      required bool regular,
      bool private = false,
    }) {
      if (_fstat(descriptor, info.cast()) != 0) {
        throw StateError('Cannot inspect installation lock');
      }
      final mode = Platform.isMacOS
          ? (info + 4).cast<Uint16>().value
          : (info + 24).cast<Uint32>().value;
      final owner = (info + (Platform.isMacOS ? 16 : 28)).cast<Uint32>().value;
      final links = Platform.isMacOS
          ? (info + 6).cast<Uint16>().value
          : (info + 16).cast<Uint64>().value;
      if ((mode & 0xf000) != (regular ? 0x8000 : 0x4000) ||
          (regular ? owner != uid || links != 1 : owner != uid && owner != 0) ||
          (mode & (private ? 0x3f : 0x12)) != 0) {
        throw StateError(
          'Installation lock requires private, user-owned regular storage',
        );
      }
    }

    try {
      directory = open(
        Platform.isMacOS ? -2 : -100,
        '/',
        _directory | _cloexec,
        0,
      );
      if (directory < 0) throw StateError('Cannot open installation lock root');
      final parts = path.split('/').where((part) => part.isNotEmpty).toList();
      for (final part in parts.take(parts.length - 1)) {
        if (part == '.' || part == '..') {
          throw StateError('Invalid installation lock path');
        }
        final encoded = part.toNativeUtf8(allocator: calloc);
        try {
          _mkdirat(directory, encoded, 0x1c0);
        } finally {
          calloc.free(encoded);
        }
        final next = open(
          directory,
          part,
          _directory | _noFollow | _cloexec,
          0,
        );
        if (next < 0) {
          throw StateError('Cannot open private installation lock directory');
        }
        _close(directory);
        directory = next;
        validate(
          directory,
          regular: false,
          private: part == parts[parts.length - 2],
        );
      }
      file = open(
        directory,
        parts.last,
        2 | _create | _noFollow | _cloexec | (Platform.isMacOS ? 4 : 0x800),
        0x180,
      );
      if (file < 0) throw StateError('Cannot open private installation lock');
      // Never turn closed stdio into a writable lock file. Relocate before
      // granting ownership, so incidental presentation never writes into it.
      final relocated = _fcntlInt(file, Platform.isMacOS ? 67 : 1030, 10);
      if (relocated < 0) {
        throw StateError('Cannot isolate installation lock descriptor');
      }
      _close(file);
      file = relocated;
      validate(file, regular: true, private: true);
      final lock = InstallationLock._(file);
      lock._setLock(1 | 4);
      file = -1;
      return lock;
    } finally {
      if (file >= 0) _close(file);
      if (directory >= 0) _close(directory);
      calloc.free(info);
    }
  }

  void _setLock(int operation) {
    if (_fd >= 0 && _flock(_fd, operation) < 0) {
      throw StateError(
        'An Open Foresight update is in progress. Retry launching after installation finishes.',
      );
    }
  }

  int lengthSync() {
    final info = calloc<Uint8>(256);
    try {
      if (_fd < 0 || _fstat(_fd, info.cast()) != 0) {
        throw StateError('Installation lock is closed');
      }
      return (info + (Platform.isMacOS ? 96 : 48)).cast<Int64>().value;
    } finally {
      calloc.free(info);
    }
  }

  void unlockSync() => _setLock(8);
  void closeSync() {
    if (_fd < 0) return;
    _close(_fd);
    _fd = -1;
  }
}

/// OS account home, independent of HOME/XDG overrides. Package tools enumerate
/// the same database, so a profile override cannot hide a service's lock.
String installationLockHome() {
  if (Platform.isMacOS) {
    final user = Process.runSync('/usr/bin/id', ['-un']);
    final result = Process.runSync('/usr/bin/dscl', [
      '.',
      '-read',
      '/Users/${user.stdout.toString().trim()}',
      'NFSHomeDirectory',
    ]);
    const prefix = 'NFSHomeDirectory: ';
    final value = result.stdout.toString().trim();
    if (user.exitCode == 0 &&
        result.exitCode == 0 &&
        value.startsWith(prefix)) {
      return Directory(
        value.substring(prefix.length),
      ).resolveSymbolicLinksSync();
    }
  } else {
    final result = Process.runSync('/usr/bin/getent', [
      'passwd',
      '${_getuid()}',
    ]);
    final fields = result.stdout.toString().trim().split(':');
    if (result.exitCode == 0 &&
        fields.length == 7 &&
        fields[2] == '${_getuid()}' &&
        fields[5].startsWith('/')) {
      return Directory(fields[5]).resolveSymbolicLinksSync();
    }
  }
  throw StateError('Cannot determine installation lock owner home');
}
