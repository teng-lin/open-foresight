/// Public-code verification in the exec child, after watch ACK and page mapping.
/// This library never resolves a profile, loads another image or starts a child.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

const _core = 'packages/foresight_core';
const _diagnostics = '$_core/lib/src/diagnostics';
const _entry = '$_core/bin/diagnostic_storage_worker.dart';
const _exactSources = {
  _entry,
  '$_core/lib/src/persistence/backup_files.dart',
  '$_core/pubspec.yaml',
  '$_core/pubspec.lock',
  '$_core/lib/src/native_diagnostics.dart',
  '$_core/lib/src/native_lifetime.dart',
  'native/diagnostic_support.c',
  'native/diagnostic_support.h',
};
const _producers = {
  'tools/diagnostic_worker_context.py',
  'tools/build_diagnostic_worker.py',
  'tools/diagnostic_build_identity.py',
};
const _packages = {'ffi', 'meta', 'path', 'crypto', 'typed_data', 'collection'};
const _external = {
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:ffi',
  'dart:io',
  'dart:isolate',
  'dart:math',
  'dart:typed_data',
  'package:crypto/crypto.dart',
  'package:ffi/ffi.dart',
  'package:meta/meta.dart',
  'package:path/path.dart',
};

final class DiagnosticSourceUnavailable implements Exception {
  const DiagnosticSourceUnavailable();
  @override
  String toString() => 'Diagnostic source verification unavailable';
}

Never _refuse() => throw const DiagnosticSourceUnavailable();
bool _identity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
bool _excluded(String name) => const [
  'reference_distribution',
  'credential',
  'search_service',
  'search-service',
].any(name.toLowerCase().contains);
String _relative(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 512 ||
      value.contains('\\') ||
      value.contains(':') ||
      value.startsWith('/') ||
      value.codeUnits.any((c) => c < 32 || c == 127) ||
      value.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
      _excluded(value)) {
    _refuse();
  }
  return value;
}

String _owned(Object? value) {
  final name = _relative(value);
  if (!_exactSources.contains(name) &&
      !(p.posix.dirname(name) == _diagnostics && name.endsWith('.dart'))) {
    _refuse();
  }
  return name;
}

String _sdk(Object? value) {
  final name = _relative(value);
  if (!const {'version', 'revision'}.contains(name) &&
      !name.startsWith('bin/') &&
      !name.startsWith('lib/')) {
    _refuse();
  }
  return name;
}

String _packageInput(Object? value) {
  final name = _relative(value);
  if (name != 'pubspec.yaml' &&
      !(name.startsWith('lib/') && name.endsWith('.dart'))) {
    _refuse();
  }
  return name;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _refuse();
  }
  return value;
}

Map<String, String> _hashes(Object? value, String Function(Object?) path) {
  if (value is! Map<String, dynamic> || value.isEmpty || value.length > 8192) {
    _refuse();
  }
  final result = <String, String>{};
  for (final entry in value.entries) {
    final name = path(entry.key);
    if (!_identity(entry.value)) _refuse();
    result[name] = entry.value as String;
  }
  return result;
}

Object? _sorted(Object? value) {
  if (value is Map<String, dynamic>) {
    return {
      for (final key in value.keys.toList()..sort()) key: _sorted(value[key]),
    };
  }
  if (value is List) return value.map(_sorted).toList(growable: false);
  return value;
}

Uint8List _canonical(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_sorted(value))));

typedef _HashInitNative = Int32 Function(Pointer<Uint8>);
typedef _HashInit = int Function(Pointer<Uint8>);
typedef _HashUpdateNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, UintPtr);
typedef _HashUpdate = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _HashFinalNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _HashFinal = int Function(Pointer<Uint8>, Pointer<Uint8>);

