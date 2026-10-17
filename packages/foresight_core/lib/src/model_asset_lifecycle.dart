import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model_acquisition.dart';

/// Authenticated public production asset already supported by this distribution.
int referenceGenerationModelType(String digest) =>
    digest == '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c'
    ? 14
    : 0;

const referenceManagedModelTypes = {1, 2, 3, 4, 14, 15, 16, 17};
const referenceInferenceModelOrder = [16, 15, 14, 12, 8, 9];

class ModelAsset {
  const ModelAsset(this.metadata, this.path);
  final OnDeviceModelMetadata metadata;
  final String path;
}

/// Original ordered asset catalog, confined to this distribution's own root.
/// Imported models and private plaintext leases never belong to this tree.
class ModelAssetLifecycle {
  ModelAssetLifecycle({
    required this.root,
    required this.fetch,
    this.protectedPaths,
    this.onWarning,
    this.listFiles,
    this.deleteFile,
    this.renameFile,
  });
  final Directory root;
  final void Function(Object)? onWarning;
  final Stream<FileSystemEntity> Function(Directory)? listFiles;
  final Future<void> Function(File)? deleteFile;
  final Future<File> Function(File, String)? renameFile;
  final Future<ForesightSharedConfig> Function() fetch;
  final Iterable<String> Function()? protectedPaths;
  final _updates = StreamController<ModelAsset>.broadcast();
  Stream<ModelAsset> get updates => _updates.stream;
  List<ModelAsset> _assets = const [];
  List<ModelAsset> get assets => _assets;
  Future<void>? _refreshing;
  bool _closed = false;

  String pathFor(OnDeviceModelMetadata metadata) {
    String component(String value) {
      if (value.isEmpty ||
          value == '.' ||
          value == '..' ||
          value.contains('/') ||
          value.contains('\\') ||
          value.contains('\u0000')) {
        throw FormatException('Invalid distribution model path component');
      }
      return value;
    }

    return p.join(
      root.absolute.path,
      'models',
      metadata.modelType.toString(),
      component(metadata.version.isEmpty ? '1.0' : metadata.version),
      component(metadata.name),
    );
  }

  Future<void> refresh() {
    if (_closed) return Future.error(StateError('Model catalog is closed'));
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final config = await fetch();
    if (_closed) throw StateError('Model catalog is closed');
    final next = [
      for (final item in config.onDeviceModelMetadatas)
        ModelAsset(
          OnDeviceModelMetadata.fromBuffer(item.writeToBuffer())..freeze(),
          pathFor(item),
        ),
    ];
    final installed = <ModelAsset>[];
    for (final asset in next) {
      if (await _regularOwned(asset.path)) installed.add(asset);
    }
    _assets = List.unmodifiable(next);
    await cleanupObsoleteModels();
    if (!_closed) {
      for (final asset in installed) {
        _updates.add(asset);
      }
    }
  }

  /// First matching metadata is intentionally distinct from first existing file.
  ModelAsset? model(int type) {
    for (final asset in _assets) {
      if (asset.metadata.modelType == type) return asset;
    }
    return null;
  }

  Future<String?> localPath(int type) async {
    for (final asset in _assets) {
      if (asset.metadata.modelType == type && await _regularOwned(asset.path)) {
        return asset.path;
      }
    }
    final directory = Directory(p.join(root.absolute.path, 'models', '$type'));
    if (!await _safeDirectory(directory.path) || !await directory.exists()) {
      return null;
    }
    await for (final item in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (item is File &&
          !_temporary(item.path) &&
          await _regularOwned(item.path)) {
        return item.path;
      }
    }
    return null;
  }

  Future<ModelAsset?> inferenceModel({int? selectedType}) async {
    final types = [
      if (selectedType != null &&
          referenceInferenceModelOrder.contains(selectedType))
        selectedType,
      ...referenceInferenceModelOrder,
    ];
    for (final type in types) {
      // The original metadata lookup returns its first match even if absent.
      final selected = model(type);
      if (selected != null) return selected;
    }
    return null;
  }

