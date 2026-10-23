import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:ffi/ffi.dart';

import 'platform_services.dart';

typedef DesktopPeerVerifier = bool Function(Socket peer);

final class UnixPeerIdentity {
  const UnixPeerIdentity(this.pid, this.uid, this.executable);
  final int pid, uid;
  final String executable;
}

final int Function() _effectiveUid = DynamicLibrary.process()
    .lookupFunction<Uint32 Function(), int Function()>('geteuid');

int get effectiveUserId => _effectiveUid();

/// Credentials belong to the accepted AF_UNIX socket, never request JSON.
/// Unknown credentials or an exited/unresolvable peer fail closed.
UnixPeerIdentity unixPeerIdentity(Socket peer) {
  final int process, user;
  if (Platform.isLinux) {
    final bytes = peer.getRawOption(RawSocketOption(1, 17, Uint8List(12)));
    if (bytes.length != 12) {
      throw StateError('Incomplete Unix peer credentials');
    }
    final value = ByteData.sublistView(bytes);
    process = value.getInt32(0, Endian.host);
    user = value.getUint32(4, Endian.host);
  } else if (Platform.isMacOS) {
    // SOL_LOCAL / LOCAL_PEERPID and LOCAL_PEERCRED (struct xucred).
    final processBytes = peer.getRawOption(RawSocketOption(0, 2, Uint8List(4)));
    final credentials = peer.getRawOption(
      RawSocketOption(0, 1, Uint8List(256)),
    );
    if (processBytes.length != 4 ||
        credentials.length < 12 ||
        ByteData.sublistView(credentials).getUint32(0, Endian.host) != 0) {
      throw StateError('Incomplete Unix peer credentials');
    }
    process = ByteData.sublistView(processBytes).getInt32(0, Endian.host);
    user = ByteData.sublistView(credentials).getUint32(4, Endian.host);
  } else {
    throw UnsupportedError(
      'Unix peer identity is unavailable on this platform',
    );
  }
  if (process <= 0) throw StateError('Unix peer process is unavailable');
  return UnixPeerIdentity(process, user, _executable(process));
}

String _executable(int process) {
  if (Platform.isLinux) {
    return File('/proc/$process/exe').resolveSymbolicLinksSync();
  }
  final resolve = DynamicLibrary.open('/usr/lib/libproc.dylib')
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('proc_pidpath');
  final buffer = calloc<Uint8>(4096);
  try {
    if (resolve(process, buffer.cast(), 4096) <= 0) {
      throw StateError('Unix peer executable is unavailable');
    }
    return File(buffer.cast<Utf8>().toDartString()).resolveSymbolicLinksSync();
  } finally {
    calloc.free(buffer);
  }
}

/// Only the installed desktop executable can own the approval surface. Generic
/// interpreters and the service/MCP executables do not qualify as the desktop.
bool verifyInstalledDesktopPeer(Socket peer) {
  try {
    final identity = unixPeerIdentity(peer);
    if (identity.uid != effectiveUserId) return false;
    final root = configuredInstallationRoot;
    if (root != null ||
        runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'] != null) {
      if (root == null) return false;
      final candidate = File(
        Platform.isMacOS
            ? '$root/Contents/MacOS/Open Foresight'
            : '$root/app/open-foresight',
      ).resolveSymbolicLinksSync();
      return candidate.startsWith('$root/') &&
          identity.executable == candidate &&
          _nativeDesktopExecutable(candidate);
    }
    final testExecutable =
        runtimeConfiguration['FORESIGHT_TEST_DESKTOP_EXECUTABLE'];
    if (foresightTestHooksEnabled && testExecutable != null) {
      return identity.executable ==
          File(testExecutable).resolveSymbolicLinksSync();
    }
    final development =
        runtimeConfiguration['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'];
    if (development == null) return false;
    final allowed = jsonDecode(development);
    if (allowed is! List ||
        allowed.length > 8 ||
        allowed.any((entry) => entry is! String || !entry.startsWith('/'))) {
      return false;
    }
    for (final entry in allowed.cast<String>()) {
      final candidate = File(entry).resolveSymbolicLinksSync();
      if (identity.executable == candidate &&
          _nativeDesktopExecutable(candidate)) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

bool _nativeDesktopExecutable(String path) {
  final name = File(path).uri.pathSegments.last;
  if (RegExp(
    r'^(dart|dartaotruntime|python[0-9.]*|bash|sh|zsh|node|deno|ruby|perl|lua|php|java)$',
  ).hasMatch(name)) {
    return false;
  }
  final file = File(path);
  if (file.statSync().mode & 0x49 == 0) return false;
  final handle = file.openSync();
  try {
    var bytes = handle.readSync(65536);
    if (bytes.length < 4) return false;
    final magic = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    if (!{
      0x7f454c46,
      0xfeedface,
      0xfeedfacf,
      0xcefaedfe,
      0xcffaedfe,
      0xcafebabe,
      0xbebafeca,
    }.contains(magic)) {
      return false;
    }
    // Mach-O symbol metadata can follow the executable sections, well beyond
    // the first read. Inspect the whole image without loading it into memory.
    // Keep enough overlap to recognize a marker split across two reads.
    var overlap = '';
    while (bytes.isNotEmpty) {
      final symbols = overlap + latin1.decode(bytes);
      if (symbols.contains('Dart_Initialize') ||
          symbols.contains('Py_BytesMain') ||
          symbols.contains('Py_Main')) {
        return false;
      }
      overlap = symbols.length > 14
          ? symbols.substring(symbols.length - 14)
          : symbols;
      bytes = handle.readSync(65536);
    }
    return true;
  } finally {
    handle.closeSync();
  }
}
