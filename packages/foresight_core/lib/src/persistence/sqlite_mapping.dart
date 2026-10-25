import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _DlInfo extends Struct {
  external Pointer<Utf8> filename;
  external Pointer<Void> image;
  external Pointer<Utf8> symbol;
  external Pointer<Void> address;
}

typedef _Dlopen = Pointer<Void> Function(Pointer<Utf8>, Int);
typedef _Dlsym = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _Dladdr = Int Function(Pointer<Void>, Pointer<_DlInfo>);

/// Original process-owned SQLite code mapping, never a connection/context.
/// Only capture at the entrypoint before database access creates a record.
final class SqliteMappingBootstrap {
  const SqliteMappingBootstrap._(
    this.path,
    this.progressAddress,
    this.imageAddress,
    this.sourceId,
  );
  final String path, sourceId;
  final int progressAddress, imageAddress;

  bool same(SqliteMappingBootstrap other) =>
      path == other.path &&
      progressAddress == other.progressAddress &&
      imageAddress == other.imageAddress &&
      sourceId == other.sourceId;
}

SqliteMappingBootstrap? _original;
SqliteMappingBootstrap? get boundSqliteMapping => _original;

void bindSqliteMapping(SqliteMappingBootstrap mapping) {
  final existing = _original;
  if (existing != null && !existing.same(mapping)) {
    throw StateError('Cannot replace the original SQLite mapping');
  }
  _original = mapping;
}

int _imageFor(int address) {
  final info = calloc<_DlInfo>();
  try {
    final dladdr = DynamicLibrary.process()
        .lookupFunction<_Dladdr, int Function(Pointer<Void>, Pointer<_DlInfo>)>(
          'dladdr',
        );
    if (dladdr(Pointer<Void>.fromAddress(address), info) == 0 ||
        info.ref.image == nullptr) {
      throw StateError('Cannot identify the original SQLite mapping');
    }
    return info.ref.image.address;
  } finally {
    calloc.free(info);
  }
}

/// A NOLOAD-only reference never maps a replacement image. It is retained for
/// process lifetime, including VM loss. No ordinary dlclose accompanies it.
void _retainOriginal(SqliteMappingBootstrap mapping) {
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw UnsupportedError('Original SQLite mapping requires glibc or dyld');
  }
  final system = DynamicLibrary.process();
  final dlopen = system
      .lookupFunction<_Dlopen, Pointer<Void> Function(Pointer<Utf8>, int)>(
        'dlopen',
      );
  final dlsym = system
      .lookupFunction<
        _Dlsym,
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
      >('dlsym');
  final path = mapping.path.toNativeUtf8();
  final symbol = 'sqlite3_progress_handler'.toNativeUtf8();
  try {
    // RTLD_NOW=2 on glibc/dyld; RTLD_NOLOAD=4 on glibc, 0x10 on dyld.
    final handle = dlopen(path, 2 | (Platform.isMacOS ? 0x10 : 4));
    if (handle == nullptr ||
        dlsym(handle, symbol).address != mapping.progressAddress ||
        _imageFor(mapping.progressAddress) != mapping.imageAddress) {
      throw StateError('The original SQLite mapping is unavailable');
    }
  } finally {
    calloc.free(path);
    calloc.free(symbol);
  }
}

/// Entry-point only: resolve the actual code's filename before ANY DB locks,
/// freeze its physical path and register that canonical alias in the loader.
SqliteMappingBootstrap captureSqliteMapping(
  DynamicLibrary library,
  String sourceId,
) {
  final progress = library.lookup<Void>('sqlite3_progress_handler').address;
  final info = calloc<_DlInfo>();
  try {
    final dladdr = DynamicLibrary.process()
        .lookupFunction<_Dladdr, int Function(Pointer<Void>, Pointer<_DlInfo>)>(
          'dladdr',
        );
    if (dladdr(Pointer<Void>.fromAddress(progress), info) == 0 ||
        info.ref.filename == nullptr ||
        info.ref.image == nullptr) {
      throw StateError('Cannot identify the original SQLite mapping');
    }
    final path = File(
      info.ref.filename.toDartString(),
    ).resolveSymbolicLinksSync();
    if (!File(path).isAbsolute) {
      throw StateError('The original SQLite mapping has no absolute path');
    }
    final mapping = SqliteMappingBootstrap._(
      path,
      progress,
      info.ref.image.address,
      sourceId,
    );
    _retainOriginal(mapping);
    // This happens only at the entrypoint before connections. Register the
    // canonical name while it still identifies the same original loaded code.
    final canonical = DynamicLibrary.open(path);
    if (canonical.lookup<Void>('sqlite3_progress_handler').address !=
        progress) {
      throw StateError('Cannot retain the original SQLite mapping');
    }
    return mapping;
  } finally {
    calloc.free(info);
  }
}

/// Worker path: no environment, basename search, realpath or install alias.
/// Refuse before a normal open unless the frozen original is already mapped.
DynamicLibrary openOriginalSqliteMapping(SqliteMappingBootstrap mapping) {
  _retainOriginal(mapping);
  // The entrypoint already opened this exact canonical name before DB locks.
  // Dart's DynamicLibrary.open contract loads a given path only once across
  // isolates; this acquires that registered original, never a discovery alias.
  final library = DynamicLibrary.open(mapping.path);
  if (library.lookup<Void>('sqlite3_progress_handler').address !=
          mapping.progressAddress ||
      _imageFor(mapping.progressAddress) != mapping.imageAddress) {
    throw StateError('Cannot replace the original SQLite mapping');
  }
  return library;
}
