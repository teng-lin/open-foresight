import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'platform_services.dart';

final int Function(Pointer<Utf8>, Pointer<Utf8>) _link =
    DynamicLibrary.process().lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');

bool _linkPath(String from, String to) {
  final source = from.toNativeUtf8(allocator: calloc);
  final target = to.toNativeUtf8(allocator: calloc);
  try {
    return _link(source, target) == 0;
  } finally {
    calloc.free(source);
    calloc.free(target);
  }
}

// RENAME_NOREPLACE for renameat2(2) on Linux, RENAME_EXCL for renamex_np(2)
// on macOS: the move fails if anything is at the target.
const _renameNoReplace = 1;
const _renameExclusive = 4;

/// Moves an entry without replacing anything at the target, or null when the
/// C library has no such call (glibc before 2.28).
final int Function(Pointer<Utf8>, Pointer<Utf8>)? _renameExclusively = () {
  try {
    if (Platform.isLinux) {
      final renameat2 = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
            int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
          >('renameat2');
      return (Pointer<Utf8> from, Pointer<Utf8> to) =>
          renameat2(_atFdCwd, from, _atFdCwd, to, _renameNoReplace);
    }
    if (Platform.isMacOS) {
      final renamex = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('renamex_np');
      return (Pointer<Utf8> from, Pointer<Utf8> to) =>
          renamex(from, to, _renameExclusive);
    }
  } on ArgumentError {
    // The symbol is missing.
  }
  return null;
}();

