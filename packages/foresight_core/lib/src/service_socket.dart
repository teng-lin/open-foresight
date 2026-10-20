import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

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

/// The device and inode of [path] itself, without following a link, or null
/// when it is missing. Throws when it exists but cannot be inspected.
Future<String?> fileIdentity(String path) async {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  final result = await Process.run(
    '/usr/bin/stat',
    Platform.isMacOS ? ['-f', '%d:%i', path] : ['-c', '%d:%i', path],
  );
  if (result.exitCode == 0) return result.stdout.toString().trim();
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  throw FileSystemException(
    'Cannot inspect ${result.stderr.toString().trim()}',
    path,
  );
}

/// Unlink the socket at [path] only if it is still the file [expected]
/// names. It is first renamed to a private name in the same directory, so
/// nothing can replace it between the check and the unlink; anything else
/// is linked back, unless a newer socket took the path meanwhile. Returns
/// whether it removed the socket.
Future<bool> _removeIfStill(String path, String expected) async {
  final random = Random.secure();
  final aside =
      '${File(path).parent.path}/.r'
      '${base64Url.encode(List.generate(6, (_) => random.nextInt(256)))}';
  try {
    File(path).renameSync(aside);
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
    File(aside).deleteSync();
    return true;
  }
  if (_linkPath(aside, path)) File(aside).deleteSync();
  return false;
}

/// Whether [error] says that nothing listens at a Unix socket path: there is
/// no socket (ENOENT), or nobody accepts on it (ECONNREFUSED: 61 on macOS,
/// 111 on Linux). A full backlog makes Linux fail with EAGAIN instead, but
/// macOS refuses at once, just as for a dead socket; [probeSocketPath] asks
/// again before trusting that.
bool nobodyListening(SocketException error) =>
    switch (error.osError?.errorCode) {
      2 || 61 || 111 => true,
      _ => false,
    };

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
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  const bound = Duration(milliseconds: 200);
  final elapsed = Stopwatch()..start();
  for (var attempt = 1; ; attempt++) {
    final left = bound - elapsed.elapsed;
    try {
      final live = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: left > Duration.zero ? left : const Duration(milliseconds: 1),
      );
      live.destroy();
      return SocketPathInUse(path);
    } on SocketException catch (error) {
      if (!nobodyListening(error)) return SocketPathInUse(path, cause: error);
      // On macOS a live listener whose backlog is full refuses like a dead
      // socket (M1). A live owner drains its backlog, so ask up to three
      // times within the bound. One that stays stalled still looks gone; it
      // can only be another profile's owner sharing an explicit runtime,
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

  /// Whether [publish] used a hard link, not the rename fallback for file
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
  Future<void> publish(void Function(Socket) onClient) async {
    if (_closing != null) throw StateError('Socket publication cancelled');
    listener.listen(onClient);
    for (var attempt = 0; ; attempt++) {
      if (_linkPath(_boundPath, path)) break;
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        // This file system cannot link a socket; nothing is at the path to
        // replace.
        File(_boundPath).renameSync(path);
        _published = true;
        return;
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
