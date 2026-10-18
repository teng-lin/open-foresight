import 'model_pins.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class GemmaModel {
  final String name, repository, revision, filename, digest;
  final int bytes, minimumMemoryGb;
  const GemmaModel(
    this.name,
    this.repository,
    this.revision,
    this.filename,
    this.digest,
    this.bytes,
    this.minimumMemoryGb,
  );
  Uri get url =>
      Uri.https('huggingface.co', '/$repository/resolve/$revision/$filename');
  String get directory =>
      '${filename.replaceAll('.litertlm', '')}-${digest.substring(0, 12)}';
}

typedef LocalModelFinder =
    Future<File?> Function(
      GemmaModel model,
      Directory root, {
      Map<String, Object?>? registration,
    });

/// Every availability decision authenticates bytes, including equal-size files.
Future<bool> verifyModelFile(File file, String digest, int bytes) async {
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() != bytes) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() == digest;
  } on FileSystemException {
    return false;
  }
}

Future<File?> localModelFile(
  GemmaModel model,
  Directory root, {
  Map<String, Object?>? registration,
}) async {
  final candidates = [
    if (registration?['digest'] == model.digest)
      File(registration!['path'] as String),
    File('${root.path}/${model.directory}/${model.filename}'),
  ];
  for (final file in candidates) {
    if (await verifyModelFile(file, model.digest, model.bytes)) return file;
  }
  return null;
}

/// Available bytes on the filesystem that owns the model cache. Unknown space
/// is an error so an unbounded multi-GB download cannot start accidentally.
Future<int> availableModelDiskBytes(Directory directory) async {
  final result = await Process.run(
    Platform.isMacOS ? '/bin/df' : '/usr/bin/df',
    ['-Pk', directory.path],
  );
  final rows = (result.stdout as String).trim().split('\n');
  final columns = rows.last.trim().split(RegExp(r'\s+'));
  final blocks = columns.length >= 6 ? int.tryParse(columns[3]) : null;
  if (result.exitCode != 0 || blocks == null || blocks < 0) {
    throw StateError('Unable to check free disk space for model download.');
  }
  return blocks * 1024;
}

// Pinned public artifact metadata, independently verified 2026-10-13. These
// are not assumed identical to Foresight's encrypted Mac service artifacts.
GemmaModel modelFromPin(String filename) {
  final pin = modelPin(filename);
  return GemmaModel(
    pin['name'] as String,
    pin['repository'] as String,
    pin['revision'] as String,
    pin['filename'] as String,
    pin['sha256'] as String,
    pin['bytes'] as int,
    pin['minimumMemoryGb'] as int,
  );
}

final gemmaModels = [
  modelFromPin('gemma-4-12B-it.litertlm'),
  modelFromPin('gemma-4-E4B-it.litertlm'),
  modelFromPin('gemma-4-E2B-it.litertlm'),
];

final embeddingGemmaModel = modelFromPin('embeddinggemma-2-740m.litertlm');

enum ModelDownloadPhase {
  checkingCache,
  verifyingCache,
  downloading,
  verifyingDownload,
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'Model download cancelled';
}