/// Optional symbols are resolved only by the post-watch child verifier. The
/// owner's fourteen-address function table and early parent path are unchanged.
final class DiagnosticSourceHash {
  DiagnosticSourceHash(DynamicLibrary image)
    : _init = image.lookupFunction<_HashInitNative, _HashInit>(
        'fs_diagnostic_sha256_init',
        isLeaf: true,
      ),
      _update = image.lookupFunction<_HashUpdateNative, _HashUpdate>(
        'fs_diagnostic_sha256_update',
        isLeaf: true,
      ),
      _final = image.lookupFunction<_HashFinalNative, _HashFinal>(
        'fs_diagnostic_sha256_final',
        isLeaf: true,
      );
  final _HashInit _init;
  final _HashUpdate _update;
  final _HashFinal _final;
  String _finish(Pointer<Uint8> context) {
    final output = calloc<Uint8>(32);
    try {
      if (_final(context, output) != 0) _refuse();
      return output
          .asTypedList(32)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    } finally {
      calloc.free(output);
    }
  }

  String bytes(Uint8List bytes) {
    final context = calloc<Uint8>(128);
    final buffer = calloc<Uint8>(65536);
    try {
      if (_init(context) != 0) _refuse();
      for (var offset = 0; offset < bytes.length;) {
        final count = bytes.length - offset > 65536
            ? 65536
            : bytes.length - offset;
        buffer.asTypedList(count).setRange(0, count, bytes, offset);
        if (_update(context, buffer, count) != 0) _refuse();
        offset += count;
      }
      return _finish(context);
    } finally {
      calloc.free(buffer);
      calloc.free(context);
    }
  }
}

final _system = DynamicLibrary.process();
final _open = _system
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>),
      int Function(Pointer<Utf8>, int)
    >('open');
final _openAt = _system
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
      int Function(int, Pointer<Utf8>, int, int)
    >('openat');
final _close = _system.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _read = _system
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _uid = _system.lookupFunction<Uint32 Function(), int Function()>(
  'geteuid',
);
final _statx = Platform.isLinux
    ? _system.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
      >('statx')
    : null;
final _fstat = Platform.isMacOS
    ? _system.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('fstat')
    : null;
int get _directory => Platform.isMacOS ? 0x100000 : 0x10000;
int get _noFollow => Platform.isMacOS ? 0x100 : 0x20000;
int get _cloexec => Platform.isMacOS ? 0x1000000 : 0x80000;
int get _nonBlocking => Platform.isMacOS ? 0x4 : 0x800;
T _name<T>(String name, T Function(Pointer<Utf8>) use) {
  final pointer = name.toNativeUtf8(allocator: calloc);
  try {
    return use(pointer);
  } finally {
    calloc.free(pointer);
  }
}

typedef _Info = ({
  String identity,
  String stamp,
  int mode,
  int uid,
  int links,
  int size,
});
_Info _info(int fd) {
  final pointer = calloc<Uint8>(256);
  try {
    final b = ByteData.sublistView(pointer.asTypedList(256));
    if (Platform.isLinux) {
      if (_name('', (name) => _statx!(fd, name, 0x1000, 0x7ff, pointer)) != 0 ||
          b.getUint32(0, Endian.host) & 0x3df != 0x3df) {
        _refuse();
      }
      final identity =
          '${b.getUint32(136, Endian.host)}:${b.getUint32(140, Endian.host)}:${b.getUint64(32, Endian.host)}';
      return (
        identity: identity,
        stamp:
            '$identity:${b.getUint64(40, Endian.host)}:${b.getInt64(96, Endian.host)}:${b.getUint32(104, Endian.host)}:${b.getInt64(112, Endian.host)}:${b.getUint32(120, Endian.host)}',
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        links: b.getUint32(16, Endian.host),
        size: b.getUint64(40, Endian.host),
      );
    }
    if (!Platform.isMacOS || _fstat!(fd, pointer) != 0) _refuse();
    final identity =
        '${b.getUint32(0, Endian.host)}:${b.getUint64(8, Endian.host)}';
    return (
      identity: identity,
      stamp:
          '$identity:${b.getInt64(96, Endian.host)}:${b.getInt64(48, Endian.host)}:${b.getInt64(56, Endian.host)}:${b.getInt64(64, Endian.host)}:${b.getInt64(72, Endian.host)}',
      mode: b.getUint16(4, Endian.host),
      uid: b.getUint32(16, Endian.host),
      links: b.getUint16(6, Endian.host),
      size: b.getInt64(96, Endian.host),
    );
  } finally {
    calloc.free(pointer);
  }
}

