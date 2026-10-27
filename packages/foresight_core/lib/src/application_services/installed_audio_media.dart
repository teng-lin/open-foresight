import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../platform_services.dart';
import 'native_audio_media.dart';

/// Service-owned installation admission, never an RPC-selected executable or
/// receipt. The composition root supplies its immutable resolved configuration.
/// Missing/invalid installs fail closed; source tests use explicit capabilities.
/// Hashing/reads occur off the service event loop. Native admission independently
/// rechecks the executable SHA and the loaded macOS CodeDirectory before transfer.
final class InstalledAudioMediaInstallation {
  InstalledAudioMediaInstallation({
    required this.executable,
    required this.assemblyProtocol,
    required List<String> operations,
  }) : operations = List.unmodifiable(operations);
  final AudioMediaExecutable executable;
  final int assemblyProtocol;
  final List<String> operations;
}

Future<AudioMediaExecutable> loadInstalledAudioMediaExecutable(
  RuntimeConfiguration configuration,
) async =>
    (await loadInstalledAudioMediaInstallation(configuration)).executable;

Future<InstalledAudioMediaInstallation> loadInstalledAudioMediaInstallation(
  RuntimeConfiguration configuration,
) async {
  final selected = configuration['FORESIGHT_INSTALL_ROOT'];
  if (selected == null ||
      !p.isAbsolute(selected) ||
      selected.contains('\u0000')) {
    throw StateError('Installed audio processing is unavailable');
  }
  // Normalize lexical relative components from the sealed runtime map, but
  // never resolve a symlink to grant authority over another installation.
  final root = p.normalize(selected);
  return Isolate.run(() => _load(root));
}

Never _refuse() =>
    throw StateError('Installed audio processing verification failed');

final _system = DynamicLibrary.process();
final _openAt = _system
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<()>),
      int Function(int, Pointer<Utf8>, int)
    >('openat');
final _close = _system.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _stat = _system
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('fstat');
final _pread = _system
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int64),
      int Function(int, Pointer<Uint8>, int, int)
    >('pread');
final _uid = _system.lookupFunction<Uint32 Function(), int Function()>(
  'geteuid',
);
int get _directory => Platform.isMacOS ? 0x100000 : 0x10000;
int get _noFollow => Platform.isMacOS ? 0x100 : 0x20000;
int get _closeOnExec => Platform.isMacOS ? 0x1000000 : 0x80000;
int get _nonBlocking => Platform.isMacOS ? 4 : 0x800;

int _open(int parent, String name, int flags) {
  final native = name.toNativeUtf8(allocator: calloc);
  try {
    return _openAt(parent, native, flags | _noFollow | _closeOnExec);
  } finally {
    calloc.free(native);
  }
}

typedef _Info = ({
  int device,
  int inode,
  int links,
  int mode,
  int uid,
  int gid,
  int size,
  int modifiedSeconds,
  int modifiedNanos,
  int changedSeconds,
  int changedNanos,
});
_Info _info(int fd) {
  final buffer = calloc<Uint8>(256);
  try {
    if (_stat(fd, buffer) != 0) _refuse();
    final data = ByteData.sublistView(buffer.asTypedList(256));
    if (Platform.isMacOS) {
      return (
        device: data.getUint32(0, Endian.host),
        inode: data.getUint64(8, Endian.host),
        links: data.getUint16(6, Endian.host),
        mode: data.getUint16(4, Endian.host),
        uid: data.getUint32(16, Endian.host),
        gid: data.getUint32(20, Endian.host),
        size: data.getInt64(96, Endian.host),
        modifiedSeconds: data.getInt64(48, Endian.host),
        modifiedNanos: data.getInt64(56, Endian.host),
        changedSeconds: data.getInt64(64, Endian.host),
        changedNanos: data.getInt64(72, Endian.host),
      );
    }
    return (
      device: data.getUint64(0, Endian.host),
      inode: data.getUint64(8, Endian.host),
      links: data.getUint64(16, Endian.host),
      mode: data.getUint32(24, Endian.host),
      uid: data.getUint32(28, Endian.host),
      gid: data.getUint32(32, Endian.host),
      size: data.getInt64(48, Endian.host),
      modifiedSeconds: data.getInt64(88, Endian.host),
      modifiedNanos: data.getInt64(96, Endian.host),
      changedSeconds: data.getInt64(104, Endian.host),
      changedNanos: data.getInt64(112, Endian.host),
    );
  } finally {
    calloc.free(buffer);
  }
}

