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

/// The device and inode of [path] itself, without following a link, or null
/// when it is missing or cannot be inspected.
Future<String?> fileIdentity(String path) async {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  final result = await Process.run(
    '/usr/bin/stat',
    Platform.isMacOS ? ['-f', '%d:%i', path] : ['-c', '%d:%i', path],
  );
  return result.exitCode == 0 ? result.stdout.toString().trim() : null;
}

/// Whether [error] says that nothing listens at a Unix socket path: there is
/// no socket (ENOENT), or nobody accepts on it (ECONNREFUSED: 61 on macOS,
/// 111 on Linux). macOS also refuses when a live listener's backlog is full;
/// its runtimes are per profile, so only a crashed owner of this profile can
/// have left a socket there.
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
  try {
    final live = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: const Duration(milliseconds: 200),
    );
    live.destroy();
    return SocketPathInUse(path);
  } on SocketException catch (error) {
    return nobodyListening(error) ? null : SocketPathInUse(path, cause: error);
  }
}

/// Remove a socket that an owner which is gone left at [path], before a new
/// listener publishes there. The caller holds its profile lock, so a listener
/// there belongs to another profile sharing the runtime directory. Throws
/// [SocketPathInUse] instead of deleting a socket that accepts, one whose
/// state a connect cannot tell, or one replaced while it was probed.
Future<void> clearStaleSocket(String path) async {
  final before = await fileIdentity(path);
  if (before == null) return;
  final inUse = await probeSocketPath(path);
  if (inUse != null) throw inUse;
  // Unlink only the socket that was probed; another owner may have published
  // a new one there meanwhile.
  final now = await fileIdentity(path);
  if (now == null) return;
  if (now != before) throw SocketPathInUse(path, cause: 'it was replaced');
  File(path).deleteSync();
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
      return ServiceSocketBinding._(
        listener,
        path,
        boundPath,
        await fileIdentity(boundPath),
      );
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
      if (_linkBound()) break;
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
    File(_boundPath).deleteSync();
    _published = true;
  }

  bool _linkBound() {
    final from = _boundPath.toNativeUtf8(allocator: calloc);
    final to = path.toNativeUtf8(allocator: calloc);
    try {
      return _link(from, to) == 0;
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }

  /// Remove the published socket if [path] is still this listener's; another
  /// owner may have published there since this listener closed (S3). Returns
  /// whether it removed the socket.
  Future<bool> unpublish() async {
    if (!_published) return false;
    final current = await fileIdentity(path);
    if (current == null) return false;
    if (identity != null && current != identity) return false;
    File(path).deleteSync();
    return true;
  }

  Future<void> close() => _closing ??= listener.close().then<void>((_) {});
}