/// Persistent range parts survive connection errors and cancellation. Only
/// authenticated bytes replace a managed-cache file; registered external files
/// remain untouched. A cache lock prevents concurrent writers sharing staging.
class GemmaDownload {
  static final _activePaths = <String>{};
  final HttpClient Function() createClient;
  final Future<int> Function(Directory) availableBytes;
  final Duration timeout;
  final int parallelism, rangeThreshold;
  HttpClient? _client;
  bool _cancelled = false, _active = false;
  GemmaDownload({
    HttpClient Function()? createClient,
    Future<int> Function(Directory)? availableBytes,
    this.timeout = const Duration(seconds: 30),
    this.parallelism = 4,
    this.rangeThreshold = 64 * 1024 * 1024,
  }) : createClient = createClient ?? (() => HttpClient()),
       availableBytes = availableBytes ?? availableModelDiskBytes;
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _check() {
    if (_cancelled) throw const ModelDownloadCancelled();
  }

  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int received, int total)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  }) async {
    if (_active || _cancelled) {
      throw StateError('Download is active or cancelled');
    }
    _active = true;
    RandomAccessFile? lock;
    String? ownedPath;
    bool locked = false;
    File? assembly;
    try {
      if (parallelism < 1 || parallelism > 8 || rangeThreshold < 0) {
        throw ArgumentError('Invalid download parallelism');
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(model.digest) ||
          model.bytes <= 0 ||
          model.filename.contains('/') ||
          model.filename.contains('\\') ||
          !(model.filename.endsWith('.litertlm') ||
              model.filename.endsWith('.bin'))) {
        throw ArgumentError('Invalid model metadata');
      }
      phase?.call(ModelDownloadPhase.checkingCache);
      final directory = Directory('${root.path}/${model.directory}');
      final destination = File('${directory.path}/${model.filename}');
      for (final candidate in [
        if (existingFile != null) existingFile,
        destination,
      ]) {
        if (FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
            FileSystemEntityType.file) {
          phase?.call(ModelDownloadPhase.verifyingCache);
          if (await verifyModelFile(candidate, model.digest, model.bytes)) {
            _check();
            progress?.call(model.bytes, model.bytes);
            return candidate;
          }
        }
      }
      _check();
      final destinationType = FileSystemEntity.typeSync(
        destination.path,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound &&
          destinationType != FileSystemEntityType.file) {
        throw StateError('The model cache destination must be a regular file.');
      }
      await directory.create(recursive: true);
      final canonical = await directory.resolveSymbolicLinks();
      if (!_activePaths.add(canonical)) {
        throw StateError('A download of this model is already active.');
      }
      ownedPath = canonical;
      lock = await File(
        '${directory.path}/.download.lock',
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      locked = true;
      _check();
      // A writer may have finished while this request waited for its lock.
      if (await verifyModelFile(destination, model.digest, model.bytes)) {
        return destination;
      }
      final temporary = Directory('${directory.path}/.download');
      await temporary.create();
      final metadata = File('${temporary.path}/identity.json');
      final identity = jsonEncode({
        'digest': model.digest,
        'bytes': model.bytes,
        'parallelism': parallelism,
        'rangeThreshold': rangeThreshold,
      });
      if (await metadata.exists() &&
          await metadata.readAsString() != identity) {
        await temporary.delete(recursive: true);
        await temporary.create();
      }
      await metadata.writeAsString(identity, flush: true);
      final staleAssembly = File('${temporary.path}/assembled.part');
      if (await staleAssembly.exists()) await staleAssembly.delete();
      final whole = File('${temporary.path}/model.part');
      final count = whole.existsSync() || model.bytes < rangeThreshold
          ? 1
          : parallelism;
      final block = (model.bytes + count - 1) ~/ count;
      final parts = <File>[];
      final ranges = <(int, int)>[];
      var retained = 0;
      for (
        var index = 0;
        index < count && index * block < model.bytes;
        index++
      ) {
        final start = index * block;
        final end = start + block - 1 < model.bytes
            ? start + block - 1
            : model.bytes - 1;
        final part = count == 1
            ? whole
            : File('${temporary.path}/range-$index.part');
        final type = FileSystemEntity.typeSync(part.path, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.notFound) {
          throw StateError('Invalid download staging file.');
        }
        if (part.existsSync() && part.lengthSync() > end - start + 1) {
          await part.delete();
        }
        retained += part.existsSync() ? part.lengthSync() : 0;
        parts.add(part);
        ranges.add((start, end));
      }
      // Parallel range assembly needs a second copy until verification finishes.
      // Include existing partials and leave headroom for filesystem metadata.
      final required =
          model.bytes -
          retained +
          (count > 1 ? model.bytes : 0) +
          16 * 1024 * 1024;
      final available = await availableBytes(directory);
      if (available < required) {
        throw StateError(
          'Not enough free disk space. Model setup needs ${(required / 1e9).toStringAsFixed(2)} GB more free space.',
        );
      }
      _check();
      phase?.call(ModelDownloadPhase.downloading);
      final client = _client = createClient();
      client.autoUncompress = false;
      client.connectionTimeout = timeout;
      final uri = sourceForTesting ?? model.url;
      var received = retained;
      progress?.call(received, model.bytes);
      void report(int bytes) {
        received += bytes;
        progress?.call(received, model.bytes);
      }

      Future<void> transfer(
        File part,
        int start,
        int end, {
        HttpClientResponse? initial,
      }) async {
        var offset = part.existsSync() ? part.lengthSync() : 0;
        if (offset == end - start + 1) return;
        final response =
            initial ??
            await _response(
              client,
              uri,
              range: offset > 0 || count > 1
                  ? 'bytes=${start + offset}-$end'
                  : null,
            );
        if (response.statusCode == 206) {
          if (response.headers.value(HttpHeaders.contentRangeHeader) !=
              'bytes ${start + offset}-$end/${model.bytes}') {
            throw StateError('Model server returned an invalid byte range');
          }
        } else if (response.statusCode == 200 &&
            start == 0 &&
            end == model.bytes - 1) {
          // A server without Range support restarts the owned partial safely.
          if (offset > 0) {
            if (await availableBytes(directory) <
                model.bytes + 16 * 1024 * 1024) {
              throw StateError(
                'Not enough free disk space to restart this download.',
              );
            }
            received -= offset;
            offset = 0;
          }
        } else {
          throw StateError(
            'Model download server returned an invalid response',
          );
        }
        final sink = part.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        try {
          await _body(response, sink, end - start + 1 - offset, report);
        } finally {
          await sink.close();
        }
      }

      if (count > 1) {
        final firstLength = parts.first.existsSync()
            ? parts.first.lengthSync()
            : 0;
        HttpClientResponse? first;
        if (firstLength < ranges.first.$2 + 1) {
          first = await _response(
            client,
            uri,
            range: 'bytes=$firstLength-${ranges.first.$2}',
          );
        }
        if (first?.statusCode == 200) {
          // The server ignored Range: retain a resumable sequential partial.
          received = 0;
          final sink = whole.openWrite();
          try {
            await _body(first!, sink, model.bytes, report);
          } finally {
            await sink.close();
          }
          assembly = whole;
        } else {
          await Future.wait([
            for (var index = 0; index < parts.length; index++)
              transfer(
                parts[index],
                ranges[index].$1,
                ranges[index].$2,
                initial: index == 0 ? first : null,
              ),
          ]);
          assembly = File('${temporary.path}/assembled.part');
          final sink = assembly.openWrite();
          try {
            for (final part in parts) {
              _check();
              await sink.addStream(part.openRead());
            }
          } finally {
            await sink.close();
          }
        }
      } else {
        await transfer(whole, 0, model.bytes - 1);
        assembly = whole;
      }
      _check();
      phase?.call(ModelDownloadPhase.verifyingDownload);
      if (!await verifyModelFile(assembly, model.digest, model.bytes)) {
        // A complete corrupt transfer cannot be resumed into a valid file.
        await temporary.delete(recursive: true);
        assembly = null;
        throw StateError('Model download failed size or hash verification');
      }
      _check();
      // POSIX rename atomically replaces only after complete authentication.
      await assembly.rename(destination.path);
      assembly = null;
      await temporary.delete(recursive: true);
      return destination;
    } catch (failure) {
      if (_cancelled) throw const ModelDownloadCancelled();
      if (failure is HttpException ||
          failure is SocketException ||
          failure is HandshakeException ||
          failure is TimeoutException) {
        throw StateError(
          'Model transfer interrupted. Retry to resume the saved download.',
        );
      }
      rethrow;
    } finally {
      _client?.close(force: true);
      _client = null;
      // Assembled output is disposable; range parts remain available to retry.
      if (assembly?.path.endsWith('/assembled.part') == true &&
          assembly!.existsSync()) {
        await assembly.delete();
      }
      try {
        if (lock != null) {
          if (locked) await lock.unlock();
          await lock.close();
        }
      } finally {
        if (ownedPath != null) _activePaths.remove(ownedPath);
        _active = false;
      }
    }
  }

  Future<HttpClientResponse> _response(
    HttpClient client,
    Uri source, {
    String? range,
  }) async {
    var uri = source;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        throw StateError('Model downloads require HTTPS');
      }
      _check();
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || redirects == 5) {
        throw StateError('Model download redirect failed');
      }
      uri = uri.resolve(location);
      await response.listen((_) {}).cancel();
    }
    throw StateError('Model download redirect failed');
  }

  Future<void> _body(
    HttpClientResponse response,
    IOSink sink,
    int expected,
    void Function(int) progress,
  ) async {
    if (response.contentLength >= 0 && response.contentLength != expected) {
      throw StateError('Model download size does not match');
    }
    var received = 0, pending = 0;
    await for (final chunk in response.timeout(timeout)) {
      _check();
      received += chunk.length;
      if (received > expected) throw StateError('Model download is too large');
      sink.add(chunk);
      pending += chunk.length;
      if (pending >= 1024 * 1024) {
        await sink.flush();
        pending = 0;
      }
      progress(chunk.length);
    }
    if (received != expected) {
      throw const HttpException('Model download was incomplete');
    }
  }
}

int physicalMemoryGb() => systemMemoryGb();