bool _directoryAllowed(String path, _Info info) {
  if (info.mode & 0xf000 != 0x4000 || info.uid != 0 && info.uid != _uid()) {
    return false;
  }
  if (info.mode & 0x12 == 0) return true;
  // Same closed system-ancestor policy as installed diagnostic admission;
  // exceptions never extend to the selected installation or its children.
  if (info.uid != 0) return false;
  final permissions = info.mode & 0xfff;
  return Platform.isMacOS &&
          path == '/Applications' &&
          info.gid == 80 &&
          permissions == 0x1fd ||
      Platform.isMacOS &&
          path == '/usr/local' &&
          info.gid == 20 &&
          permissions == 0x5fd ||
      path == (Platform.isMacOS ? '/private/var/tmp' : '/var/tmp') &&
          info.gid == 0 &&
          permissions == 0x3ff;
}

final class _Installation {
  _Installation(this.path) {
    if (Abi.current() != Abi.linuxX64 && Abi.current() != Abi.macosArm64 ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path == '/') {
      _refuse();
    }
    var descriptor = _open(Platform.isMacOS ? -2 : -100, '/', _directory);
    if (descriptor < 0) _refuse();
    try {
      var current = '/';
      var privateDescendant = false;
      for (final part in p.split(path).skip(1)) {
        final next = _open(descriptor, part, _directory);
        if (next < 0) _refuse();
        _close(descriptor);
        descriptor = next;
        current = p.join(current, part);
        final info = _info(descriptor);
        if (!_directoryAllowed(current, info) ||
            privateDescendant &&
                (info.uid != _uid() || info.mode & 0x3f != 0)) {
          _refuse();
        }
        privateDescendant =
            current == (Platform.isMacOS ? '/private/var/tmp' : '/var/tmp');
      }
      final info = _info(descriptor);
      if (privateDescendant || info.mode & 0x12 != 0) _refuse();
      identity = (info.device, info.inode);
      fd = descriptor;
      descriptor = -1;
    } finally {
      if (descriptor >= 0) _close(descriptor);
    }
  }
  final String path;
  late final int fd;
  late final (int, int) identity;
  Uint8List read(String relative, int maximum, {bool executable = false}) {
    final parts = p.posix.split(relative);
    if (p.posix.isAbsolute(relative) ||
        p.posix.normalize(relative) != relative ||
        parts.any((s) => s.isEmpty || s == '.' || s == '..')) {
      _refuse();
    }
    var directory = _open(fd, '.', _directory);
    var file = -1;
    if (directory < 0) _refuse();
    try {
      for (final part in parts.take(parts.length - 1)) {
        final next = _open(directory, part, _directory);
        if (next < 0) _refuse();
        _close(directory);
        directory = next;
        final info = _info(directory);
        if (info.mode & 0xf000 != 0x4000 ||
            info.mode & 0x12 != 0 ||
            info.uid != 0 && info.uid != _uid()) {
          _refuse();
        }
      }
      file = _open(directory, parts.last, _nonBlocking);
      if (file < 0) _refuse();
      final before = _info(file);
      if (before.mode & 0xf000 != 0x8000 ||
          before.links != 1 ||
          before.mode & 0x12 != 0 ||
          before.uid != 0 && before.uid != _uid() ||
          before.size < 1 ||
          before.size > maximum ||
          executable && before.mode & 0x49 == 0) {
        _refuse();
      }
      final result = Uint8List(before.size);
      final buffer = calloc<Uint8>(65536);
      try {
        var position = 0;
        while (position < result.length) {
          final count = _pread(
            file,
            buffer,
            result.length - position > 65536 ? 65536 : result.length - position,
            position,
          );
          if (count <= 0) _refuse();
          result.setRange(
            position,
            position + count,
            buffer.asTypedList(count),
          );
          position += count;
        }
      } finally {
        calloc.free(buffer);
      }
      if (before != _info(file)) _refuse();
      return result;
    } finally {
      if (file >= 0) _close(file);
      _close(directory);
    }
  }

  void verifyAnchor() {
    final probe = _Installation(path);
    try {
      if (probe.identity != identity) _refuse();
    } finally {
      probe.close();
    }
  }

  void close() => _close(fd);
}