/// Move [from] to [to] unless something is at [to]; never replaces it.
bool _movePathExclusively(String from, String to) {
  final rename = _renameExclusively;
  if (rename == null) return false;
  final source = from.toNativeUtf8(allocator: calloc);
  final target = to.toNativeUtf8(allocator: calloc);
  try {
    return rename(source, target) == 0;
  } finally {
    calloc.free(source);
    calloc.free(target);
  }
}

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
Future<String?> fileIdentity(String path) async {
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'Path contains a NUL character');
  }
  final nativePath = path.toNativeUtf8(allocator: calloc);
  final buffer = calloc<Uint8>(_statxSize);
  try {
    final String? identity;
    if (_statx case final statx?) {
      identity =
          statx(
                _atFdCwd,
                nativePath,
                _atSymlinkNoFollow,
                _statxBasicStats,
                buffer,
              ) ==
              0
          ? _linuxIdentity(buffer)
          : null;
    } else if (_lstat case final lstat?) {
      identity = lstat(nativePath, buffer) == 0
          ? _darwinIdentity(buffer)
          : null;
    } else {
      throw UnsupportedError('No file identity on ${Platform.operatingSystem}');
    }
    if (identity != null) return identity;
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

/// Unlink the socket, file or link at [path] only if it is still the entry
/// [expected] names. It is checked, renamed to a private name in the same
/// directory, so nothing can replace it between the check and the unlink,
/// and checked again; anything else is linked back, unless a newer entry
/// took the path meanwhile. A link is renamed and removed as a link, never
/// followed. Returns whether it removed the entry.
Future<bool> _removeIfStill(String path, String expected) async {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  final link = type == FileSystemEntityType.link;
  // A directory, or anything else, is not a stale socket to remove.
  if (!link &&
      type != FileSystemEntityType.unixDomainSock &&
      type != FileSystemEntityType.file) {
    return false;
  }
  // What was probed may have been replaced since.
  try {
    if (await fileIdentity(path) != expected) return false;
  } on FileSystemException {
    return false;
  }
  // File.rename resolves a link first, so a dangling link would look absent
  // (mac: found by HanSolo).
  void rename(String from, String to) =>
      link ? Link(from).renameSync(to) : File(from).renameSync(to);
  void delete(String entry) =>
      link ? Link(entry).deleteSync() : File(entry).deleteSync();
  final random = Random.secure();
  final aside =
      '${File(path).parent.path}/.r'
      '${base64Url.encode(List.generate(6, (_) => random.nextInt(256)))}';
  try {
    rename(path, aside);
  } on PathNotFoundException {
    return false;
  }
  String? moved;
  try {
    moved = await fileIdentity(aside);
  } on FileSystemException {
    moved = null;
  }
  if (moved == expected) {
    delete(aside);
    return true;
  }
  if (_linkPath(aside, path)) {
    delete(aside);
  } else {
    stderr.writeln(
      'Left $aside behind: it replaced $path while that was being removed, '
      'and a newer entry has taken the path since.',
    );
  }
  return false;
}

/// Whether [error] says that nothing listens at a Unix socket path: there is
/// nothing (ENOENT), the path is not a socket (ENOTSOCK: 38 on macOS, 88 on
/// Linux, which reports ECONNREFUSED for a regular file instead), or nobody
/// accepts on it (ECONNREFUSED: 61 on macOS, 111 on Linux). A full backlog
/// makes Linux fail with EAGAIN instead, but macOS refuses at once, just as
/// for a dead socket; [probeSocketPath] asks again before trusting that.
bool nobodyListening(SocketException error) =>
    (Platform.isMacOS ? const {2, 38, 61} : const {2, 88, 111}).contains(
      error.osError?.errorCode,
    );

/// Whether [error] is ECONNRESET (54 on macOS, 104 on Linux): the listener a
/// connect reached closed while the connect waited in its backlog.
bool _listenerReset(SocketException error) =>
    error.osError?.errorCode == (Platform.isMacOS ? 54 : 104);

/// A socket path that a new listener must not take: something accepts
/// connections there, or a connect could not tell (for example it timed out,
/// or failed with EAGAIN or EACCES).
class SocketPathInUse implements Exception {
  SocketPathInUse(this.path, {this.cause});
  final String path;

  /// Why a connect could not tell; null when a connection was accepted.
  final Object? cause;
  bool get live => cause == null;

  @override
  String toString() => live
      ? 'A service is listening at $path'
      : 'Cannot tell whether a service is listening at $path: $cause';
}

/// What a connect says about the socket at [path]: null when nothing is
/// there or nobody listens, otherwise why the path is in use.
Future<SocketPathInUse?> probeSocketPath(String path) async {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  // Nothing can listen on a regular file, so it is stale. A connect follows
  // a link, so a link to a live socket is a live endpoint; a dead link is
  // still removed as a link.
  if (type == FileSystemEntityType.notFound ||
      type == FileSystemEntityType.file) {
    return null;
  }
  if (type != FileSystemEntityType.unixDomainSock &&
      type != FileSystemEntityType.link) {
    return SocketPathInUse(path, cause: 'it is a $type, not a socket');
  }
  const bound = Duration(milliseconds: 200);
  final elapsed = Stopwatch()..start();
  for (var attempt = 1; ; attempt++) {
    final left = bound - elapsed.elapsed;
    final SocketException error;
    try {
      final live = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: left > Duration.zero ? left : const Duration(milliseconds: 1),
      );
      live.destroy();
      return SocketPathInUse(path);
    } on SocketException catch (failure) {
      error = failure;
    } on OSError catch (failure) {
      // A connect that waited and then failed reports the socket's pending
      // error as a bare OSError, not a SocketException.
      error = SocketException(
        'Connection failed',
        osError: failure,
        address: InternetAddress(path, type: InternetAddressType.unix),
      );
    }
    // The listener this connect reached closed while it waited: its owner
    // stopped, or the last copy went, such as one a child process inherited
    // until it called exec. Ask again what is at the path now.
    if (_listenerReset(error) && attempt < 3 && elapsed.elapsed < bound) {
      continue;
    }
    if (!nobodyListening(error)) return SocketPathInUse(path, cause: error);
    // On macOS a live listener whose backlog is full refuses like a dead
    // socket (M1). A live owner drains its backlog, so ask up to three
    // times within the bound. A connect cannot tell a backlog that never
    // drains from a dead socket, so such a listener is replaced; it can
    // only be another profile's owner sharing an explicitly set runtime,
    // since macOS runtimes are per profile by default.
    if (!Platform.isMacOS ||
        error.osError?.errorCode != 61 ||
        attempt >= 3 ||
        elapsed.elapsed >= bound) {
      return null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

/// Remove a socket that an owner which is gone left at [path], before a new
/// listener publishes there. The caller holds its profile lock, so a listener
/// there belongs to another profile sharing the runtime directory. Throws
/// [SocketPathInUse] instead of deleting a socket that accepts, one whose
/// state a connect cannot tell, or one replaced while it was probed.
Future<void> clearStaleSocket(String path) async {
  final String? before;
  try {
    before = await fileIdentity(path);
  } on FileSystemException catch (error) {
    throw SocketPathInUse(path, cause: error);
  }
  if (before == null) return;
  final inUse = await probeSocketPath(path);
  if (inUse != null) throw inUse;
  // Unlink only the socket that was probed; another owner may have published
  // a new one there meanwhile.
  if (!await _removeIfStill(path, before) &&
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw SocketPathInUse(path, cause: 'it was replaced');
  }
}

/// Bind under a private, generation-specific name before publishing a socket.
///
/// Dart unlinks the original bind address when a Unix listener closes, even if
/// another listener has since replaced that address. Publishing a hard link
/// leaves that automatic cleanup confined to this generation's temporary name.
/// The owner must remove [path] explicitly while it still holds its profile
/// lock, with [unpublish], which never removes another owner's socket.
class ServiceSocketBinding {
  final ServerSocket listener;
  final String path;
  final String _boundPath;

  /// The device and inode of this listener's socket file, taken before it
  /// was published, or null if it could not be read.
  final String? identity;
  Future<void>? _closing;
  bool _published = false;
  bool _linked = false;

  /// Whether [publish] used a hard link, not the move fallback for file
  /// systems that cannot link a socket.
  bool get linkedForTesting => _linked;

  /// Whether [publish] made this listener discoverable at [path]. Until
  /// then, whatever is at [path] is not this owner's to remove.
  bool get published => _published;

  ServiceSocketBinding._(
    this.listener,
    this.path,
    this._boundPath,
    this.identity,
  );

  static Future<ServiceSocketBinding> bind(String path) async {
    final random = Random.secure();
    // Ten bytes, shorter than worker.sock, also fits every public socket path.
    final name =
        '.s${base64Url.encode(List.generate(6, (_) => random.nextInt(256)))}';
    final boundPath = '${File(path).parent.path}/$name';
    final listener = await ServerSocket.bind(
      InternetAddress(boundPath, type: InternetAddressType.unix),
      0,
    );
    try {
      protectPrivateFile(boundPath);
      String? identity;
      try {
        identity = await fileIdentity(boundPath);
      } on FileSystemException {
        // unpublish then probes before it removes the published socket.
      }
      return ServiceSocketBinding._(listener, path, boundPath, identity);
    } catch (_) {
      await listener.close();
      rethrow;
    }
  }

  /// Attach the consumer, then make the protected socket discoverable at
  /// [path] without replacing anything there: a socket that appeared since
  /// the owner cleared the path is removed only if nobody listens on it
  /// (S2). Throws [SocketPathInUse] otherwise.
  ///
  /// [linkForTesting] stands in for link(2), and [beforeMoveForTesting]
  /// runs just before the fallback moves the socket into place.
  Future<void> publish(
    void Function(Socket) onClient, {
    bool Function(String from, String to)? linkForTesting,
    void Function()? beforeMoveForTesting,
  }) async {
    if (_closing != null) throw StateError('Socket publication cancelled');
    listener.listen(onClient);
    final link = linkForTesting ?? _linkPath;
    for (var attempt = 0; ; attempt++) {
      if (link(_boundPath, path)) break;
      // A file system that cannot link a socket can still move it into
      // place. The move fails if anything is at the path, so it never
      // replaces a socket another owner published there meanwhile.
      beforeMoveForTesting?.call();
      if (_movePathExclusively(_boundPath, path)) {
        _published = true;
        return;
      }
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        // Neither a link nor a move that cannot replace works here.
        if (attempt > 0) {
          throw FileSystemException(
            'Cannot publish the service socket without risking replacing '
            'another one',
            path,
          );
        }
        continue;
      }
      if (attempt > 0) throw SocketPathInUse(path, cause: 'it reappeared');
      await clearStaleSocket(path);
      if (_closing != null) throw StateError('Socket publication cancelled');
    }
    // Published from here on, even if the temporary name stays behind.
    _published = true;
    _linked = true;
    try {
      File(_boundPath).deleteSync();
    } on FileSystemException {
      // Closing the listener removes the temporary name too.
    }
  }

  /// Remove the published socket if [path] is still this listener's; another
  /// owner may have published there since this listener closed (S3). Without
  /// a known identity it is removed only if nobody listens on it. Returns
  /// whether it removed the socket.
  Future<bool> unpublish() async {
    if (!_published) return false;
    final known = identity;
    if (known != null) return _removeIfStill(path, known);
    try {
      await clearStaleSocket(path);
    } on SocketPathInUse {
      return false;
    }
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound;
  }

  Future<void> close() => _closing ??= listener.close().then<void>((_) {});
}
