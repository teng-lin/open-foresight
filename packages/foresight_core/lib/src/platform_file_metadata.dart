import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// statx(2) on Linux has the same layout on every architecture; the app
// ships for macOS on arm64 only, where lstat(2) fills the 64-bit-inode
// struct stat.
const _atFdCwd = -100;
const _atSymlinkNoFollow = 0x100;
const _statxBasicStats = 0x7ff;
const _statxSize = 256;
const _darwinStatSize = 144;

final int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)? _statx =
    Platform.isLinux
    ? DynamicLibrary.process().lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
      >('statx')
    : null;

final int Function(Pointer<Utf8>, Pointer<Uint8>)? _lstat = Platform.isMacOS
    ? DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('lstat')
    : null;

/// The identity of the entry at [path] itself, without following a link, or
/// null when it is missing. Throws when it exists but cannot be inspected.
///
/// It is the device and inode, read in process: spawning a process here would
/// fork the service while its other isolates run. On Linux the modification
/// time, to the nanosecond, is part of it: ext4 and overlay filesystems hand
/// a freed inode number to the next file at once, so a socket that replaced a
/// dead one can carry its old inode. A socket's modification time is set when
/// it is bound; linking, renaming and chmod leave it alone. APFS never reuses
/// inode numbers.
Future<String?> fileIdentity(String path) async => fileIdentitySync(path);

/// The same filesystem identity for synchronous database qualification.
String? fileIdentitySync(String path) =>
    _fileStat(path, _linuxIdentity, _darwinIdentity);

/// One native metadata snapshot, retaining precision lost by Dart FileStat.
/// Socket ownership keeps its separate identity: rename/link/chmod must not
/// change which entry an owner is allowed to remove.
typedef FileMetadata = ({
  String identity,
  int size,
  int mode,
  int modifiedSeconds,
  int modifiedNanos,
  int changedSeconds,
  int changedNanos,
});

FileMetadata? fileMetadataSync(String path) =>
    _fileStat(path, _linuxMetadata, _darwinMetadata);

T? _fileStat<T>(
  String path,
  T Function(Pointer<Uint8>) linux,
  T Function(Pointer<Uint8>) darwin,
) {
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'Path contains a NUL character');
  }
  final nativePath = path.toNativeUtf8(allocator: calloc);
  final buffer = calloc<Uint8>(_statxSize);
  try {
    final T? metadata;
    if (_statx case final statx?) {
      metadata =
          statx(
                _atFdCwd,
                nativePath,
                _atSymlinkNoFollow,
                _statxBasicStats,
                buffer,
              ) ==
              0
          ? linux(buffer)
          : null;
    } else if (_lstat case final lstat?) {
      metadata = lstat(nativePath, buffer) == 0 ? darwin(buffer) : null;
    } else {
      throw UnsupportedError('No file identity on ${Platform.operatingSystem}');
    }
    if (metadata != null) return metadata;
  } finally {
    calloc.free(buffer);
    calloc.free(nativePath);
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  throw FileSystemException('Cannot inspect', path);
}

FileMetadata _linuxMetadata(Pointer<Uint8> statx) {
  final view = ByteData.sublistView(statx.asTypedList(_statxSize));
  // statx: type, mode, mtime, ctime, inode and size must all be available.
  const required = 0x001 | 0x002 | 0x040 | 0x080 | 0x100 | 0x200;
  if (view.getUint32(0, Endian.host) & required != required) {
    throw FileSystemException('Incomplete native file metadata');
  }
  return (
    identity:
        '${view.getUint32(136, Endian.host)}:'
        '${view.getUint32(140, Endian.host)}:'
        '${view.getUint64(32, Endian.host)}',
    size: view.getUint64(40, Endian.host),
    mode: view.getUint16(28, Endian.host),
    modifiedSeconds: view.getInt64(112, Endian.host),
    modifiedNanos: view.getUint32(120, Endian.host),
    changedSeconds: view.getInt64(96, Endian.host),
    changedNanos: view.getUint32(104, Endian.host),
  );
}

FileMetadata _darwinMetadata(Pointer<Uint8> stat) {
  final view = ByteData.sublistView(stat.asTypedList(_darwinStatSize));
  // Darwin arm64 struct stat: st_mtimespec at 48, st_ctimespec at 64.
  return (
    identity: _darwinIdentity(stat),
    size: view.getInt64(96, Endian.host),
    mode: view.getUint16(4, Endian.host),
    modifiedSeconds: view.getInt64(48, Endian.host),
    modifiedNanos: view.getInt64(56, Endian.host),
    changedSeconds: view.getInt64(64, Endian.host),
    changedNanos: view.getInt64(72, Endian.host),
  );
}

/// dev_major:dev_minor:ino:mtime from a struct statx.
String _linuxIdentity(Pointer<Uint8> statx) {
  final view = ByteData.sublistView(statx.asTypedList(_statxSize));
  final ino = view.getUint64(32, Endian.host);
  final mtimeSeconds = view.getInt64(112, Endian.host);
  final mtimeNanos = view.getUint32(120, Endian.host);
  final major = view.getUint32(136, Endian.host);
  final minor = view.getUint32(140, Endian.host);
  return '$major:$minor:$ino:$mtimeSeconds.$mtimeNanos';
}

/// dev:ino from a 64-bit-inode struct stat on macOS.
String _darwinIdentity(Pointer<Uint8> stat) {
  final view = ByteData.sublistView(stat.asTypedList(_darwinStatSize));
  final dev = view.getInt32(0, Endian.host);
  final ino = view.getUint64(8, Endian.host);
  return '$dev:$ino';
}