InstalledAudioMediaInstallation _load(String root) {
  final mac = Platform.isMacOS;
  final target = mac ? 'darwin-arm64' : 'linux-x86_64';
  final receiptPath = mac
      ? 'Contents/Resources/media-worker.json'
      : 'share/open-foresight/media-worker.json';
  final payload = mac ? 'Contents/Resources/' : '';
  final installation = _Installation(root);
  try {
    final receipt = jsonDecode(
      utf8.decode(installation.read(receiptPath, 16384)),
    );
    const keys = {
      'schema',
      'kind',
      'target',
      'path',
      'protocol',
      'bootstrap_protocol',
      'supervisor_fence_protocol',
      'build_id',
      'sha256',
      'bytes',
      'macos_cdhash',
      'source_receipt_sha256',
      'capabilities',
    };
    final sha = RegExp(r'^[0-9a-f]{64}$');
    if (receipt is! Map<String, dynamic> ||
        receipt.length != keys.length ||
        !receipt.keys.every(keys.contains) ||
        receipt['schema'] != 1 ||
        receipt['kind'] != 'audio-media-worker' ||
        receipt['target'] != target ||
        receipt['path'] != 'bin/foresight-media-worker' ||
        receipt['protocol'] != 1 ||
        receipt['bootstrap_protocol'] != 2 ||
        receipt['supervisor_fence_protocol'] != 1 ||
        receipt['bytes'] is! int ||
        receipt['bytes'] < 1 ||
        receipt['bytes'] > 32 * 1024 * 1024 ||
        [
          receipt['build_id'],
          receipt['sha256'],
          receipt['source_receipt_sha256'],
        ].any((s) => s is! String || !sha.hasMatch(s)) ||
        (mac
            ? receipt['macos_cdhash'] is! String ||
                  !RegExp(
                    r'^[0-9a-f]{40,64}$',
                  ).hasMatch(receipt['macos_cdhash'])
            : receipt['macos_cdhash'] != null)) {
      _refuse();
    }
    final capabilities = receipt['capabilities'];
    if (capabilities is! Map<String, dynamic> ||
        capabilities.length != 2 ||
        capabilities['assembly_protocol'] is! int ||
        ![0, 1].contains(capabilities['assembly_protocol']) ||
        !capabilities.containsKey('operations')) {
      _refuse();
    }
    final assemblyProtocol = capabilities['assembly_protocol'] as int;
    final operations = [
      'encode-opus',
      'encode-recording-wav-v1',
      'decode-pcm',
      'mix-export-mp3',
      if (assemblyProtocol == 1) ...[
        'assemble-mp3-v1',
        'assemble-opus-v1',
        'assemble-pcm-v1',
      ],
    ];
    if (jsonEncode(capabilities['operations']) != jsonEncode(operations)) {
      _refuse();
    }
    final provenance = installation.read(
      '${payload}licenses/media/media-worker-build.json',
      1024 * 1024,
    );
    if (sha256.convert(provenance).toString() !=
        receipt['source_receipt_sha256']) {
      _refuse();
    }
    final source = jsonDecode(utf8.decode(provenance));
    if (source is! Map<String, dynamic> ||
        source['protocol'] != 1 ||
        source['build_id'] != receipt['build_id'] ||
        source['platform'] != (mac ? 'Darwin' : 'Linux') ||
        source['architecture'] != (mac ? 'arm64' : 'x86_64')) {
      _refuse();
    }
    final description = source['description'];
    if (description is! Map<String, dynamic> ||
        description['protocol'] != 1 ||
        description['bootstrap_protocol'] != 2 ||
        description['supervisor_fence_protocol'] != 1 ||
        description['build_id'] != receipt['build_id'] ||
        description['capability_transport'] != 'scm_rights' ||
        description['owner_lock_fd'] != 7 ||
        (description['assembly_protocol'] ?? 0) != assemblyProtocol ||
        jsonEncode(description['operations']) != jsonEncode(operations)) {
      _refuse();
    }
    if (assemblyProtocol == 1) {
      final sources = source['application_sources'];
      if (sources is! Map<String, dynamic> ||
          ['native/media_assembly.inc', 'native/media_pager_protocol.h'].any(
            (name) => sources[name] is! String || !sha.hasMatch(sources[name]),
          ) ||
          description['max_range_frames'] != 240000) {
        _refuse();
      }
    }
    final binary = installation.read(
      '${payload}bin/foresight-media-worker',
      32 * 1024 * 1024,
      executable: true,
    );
    final header = mac
        ? [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
        : [0x7f, 0x45, 0x4c, 0x46, 2, 1];
    if (binary.length != receipt['bytes'] ||
        binary.length < 64 ||
        !Iterable.generate(
          header.length,
          (i) => binary[i] == header[i],
        ).every((v) => v) ||
        !mac && (binary[18] != 0x3e || binary[19] != 0) ||
        sha256.convert(binary).toString() != receipt['sha256']) {
      _refuse();
    }
    installation.verifyAnchor();
    return InstalledAudioMediaInstallation(
      assemblyProtocol: assemblyProtocol,
      operations: operations,
      executable: AudioMediaExecutable(
        path: p.join(root, payload, 'bin/foresight-media-worker'),
        sha256: receipt['sha256'],
        buildId: receipt['build_id'],
        macosCdHash: receipt['macos_cdhash'] ?? '',
      ),
    );
  } finally {
    installation.close();
  }
}