final class _SourceFiles {
  final _roots = <String, ({int fd, String identity})>{};
  final _buffer = calloc<Uint8>(65536);
  int _root(String root) {
    if (!p.isAbsolute(root) || p.normalize(root) != root || _excluded(root)) {
      _refuse();
    }
    final cached = _roots[root];
    if (cached != null) return cached.fd;
    var fd = _name('/', (name) => _open(name, _directory | _cloexec));
    if (fd < 0) _refuse();
    var current = '/';
    var privateNext = false;
    try {
      for (final part in p.split(root).skip(1)) {
        current = p.join(current, part);
        final next = _name(
          part,
          (name) => _openAt(fd, name, _directory | _noFollow | _cloexec, 0),
        );
        if (next < 0) _refuse();
        _close(fd);
        fd = next;
        final info = _info(fd);
        final sticky =
            current == (Platform.isMacOS ? '/private/var/tmp' : '/var/tmp') &&
            info.uid == 0 &&
            info.mode & 0xfff == 0x3ff;
        if (info.mode & 0xf000 != 0x4000 ||
            info.uid != 0 && info.uid != _uid() ||
            (info.mode & 0x12 != 0 && !sticky) ||
            privateNext && (info.uid != _uid() || info.mode & 0x3f != 0)) {
          _refuse();
        }
        privateNext = sticky;
      }
      if (privateNext) _refuse();
      _roots[root] = (fd: fd, identity: _info(fd).identity);
      return fd;
    } catch (_) {
      _close(fd);
      rethrow;
    }
  }

  T file<T>(String root, String name, T Function(int, _Info) use) {
    name = _relative(name);
    var directory = _root(root);
    var owned = false;
    var file = -1;
    try {
      final parts = name.split('/');
      for (final part in parts.take(parts.length - 1)) {
        final next = _name(
          part,
          (name) =>
              _openAt(directory, name, _directory | _noFollow | _cloexec, 0),
        );
        if (next < 0) _refuse();
        if (owned) _close(directory);
        directory = next;
        owned = true;
        final info = _info(directory);
        if (info.mode & 0xf000 != 0x4000 ||
            info.mode & 0x12 != 0 ||
            info.uid != 0 && info.uid != _uid()) {
          _refuse();
        }
      }
      file = _name(
        parts.last,
        (name) =>
            _openAt(directory, name, _noFollow | _cloexec | _nonBlocking, 0),
      );
      if (file < 0) _refuse();
      final before = _info(file);
      if (before.mode & 0xf000 != 0x8000 ||
          before.mode & 0x12 != 0 ||
          before.links != 1 ||
          before.uid != 0 && before.uid != _uid() ||
          before.size < 0 ||
          before.size > 256 * 1024 * 1024) {
        _refuse();
      }
      final result = use(file, before);
      final after = _info(file);
      if (after != before) _refuse();
      return result;
    } finally {
      if (file >= 0) _close(file);
      if (owned) _close(directory);
    }
  }

  Uint8List small(String root, String name) => file(root, name, (fd, info) {
    if (info.size > 2 * 1024 * 1024) _refuse();
    final bytes = BytesBuilder();
    var total = 0;
    while (total < info.size) {
      final remaining = info.size - total;
      final count = _read(fd, _buffer, remaining > 65536 ? 65536 : remaining);
      if (count <= 0) _refuse();
      bytes.add(_buffer.asTypedList(count));
      total += count;
    }
    return bytes.takeBytes();
  });
  String hash(
    String root,
    String name,
    DiagnosticSourceHash hash,
  ) => file(root, name, (fd, info) {
    final context = calloc<Uint8>(128);
    try {
      if (hash._init(context) != 0) _refuse();
      var total = 0;
      while (total < info.size) {
        final remaining = info.size - total;
        final count = _read(fd, _buffer, remaining > 65536 ? 65536 : remaining);
        if (count <= 0 || hash._update(context, _buffer, count) != 0) _refuse();
        total += count;
      }
      return hash._finish(context);
    } finally {
      calloc.free(context);
    }
  });
  void verifyRoots() {
    final current = _SourceFiles();
    try {
      for (final root in _roots.entries) {
        if (_info(current._root(root.key)).identity != root.value.identity) {
          _refuse();
        }
      }
    } finally {
      current.close();
    }
  }