  Future<void> cleanupObsoleteModels() async {
    final directory = Directory(p.join(root.absolute.path, 'models'));
    if (!await _safeDirectory(directory.path) || !await directory.exists()) {
      return;
    }
    final managed = _assets
        .where((a) => referenceManagedModelTypes.contains(a.metadata.modelType))
        .toList();
    final current = managed.map((a) => p.normalize(a.path)).toSet();
    final missing = <int>[];
    for (final asset in managed) {
      if (!await _regularOwned(asset.path)) {
        missing.add(asset.metadata.modelType);
      }
    }
    final protected = {
      for (final path in protectedPaths?.call() ?? const <String>[])
        p.normalize(p.absolute(path)),
    };
    await for (final item
        in (listFiles?.call(directory) ??
            directory.list(recursive: true, followLinks: false))) {
      if (item is! File ||
          _temporary(item.path) ||
          !await _regularOwned(item.path)) {
        continue;
      }
      final path = p.normalize(item.absolute.path);
      // Original String.contains examines the entire path, including ancestor
      // names. Preserve that broad predicate, rather than interpreting a type
      // directory or comparing versions numerically.
      if (current.contains(path) ||
          protected.contains(path) ||
          missing.any((type) => path.contains('$type'))) {
        continue;
      }
      try {
        if (deleteFile case final remove?) {
          await remove(item);
        } else {
          await item.delete();
        }
      } on FileSystemException catch (error) {
        (onWarning ?? stderr.writeln)(error);
      }
    }
  }

  /// Publish only an authenticated candidate; roll back filesystem adoption if
  /// the existing model registration/readiness operation rejects it.
  Future<void> publish(
    OnDeviceModelMetadata metadata,
    File candidate,
    Future<void> Function(File) adopt,
  ) async {
    final target = File(pathFor(metadata));
    if (!await _safeDirectory(target.parent.path)) {
      throw StateError('Unsafe model directory');
    }
    await target.parent.create(recursive: true);
    final kind = await FileSystemEntity.type(target.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.file) {
      throw StateError('Unsafe model destination');
    }
    final backup = await root.createTemp('.model-adoption-');
    final previous = File(p.join(backup.path, 'previous'));
    Future<File> rename(File file, String destination) =>
        renameFile?.call(file, destination) ?? file.rename(destination);
    var published = false;
    var accepted = false;
    Object? adoptionError;
    try {
      if (kind == FileSystemEntityType.file) {
        await rename(target, previous.path);
      }
      await rename(candidate, target.path);
      published = true;
      await adopt(target);
      accepted = true;
    } catch (error) {
      adoptionError = error;
      rethrow;
    } finally {
      if (!accepted) {
        try {
          if (published) await target.delete();
          if (await previous.exists()) await rename(previous, target.path);
        } catch (rollbackError) {
          // Do not run backup cleanup when restoring the only prior copy fails.
          throw StateError(
            'Model adoption failed ($adoptionError); rollback failed '
            '($rollbackError). Recovery files retained in ${backup.path}',
          );
        }
      }
      try {
        await backup.delete(recursive: true);
      } on FileSystemException catch (error) {
        if (!accepted) rethrow;
        (onWarning ?? stderr.writeln)(error);
      }
    }
  }

  bool _temporary(String path) =>
      path.endsWith('.downloading') || path.endsWith('.tmp');

  Future<bool> _safeDirectory(String path) async {
    final absoluteRoot = p.normalize(root.absolute.path);
    final absolute = p.normalize(p.absolute(path));
    if (absolute != absoluteRoot && !p.isWithin(absoluteRoot, absolute)) {
      return false;
    }
    var cursor = Directory(absolute);
    while (true) {
      final type = await FileSystemEntity.type(cursor.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        return false;
      }
      if (cursor.path == absoluteRoot) return true;
      cursor = cursor.parent;
    }
  }

  Future<bool> _regularOwned(String path) async =>
      await _safeDirectory(File(path).parent.path) &&
      await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file;

  Future<void> close() async {
    _closed = true;
    try {
      await _refreshing;
    } finally {
      await _updates.close();
    }
  }
}