  void close() {
    for (final root in _roots.values) {
      _close(root.fd);
    }
    _roots.clear();
    calloc.free(_buffer);
  }
}

Future<void> verifyDiagnosticWorkerSources({
  required DynamicLibrary image,
  required String sourceAnchor,
  required String buildRoot,
  required String sdkRoot,
  required String sdkId,
  required String packageConfig,
  required String nativeId,
  required String workerId,
  required String catalogId,
  required String mode,
}) async {
  if (!_identity(nativeId) ||
      !_identity(workerId) ||
      !_identity(catalogId) ||
      !_identity(sdkId) ||
      !const {'jit', 'kernel', 'aot'}.contains(mode) ||
      packageConfig !=
          p.join(sourceAnchor, _core, '.dart_tool/package_config.json')) {
    _refuse();
  }
  final files = _SourceFiles();
  try {
    final hash = DiagnosticSourceHash(image);
    final bytes = files.small(
      p.join(buildRoot, 'native'),
      'diagnostic-worker-inputs.json',
    );
    final manifest = _object(jsonDecode(utf8.decode(bytes)), {
      'schema',
      'kind',
      'worker_id',
      'catalog_id',
      'record',
    });
    if (manifest['schema'] is! int ||
        manifest['schema'] != 1 ||
        manifest['kind'] != 'standalone-worker' ||
        manifest['worker_id'] != workerId ||
        manifest['catalog_id'] != catalogId ||
        utf8.decode(bytes) != '${utf8.decode(_canonical(manifest))}\n') {
      _refuse();
    }
    final record = _object(manifest['record'], {
      'algorithm',
      'scope',
      'native_id',
      'mode',
      'catalog_id',
      'inputs',
      'producer_inputs',
      'sdk',
      'packages',
      'options',
      'external_imports',
    });
    if (record['algorithm'] != 'foresight-standalone-worker-v1' ||
        record['scope'] != 'components' ||
        record['native_id'] != nativeId ||
        record['mode'] != mode ||
        record['catalog_id'] != catalogId ||
        hash.bytes(_canonical(record)) != workerId) {
      _refuse();
    }
    final options = _object(record['options'], {
      'record_schema',
      'assertions',
      'compile',
    });
    if (options['record_schema'] is! int ||
        options['record_schema'] != 2 ||
        options['assertions'] != false) {
      _refuse();
    }
    final recipe = {
      'entry': _entry,
      'format': mode == 'jit'
          ? 'source'
          : mode == 'kernel'
          ? 'kernel'
          : 'exe',
      'packages': mode == 'jit' ? 'selected-public-config' : 'closed-snapshot',
      'environment': 'PATH=/usr/bin:/bin;LANG=C;LC_ALL=C;private-TMPDIR',
      'defines': 'fixed-public-worker-context-v1',
    };
    if (utf8.decode(_canonical(options['compile'])) !=
        utf8.decode(_canonical(recipe))) {
      _refuse();
    }
    final producers = _hashes(record['producer_inputs'], (name) {
      final path = _relative(name);
      if (!_producers.contains(path)) _refuse();
      return path;
    });
    if (producers.length != _producers.length) _refuse();
    final imports = record['external_imports'];
    if (imports is! List ||
        imports.length != _external.length ||
        imports.toSet().length != imports.length ||
        !imports.every(_external.contains)) {
      _refuse();
    }
    final source = _hashes(record['inputs'], _owned);
    if (!_exactSources.every(source.containsKey)) _refuse();
    final sdk = _object(record['sdk'], {
      'version',
      'revision',
      'inputs',
      'runtime_inputs',
    });
    if (sdk['version'] != '3.9.2' ||
        sdk['revision'] != 'a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd' ||
        hash.bytes(_canonical(sdk)) != sdkId) {
      _refuse();
    }
    final sdkInputs = _hashes(sdk['inputs'], _sdk);
    final runtime = _hashes(sdk['runtime_inputs'], _sdk);
    final expectedRuntime = {
      'version',
      'revision',
      'bin/dart',
      'bin/snapshots/kernel-service.dart.snapshot',
      ...sdkInputs.keys.where((name) => name.startsWith('lib/')),
    };
    if (runtime.length != expectedRuntime.length ||
        !expectedRuntime.every(runtime.containsKey) ||
        runtime.entries.any((e) => sdkInputs[e.key] != e.value)) {
      _refuse();
    }
    final packages = _object(record['packages'], _packages);
    final packageInputs = <String, Map<String, String>>{};
    for (final name in _packages) {
      final value = _object(packages[name], {'language', 'inputs'});
      if (value['language'] is! String) _refuse();
      packageInputs[name] = _hashes(value['inputs'], _packageInput);
      if (!packageInputs[name]!.containsKey('pubspec.yaml')) _refuse();
    }
    // All manifest paths are positively classified before any source/package
    // content read. Package config is public resolver metadata, read here only.
    final config = jsonDecode(
      utf8.decode(
        files.small(sourceAnchor, '$_core/.dart_tool/package_config.json'),
      ),
    );
    if (config is! Map<String, dynamic> ||
        config['configVersion'] is! int ||
        config['configVersion'] != 2 ||
        config['packages'] is! List) {
      _refuse();
    }
    final packageRoots = <String, String>{};
    final seen = <String>{};
    var core = false;
    for (final entry in config['packages'] as List) {
      if (entry is! Map<String, dynamic> ||
          entry['name'] is! String ||
          !seen.add(entry['name'] as String)) {
        _refuse();
      }
      final name = entry['name'] as String;
      if (name != 'foresight_core' && !_packages.contains(name)) continue;
      if (entry['packageUri'] != 'lib/' ||
          entry['rootUri'] is! String ||
          entry['languageVersion'] is! String) {
        _refuse();
      }
      final uri = Uri.parse(entry['rootUri'] as String);
      if (uri.hasAuthority && uri.host.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.scheme.isNotEmpty && uri.scheme != 'file') {
        _refuse();
      }
      final root = p.normalize(
        uri.scheme == 'file'
            ? uri.toFilePath()
            : p.join(p.dirname(packageConfig), uri.path),
      );
      if (_excluded(root) || !p.isAbsolute(root)) _refuse();
      if (name == 'foresight_core') {
        if (root != p.join(sourceAnchor, _core) ||
            entry['languageVersion'] != '3.8') {
          _refuse();
        }
        core = true;
      } else {
        final value = packages[name] as Map<String, dynamic>;
        if (p.basename(p.dirname(root)) != 'pub.dev' ||
            p.basename(p.dirname(p.dirname(root))) != 'hosted' ||
            !p.basename(root).startsWith('$name-') ||
            entry['languageVersion'] != value['language']) {
          _refuse();
        }
        packageRoots[name] = root;
      }
    }
    if (!core || packageRoots.length != _packages.length) _refuse();
    for (final entry in producers.entries) {
      if (files.hash(sourceAnchor, entry.key, hash) != entry.value) _refuse();
    }
    for (final entry in source.entries) {
      if (files.hash(sourceAnchor, entry.key, hash) != entry.value) _refuse();
    }
    for (final entry in runtime.entries) {
      if (files.hash(sdkRoot, entry.key, hash) != entry.value) _refuse();
    }
    for (final package in _packages) {
      for (final entry in packageInputs[package]!.entries) {
        if (files.hash(packageRoots[package]!, entry.key, hash) !=
            entry.value) {
          _refuse();
        }
      }
    }
    final catalog = {
      for (final name in [
        '$_diagnostics/code_locations.g.dart',
        '$_diagnostics/operations.g.dart',
      ])
        name: source[name],
    };
    if (catalog.values.any((value) => value == null) ||
        hash.bytes(_canonical(catalog)) != catalogId) {
      _refuse();
    }
    files.verifyRoots();
  } finally {
    files.close();
  }
}
